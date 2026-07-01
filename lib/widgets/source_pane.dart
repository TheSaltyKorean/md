import 'package:flutter/material.dart';

import '../state/document_controller.dart';

/// Text style of the raw Markdown source editor. Exposed so a [TextPainter] can
/// measure match positions identically to the field (find & replace scroll).
const TextStyle kSourceTextStyle = TextStyle(
  fontFamily: 'monospace',
  fontSize: 14,
  height: 1.5,
);

/// Content padding inside the source field. Shared with the match-measuring
/// [TextPainter] so computed offsets line up with what's rendered.
const EdgeInsets kSourceContentPadding = EdgeInsets.fromLTRB(20, 16, 20, 80);

/// A plain, full-height monospace editor bound to the document's raw Markdown
/// [DocumentController.sourceController]. Shared by the [SplitView] source pane
/// and the full-width [RawSourceView].
class SourcePane extends StatelessWidget {
  const SourcePane({
    super.key,
    required this.controller,
    this.scrollController,
    this.focusNode,
    this.fieldKey,
  });

  final DocumentController controller;

  /// Optional external scroll controller (used by the split view to keep the
  /// source in sync with the preview). When null the field scrolls on its own.
  final ScrollController? scrollController;

  /// Optional focus node so callers (find & replace) can refocus the editor.
  final FocusNode? focusNode;

  /// Optional key placed on the [TextField] so its size can be measured.
  final Key? fieldKey;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      color: theme.colorScheme.surfaceContainerLowest,
      child: TextField(
        key: fieldKey,
        controller: controller.sourceController,
        scrollController: scrollController,
        focusNode: focusNode,
        maxLines: null,
        expands: true,
        textAlignVertical: TextAlignVertical.top,
        keyboardType: TextInputType.multiline,
        style: kSourceTextStyle,
        decoration: const InputDecoration(
          filled: false,
          border: InputBorder.none,
          contentPadding: kSourceContentPadding,
          hintText: '# Start writing Markdown…',
        ),
      ),
    );
  }
}
