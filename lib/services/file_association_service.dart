import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Best-effort registration of this app as a handler for `.md` files, plus a
/// once-per-decision "should I prompt?" gate.
///
/// **Installed copies register the association from the installer** (Inno
/// `[Registry]` / MSI advertised ProgId on Windows, the `.desktop` MimeType on
/// the Linux `.deb`), so the app never touches associations there — see
/// [isInstalledCopy]. This runtime path is only a fallback for portable / zip /
/// dev builds that no installer configured:
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
    // Installer-owned copies get their association at install time; never nag.
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
      // The .deb installs the real executable under /opt/markdown-studio; its
      // /usr/bin entry is only a symlink, and resolvedExecutable resolves
      // through it to the /opt path. So /opt is the sole installer-owned root —
      // a portable build unpacked under e.g. /usr/local or $HOME is NOT
      // installed and still gets the runtime prompt.
      return isInstalledPath(
        exe: Platform.resolvedExecutable,
        installRoots: const ['/opt/markdown-studio'],
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

  Future<bool> _associateWindows() async {
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
    // Surface Default Apps so the user can set us as the default for .md.
    await Process.run('cmd', ['/c', 'start', '', 'ms-settings:defaultapps']);
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
