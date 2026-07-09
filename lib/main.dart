import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

import 'app.dart';
import 'services/file_association_service.dart';
import 'services/open_file_channel.dart';
import 'services/print_profile_service.dart';
import 'services/session_service.dart';
import 'services/single_instance_service.dart';
import 'services/update_service.dart';
import 'state/theme_controller.dart';
import 'state/workspace_controller.dart';
import 'state/zoom_controller.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();

  final single = SingleInstanceService();
  final forceNewWindow = args.contains(SingleInstanceService.newWindowFlag);

  // If another instance is already running (and this isn't an explicit
  // torn-off window), hand our file paths to it and exit so the file opens as a
  // tab in the existing window instead of spawning a second one.
  if (single.isSupported && !forceNewWindow) {
    final isPrimary = await single.tryBecomePrimary();
    if (!isPrimary) {
      // Resolve to absolute paths so the primary (different cwd) opens the
      // right files.
      final paths = _fileArgs(args).map((a) => File(a).absolute.path).toList();
      await single.forward(paths);
      exit(0);
    }
  }

  final prefs = await SharedPreferences.getInstance();
  final handoffPath = _flagValue(args, '--handoff');
  final fileArgs = _fileArgs(args);
  // The session (restore + persist) belongs only to a **plain** primary
  // launch. It's disabled for:
  //  - torn-off (`--new-window` / `--handoff`) windows — a separate process
  //    that would clobber the app-wide session.json (last writer wins);
  //  - a launch that names files (double-click a `.md`) — that should open
  //    exactly those files, and must not overwrite the saved session's
  //    unsaved buffers with only the requested file.
  // The updater's silent relaunch passes no args, so it's a plain launch and
  // restores everything. (Mobile has no argv, so mobile is always plain.)
  final isTornOffWindow = forceNewWindow || handoffPath != null;
  final plainLaunch = !isTornOffWindow && fileArgs.isEmpty;
  final workspace = WorkspaceController(prefs,
      sessionStore: plainLaunch ? FileSessionStore() : null);

  if (single.isSupported) {
    try {
      await windowManager.ensureInitialized();
    } catch (_) {/* window_manager optional */}
    single.onPaths((paths) async {
      await _openPaths(paths, workspace);
      await _bringToFront();
    });
  }

  if (handoffPath != null) {
    await _openHandoff(handoffPath, workspace);
  } else if (fileArgs.isNotEmpty) {
    // Named files: open exactly those (session persistence is off, so the
    // previously saved session survives untouched for the next plain launch).
    await _openPaths(fileArgs, workspace);
  } else {
    // Plain launch (incl. the updater's silent relaunch). On
    // Android/iOS/macOS a launch document arrives via the platform channel,
    // not argv — init it FIRST so, if the app was launched to open a file,
    // that document is present before restore, whose freshness guard then
    // leaves it alone. With no launch document, restore reopens the session.
    if (!kIsWeb && (Platform.isAndroid || Platform.isIOS || Platform.isMacOS)) {
      await OpenFileChannel(workspace).init();
      // If the channel opened a launch document, this run is really a
      // "quick open this file" launch (argv-equivalent). Suspend session
      // persistence so the exit/edit flush writes only-that-file over the
      // saved session; the previous session stays intact for the next plain
      // launch — matching the desktop file-argument behavior above.
      if (workspace.documents.any((d) => !d.isPristine)) {
        workspace.suspendSession();
      }
    }
    await workspace.restoreSession();
  }

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => ThemeController(prefs)),
        ChangeNotifierProvider(create: (_) => ZoomController(prefs)),
        ChangeNotifierProvider(create: (_) => UpdateController(prefs)),
        ChangeNotifierProvider(create: (_) => PrintProfileService(prefs)),
        ChangeNotifierProvider<WorkspaceController>.value(value: workspace),
        Provider(create: (_) => FileAssociationService(prefs)),
        Provider<SingleInstanceService>.value(value: single),
      ],
      child: const MarkdownStudioApp(),
    ),
  );
}

/// File-path arguments (skip flags and the value following `--handoff`).
List<String> _fileArgs(List<String> args) {
  final result = <String>[];
  for (var i = 0; i < args.length; i++) {
    final a = args[i];
    if (a == '--handoff') {
      i++; // skip its value
      continue;
    }
    if (a.isEmpty || a.startsWith('-')) continue;
    result.add(a);
  }
  return result;
}

String? _flagValue(List<String> args, String flag) {
  final i = args.indexOf(flag);
  if (i >= 0 && i + 1 < args.length) return args[i + 1];
  return null;
}

/// Open a torn-off tab handoff (JSON: {path, content, dirty}); preserves edits.
Future<void> _openHandoff(String handoffPath, WorkspaceController ws) async {
  try {
    final file = File(handoffPath);
    final raw = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    ws.openDocument(
      raw['content'] as String? ?? '',
      path: raw['path'] as String?,
      displayName: raw['name'] as String?,
      markDirty: raw['dirty'] as bool? ?? false,
    );
    try {
      // Only recursively remove our own private handoff dir — it must be a
      // mdstudio_handoff_* directory *inside* the system temp root. Otherwise
      // (a stray/crafted --handoff path) delete just the file.
      final dir = file.parent;
      final inTemp = p.isWithin(Directory.systemTemp.path, dir.path);
      if (inTemp && p.basename(dir.path).startsWith('mdstudio_handoff_')) {
        await dir.delete(recursive: true);
      } else {
        await file.delete();
      }
    } catch (_) {/* leave temp file if locked */}
  } catch (_) {
    // Malformed handoff; ignore.
  }
}

/// Open existing files at [paths] as tabs in [ws].
Future<void> _openPaths(List<String> paths, WorkspaceController ws) async {
  for (final path in paths) {
    try {
      final file = File(path);
      if (await file.exists()) {
        final content = await file.readAsString();
        ws.openDocument(content, path: file.absolute.path);
      }
    } catch (_) {
      // Not a readable file path; ignore.
    }
  }
}

Future<void> _bringToFront() async {
  try {
    if (await windowManager.isMinimized()) {
      await windowManager.restore();
    }
    await windowManager.show();
    // Windows blocks background apps from stealing focus, so a plain focus()
    // call often just flashes the taskbar. Briefly forcing always-on-top pulls
    // the window to the foreground. This is best-effort: if a platform/WM
    // rejects always-on-top we must still fall through to show()/focus() (the
    // original behavior), and we drop topmost again afterwards in a finally so a
    // later throw can't leave the window stuck above everything.
    var topped = false;
    try {
      await windowManager.setAlwaysOnTop(true);
      topped = true;
    } catch (_) {/* unsupported — fall back to a plain focus below */}
    try {
      await windowManager.show();
      await windowManager.focus();
    } finally {
      if (topped) {
        try {
          await windowManager.setAlwaysOnTop(false);
        } catch (_) {/* best effort */}
      }
    }
  } catch (_) {/* best effort */}
}
