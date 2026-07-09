import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart' show Offset;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/editor_mode.dart';
import '../services/session_service.dart';
import 'document_controller.dart';

/// A document to restore, with its content resolved (disk read done) before
/// the workspace is mutated. Internal to [WorkspaceController.restoreSession].
class _RestoredDoc {
  _RestoredDoc({
    required this.path,
    required this.name,
    required this.content,
    required this.markDirty,
    required this.mode,
  });

  final String? path;
  final String? name;
  final String content;
  final bool markDirty;
  final String? mode;
}

/// A tab in the workspace strip: an editable document or a print preview.
sealed class WorkspaceTab {}

/// A regular editable Markdown document.
class DocumentTab extends WorkspaceTab {
  DocumentTab(this.doc);

  final DocumentController doc;
}

/// A print / PDF-export preview opened from the print action. Holds a snapshot
/// of the Markdown at the moment it was opened; printing the same document
/// again refreshes the snapshot in place (bumping [epoch]).
class PrintPreviewTab extends WorkspaceTab {
  PrintPreviewTab({
    required this.markdown,
    required this.title,
    required this.docPath,
    this.sourceKey,
  });

  String markdown;
  String title;
  String? docPath;

  /// Identity of the source document (its controller), used to match a
  /// preview to its origin when the document has no path (unsaved/pathless
  /// docs can share titles). Cleared when the source tab closes so an orphan
  /// preview is never hijacked by a different document later.
  Object? sourceKey;

  /// Bumped on refresh so the preview widget rebuilds from the new snapshot.
  int epoch = 0;
}

/// Owns the set of open tabs (documents and print previews), the active tab,
/// and the global auto-reload setting. Each document tab is its own
/// [DocumentController].
class WorkspaceController extends ChangeNotifier {
  WorkspaceController(this._prefs, {SessionStore? sessionStore})
      : _sessionStore = sessionStore {
    _autoReload = _prefs.getBool(_autoReloadKey) ?? true;
    final tx = _prefs.getDouble(_toolbarXKey);
    final ty = _prefs.getDouble(_toolbarYKey);
    if (tx != null && ty != null) _toolbarOffset = Offset(tx, ty);
    _tabs.add(DocumentTab(_newDoc()));
    _activeIndex = 0;
    // Persist the session (debounced) whenever tabs, the active tab, or any
    // open document changes, so a restart/update reopens where we left off.
    if (_sessionStore != null) addListener(_scheduleSessionSave);
  }

  static const _autoReloadKey = 'auto_reload';
  static const _toolbarXKey = 'format_toolbar_x';
  static const _toolbarYKey = 'format_toolbar_y';
  static const _sessionDebounce = Duration(milliseconds: 1200);

  final SharedPreferences _prefs;

  /// Where the open-tabs session is stored (null disables session
  /// persistence — e.g. in tests that don't exercise it).
  final SessionStore? _sessionStore;
  Timer? _sessionTimer;

  final List<WorkspaceTab> _tabs = [];
  int _activeIndex = 0;
  bool _autoReload = true;

  /// Persisted position of the floating format toolbar (null until first moved,
  /// in which case it defaults to the top-left dock).
  Offset? _toolbarOffset;
  Offset? get toolbarOffset => _toolbarOffset;

  /// All in-flight persistence writes (UI callbacks don't await them), chained
  /// so rapid repeated toggles are all drained before an immediate app close.
  Future<void> _pending = Future.value();
  Future<void> get pendingWrites => _pending;

  /// Serialise persistence: [op] (which starts the write) is not invoked until
  /// the previous write completes, so rapid toggles persist in order.
  Future<void> _track(Future<void> Function() op) {
    final result = _pending.then((_) => op(), onError: (_) => op());
    _pending = result.catchError((_) {});
    return result;
  }

  List<WorkspaceTab> get tabs => List.unmodifiable(_tabs);

  /// The open editable documents (print previews excluded).
  List<DocumentController> get documents => List.unmodifiable([
        for (final tab in _tabs)
          if (tab is DocumentTab) tab.doc
      ]);

  int get activeIndex => _activeIndex;
  WorkspaceTab get activeTab => _tabs[_activeIndex];

  /// The active tab's document, or null when a print preview is active.
  DocumentController? get activeDocument => switch (_tabs[_activeIndex]) {
        DocumentTab(:final doc) => doc,
        PrintPreviewTab() => null,
      };

  bool get autoReload => _autoReload;

  DocumentController _newDoc() {
    final doc = DocumentController(isAutoReloadEnabled: () => _autoReload);
    doc.addListener(_relay);
    // Content edits don't re-fire the dirty notification once already dirty,
    // so listen to the per-edit tick to keep the session debounce armed.
    doc.contentTick.addListener(_scheduleSessionSave);
    return doc;
  }

  void _detachDoc(DocumentController doc) {
    doc.removeListener(_relay);
    doc.contentTick.removeListener(_scheduleSessionSave);
    doc.dispose();
  }

  // Relay any open document's changes (e.g. dirty flag, title) so the tab strip
  // and body rebuild.
  void _relay() => notifyListeners();

  // --- Tab commands -----------------------------------------------------------

  /// Add a fresh empty document and focus it.
  void newDocument() {
    _tabs.add(DocumentTab(_newDoc()));
    _activeIndex = _tabs.length - 1;
    notifyListeners();
  }

  /// Open a loaded document. If the same file is already open, just focus it;
  /// otherwise add a new tab. If the only open tab is a pristine "Untitled"
  /// document, replace it instead of stacking an empty tab.
  void openDocument(
    String content, {
    String? path,
    String? displayName,
    bool markDirty = false,
  }) {
    // For a clean open of an already-open file, just focus it. (Handoffs with
    // unsaved edits always open their own tab.)
    if (path != null && !markDirty) {
      final existing =
          _tabs.indexWhere((t) => t is DocumentTab && t.doc.filePath == path);
      if (existing >= 0) {
        _activeIndex = existing;
        notifyListeners();
        return;
      }
    }

    // If the only open *document* is a pristine "Untitled", replace it rather
    // than stacking an empty tab — even when print previews are also open.
    final docTabs = [
      for (final t in _tabs)
        if (t is DocumentTab) t
    ];
    if (docTabs.length == 1 && docTabs.first.doc.isPristine) {
      docTabs.first.doc.loadMarkdown(content,
          path: path, displayName: displayName, markDirty: markDirty);
      _activeIndex = _tabs.indexOf(docTabs.first);
      notifyListeners();
      return;
    }

    final doc = _newDoc()
      ..loadMarkdown(content,
          path: path, displayName: displayName, markDirty: markDirty);
    _tabs.add(DocumentTab(doc));
    _activeIndex = _tabs.length - 1;
    notifyListeners();
  }

  /// Open (or refresh) a print-preview tab for the given document snapshot.
  /// A preview of the same source — matched by file path **or** by document
  /// identity ([sourceKey]) — is reused: its snapshot is replaced and the tab
  /// focused, so printing twice never stacks duplicate previews. Identity
  /// matching keeps distinct unsaved documents (which can share a title like
  /// "Untitled") on separate previews, and lets a preview follow its document
  /// through Save As (the stored path is updated on refresh).
  void openPrintPreview({
    required String markdown,
    required String title,
    required String? docPath,
    Object? sourceKey,
  }) {
    final existing = _tabs.indexWhere((t) =>
        t is PrintPreviewTab &&
        ((docPath != null && t.docPath == docPath) ||
            (t.sourceKey != null && identical(t.sourceKey, sourceKey))));
    if (existing >= 0) {
      final tab = _tabs[existing] as PrintPreviewTab;
      tab
        ..markdown = markdown
        ..title = title
        ..docPath = docPath
        ..sourceKey = sourceKey
        ..epoch += 1;
      _activeIndex = existing;
    } else {
      _tabs.add(PrintPreviewTab(
          markdown: markdown,
          title: title,
          docPath: docPath,
          sourceKey: sourceKey));
      _activeIndex = _tabs.length - 1;
    }
    notifyListeners();
  }

  void select(int index) {
    if (index < 0 || index >= _tabs.length || index == _activeIndex) return;
    _activeIndex = index;
    notifyListeners();
  }

  /// Move the tab at [oldIndex] to [newIndex] (drag-to-reorder), keeping the
  /// same tab active.
  void reorder(int oldIndex, int newIndex) {
    if (oldIndex < 0 || oldIndex >= _tabs.length) return;
    if (oldIndex == newIndex) return;
    final active = _tabs[_activeIndex];
    final tab = _tabs.removeAt(oldIndex);
    // Removing a lower index shifts the target left by one, so insert before the
    // highlighted tab in both directions.
    final target =
        (oldIndex < newIndex ? newIndex - 1 : newIndex).clamp(0, _tabs.length);
    _tabs.insert(target, tab);
    _activeIndex = _tabs.indexOf(active);
    notifyListeners();
  }

  /// Close the tab at [index]. Always keeps at least one tab open.
  void closeAt(int index) {
    if (index < 0 || index >= _tabs.length) return;
    final tab = _tabs.removeAt(index);
    if (tab is DocumentTab) {
      _detachDoc(tab.doc);
      // Orphan any preview of this document: don't retain the disposed
      // controller, and don't let a later pathless document adopt the tab.
      for (final t in _tabs) {
        if (t is PrintPreviewTab && identical(t.sourceKey, tab.doc)) {
          t.sourceKey = null;
        }
      }
    }

    if (_tabs.isEmpty) {
      _tabs.add(DocumentTab(_newDoc()));
      _activeIndex = 0;
    } else if (_activeIndex >= _tabs.length) {
      _activeIndex = _tabs.length - 1;
    } else if (index < _activeIndex) {
      _activeIndex -= 1;
    }
    notifyListeners();
  }

  // --- Global settings --------------------------------------------------------

  /// Persist the floating format toolbar's position. Fire-and-forget from the
  /// drag handler; not notified (the toolbar tracks its own live position).
  void setToolbarOffset(Offset offset) {
    _toolbarOffset = offset;
    _track(() => Future.wait([
          _prefs.setDouble(_toolbarXKey, offset.dx),
          _prefs.setDouble(_toolbarYKey, offset.dy),
        ]));
  }

  Future<void> setAutoReload(bool value) async {
    if (value == _autoReload) return;
    _autoReload = value;
    notifyListeners();
    await _track(() => _prefs.setBool(_autoReloadKey, value));
    // Resolve any pending conflicts that no longer need the user.
    for (final d in documents) {
      d.resolveIfSafe();
    }
  }

  /// Stop all file watchers (used on app shutdown for a prompt exit).
  void disposeWatchers() {
    for (final d in documents) {
      d.stopWatching();
    }
  }

  // --- Session persistence ----------------------------------------------------

  /// A JSON-able snapshot of the open document tabs (print previews excluded),
  /// including each document's unsaved buffer, dirty flag, and view mode, plus
  /// which document is active. Restored verbatim by [restoreSession].
  @visibleForTesting
  Map<String, dynamic> sessionSnapshot() {
    final docs = <Map<String, dynamic>>[];
    var activeDoc = 0;
    var i = 0;
    for (final tab in _tabs) {
      if (tab is! DocumentTab) continue;
      if (identical(tab, _tabs[_activeIndex])) activeDoc = i;
      final d = tab.doc;
      docs.add({
        'path': d.filePath,
        'name': d.displayName,
        'content': d.currentMarkdown(),
        'dirty': d.isDirty,
        'mode': d.mode.name,
      });
      i++;
    }
    return {'version': 1, 'active': activeDoc, 'docs': docs};
  }

  void _scheduleSessionSave() {
    if (_sessionStore == null) return;
    _sessionTimer?.cancel();
    _sessionTimer = Timer(_sessionDebounce, _saveSession);
  }

  void _saveSession() {
    final store = _sessionStore;
    if (store == null) return;
    final json = jsonEncode(sessionSnapshot());
    _track(() => store.write(json));
  }

  /// Force an immediate session write and stop the debounce timer. Called on
  /// shutdown (normal close or update relaunch); the queued write is drained
  /// via [pendingWrites].
  void flushSession() {
    _sessionTimer?.cancel();
    _saveSession();
  }

  /// Rebuild the tabs from a previously saved session. No-op when session
  /// persistence is disabled, there is no saved session, or it's empty — the
  /// initial blank document is left in place. Restored documents keep their
  /// unsaved buffer, dirty state, and view mode.
  Future<void> restoreSession() async {
    final store = _sessionStore;
    if (store == null) return;
    // Only populate a *fresh* workspace. If a document was already opened
    // (an OS file-association open via the platform channel, or an instance
    // forward), don't clobber it with the saved session.
    if (documents.any((d) => !d.isPristine)) return;
    Map<String, dynamic>? data;
    try {
      final raw = await store.read();
      if (raw == null) return;
      data = jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return; // absent or corrupt — keep the fresh blank document
    }
    final entries = (data['docs'] as List?) ?? const [];
    if (entries.isEmpty) return;

    // Resolve each tab's content BEFORE mutating the workspace (the disk
    // reads are async): a clean file-backed tab reflects the CURRENT file,
    // which may have changed while closed — restoring the stale saved buffer
    // as a clean baseline would let a later save silently clobber those
    // changes with no conflict shown. Unsaved (dirty) tabs keep their buffer.
    final restored = <_RestoredDoc>[];
    for (final entry in entries) {
      if (entry is! Map) continue;
      final path = entry['path'] as String?;
      final dirty = (entry['dirty'] as bool?) ?? false;
      var content = (entry['content'] as String?) ?? '';
      var markDirty = dirty;
      if (!dirty && path != null) {
        try {
          content = await File(path).readAsString();
        } catch (_) {
          // File gone/unreadable: keep the saved buffer, but as *unsaved* so
          // it isn't silently treated as matching a file that isn't there.
          markDirty = true;
        }
      }
      restored.add(_RestoredDoc(
        path: path,
        name: entry['name'] as String?,
        content: content,
        markDirty: markDirty,
        mode: entry['mode'] as String?,
      ));
    }
    if (restored.isEmpty) return;

    // Replace the initial blank tab(s).
    for (final t in _tabs) {
      if (t is DocumentTab) _detachDoc(t.doc);
    }
    _tabs.clear();
    for (final r in restored) {
      final doc = _newDoc()
        ..loadMarkdown(r.content,
            path: r.path, displayName: r.name, markDirty: r.markDirty);
      for (final m in EditorMode.values) {
        if (m.name == r.mode) {
          doc.setMode(m);
          break;
        }
      }
      _tabs.add(DocumentTab(doc));
    }
    if (_tabs.isEmpty) _tabs.add(DocumentTab(_newDoc()));
    final active = (data['active'] as int?) ?? 0;
    _activeIndex = active.clamp(0, _tabs.length - 1);
    notifyListeners();
  }

  @override
  void dispose() {
    _sessionTimer?.cancel();
    for (final d in documents) {
      _detachDoc(d);
    }
    super.dispose();
  }
}
