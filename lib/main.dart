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
  // Only the primary window owns the session. A torn-off (`--new-window`)
  // window is a separate process; if it also wrote the app-wide session.json,
  // two windows would clobber each other's snapshot (last writer wins). Those
  // windows run without session persistence — the primary remembers the tabs.
  final isTornOffWindow =
      forceNewWindow || _flagValue(args, '--handoff') != null;
  final workspace = WorkspaceController(prefs,
      sessionStore: isTornOffWindow ? null : FileSessionStore());

  if (single.isSupported) {
    try {
      await windowManager.ensureInitialized();
    } catch (_) {/* window_manager optional */}
    single.onPaths((paths) async {
      await _openPaths(paths, workspace);
      await _bringToFront();
    });
  }

  // On Android/iOS/macOS, document opens arrive as intents/URLs rather than
  // argv — wire up the platform channel that receives them.
  if (!kIsWeb && (Platform.isAndroid || Platform.isIOS || Platform.isMacOS)) {
    await OpenFileChannel(workspace).init();
  }

  // A torn-off tab is handed off via a temp JSON file carrying its (possibly
  // unsaved) content, so edits aren't lost when it opens in the new window.
  final handoffPath = _flagValue(args, '--handoff');
  final fileArgs = _fileArgs(args);
  if (handoffPath != null) {
    await _openHandoff(handoffPath, workspace);
  } else if (fileArgs.isNotEmpty) {
    await _openPaths(fileArgs, workspace);
  } else {
    // A plain launch (including the updater's silent relaunch) reopens the
    // previous session — tabs, unsaved buffers, and the active document.
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
