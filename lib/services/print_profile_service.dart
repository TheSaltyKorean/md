import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/print_profile.dart';

/// Stores the user's [PrintProfile]s, the default profile, and the mapping of
/// document path -> profile id (so each document remembers its own branding).
class PrintProfileService extends ChangeNotifier {
  PrintProfileService(this._prefs) {
    _load();
  }

  static const _profilesKey = 'print_profiles';
  static const _defaultKey = 'default_print_profile';
  static const _docMapKey = 'doc_print_profile_map';

  final SharedPreferences _prefs;

  List<PrintProfile> _profiles = [];
  String _defaultId = PrintProfile.personal.id;
  Map<String, String> _docMap = {};

  List<PrintProfile> get profiles => List.unmodifiable(_profiles);
  String get defaultId => _defaultId;
  PrintProfile get defaultProfile => byId(_defaultId);

  PrintProfile byId(String id) => _profiles.firstWhere(
        (p) => p.id == id,
        orElse: () =>
            _profiles.isNotEmpty ? _profiles.first : PrintProfile.personal,
      );

  /// Resolve which profile applies to a given document path, falling back to
  /// the default when the document has no explicit association.
  PrintProfile forDocument(String? docPath) {
    if (docPath != null && _docMap.containsKey(docPath)) {
      return byId(_docMap[docPath]!);
    }
    return defaultProfile;
  }

  String? assignedId(String? docPath) =>
      docPath == null ? null : _docMap[docPath];

  void _load() {
    final stored = _prefs.getString(_profilesKey);
    if (stored != null && stored.isNotEmpty) {
      try {
        _profiles = PrintProfile.decodeList(stored);
      } catch (_) {
        _profiles = List.of(PrintProfile.seeds);
      }
    } else {
      _profiles = List.of(PrintProfile.seeds);
    }
    if (_profiles.isEmpty) _profiles = List.of(PrintProfile.seeds);

    _defaultId = _prefs.getString(_defaultKey) ?? _profiles.first.id;
    if (!_profiles.any((p) => p.id == _defaultId)) {
      _defaultId = _profiles.first.id;
    }

    final mapStr = _prefs.getString(_docMapKey);
    if (mapStr != null && mapStr.isNotEmpty) {
      try {
        final decoded = jsonDecode(mapStr) as Map<String, dynamic>;
        _docMap = decoded.map((k, v) => MapEntry(k, v.toString()));
      } catch (_) {
        _docMap = {};
      }
    }
  }

  Future<void> _persistProfiles() async =>
      _prefs.setString(_profilesKey, PrintProfile.encodeList(_profiles));

  Future<void> _persistDocMap() async =>
      _prefs.setString(_docMapKey, jsonEncode(_docMap));

  Future<void> upsert(PrintProfile profile) async {
    final idx = _profiles.indexWhere((p) => p.id == profile.id);
    if (idx >= 0) {
      _profiles[idx] = profile;
    } else {
      _profiles.add(profile);
    }
    notifyListeners();
    await _persistProfiles();
  }

  Future<void> delete(String id) async {
    if (_profiles.length <= 1) return; // always keep at least one
    _profiles.removeWhere((p) => p.id == id);
    if (_defaultId == id) {
      _defaultId = _profiles.first.id;
      await _prefs.setString(_defaultKey, _defaultId);
    }
    _docMap.removeWhere((_, v) => v == id);
    notifyListeners();
    await _persistProfiles();
    await _persistDocMap();
  }

  Future<void> setDefault(String id) async {
    _defaultId = id;
    notifyListeners();
    await _prefs.setString(_defaultKey, id);
  }

  /// Associate a document with a profile (or clear it when [id] is null).
  Future<void> assignToDocument(String docPath, String? id) async {
    if (id == null) {
      _docMap.remove(docPath);
    } else {
      _docMap[docPath] = id;
    }
    notifyListeners();
    await _persistDocMap();
  }
}
