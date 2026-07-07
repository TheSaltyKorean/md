import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart' show TextScaler;
import 'package:shared_preferences/shared_preferences.dart';

/// Browser-style document zoom, persisted across launches.
///
/// The factor scales the *document* text in every view mode (WYSIWYG via
/// AppFlowy's `EditorStyle.textScaleFactor`, the source/preview panes via a
/// `MediaQuery` text scaler) — app chrome (tabs, toolbar, menus) stays at
/// 100%. Print previews are untouched: `PdfPreview` has its own pinch/scroll
/// zoom, and zooming must never change what prints.
class ZoomController extends ChangeNotifier {
  ZoomController(this._prefs) {
    final saved = _prefs.getDouble(_prefsKey);
    if (saved != null) _factor = _snap(saved);
  }

  static const _prefsKey = 'zoom_factor';
  static const double minFactor = 0.5;
  static const double maxFactor = 3.0;
  static const double step = 0.1;

  final SharedPreferences _prefs;
  double _factor = 1.0;

  /// All in-flight persistence writes (UI callbacks fire-and-forget), chained
  /// so rapid repeated zooming is fully drained before an immediate app close.
  Future<void> _pending = Future.value();
  Future<void> get pendingWrites => _pending;

  Future<void> _track(Future<void> Function() op) {
    final result = _pending.then((_) => op(), onError: (_) => op());
    _pending = result.catchError((_) {});
    return result;
  }

  double get factor => _factor;

  /// The factor as a percentage, e.g. `110%`.
  String get label => '${(_factor * 100).round()}%';

  bool get canZoomIn => _factor < maxFactor;
  bool get canZoomOut => _factor > minFactor;
  bool get isDefault => _factor == 1.0;

  void zoomIn() => _set(_factor + step);
  void zoomOut() => _set(_factor - step);
  void reset() => _set(1.0);

  /// Clamp to range and round to the step grid so repeated +/- pairs return
  /// exactly to 100% (raw doubles would drift: 1.0 + 0.1 - 0.1 != 1.0).
  static double _snap(double v) =>
      ((v.clamp(minFactor, maxFactor) / step).roundToDouble() * step * 100)
          .roundToDouble() /
      100;

  void _set(double v) {
    final next = _snap(v);
    if (next == _factor) return;
    _factor = next;
    notifyListeners();
    _track(() => _prefs.setDouble(_prefsKey, next));
  }
}

/// The inherited (platform / accessibility) text scaler with the document
/// zoom applied on top, so zooming never discards the user's OS text size.
///
/// Chrome that mounts *inside* a zoomed document view (e.g. the find/replace
/// card) can recover [inherited] to opt back out of the zoom while keeping
/// the accessibility scale.
class ZoomedTextScaler extends TextScaler {
  const ZoomedTextScaler(this.inherited, this.zoom);

  final TextScaler inherited;
  final double zoom;

  @override
  double scale(double fontSize) => inherited.scale(fontSize) * zoom;

  @override
  // ignore: deprecated_member_use
  double get textScaleFactor => inherited.textScaleFactor * zoom;

  @override
  bool operator ==(Object other) =>
      other is ZoomedTextScaler &&
      other.inherited == inherited &&
      other.zoom == zoom;

  @override
  int get hashCode => Object.hash(inherited, zoom);
}
