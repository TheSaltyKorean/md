import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A newer published release, as reported by [UpdateController.check].
class UpdateInfo {
  const UpdateInfo({required this.version});

  /// Bare semver of the newer release, e.g. `1.0.5`.
  final String version;

  /// Stable versionless asset URLs — the release pipeline publishes every
  /// artifact under these names, and `latest` always points at the newest
  /// release, so the URLs are known without parsing the release's assets.
  static const _base =
      'https://github.com/TheSaltyKorean/md/releases/latest/download';
  String get msiUrl => '$_base/markdown-studio-windows-x64.msi';
  String get debUrl => '$_base/markdown-studio-linux-amd64.deb';

  /// Where a user on a platform without a one-click path picks an installer.
  String get downloadPageUrl => 'https://markdownstudio.dev/#get';
}

/// Checks GitHub for a newer published release and drives the one-click
/// update. The check is a single anonymous request for the latest release
/// tag (no account, nothing sent beyond the request itself — disclosed in
/// PRIVACY.md) and can be disabled from the app menu.
class UpdateController extends ChangeNotifier {
  UpdateController(this._prefs, {Future<String?> Function()? fetchLatestTag})
      : _fetchLatestTag = fetchLatestTag ?? _fetchLatestTagFromGitHub;

  static const _enabledKey = 'update_check_enabled';
  static const _latestUrl =
      'https://api.github.com/repos/TheSaltyKorean/md/releases/latest';

  final SharedPreferences _prefs;
  final Future<String?> Function() _fetchLatestTag;

  /// All in-flight persistence writes, chained (see ThemeController).
  Future<void> _pending = Future.value();
  Future<void> get pendingWrites => _pending;

  Future<void> _track(Future<void> Function() op) {
    final result = _pending.then((_) => op(), onError: (_) => op());
    _pending = result.catchError((_) {});
    return result;
  }

  UpdateInfo? _available;
  UpdateInfo? get available => _available;

  bool get checkOnStartup => _prefs.getBool(_enabledKey) ?? true;
  void setCheckOnStartup(bool value) {
    if (value == checkOnStartup) return;
    _track(() => _prefs.setBool(_enabledKey, value));
    notifyListeners();
  }

  /// Compare the latest published tag against the running version. Quiet on
  /// every failure — an update check must never surface an error. Returns
  /// true when a newer release was found.
  Future<bool> check({bool respectToggle = true}) async {
    if (respectToggle && !checkOnStartup) return false;
    try {
      final tag = await _fetchLatestTag();
      if (tag == null) return false;
      final latest = tag.startsWith('v') ? tag.substring(1) : tag;
      final current = (await PackageInfo.fromPlatform()).version;
      if (isNewer(latest, current)) {
        _available = UpdateInfo(version: latest);
        notifyListeners();
        return true;
      }
    } catch (_) {/* offline / rate-limited / malformed — stay quiet */}
    return false;
  }

  /// Whether semver [candidate] is strictly newer than [current]. Unparsable
  /// input is never "newer" (a bad tag must not trigger update prompts).
  @visibleForTesting
  static bool isNewer(String candidate, String current) {
    List<int>? parse(String v) {
      final m = RegExp(r'^(\d+)\.(\d+)\.(\d+)').firstMatch(v.trim());
      if (m == null) return null;
      return [1, 2, 3].map((i) => int.parse(m.group(i)!)).toList();
    }

    final a = parse(candidate);
    final b = parse(current);
    if (a == null || b == null) return false;
    for (var i = 0; i < 3; i++) {
      if (a[i] != b[i]) return a[i] > b[i];
    }
    return false;
  }

  static Future<String?> _fetchLatestTagFromGitHub() async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    try {
      final request = await client
          .getUrl(Uri.parse(_latestUrl))
          .timeout(const Duration(seconds: 8));
      request.headers
          .set(HttpHeaders.acceptHeader, 'application/vnd.github+json');
      final response =
          await request.close().timeout(const Duration(seconds: 8));
      if (response.statusCode != HttpStatus.ok) return null;
      final body = await response
          .transform(utf8.decoder)
          .join()
          .timeout(const Duration(seconds: 8));
      return (jsonDecode(body) as Map<String, dynamic>)['tag_name'] as String?;
    } finally {
      client.close();
    }
  }

  /// Download [url] to a temp file, reporting progress in [0, 1] (or an
  /// indeterminate -1 when the server sends no Content-Length). Throws on
  /// any failure — unlike the quiet check, an explicit update action should
  /// tell the user when it can't proceed.
  Future<String> downloadInstaller(
    String url,
    String filename,
    void Function(double progress) onProgress,
  ) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    try {
      final request = await client
          .getUrl(Uri.parse(url))
          .timeout(const Duration(minutes: 1));
      final response =
          await request.close().timeout(const Duration(minutes: 1));
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException('HTTP ${response.statusCode}', uri: Uri.parse(url));
      }
      final total = response.contentLength;
      final file = File(
          '${Directory.systemTemp.path}${Platform.pathSeparator}$filename');
      final sink = file.openWrite();
      var received = 0;
      try {
        await for (final chunk
            in response.timeout(const Duration(seconds: 30))) {
          sink.add(chunk);
          received += chunk.length;
          onProgress(total > 0 ? received / total : -1);
        }
      } finally {
        await sink.close();
      }
      return file.path;
    } finally {
      client.close();
    }
  }

  /// Hand the downloaded installer to the OS. Windows: msiexec runs the
  /// in-place upgrade (the caller exits the app so no files are in use).
  /// Linux: the default handler (a software installer) opens the .deb.
  Future<void> launchInstaller(String path) async {
    if (Platform.isWindows) {
      await Process.start('msiexec', ['/i', path],
          mode: ProcessStartMode.detached);
    } else if (Platform.isLinux) {
      await Process.start('xdg-open', [path], mode: ProcessStartMode.detached);
    } else {
      throw UnsupportedError('no installer launcher for this platform');
    }
  }

  /// Whether this build can run a one-click install: an *installed* desktop
  /// copy (Program Files on Windows, /opt on Linux — the MSI/.deb install
  /// roots). Portable and store/dev copies go to the download page instead:
  /// silently swapping files under a portable directory or a store install
  /// would fight the way the user chose to install.
  bool get canOneClickInstall {
    if (kIsWeb) return false;
    final exe = Platform.resolvedExecutable.toLowerCase();
    if (Platform.isWindows) {
      for (final v in ['ProgramFiles', 'ProgramFiles(x86)']) {
        final p = Platform.environment[v];
        if (p != null &&
            p.isNotEmpty &&
            exe.startsWith('${p.toLowerCase()}\\')) {
          return true;
        }
      }
      return false;
    }
    if (Platform.isLinux) return exe.startsWith('/opt/markdown-studio/');
    return false;
  }
}
