import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Best-effort registration of this app as a handler for `.md` files, plus a
/// once-per-decision "should I prompt?" gate.
///
/// Runtime association is only meaningful on desktop:
///  * **Windows** — register a per-user ProgID under `HKCU\Software\Classes`
///    and surface the Default Apps settings so the user can confirm the default.
///  * **Linux** — `xdg-mime default` for `text/markdown`.
///
/// On Android/iOS/macOS, associations are declared in the app manifest/Info.plist
/// at build time, not set at runtime, so [isSupported] is false there and the
/// app never prompts.
class FileAssociationService {
  FileAssociationService(this._prefs);

  static const _doneKey = 'assoc_prompt_done';
  static const progId = 'MarkdownStudio.md';

  final SharedPreferences _prefs;

  bool get isSupported => !kIsWeb && (Platform.isWindows || Platform.isLinux);

  /// Whether to show the association prompt on launch: supported platform, the
  /// user hasn't already decided, we're not already the handler, and we're not
  /// running from an installed location.
  ///
  /// Installed copies register the association from the installer (Inno/WiX
  /// `[Registry]` on Windows, the `.desktop` MimeType on the Linux `.deb`), so
  /// the app must not nag about it at first run. Only portable/zip/dev builds —
  /// which no installer touched — still fall back to the runtime prompt.
  Future<bool> shouldPrompt() async {
    if (!isSupported) return false;
    if (_prefs.getBool(_doneKey) ?? false) return false;
    if (isInstalledCopy()) return false;
    return !(await isAssociated());
  }

  /// True when this executable lives under a location an installer owns, so
  /// the package (not the app) is responsible for the file association.
  bool isInstalledCopy() {
    if (kIsWeb) return false;
    if (Platform.isWindows) {
      final localApps = Platform.environment['LocalAppData'];
      return isInstalledPath(
        exe: Platform.resolvedExecutable,
        installRoots: [
          if (localApps != null && localApps.isNotEmpty) '$localApps\\Programs',
          Platform.environment['ProgramFiles'],
          Platform.environment['ProgramFiles(x86)'],
        ],
        separator: '\\',
      );
    }
    if (Platform.isLinux) {
      // The .deb installs under /opt/markdown-studio; the /usr/bin launcher is
      // a symlink but resolvedExecutable resolves to the real /opt path.
      return isInstalledPath(
        exe: Platform.resolvedExecutable,
        installRoots: const ['/opt', '/usr'],
        separator: '/',
      );
    }
    return false;
  }

  /// Pure decision for [isInstalledCopy]: whether [exe] sits under one of the
  /// [installRoots] (case-insensitive, path-separator aware).
  @visibleForTesting
  static bool isInstalledPath({
    required String exe,
    required List<String?> installRoots,
    required String separator,
  }) {
    final e = exe.toLowerCase();
    return installRoots.whereType<String>().any((root) {
      if (root.isEmpty) return false;
      return e.startsWith('${root.toLowerCase()}$separator');
    });
  }

  /// Record that the user has made a decision so we stop prompting.
  Future<void> markDecided() => _prefs.setBool(_doneKey, true);

  Future<bool> isAssociated() async {
    try {
      if (Platform.isWindows) {
        final res = await Process.run('reg', [
          'query',
          r'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts\.md\UserChoice',
          '/v',
          'ProgId',
        ]);
        return res.stdout.toString().contains(progId);
      }
      if (Platform.isLinux) {
        final res = await Process.run(
            'xdg-mime', ['query', 'default', 'text/markdown']);
        return res.stdout.toString().contains('markdown_studio');
      }
    } catch (_) {/* tools absent → treat as not associated */}
    return false;
  }

  /// Register this app as a `.md` handler. Returns true if registration ran
  /// without error. On Windows the user must still confirm the default in the
  /// Settings pane we open for them.
  Future<bool> associate() async {
    try {
      if (Platform.isWindows) {
        return _associateWindows();
      }
      if (Platform.isLinux) {
        return _associateLinux();
      }
    } catch (e) {
      debugPrint('associate failed: $e');
    }
    return false;
  }

  /// Windows self-heal: if our ProgID's open command points at a *different*
  /// executable than the one running — classic case: a locally built copy
  /// registered the association, then the user installed the app, so
  /// double-clicking `.md` files keeps launching the stale build — re-point
  /// the registration to this executable. Only an **installed** copy (the
  /// per-user `%LocalAppData%\Programs` location, or a legacy Program Files
  /// one) asserts ownership; ad-hoc dev builds never silently steal the
  /// association back. Runs quietly (no Settings pane).
  Future<void> repairRegistrationIfNeeded() async {
    if (kIsWeb || !Platform.isWindows) return;
    try {
      final res = await Process.run('reg', [
        'query',
        'HKCU\\Software\\Classes\\$progId\\shell\\open\\command',
        '/ve',
      ]);
      if (res.exitCode != 0) return; // never registered — nothing to repair
      final localApps = Platform.environment['LocalAppData'];
      if (needsRepair(
        exe: Platform.resolvedExecutable,
        programDirs: [
          // The per-user install root (since 1.0.9).
          if (localApps != null && localApps.isNotEmpty) '$localApps\\Programs',
          // Legacy per-machine installs.
          Platform.environment['ProgramFiles'],
          Platform.environment['ProgramFiles(x86)'],
        ],
        registeredCommand: res.stdout.toString(),
      )) {
        await _associateWindows(openSettings: false);
      }
    } catch (_) {/* best effort */}
  }

  /// Pure decision for [repairRegistrationIfNeeded]: repair only when this
  /// executable lives under one of the install directories (an installed
  /// copy) and the registered open command doesn't already point at it.
  @visibleForTesting
  static bool needsRepair({
    required String exe,
    required List<String?> programDirs,
    required String? registeredCommand,
  }) {
    if (registeredCommand == null) return false;
    final e = exe.toLowerCase();
    final installed = programDirs
        .whereType<String>()
        .any((p) => p.isNotEmpty && e.startsWith('${p.toLowerCase()}\\'));
    if (!installed) return false;
    return !registeredCommand.toLowerCase().contains(e);
  }

  Future<bool> _associateWindows({bool openSettings = true}) async {
    final exe = Platform.resolvedExecutable.replaceAll(r'\', r'\\');
    final reg = StringBuffer()
      ..writeln('Windows Registry Editor Version 5.00')
      ..writeln()
      ..writeln('[HKEY_CURRENT_USER\\Software\\Classes\\$progId]')
      ..writeln('@="Markdown Document"')
      ..writeln()
      ..writeln('[HKEY_CURRENT_USER\\Software\\Classes\\$progId\\DefaultIcon]')
      ..writeln('@="\\"$exe\\",0"')
      ..writeln()
      ..writeln(
          '[HKEY_CURRENT_USER\\Software\\Classes\\$progId\\shell\\open\\command]')
      ..writeln('@="\\"$exe\\" \\"%1\\""')
      ..writeln()
      ..writeln('[HKEY_CURRENT_USER\\Software\\Classes\\.md\\OpenWithProgids]')
      ..writeln('"$progId"=hex(0):');

    final file = File('${Directory.systemTemp.path}\\md_assoc.reg');
    await file.writeAsString(reg.toString());
    final res = await Process.run('reg', ['import', file.path]);
    if (openSettings) {
      // Surface Default Apps so the user can set us as the default for .md.
      await Process.run('cmd', ['/c', 'start', '', 'ms-settings:defaultapps']);
    }
    return res.exitCode == 0;
  }

  Future<bool> _associateLinux() async {
    final home = Platform.environment['HOME'];
    if (home == null) return false;

    // Install a desktop entry so the MIME default points at a real handler
    // (otherwise xdg-mime default references a non-existent .desktop file).
    final appsDir = Directory('$home/.local/share/applications');
    await appsDir.create(recursive: true);
    final exe = Platform.resolvedExecutable;
    final desktop = File('${appsDir.path}/markdown_studio.desktop');
    await desktop.writeAsString('''[Desktop Entry]
Type=Application
Name=Markdown Studio
Comment=Markdown viewer and WYSIWYG editor
Exec="$exe" %F
Icon=markdown_studio
Terminal=false
Categories=Office;TextEditor;Utility;
MimeType=text/markdown;text/x-markdown;
''');
    try {
      await Process.run('update-desktop-database', [appsDir.path]);
    } catch (_) {/* optional, may be absent */}

    var ok = false;
    for (final mime in ['text/markdown', 'text/x-markdown']) {
      final res = await Process.run(
          'xdg-mime', ['default', 'markdown_studio.desktop', mime]);
      ok = ok || res.exitCode == 0;
    }
    return ok;
  }
}
