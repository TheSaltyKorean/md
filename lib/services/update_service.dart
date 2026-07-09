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
  String get setupExeUrl => '$_base/markdown-studio-windows-x64-setup.exe';
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
      // Anchored — a malformed tag like '1.2.3oops' must not prompt — but a
      // '+build' suffix is tolerated: on Windows PackageInfo.version can
      // carry it (the exe's ProductVersion string is '1.0.5+6'), and the
      // running version failing to parse silently disabled every check.
      final m = RegExp(r'^(\d+)\.(\d+)\.(\d+)(?:\+\d+)?$').firstMatch(v.trim());
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
    void Function(double progress) onProgress, {
    bool Function()? isCancelled,
    void Function(void Function() abort)? onAbortAvailable,
  }) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    // Cancel must bite immediately even when the connection is stalled (no
    // chunk arriving to observe the flag on): force-closing the client
    // errors the stream right away.
    onAbortAvailable?.call(() => client.close(force: true));
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
      // A private, freshly created temp directory (mkdtemp semantics: owner
      // only) — writing a predictable name straight into the shared system
      // temp would let another local user pre-plant a symlink and swap the
      // installer we hand to the OS.
      final dir = Directory.systemTemp.createTempSync('markdown-studio-');
      final file = File('${dir.path}${Platform.pathSeparator}$filename');
      final sink = file.openWrite();
      var received = 0;
      try {
        await for (final chunk
            in response.timeout(const Duration(seconds: 30))) {
          if (isCancelled?.call() ?? false) {
            // Abort for real: stop reading (cancels the subscription and
            // the connection) and remove the partial file.
            throw const UpdateCancelled();
          }
          sink.add(chunk);
          received += chunk.length;
          onProgress(total > 0 ? received / total : -1);
        }
      } catch (_) {
        await sink.close();
        try {
          file.deleteSync();
        } catch (_) {/* best effort */}
        rethrow;
      }
      await sink.close();
      return file.path;
    } finally {
      client.close();
    }
  }

  /// Hand the downloaded installer to the OS, matching the install channel.
  ///
  /// On Windows the per-user MSI/Inno installers run **silently** and
  /// in-place — no admin, no prompts — via a tiny generated VBScript (run
  /// with wscript: GUI subsystem, so no console window, and we author the
  /// file directly, avoiding cmd quoting). The script: (1) waits for this
  /// exact process id to exit — the exe/DLLs stay loaded until then, so file
  /// replacement never races shutdown — (2) runs the installer and waits for
  /// it, then (3) relaunches the (same-path) app. The whole update is
  /// hands-off: the app closes, updates, and reopens on its own.
  /// Linux opens the .deb in the system installer.
  Future<void> launchInstaller(String path, InstallKind kind) async {
    switch (kind) {
      case InstallKind.msi || InstallKind.inno:
        // /passive (MSI) and /SILENT (Inno) show an unattended progress
        // bar and need no interaction; per-user scope means no elevation.
        final command = kind == InstallKind.msi
            ? 'msiexec /i "$path" /passive /norestart'
            : '"$path" /SILENT /SUPPRESSMSGBOXES /NORESTART';
        final script = windowsLauncherScript(
          waitForPid: pid,
          installerCommand: command,
          relaunchExe: Platform.resolvedExecutable,
        );
        final vbs = File(
            '${File(path).parent.path}${Platform.pathSeparator}run-update.vbs');
        vbs.writeAsStringSync(script);
        await Process.start('wscript', [vbs.path],
            mode: ProcessStartMode.detached);
      case InstallKind.deb:
        await Process.start('xdg-open', [path],
            mode: ProcessStartMode.detached);
      case InstallKind.other:
        throw UnsupportedError('no installer launcher for this install');
    }
  }

  /// The Windows launcher script: wait until [waitForPid] is gone, run
  /// [installerCommand] and wait for it, then relaunch [relaunchExe]. Lives
  /// in the same private temp directory as the downloaded installer.
  ///
  /// `WScript.Shell.Run` takes a single command line, so quote any path
  /// inside [installerCommand] with real `"` — they're VBS-escaped (doubled)
  /// on the way in. Both installers are GUI apps, so no console appears.
  @visibleForTesting
  static String windowsLauncherScript({
    required int waitForPid,
    required String installerCommand,
    required String relaunchExe,
  }) {
    String vbs(String v) => v.replaceAll('"', '""');
    return '''
Set wmi = GetObject("winmgmts:root\\cimv2")
Do While wmi.ExecQuery("SELECT ProcessId FROM Win32_Process WHERE ProcessId = $waitForPid").Count > 0
  WScript.Sleep 200
Loop
Dim sh : Set sh = CreateObject("WScript.Shell")
sh.Run "${vbs(installerCommand)}", 1, True
sh.Run """${vbs(relaunchExe)}""", 1, False
''';
  }

  /// How this copy was installed — decides the one-click update artifact.
  InstallKind get installKind {
    if (kIsWeb) return InstallKind.other;
    final exe = Platform.resolvedExecutable;
    return detectInstallKind(
      exe: exe,
      env: Platform.environment,
      isWindows: Platform.isWindows,
      isLinux: Platform.isLinux,
      hasInnoUninstaller: Platform.isWindows &&
          File('${File(exe).parent.path}\\unins000.exe').existsSync(),
    );
  }

  /// Pure decision behind [installKind]. Since 1.0.9 the per-user MSI and
  /// Inno installers live under `%LocalAppData%\Programs\Markdown Studio`,
  /// the only one-click-updatable location. MSI only MajorUpgrades MSI
  /// installs, so serving it over an Inno install would leave duplicate
  /// uninstall state — Inno leaves its `unins000.exe` beside the app, which
  /// is the discriminator.
  ///
  /// A legacy per-machine **Program Files** copy is deliberately NOT
  /// one-click: a per-user MSI can't major-upgrade a per-machine install
  /// (different context), so it would install alongside and the launcher
  /// would relaunch the old Program Files exe — an endless "update
  /// available" loop. Those (plus Store/WindowsApps, portable, and dev
  /// copies) route to the download page for the one-time manual migration.
  @visibleForTesting
  static InstallKind detectInstallKind({
    required String exe,
    required Map<String, String> env,
    required bool isWindows,
    required bool isLinux,
    required bool hasInnoUninstaller,
  }) {
    final lower = exe.toLowerCase();
    if (isWindows) {
      final localApps = env['LocalAppData'];
      if (localApps != null &&
          localApps.isNotEmpty &&
          lower.startsWith('${localApps.toLowerCase()}\\programs\\')) {
        return hasInnoUninstaller ? InstallKind.inno : InstallKind.msi;
      }
      return InstallKind.other;
    }
    if (isLinux && lower.startsWith('/opt/markdown-studio/')) {
      return InstallKind.deb;
    }
    return InstallKind.other;
  }
}

/// Thrown when the user cancels a download mid-stream.
class UpdateCancelled implements Exception {
  const UpdateCancelled();
}

/// The install channel a one-click update must match.
enum InstallKind {
  /// Windows MSI — update via msiexec MajorUpgrade.
  msi,

  /// Windows Inno setup.exe — update by running the new setup.exe
  /// (same AppId upgrades in place).
  inno,

  /// Linux .deb under /opt — update by opening the new .deb.
  deb,

  /// Portable, store, mobile, or dev copy — no one-click; download page.
  other;

  bool get canOneClick => this != InstallKind.other;
}
