import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

import 'app.dart';
import 'services/file_association_service.dart';
import 'services/open_file_channel.dart';
import 'services/print_profile_service.dart';
import 'services/single_instance_service.dart';
import 'state/theme_controller.dart';
import 'state/workspace_controller.dart';

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
  final workspace = WorkspaceController(prefs);

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
  if (handoffPath != null) {
    await _openHandoff(handoffPath, workspace);
  } else {
    await _openPaths(_fileArgs(args), workspace);
  }

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => ThemeController(prefs)),
        ChangeNotifierProvider(create: (_) => PrintProfileService(prefs)),
        ChangeNotifierProvider<WorkspaceController>.value(value: workspace),
        Provider(create: (_) => FileAssociationService(prefs)),
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
      await file.delete();
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
    await windowManager.focus();
  } catch (_) {/* best effort */}
}
