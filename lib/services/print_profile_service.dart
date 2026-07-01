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

  /// Ids of built-in seeds already introduced to this install, so newly-shipped
  /// seeds (e.g. "Court Filing") are merged into an existing user's saved list
  /// exactly once — without resurrecting a seed they deliberately deleted.
  static const _seededIdsKey = 'seeded_profile_ids';

  /// Seeds that shipped before the merge-on-load scheme existed. Used only the
  /// first time it runs (when [_seededIdsKey] is absent) so pre-existing users
  /// receive genuinely new seeds only, not ones they had removed.
  static const _priorSeedIds = <String>{'personal', 'work'};

  final SharedPreferences _prefs;

  List<PrintProfile> _profiles = [];
  String _defaultId = PrintProfile.personal.id;
  Map<String, String> _docMap = {};

  /// All in-flight persistence operations (UI callbacks don't await them). Each
  /// mutator chains onto this so several fire-and-forget changes followed by an
  /// immediate app close can all be drained, not just the most recent one.
  Future<void> _pending = Future.value();
  Future<void> get pendingWrites => _pending;

  /// Run [op] and fold it into [_pending] without dropping any prior in-flight
  /// operation. Errors are isolated so one failure can't poison the drain.
  /// Serialise persistence: [op] (which starts the operation) is not invoked
  /// until the previous one has completed, so writes to the same key can't
  /// land out of order and a close-time drain awaits all of them.
  Future<void> _track(Future<void> Function() op) {
    final result = _pending.then((_) => op(), onError: (_) => op());
    _pending = result.catchError((_) {});
    return result;
  }

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

    _mergeNewSeeds();

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

  /// Add any built-in seed the user hasn't seen yet (by id), then remember the
  /// full set of introduced seed ids. Runs once per newly-shipped seed; a seed
  /// the user explicitly deleted is recorded as introduced and stays gone.
  void _mergeNewSeeds() {
    final raw = _prefs.getString(_seededIdsKey);
    Set<String> introduced;
    if (raw == null || raw.isEmpty) {
      introduced = {..._priorSeedIds};
    } else {
      try {
        introduced = (jsonDecode(raw) as List).map((e) => e.toString()).toSet();
      } catch (_) {
        introduced = {..._priorSeedIds};
      }
    }

    final existingIds = _profiles.map((p) => p.id).toSet();
    var addedProfile = false;
    for (final seed in PrintProfile.seeds) {
      if (!introduced.contains(seed.id) && !existingIds.contains(seed.id)) {
        _profiles.add(seed);
        addedProfile = true;
      }
    }

    final allSeedIds = PrintProfile.seeds.map((p) => p.id).toSet();
    final introducedChanged = !allSeedIds.every(introduced.contains);
    if (addedProfile) _track(_persistProfiles);
    if (raw == null || raw.isEmpty || introducedChanged) {
      _track(() => _prefs.setString(
          _seededIdsKey, jsonEncode({...introduced, ...allSeedIds}.toList())));
    }
  }

  Future<void> _persistProfiles() =>
      _prefs.setString(_profilesKey, PrintProfile.encodeList(_profiles));

  Future<void> _persistDocMap() =>
      _prefs.setString(_docMapKey, jsonEncode(_docMap));

  // Public mutators run their whole operation through [_track], so several
  // fire-and-forget changes serialise and are all drained on an immediate close
  // — including multi-write transactions like delete().

  Future<void> upsert(PrintProfile profile) => _track(() => _upsert(profile));
  Future<void> _upsert(PrintProfile profile) async {
    final idx = _profiles.indexWhere((p) => p.id == profile.id);
    if (idx >= 0) {
      _profiles[idx] = profile;
    } else {
      _profiles.add(profile);
    }
    notifyListeners();
    await _persistProfiles();
  }

  Future<void> delete(String id) => _track(() => _delete(id));
  Future<void> _delete(String id) async {
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

  Future<void> setDefault(String id) => _track(() => _setDefault(id));
  Future<void> _setDefault(String id) async {
    _defaultId = id;
    notifyListeners();
    await _prefs.setString(_defaultKey, id);
  }

  /// Associate a document with a profile (or clear it when [id] is null).
  Future<void> assignToDocument(String docPath, String? id) =>
      _track(() => _assignToDocument(docPath, id));
  Future<void> _assignToDocument(String docPath, String? id) async {
    if (id == null) {
      _docMap.remove(docPath);
    } else {
      _docMap[docPath] = id;
    }
    notifyListeners();
    await _persistDocMap();
  }
}
