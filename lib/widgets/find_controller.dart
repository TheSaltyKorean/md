import 'package:flutter/foundation.dart';

/// Small shared handle so the toolbar / keyboard shortcuts (owned by the editor
/// screen) can open, switch, and close the find & replace bar that lives inside
/// the currently-mounted source view.
class FindController extends ChangeNotifier {
  bool _visible = false;
  bool _replaceVisible = false;

  /// Bumped every time find/replace is (re)invoked, so a bar that is already
  /// open can re-focus and select its query field.
  int _openEpoch = 0;

  bool get visible => _visible;
  bool get replaceVisible => _replaceVisible;
  int get openEpoch => _openEpoch;

  void openFind() {
    _visible = true;
    _replaceVisible = false;
    _openEpoch++;
    notifyListeners();
  }

  void openReplace() {
    _visible = true;
    _replaceVisible = true;
    _openEpoch++;
    notifyListeners();
  }

  void hide() {
    if (!_visible) return;
    _visible = false;
    notifyListeners();
  }
}
