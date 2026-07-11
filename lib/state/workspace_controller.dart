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
    required this.baseline,
    required this.conflict,
  });

  final String? path;
  final String? name;
  final String content;
  final bool markDirty;
  final String? mode;
  final String? baseline;
  final String? conflict;
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
  /// [autoPersist] controls the automatic (debounced) session save and hot
  /// exit. A file-args launch (double-click a `.md`) passes a store with
  /// [autoPersist] `false`: normal editing must NOT overwrite the saved
  /// session, but the store is still there so [persistSessionForRelaunch] can
  /// snapshot the current tabs before an update relaunch (otherwise the
  /// arg-less relaunch would restore a stale, unrelated session).
  WorkspaceController(this._prefs,
      {SessionStore? sessionStore,
      SessionStore? relaunchStore,
      bool autoPersist = true})
      : _sessionStore = sessionStore,
        _relaunchStore = relaunchStore,
        _autoPersist = autoPersist {
    _autoReload = _prefs.getBool(_autoReloadKey) ?? true;
    final tx = _prefs.getDouble(_toolbarXKey);
    final ty = _prefs.getDouble(_toolbarYKey);
    if (tx != null && ty != null) _toolbarOffset = Offset(tx, ty);
    _tabs.add(DocumentTab(_newDoc()));
    _activeIndex = 0;
    // Persist the session (debounced) whenever tabs, the active tab, or any
    // open document changes, so a restart/update reopens where we left off.
    if (_sessionStore != null && _autoPersist) {
      addListener(_scheduleSessionSave);
    }
  }

  static const _autoReloadKey = 'auto_reload';
  static const _toolbarXKey = 'format_toolbar_x';
  static const _toolbarYKey = 'format_toolbar_y';
  static const _sessionDebounce = Duration(milliseconds: 1200);

  final SharedPreferences _prefs;

  /// Where the open-tabs session is stored (null disables session
  /// persistence — e.g. in torn-off windows or tests that don't exercise it).
  final SessionStore? _sessionStore;

  /// A SEPARATE one-shot store (`relaunch.json`) for the update-relaunch
  /// snapshot on a file-args launch — kept apart from [_sessionStore] so
  /// snapshotting the current tabs for an update never overwrites the protected
  /// session (which may hold a prior plain launch's hot-exit unsaved buffers).
  /// Consumed (and cleared) by the next [restoreSession].
  final SessionStore? _relaunchStore;

  /// Whether the automatic debounced save + hot exit are active. False on a
  /// file-args launch, whose store exists only for [persistSessionForRelaunch].
  final bool _autoPersist;
  Timer? _sessionTimer;
  bool _sessionAbandoned = false;

  /// Whether this workspace persists/restores its session. When false (a
  /// torn-off window, a file-args launch, or a launch where [restoreSession]
  /// abandoned to a pre-opened document), closing with unsaved work still needs
  /// a discard prompt — hot exit only applies when the session is actually
  /// saved automatically.
  bool get sessionEnabled =>
      _sessionStore != null && _autoPersist && !_sessionAbandoned;

  /// Whether an update's relaunch can bring this window's tabs back. True when
  /// the snapshot [persistSessionForRelaunch] needs has somewhere to go and the
  /// session isn't abandoned: a plain launch flushes the persistent session, a
  /// file-args launch writes the one-shot relaunch store. False for a torn-off
  /// window (no stores), and for an abandoned session (a forwarded/pre-opened
  /// doc) whose saved session is deliberately protected.
  bool get willRestoreOnRelaunch =>
      !_sessionAbandoned &&
      (_autoPersist ? _sessionStore != null : _relaunchStore != null);

  /// Stop this run from persisting the session. Used when [restoreSession]
  /// finds a document was already opened (an instance-forwarded path, or a
  /// buffered platform-channel open) and bails: that pre-opened document must
  /// not overwrite the saved session's unsaved buffers that restore just
  /// abandoned — the saved session survives untouched for the next launch,
  /// and the pre-opened document is protected by the normal close prompt.
  void _abandonSession() {
    _sessionAbandoned = true;
    _sessionTimer?.cancel();
  }

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
    for (final tab in _tabs) {
      if (tab is! DocumentTab) continue;
      final d = tab.doc;
      // A blank, never-touched Untitled is not real work: persisting it would
      // resurrect it on next launch as a non-pristine tab that a real file
      // open can no longer replace, leaving a stray empty tab behind.
      if (d.isPristine) continue;
      if (identical(tab, _tabs[_activeIndex])) activeDoc = docs.length;
      docs.add({
        'path': d.filePath,
        'name': d.displayName,
        'content': d.currentMarkdown(),
        'dirty': d.isDirty,
        'mode': d.mode.name,
        // For a dirty file-backed tab, the disk content it was last in sync
        // with — so restore can tell whether the file changed while closed.
        if (d.isDirty && d.filePath != null) 'synced': d.syncedContent,
        // Record only THAT an external-change conflict was pending, never the
        // conflicting text: it can go stale between shutdown and the next
        // launch, so restore re-reads the current file to produce fresh
        // conflict content (and drops the conflict if the file has caught up).
        if (d.hasExternalConflict) 'conflict': true,
      });
    }
    return {'version': 1, 'active': activeDoc, 'docs': docs};
  }

  void _scheduleSessionSave() {
    if (!sessionEnabled) return;
    _sessionTimer?.cancel();
    _sessionTimer = Timer(_sessionDebounce, _saveSession);
  }

  void _saveSession() {
    if (!sessionEnabled) return;
    final json = jsonEncode(sessionSnapshot());
    _track(() => _sessionStore!.write(json));
  }

  /// Force an immediate session write, awaiting the result, and stop the
  /// debounce timer. Returns false if the write failed (disk full/unwritable)
  /// so the caller can fall back to a discard prompt rather than lose unsaved
  /// work silently. A no-op returning true when persistence is disabled.
  Future<bool> flushSession() async {
    _sessionTimer?.cancel();
    if (!sessionEnabled) return true;
    final json = jsonEncode(sessionSnapshot());
    // Run through the same _track chain as the debounced saves, so a forced
    // flush can't complete BEFORE an older queued save and then be
    // overwritten by it (last-writer-wins) once the caller awaits
    // pendingWrites.
    var ok = true;
    await _track(() async {
      try {
        await _sessionStore!.write(json);
      } catch (_) {
        ok = false;
      }
    });
    return ok;
  }

  /// Snapshot the CURRENT tabs so an update's arg-less silent relaunch restores
  /// exactly what's open now — otherwise a file-args launch (auto-session off)
  /// would relaunch onto the last *plain*-launch session: an unrelated file.
  ///
  /// - Plain launch: the live session IS the persistent one, so just flush it.
  /// - File-args launch: write a ONE-SHOT snapshot to the separate relaunch
  ///   store, leaving the persistent session (and any hot-exit unsaved buffers
  ///   it protects) untouched. [restoreSession] consumes it next launch.
  ///
  /// Returns false when the snapshot can't be taken (no store, an abandoned
  /// session, or a failed write), so the caller can abort/fall back rather than
  /// relaunch onto a stale session.
  Future<bool> persistSessionForRelaunch() async {
    if (_sessionAbandoned) return false;
    // Plain launch: the persistent session is the live one — flush it and let
    // the arg-less relaunch restore it normally.
    if (_autoPersist) return flushSession();
    final store = _relaunchStore;
    if (store == null) return false;
    _sessionTimer?.cancel();
    final json = jsonEncode(sessionSnapshot());
    var ok = true;
    await _track(() async {
      try {
        await store.write(json);
      } catch (_) {
        ok = false;
      }
    });
    return ok;
  }

  /// Discard a one-shot relaunch snapshot — used to roll back when the installer
  /// fails to launch, so a later manual launch doesn't resurrect the stale
  /// update-time tabs.
  Future<void> clearRelaunchSnapshot() async {
    final store = _relaunchStore;
    if (store == null) return;
    await _track(() async {
      try {
        await store.clear();
      } catch (_) {/* best effort */}
    });
  }

  /// Rebuild the tabs from a previously saved session. No-op when session
  /// persistence is disabled, there is no saved session, or it's empty — the
  /// initial blank document is left in place. Restored documents keep their
  /// unsaved buffer, dirty state, and view mode.
  Future<void> restoreSession() async {
    final store = _sessionStore;
    final relaunch = _relaunchStore;
    if (store == null && relaunch == null) return;
    // Only populate a *fresh* workspace. If a document was already opened
    // (an OS file-association open via the platform channel, or an instance
    // forward), don't clobber it with the saved session — and suppress
    // persistence so that pre-opened document doesn't overwrite the saved
    // session we're abandoning.
    if (documents.any((d) => !d.isPristine)) {
      _abandonSession();
      return;
    }
    Map<String, dynamic>? data;
    try {
      // A one-shot relaunch snapshot (from a file-args window that just
      // updated) takes precedence and is CONSUMED, so it restores the window
      // that updated — not the untouched persistent session — and can never
      // resurface on a later launch.
      String? raw;
      if (relaunch != null) {
        raw = await relaunch.read();
        if (raw != null) await relaunch.clear();
      }
      raw ??= store != null ? await store.read() : null;
      if (raw == null) return;
      data = jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return; // absent or corrupt — keep the fresh blank document
    }
    // `docs` may be missing or (in a corrupt/forward-incompatible file) not a
    // list — guard the type instead of casting so a bad value degrades to an
    // empty restore rather than throwing.
    final docsRaw = data['docs'];
    final entries = docsRaw is List ? docsRaw : const [];
    if (entries.isEmpty) return;

    // Resolve each tab BEFORE mutating the workspace (the disk reads are
    // async). This is the SINGLE place that reads the current file and decides
    // each restored tab's content, baseline, and conflict — loadMarkdown then
    // applies that decision verbatim (see fromRestore) rather than re-reading
    // disk itself, so the two can't disagree.
    final restored = <_RestoredDoc>[];
    for (final entry in entries) {
      if (entry is! Map) continue;
      try {
        final path = entry['path'] as String?;
        final dirty = (entry['dirty'] as bool?) ?? false;
        // Only whether a conflict was pending — never trust persisted text
        // (tolerate an old session that stored the string form: any non-null
        // value means "was conflicted").
        final hadConflict = entry['conflict'] != null;
        final synced = entry['synced'] as String?;
        var content = (entry['content'] as String?) ?? '';
        var markDirty = dirty;
        var baseline = synced;
        String? conflict;

        if (path != null) {
          String? disk;
          try {
            disk = await File(path).readAsString();
          } catch (_) {
            disk = null; // file gone/unreadable
          }
          if (disk == null) {
            // No file to reconcile against. A clean tab that merely tracked
            // the file keeps its buffer, but marked unsaved so it isn't
            // treated as matching a now-missing file.
            if (!dirty) markDirty = true;
            baseline = synced ?? content;
          } else if (disk == content) {
            // The current file already equals the buffer: nothing unsaved,
            // nothing to reconcile. Restore as a clean tab in sync with disk —
            // even if it was saved dirty/conflicted, another tool has since
            // written exactly this text, so the tab must not reopen forever as
            // unsaved.
            markDirty = false;
            baseline = disk;
          } else if (!dirty) {
            // A CLEAN tab (with or without a prior conflict) whose file changed
            // while closed. Mirror the live watcher / resolveIfSafe: auto-adopt
            // only when auto-reload is on; otherwise surface a Reload/Keep-mine
            // conflict so an auto-reload-off user can still keep their buffer.
            // Either way the baseline tracks the current disk, matching the live
            // invariant (so "Keep mine" won't re-fire on the next unchanged
            // watcher event).
            baseline = disk;
            if (_autoReload) {
              content = disk;
            } else {
              conflict = disk;
            }
          } else {
            // A DIRTY tab whose file differs from the buffer. Dirty tabs never
            // auto-reload. Surface a conflict unless the file is unchanged from
            // the (clean) edit baseline — that's normal dirty editing, not an
            // external change. `synced` is polluted for a tab that already had
            // a conflict, so such a tab always reconciles against fresh disk.
            if (!hadConflict && disk == synced) {
              baseline = synced;
            } else {
              baseline = disk;
              conflict = disk;
            }
          }
        }

        restored.add(_RestoredDoc(
          path: path,
          name: entry['name'] as String?,
          content: content,
          markDirty: markDirty,
          mode: entry['mode'] as String?,
          baseline: baseline,
          conflict: conflict,
        ));
      } catch (_) {
        // Malformed/forward-incompatible entry (e.g. a non-string field):
        // skip it rather than aborting the whole restore.
      }
    }
    if (restored.isEmpty) return;

    // The disk reads above are async; a forwarded open-file request could
    // have arrived meanwhile and added a real document. Re-check freshness so
    // we don't clobber it — and suppress persistence for the same reason as
    // the pre-read check above.
    if (documents.any((d) => !d.isPristine)) {
      _abandonSession();
      return;
    }

    // Replace the initial blank tab(s).
    for (final t in _tabs) {
      if (t is DocumentTab) _detachDoc(t.doc);
    }
    _tabs.clear();
    for (final r in restored) {
      final doc = _newDoc()
        ..loadMarkdown(r.content,
            path: r.path,
            displayName: r.name,
            markDirty: r.markDirty,
            restoredBaseline: r.baseline,
            restoredConflict: r.conflict,
            fromRestore: true);
      for (final m in EditorMode.values) {
        if (m.name == r.mode) {
          doc.setMode(m);
          break;
        }
      }
      _tabs.add(DocumentTab(doc));
    }
    if (_tabs.isEmpty) _tabs.add(DocumentTab(_newDoc()));
    // Type-guard the active index too (a corrupt/forward-version session could
    // hold a non-int here): this runs after the tabs are rebuilt and outside
    // the corrupt-session try, so a bad cast would crash launch instead of
    // falling back to tab 0.
    final activeRaw = data['active'];
    final active = activeRaw is int ? activeRaw : 0;
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
