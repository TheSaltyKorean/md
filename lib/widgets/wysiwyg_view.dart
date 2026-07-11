import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:flutter/material.dart';

import '../state/document_controller.dart';
import 'wysiwyg_copy.dart';

/// Hosts the AppFlowy block-style WYSIWYG editor. The editor is keyed on the
/// controller's [DocumentController.editorEpoch] so it rebuilds cleanly when the
/// underlying [EditorState] is replaced (e.g. after opening a file or switching
/// back from the source view).
///
/// AppFlowy provides slash-commands (type "/"), a selection toolbar, and the
/// usual keyboard shortcuts out of the box, so no custom toolbar is required.
class WysiwygView extends StatelessWidget {
  const WysiwygView({super.key, required this.controller});

  final DocumentController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final editorStyle = EditorStyle.desktop(
      cursorColor: theme.colorScheme.primary,
      selectionColor: theme.colorScheme.primary.withValues(alpha: 0.25),
      // AppFlowy ignores the ambient MediaQuery text scaler and applies its
      // own factor. Re-derive it from the ambient scaler (accessibility text
      // size × document zoom, composed by EditorScreen) against this
      // editor's 16pt base, so all view modes scale identically.
      textScaleFactor: MediaQuery.textScalerOf(context).scale(16) / 16,
      textStyleConfiguration: TextStyleConfiguration(
        text: theme.textTheme.bodyLarge!.copyWith(
          fontSize: 16,
          height: 1.6,
          color: theme.colorScheme.onSurface,
        ),
      ),
    ).copyWith(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
    );

    return Container(
      color: theme.colorScheme.surface,
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 900),
        child: AppFlowyEditor(
          key: ValueKey('appflowy-${controller.editorEpoch}'),
          editorState: controller.editorState,
          editorStyle: editorStyle,
          shrinkWrap: false,
          // Replace the built-in plain-text copy with one that also puts rich
          // HTML on the clipboard, so paste keeps formatting (see wysiwyg_copy).
          commandShortcutEvents: wysiwygCommandShortcutEvents(),
        ),
      ),
    );
  }
}
