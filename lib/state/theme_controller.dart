import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Holds the user's preferred [ThemeMode] (light / dark / system) and persists
/// it across launches via [SharedPreferences].
class ThemeController extends ChangeNotifier {
  ThemeController(this._prefs) {
    _load();
  }

  static const _prefsKey = 'theme_mode';

  final SharedPreferences _prefs;
  ThemeMode _mode = ThemeMode.system;

  /// All in-flight persistence writes (UI callbacks fire-and-forget), chained so
  /// rapid repeated theme toggles are all drained before an immediate app close.
  Future<void> _pending = Future.value();
  Future<void> get pendingWrites => _pending;

  Future<void> _track(Future<void> op) {
    final prev = _pending;
    _pending = Future(() async {
      try {
        await prev;
      } catch (_) {}
      try {
        await op;
      } catch (_) {}
    });
    return op;
  }

  ThemeMode get mode => _mode;

  bool isDark(BuildContext context) {
    switch (_mode) {
      case ThemeMode.light:
        return false;
      case ThemeMode.dark:
        return true;
      case ThemeMode.system:
        return MediaQuery.platformBrightnessOf(context) == Brightness.dark;
    }
  }

  void _load() {
    final stored = _prefs.getString(_prefsKey);
    _mode = ThemeMode.values.firstWhere(
      (m) => m.name == stored,
      orElse: () => ThemeMode.system,
    );
  }

  Future<void> setMode(ThemeMode mode) async {
    if (mode == _mode) return;
    _mode = mode;
    notifyListeners();
    await _track(_prefs.setString(_prefsKey, mode.name));
  }

  /// Convenience toggle used by the toolbar icon button. Cycles
  /// system -> light -> dark -> system.
  Future<void> cycle() async {
    final next = switch (_mode) {
      ThemeMode.system => ThemeMode.light,
      ThemeMode.light => ThemeMode.dark,
      ThemeMode.dark => ThemeMode.system,
    };
    await setMode(next);
  }
}
