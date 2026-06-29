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
  /// user hasn't already decided, and we're not already the handler.
  Future<bool> shouldPrompt() async {
    if (!isSupported) return false;
    if (_prefs.getBool(_doneKey) ?? false) return false;
    return !(await isAssociated());
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
    var ok = false;
    for (final mime in ['text/markdown', 'text/x-markdown']) {
      final res = await Process.run(
          'xdg-mime', ['default', 'markdown_studio.desktop', mime]);
      ok = ok || res.exitCode == 0;
    }
    return ok;
  }
}
