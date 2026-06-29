import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app.dart';
import 'services/file_association_service.dart';
import 'services/print_profile_service.dart';
import 'state/theme_controller.dart';
import 'state/workspace_controller.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();

  // Build the workspace up front so files passed on the command line (e.g. when
  // the OS launches the app by double-clicking a .md file) are open before the
  // first frame. Desktop embedders forward argv to the Dart entrypoint.
  final workspace = WorkspaceController(prefs);
  await _openLaunchFiles(args, workspace);

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

/// Open any existing files passed as command-line arguments. Used for OS file
/// associations on desktop (Windows/Linux), where the file path arrives in argv.
Future<void> _openLaunchFiles(List<String> args, WorkspaceController ws) async {
  for (final arg in args) {
    if (arg.isEmpty || arg.startsWith('-')) continue; // skip flags
    try {
      final file = File(arg);
      if (await file.exists()) {
        final content = await file.readAsString();
        ws.openDocument(content, path: file.absolute.path);
      }
    } catch (_) {
      // Not a readable file path; ignore.
    }
  }
}
