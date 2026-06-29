import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';

import 'screens/editor_screen.dart';
import 'state/theme_controller.dart';
import 'theme/app_theme.dart';

/// Root widget: wires the [ThemeController] to a Material 3 [MaterialApp] and
/// registers the localization delegates the AppFlowy editor depends on.
class MarkdownStudioApp extends StatelessWidget {
  const MarkdownStudioApp({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = context.watch<ThemeController>();

    return MaterialApp(
      title: 'Markdown Studio',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: theme.mode,
      localizationsDelegates: const [
        AppFlowyEditorLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [Locale('en')],
      home: const EditorScreen(),
    );
  }
}
