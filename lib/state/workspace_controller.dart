import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart' show Offset;
import 'package:shared_preferences/shared_preferences.dart';

import 'document_controller.dart';

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
  });

  String markdown;
  String title;
  String? docPath;

  /// Bumped on refresh so the preview widget rebuilds from the new snapshot.
  int epoch = 0;
}

/// Owns the set of open tabs (documents and print previews), the active tab,
/// and the global auto-reload setting. Each document tab is its own
/// [DocumentController].
class WorkspaceController extends ChangeNotifier {
  WorkspaceController(this._prefs) {
    _autoReload = _prefs.getBool(_autoReloadKey) ?? true;
    final tx = _prefs.getDouble(_toolbarXKey);
    final ty = _prefs.getDouble(_toolbarYKey);
    if (tx != null && ty != null) _toolbarOffset = Offset(tx, ty);
    _tabs.add(DocumentTab(_newDoc()));
    _activeIndex = 0;
  }

  static const _autoReloadKey = 'auto_reload';
  static const _toolbarXKey = 'format_toolbar_x';
  static const _toolbarYKey = 'format_toolbar_y';

  final SharedPreferences _prefs;

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
    return doc;
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

    final sole = _tabs.length == 1 ? _tabs.first : null;
    if (sole is DocumentTab && sole.doc.isPristine) {
      sole.doc.loadMarkdown(content,
          path: path, displayName: displayName, markDirty: markDirty);
      _activeIndex = 0;
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
  /// A preview of the same file (or, for unsaved documents, the same title)
  /// is reused: its snapshot is replaced and the tab focused, so printing
  /// twice never stacks duplicate previews.
  void openPrintPreview({
    required String markdown,
    required String title,
    required String? docPath,
  }) {
    final existing = _tabs.indexWhere((t) =>
        t is PrintPreviewTab &&
        (docPath != null
            ? t.docPath == docPath
            : t.docPath == null && t.title == title));
    if (existing >= 0) {
      final tab = _tabs[existing] as PrintPreviewTab;
      tab
        ..markdown = markdown
        ..title = title
        ..epoch += 1;
      _activeIndex = existing;
    } else {
      _tabs.add(
          PrintPreviewTab(markdown: markdown, title: title, docPath: docPath));
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
      tab.doc.removeListener(_relay);
      tab.doc.dispose();
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

  @override
  void dispose() {
    for (final d in documents) {
      d.removeListener(_relay);
      d.dispose();
    }
    super.dispose();
  }
}
