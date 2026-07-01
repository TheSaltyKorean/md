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
  final FocusNode _editorFocus = FocusNode(debugLabel: 'raw source');
  bool _wasFindVisible = false;

  @override
  void initState() {
    super.initState();
    _wasFindVisible = widget.find.visible;
    widget.find.addListener(_onFindChanged);
  }

  @override
  void didUpdateWidget(covariant RawSourceView old) {
    super.didUpdateWidget(old);
    if (!identical(old.find, widget.find)) {
      old.find.removeListener(_onFindChanged);
      widget.find.addListener(_onFindChanged);
      _wasFindVisible = widget.find.visible;
    }
  }

  void _onFindChanged() {
    // When the find bar closes, return focus to the editor so typing continues.
    if (_wasFindVisible && !widget.find.visible) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _editorFocus.requestFocus();
      });
    }
    _wasFindVisible = widget.find.visible;
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.find.removeListener(_onFindChanged);
    _scroll.dispose();
    _editorFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned.fill(
          child: SourcePane(
            controller: widget.controller,
            scrollController: _scroll,
            focusNode: _editorFocus,
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
    );
  }
}
