import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart' show Offset;
import 'package:shared_preferences/shared_preferences.dart';

import 'document_controller.dart';

/// Owns the set of open documents (tabs), the active tab, and the global
/// auto-reload setting. Each tab is its own [DocumentController].
class WorkspaceController extends ChangeNotifier {
  WorkspaceController(this._prefs) {
    _autoReload = _prefs.getBool(_autoReloadKey) ?? true;
    final tx = _prefs.getDouble(_toolbarXKey);
    final ty = _prefs.getDouble(_toolbarYKey);
    if (tx != null && ty != null) _toolbarOffset = Offset(tx, ty);
    _docs.add(_newDoc());
    _activeIndex = 0;
  }

  static const _autoReloadKey = 'auto_reload';
  static const _toolbarXKey = 'format_toolbar_x';
  static const _toolbarYKey = 'format_toolbar_y';

  final SharedPreferences _prefs;

  final List<DocumentController> _docs = [];
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

  List<DocumentController> get documents => List.unmodifiable(_docs);
  int get activeIndex => _activeIndex;
  DocumentController get active => _docs[_activeIndex];
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
    _docs.add(_newDoc());
    _activeIndex = _docs.length - 1;
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
      final existing = _docs.indexWhere((d) => d.filePath == path);
      if (existing >= 0) {
        _activeIndex = existing;
        notifyListeners();
        return;
      }
    }

    if (_docs.length == 1 && _docs.first.isPristine) {
      _docs.first.loadMarkdown(content,
          path: path, displayName: displayName, markDirty: markDirty);
      _activeIndex = 0;
      notifyListeners();
      return;
    }

    final doc = _newDoc()
      ..loadMarkdown(content,
          path: path, displayName: displayName, markDirty: markDirty);
    _docs.add(doc);
    _activeIndex = _docs.length - 1;
    notifyListeners();
  }

  void select(int index) {
    if (index < 0 || index >= _docs.length || index == _activeIndex) return;
    _activeIndex = index;
    notifyListeners();
  }

  /// Move the tab at [oldIndex] to [newIndex] (drag-to-reorder), keeping the
  /// same document active.
  void reorder(int oldIndex, int newIndex) {
    if (oldIndex < 0 || oldIndex >= _docs.length) return;
    if (oldIndex == newIndex) return;
    final active = _docs[_activeIndex];
    final doc = _docs.removeAt(oldIndex);
    // Removing a lower index shifts the target left by one, so insert before the
    // highlighted tab in both directions.
    final target =
        (oldIndex < newIndex ? newIndex - 1 : newIndex).clamp(0, _docs.length);
    _docs.insert(target, doc);
    _activeIndex = _docs.indexOf(active);
    notifyListeners();
  }

  /// Close the tab at [index]. Always keeps at least one tab open.
  void closeAt(int index) {
    if (index < 0 || index >= _docs.length) return;
    final doc = _docs.removeAt(index);
    doc.removeListener(_relay);
    doc.dispose();

    if (_docs.isEmpty) {
      _docs.add(_newDoc());
      _activeIndex = 0;
    } else if (_activeIndex >= _docs.length) {
      _activeIndex = _docs.length - 1;
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
    for (final d in _docs) {
      d.resolveIfSafe();
    }
  }

  /// Stop all file watchers (used on app shutdown for a prompt exit).
  void disposeWatchers() {
    for (final d in _docs) {
      d.stopWatching();
    }
  }

  @override
  void dispose() {
    for (final d in _docs) {
      d.removeListener(_relay);
      d.dispose();
    }
    super.dispose();
  }
}
