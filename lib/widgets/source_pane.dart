import 'package:flutter/material.dart';

import '../state/document_controller.dart';

/// A plain, full-height monospace editor bound to the document's raw Markdown
/// [DocumentController.sourceController]. Shared by the [SplitView] source pane
/// and the full-width [RawView].
class SourcePane extends StatelessWidget {
  const SourcePane({
    super.key,
    required this.controller,
    this.scrollController,
  });

  final DocumentController controller;

  /// Optional external scroll controller (used by the split view to keep the
  /// source in sync with the preview). When null the field scrolls on its own.
  final ScrollController? scrollController;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      color: theme.colorScheme.surfaceContainerLowest,
      child: TextField(
        controller: controller.sourceController,
        scrollController: scrollController,
        maxLines: null,
        expands: true,
        textAlignVertical: TextAlignVertical.top,
        keyboardType: TextInputType.multiline,
        style: const TextStyle(
          fontFamily: 'monospace',
          fontSize: 14,
          height: 1.5,
        ),
        decoration: const InputDecoration(
          filled: false,
          border: InputBorder.none,
          contentPadding: EdgeInsets.fromLTRB(20, 16, 20, 80),
          hintText: '# Start writing Markdown…',
        ),
      ),
    );
  }
}
