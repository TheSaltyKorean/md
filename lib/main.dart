import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app.dart';
import 'services/file_association_service.dart';
import 'services/print_profile_service.dart';
import 'state/theme_controller.dart';
import 'state/workspace_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => ThemeController(prefs)),
        ChangeNotifierProvider(create: (_) => PrintProfileService(prefs)),
        ChangeNotifierProvider(create: (_) => WorkspaceController(prefs)),
        Provider(create: (_) => FileAssociationService(prefs)),
      ],
      child: const MarkdownStudioApp(),
    ),
  );
}
