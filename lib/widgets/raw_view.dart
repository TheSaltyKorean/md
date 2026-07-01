import 'package:flutter/material.dart';

import '../state/document_controller.dart';
import 'find_controller.dart';
import 'find_replace_bar.dart';
import 'source_pane.dart';

/// Full-width raw Markdown source editor — like the [SplitView] source pane but
/// with no rendered preview. For editing the literal Markdown text directly.
///
/// Named `RawSourceView` (not `RawView`) to avoid clashing with Flutter's own
/// `RawView` widget.
class RawSourceView extends StatefulWidget {
  const RawSourceView({
    super.key,
    required this.controller,
    required this.find,
  });

  final DocumentController controller;
  final FindController find;

  @override
  State<RawSourceView> createState() => _RawSourceViewState();
}

class _RawSourceViewState extends State<RawSourceView> {
  final ScrollController _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.find,
      builder: (context, _) => Stack(
        children: [
          Positioned.fill(
            child: SourcePane(
              controller: widget.controller,
              scrollController: _scroll,
            ),
          ),
          if (widget.find.visible)
            Positioned.fill(
              child: FindReplaceBar(
                find: widget.find,
                target: widget.controller.sourceController,
                scroll: _scroll,
              ),
            ),
        ],
      ),
    );
  }
}
