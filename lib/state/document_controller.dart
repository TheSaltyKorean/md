import 'dart:async';
import 'dart:io';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:watcher/watcher.dart';

import '../models/editor_mode.dart';

/// A single open document (one tab). Exposes the document in two synchronised
/// representations:
///
///  * [editorState] — the AppFlowy block model used by the WYSIWYG editor.
///  * [sourceController] — the raw Markdown text used by the split/source view.
///
/// It watches the backing file on disk (desktop) and reports external changes
/// (a `git pull`, a sync client, another editor). Whether those reload
/// automatically is decided by [isAutoReloadEnabled], which the owning
/// [WorkspaceController] supplies (the setting is global, not per-tab).
///
/// File access is deliberately **lock-free**: we only ever `readAsString` /
/// `writeAsString` (open-write/read-close immediately) and never hold an open
/// handle, and we watch the *directory* via [FileWatcher] rather than keeping
/// the file open — so an external tool (git) can freely replace the file.
class DocumentController extends ChangeNotifier {
  DocumentController({required this.isAutoReloadEnabled}) {
    _initBlank();
  }

  /// Supplied by the workspace; returns the current global auto-reload setting.
  final bool Function() isAutoReloadEnabled;

  // --- Document identity ------------------------------------------------------
  String? _filePath;
  String? get filePath => _filePath;

  bool _dirty = false;
  bool get isDirty => _dirty;

  /// Display name for documents with no re-writable path (e.g. mobile opens).
  String? _displayName;

  String get title =>
      _filePath != null ? p.basename(_filePath!) : (_displayName ?? 'Untitled');

  /// A brand-new, never-loaded/saved tab — safe to replace when opening a file
  /// rather than stacking an empty tab. Cleared once any content is loaded,
  /// edited, or saved (even a pathless mobile save).
  bool _pristine = true;
  bool get isPristine =>
      _pristine && _filePath == null && _displayName == null && !_dirty;

  // --- View mode (per document) ----------------------------------------------
  // Documents open in read-only Preview by default; the user switches to Edit
  // (WYSIWYG) or Split to make changes.
  EditorMode _mode = EditorMode.preview;
  EditorMode get mode => _mode;

  // --- Representations --------------------------------------------------------
  late EditorState editorState;
  final TextEditingController sourceController = TextEditingController();

  int _editorEpoch = 0;
  int get editorEpoch => _editorEpoch;

  StreamSubscription<dynamic>? _txnSub;
  bool _suppressDirty = false;

  // --- External-change handling ----------------------------------------------
  String? _lastSyncedContent;
  StreamSubscription<WatchEvent>? _watchSub;

  String? _pendingExternalContent;
  String? get pendingExternalContent => _pendingExternalContent;
  bool get hasExternalConflict => _pendingExternalContent != null;

  bool _autoReloadNotice = false;
  bool takeAutoReloadNotice() {
    if (!_autoReloadNotice) return false;
    _autoReloadNotice = false;
    return true;
  }

  bool get _canWatch =>
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  void _initBlank() {
    _setEditorState(EditorState.blank(withInitialText: true));
    sourceController.text = '';
    sourceController.addListener(_onSourceChanged);
  }

  void _setEditorState(EditorState state) {
    _txnSub?.cancel();
    editorState = state;
    _editorEpoch++;
    _txnSub = editorState.transactionStream.listen((_) {
      if (!_suppressDirty) _markDirty();
    });
  }

  void _onSourceChanged() {
    // Both source modes (split and raw) edit [sourceController] directly.
    if (_mode.isSource && !_suppressDirty) _markDirty();
  }

  void _markDirty() {
    _pristine = false;
    if (_dirty) return;
    _dirty = true;
    notifyListeners();
  }

  // --- Public commands --------------------------------------------------------

  /// Load [content] into both representations. When [markDirty] is true (used by
  /// tab tear-off handoff), the document is flagged as having unsaved edits and
  /// the on-disk version is used as the external-change baseline so those edits
  /// aren't silently lost.
  void loadMarkdown(
    String content, {
    String? path,
    String? displayName,
    bool markDirty = false,
  }) {
    _suppressDirty = true;
    sourceController.text = content;
    _setEditorState(EditorState(document: markdownToDocument(content)));
    _filePath = path;
    _displayName = displayName;
    _pristine = false;
    _suppressDirty = false;
    _pendingExternalContent = null;
    _startWatching(path);
    if (markDirty) {
      _dirty = true;
      String? disk;
      if (path != null) {
        try {
          disk = File(path).readAsStringSync();
        } catch (_) {/* file may not exist */}
      }
      _lastSyncedContent = disk ?? content;
    } else {
      _dirty = false;
      _lastSyncedContent = content;
    }
    notifyListeners();
  }

  void markSaved(String path, String content) {
    _filePath = path;
    _dirty = false;
    _lastSyncedContent = content;
    _pendingExternalContent = null;
    _startWatching(path);
    notifyListeners();
  }

  /// Mark the document saved when there is no re-writable path to track (e.g.
  /// a mobile Save As that wrote via the platform picker). Clears the dirty
  /// flag but leaves [filePath] unchanged so the next save re-prompts.
  void markCleanSaved(String content) {
    _dirty = false;
    _pristine = false;
    _lastSyncedContent = content;
    notifyListeners();
  }

  void setMode(EditorMode next) {
    if (next == _mode) return;
    _suppressDirty = true;

    final leavingWysiwyg = _mode == EditorMode.wysiwyg;
    final enteringWysiwyg = next == EditorMode.wysiwyg;

    if (leavingWysiwyg) {
      sourceController.text = documentToMarkdown(editorState.document);
    }
    if (enteringWysiwyg) {
      _setEditorState(
        EditorState(document: markdownToDocument(sourceController.text)),
      );
    }

    _mode = next;
    _suppressDirty = false;
    notifyListeners();
  }

  String currentMarkdown() {
    if (_mode == EditorMode.wysiwyg) {
      return documentToMarkdown(editorState.document);
    }
    return sourceController.text;
  }

  String get suggestedFileName => _filePath != null
      ? p.basename(_filePath!)
      : (_displayName ?? 'untitled.md');

  // --- External-change resolution (called by the UI) --------------------------

  void applyExternalChange() {
    final content = _pendingExternalContent ?? _lastSyncedContent;
    if (content == null) return;
    final path = _filePath;
    _pendingExternalContent = null;
    loadMarkdown(content, path: path);
    _autoReloadNotice = true;
    notifyListeners();
  }

  void keepMineAfterExternalChange() {
    _pendingExternalContent = null;
    // The buffer now diverges from the (advanced) on-disk baseline, so mark it
    // dirty — otherwise it would look clean and the kept version could be lost
    // on close without a prompt.
    _dirty = true;
    notifyListeners();
  }

  /// Called by the workspace when auto-reload is switched on, to resolve a
  /// pending conflict that no longer needs the user (no local edits).
  void resolveIfSafe() {
    if (_pendingExternalContent != null && !_dirty) applyExternalChange();
  }

  // --- File watching ----------------------------------------------------------

  void _startWatching(String? path) {
    _stopWatching();
    if (path == null || !_canWatch) return;
    if (!File(path).existsSync()) return;
    try {
      // FileWatcher watches the file via directory events / polling — it does
      // not hold the file open, so git can replace it freely.
      _watchSub = FileWatcher(path).events.listen(
            (_) => _onFileChanged(path),
            onError: (_) {},
          );
    } catch (_) {
      // Some platforms/paths don't support watching; degrade silently.
    }
  }

  void _stopWatching() {
    _watchSub?.cancel();
    _watchSub = null;
  }

  /// Stop watching the file (used on app shutdown to release the watcher).
  void stopWatching() => _stopWatching();

  Future<void> _onFileChanged(String path) async {
    if (path != _filePath) return;
    String disk;
    try {
      disk = await File(path).readAsString();
    } catch (_) {
      return; // file briefly missing mid-replace, etc.
    }
    if (disk == _lastSyncedContent) return; // echo of our own write / no-op
    _lastSyncedContent = disk;

    if (isAutoReloadEnabled() && !_dirty) {
      final keepPath = _filePath;
      _pendingExternalContent = null;
      loadMarkdown(disk, path: keepPath);
      _autoReloadNotice = true;
      notifyListeners();
    } else {
      _pendingExternalContent = disk;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _watchSub?.cancel();
    _txnSub?.cancel();
    sourceController.removeListener(_onSourceChanged);
    sourceController.dispose();
    super.dispose();
  }
}
