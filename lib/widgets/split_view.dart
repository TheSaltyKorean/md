import 'package:flutter/material.dart';

import '../state/document_controller.dart';
import 'find_controller.dart';
import 'find_replace_bar.dart';
import 'preview_view.dart';
import 'source_pane.dart';

/// Raw Markdown source editor and a live rendered preview, laid out **side by
/// side in landscape** and **stacked in portrait** (by screen orientation).
///
/// The two panes are kept in sync:
///  * scrolling either pane proportionally scrolls the other;
///  * moving the caret in the source scrolls the preview to the matching line.
class SplitView extends StatefulWidget {
  const SplitView({super.key, required this.controller, required this.find});

  final DocumentController controller;
  final FindController find;

  @override
  State<SplitView> createState() => _SplitViewState();
}

class _SplitViewState extends State<SplitView> {
  final ScrollController _sourceScroll = ScrollController();
  final ScrollController _previewScroll = ScrollController();

  /// Guards against scroll-sync feedback loops.
  bool _syncing = false;
  int _lastCursorLine = -1;

  TextEditingController get _text => widget.controller.sourceController;

  @override
  void initState() {
    super.initState();
    _sourceScroll.addListener(_onSourceScroll);
    _previewScroll.addListener(_onPreviewScroll);
    _text.addListener(_onTextChanged);
    widget.find.addListener(_onFindChanged);
  }

  @override
  void didUpdateWidget(covariant SplitView old) {
    super.didUpdateWidget(old);
    if (!identical(old.find, widget.find)) {
      old.find.removeListener(_onFindChanged);
      widget.find.addListener(_onFindChanged);
    }
  }

  void _onFindChanged() {
    if (mounted) setState(() {}); // show/hide the find bar overlay
  }

  @override
  void dispose() {
    _sourceScroll.removeListener(_onSourceScroll);
    _previewScroll.removeListener(_onPreviewScroll);
    _text.removeListener(_onTextChanged);
    widget.find.removeListener(_onFindChanged);
    _sourceScroll.dispose();
    _previewScroll.dispose();
    super.dispose();
  }

  double _fraction(ScrollController c) {
    if (!c.hasClients) return 0;
    final max = c.position.maxScrollExtent;
    return max <= 0 ? 0 : (c.offset / max).clamp(0.0, 1.0);
  }

  void _applyFraction(ScrollController target, double fraction) {
    if (!target.hasClients) return;
    final max = target.position.maxScrollExtent;
    target.jumpTo((fraction * max).clamp(0.0, max));
  }

  void _onSourceScroll() {
    if (_syncing) return;
    _syncing = true;
    _applyFraction(_previewScroll, _fraction(_sourceScroll));
    _syncing = false;
  }

  void _onPreviewScroll() {
    if (_syncing) return;
    _syncing = true;
    _applyFraction(_sourceScroll, _fraction(_previewScroll));
    _syncing = false;
  }

  /// Rebuild the preview as the user types, and keep the edited line visible in
  /// the preview by scrolling it to the caret's line fraction.
  void _onTextChanged() {
    setState(() {}); // refresh preview content

    final sel = _text.selection;
    if (!sel.isValid) return;
    final upto =
        _text.text.substring(0, sel.baseOffset.clamp(0, _text.text.length));
    final line = '\n'.allMatches(upto).length;
    final total = '\n'.allMatches(_text.text).length;
    if (line == _lastCursorLine || total == 0) return;
    _lastCursorLine = line;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _syncing) return;
      _syncing = true;
      _applyFraction(_previewScroll, line / total);
      _syncing = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final portrait = MediaQuery.orientationOf(context) == Orientation.portrait;

    final source = Stack(
      children: [
        Positioned.fill(
          child: SourcePane(
            controller: widget.controller,
            scrollController: _sourceScroll,
          ),
        ),
        if (widget.find.visible)
          Positioned.fill(
            child: FindReplaceBar(
              find: widget.find,
              target: widget.controller.sourceController,
              scroll: _sourceScroll,
            ),
          ),
      ],
    );
    final preview = Container(
      color: theme.colorScheme.surface,
      child: PreviewView(
        markdown: _text.text,
        controller: _previewScroll,
      ),
    );

    final divider = portrait
        ? Divider(height: 1, color: theme.colorScheme.outlineVariant)
        : VerticalDivider(width: 1, color: theme.colorScheme.outlineVariant);

    final children = [
      Expanded(child: source),
      divider,
      Expanded(child: preview),
    ];

    return portrait ? Column(children: children) : Row(children: children);
  }
}
