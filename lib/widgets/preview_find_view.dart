import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../state/zoom_controller.dart';
import 'find_controller.dart';
import 'preview_view.dart';

/// Preview (read-only) mode with in-place find: a [PreviewView] plus a compact
/// find bar that highlights every occurrence of the query in the RENDERED
/// document, emphasizes the current match, and scrolls it into view — so find
/// works without leaving Preview for the raw source.
class PreviewFindView extends StatefulWidget {
  const PreviewFindView({
    super.key,
    required this.markdown,
    required this.find,
  });

  final String markdown;
  final FindController find;

  @override
  State<PreviewFindView> createState() => _PreviewFindViewState();
}

class _PreviewFindViewState extends State<PreviewFindView> {
  final _scroll = ScrollController();
  final _queryCtl = TextEditingController();
  final _queryFocus = FocusNode();
  // Attached to the current match's rendered fragment so it can be scrolled
  // into view; a GlobalKey binds to exactly one widget, so it always tracks
  // whichever match is current in the latest build.
  final _currentKey = GlobalKey();

  bool _caseSensitive = false;
  bool _wholeWord = false;
  int _current = 0;
  int _matchCount = 0;
  int _lastEpoch = -1;

  @override
  void initState() {
    super.initState();
    widget.find.addListener(_onFindChanged);
    _queryCtl.addListener(_recompute);
    _syncOpen();
  }

  @override
  void didUpdateWidget(covariant PreviewFindView old) {
    super.didUpdateWidget(old);
    if (!identical(old.find, widget.find)) {
      old.find.removeListener(_onFindChanged);
      widget.find.addListener(_onFindChanged);
    }
    // A refreshed document (edited elsewhere, reopened) can change match count.
    if (old.markdown != widget.markdown) _recompute();
  }

  @override
  void dispose() {
    widget.find.removeListener(_onFindChanged);
    _queryCtl.dispose();
    _queryFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onFindChanged() {
    _syncOpen();
    if (mounted) setState(() {});
  }

  /// Focus + select the query field each time find is (re)invoked.
  void _syncOpen() {
    if (widget.find.visible && widget.find.openEpoch != _lastEpoch) {
      _lastEpoch = widget.find.openEpoch;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _queryFocus.requestFocus();
        _queryCtl.selection =
            TextSelection(baseOffset: 0, extentOffset: _queryCtl.text.length);
      });
    }
  }

  /// A query/option change resets to the first match and rebuilds; the true
  /// match count then arrives from the renderer via [_onMatchCount] (exactly
  /// what was highlighted — no phantom code/URL matches).
  void _recompute() {
    setState(() {
      _current = 0;
      if (_queryCtl.text.isEmpty) _matchCount = 0;
    });
    _scrollToCurrent();
  }

  void _onMatchCount(int n) {
    if (!mounted || n == _matchCount) return;
    setState(() {
      _matchCount = n;
      final maxIdx = n == 0 ? 0 : n - 1;
      if (_current > maxIdx) _current = maxIdx;
    });
    _scrollToCurrent();
  }

  void _next() {
    if (_matchCount == 0) return;
    setState(() => _current = (_current + 1) % _matchCount);
    _scrollToCurrent();
  }

  void _prev() {
    if (_matchCount == 0) return;
    setState(() => _current = (_current - 1 + _matchCount) % _matchCount);
    _scrollToCurrent();
  }

  void _scrollToCurrent() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _currentKey.currentContext;
      if (ctx != null) {
        Scrollable.ensureVisible(ctx,
            alignment: 0.3,
            duration: const Duration(milliseconds: 160),
            curve: Curves.easeOut);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final visible = widget.find.visible;
    final query = visible ? _queryCtl.text : null;
    return Stack(
      children: [
        Positioned.fill(
          child: PreviewView(
            markdown: widget.markdown,
            controller: _scroll,
            highlightQuery: query,
            highlightCaseSensitive: _caseSensitive,
            highlightWholeWord: _wholeWord,
            currentMatch: _current,
            currentMatchKey: _currentKey,
            onMatchCount: _onMatchCount,
          ),
        ),
        if (visible)
          // Bind left AND right so the bar can never exceed the viewport on
          // narrow/mobile layouts; it aligns to the right within that space.
          Positioned(
            top: 8,
            left: 8,
            right: 8,
            child: Align(
              alignment: Alignment.topRight,
              // The bar is app chrome mounted inside the zoomed document
              // subtree; shed the document zoom (keep the platform/
              // accessibility scale) so it stays 100% and doesn't overgrow.
              child: Builder(builder: (context) {
                final scaler = MediaQuery.textScalerOf(context);
                return MediaQuery(
                  data: MediaQuery.of(context).copyWith(
                    textScaler:
                        scaler is ZoomedTextScaler ? scaler.inherited : scaler,
                  ),
                  child: _bar(context),
                );
              }),
            ),
          ),
      ],
    );
  }

  KeyEventResult _onFieldKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.enter) {
      HardwareKeyboard.instance.isShiftPressed ? _prev() : _next();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      widget.find.hide();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Widget _bar(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final has = _queryCtl.text.isNotEmpty;
    final label = !has
        ? ''
        : (_matchCount == 0 ? 'No results' : '${_current + 1}/$_matchCount');
    return Material(
      elevation: 3,
      borderRadius: BorderRadius.circular(8),
      color: cs.surfaceContainerHigh,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Flexible so it shrinks below its 200px preference when the
              // viewport is too narrow for the full bar.
              Flexible(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 200),
                  // Focus wrapper handles Enter → next, Shift+Enter → previous,
                  // Esc → close (matches the source find bar and the tooltips).
                  child: Focus(
                    onKeyEvent: _onFieldKey,
                    child: TextField(
                      controller: _queryCtl,
                      focusNode: _queryFocus,
                      decoration: const InputDecoration(
                        isDense: true,
                        border: InputBorder.none,
                        hintText: 'Find in preview',
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 4),
              if (has)
                Text(label,
                    style: TextStyle(
                      color: _matchCount == 0 ? cs.error : cs.onSurfaceVariant,
                      fontSize: 12,
                    )),
              _toggle(
                  'Aa',
                  'Match case',
                  _caseSensitive,
                  () => setState(() {
                        _caseSensitive = !_caseSensitive;
                        _recompute();
                      })),
              _toggle(
                  'W',
                  'Whole word',
                  _wholeWord,
                  () => setState(() {
                        _wholeWord = !_wholeWord;
                        _recompute();
                      })),
              IconButton(
                tooltip: 'Previous (Shift+Enter)',
                visualDensity: VisualDensity.compact,
                iconSize: 20,
                onPressed: _matchCount == 0 ? null : _prev,
                icon: const Icon(Icons.keyboard_arrow_up_rounded),
              ),
              IconButton(
                tooltip: 'Next (Enter)',
                visualDensity: VisualDensity.compact,
                iconSize: 20,
                onPressed: _matchCount == 0 ? null : _next,
                icon: const Icon(Icons.keyboard_arrow_down_rounded),
              ),
              IconButton(
                tooltip: 'Close (Esc)',
                visualDensity: VisualDensity.compact,
                iconSize: 20,
                onPressed: widget.find.hide,
                icon: const Icon(Icons.close_rounded),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _toggle(String text, String tooltip, bool on, VoidCallback onTap) {
    final cs = Theme.of(context).colorScheme;
    return Tooltip(
      message: tooltip,
      child: InkResponse(
        onTap: onTap,
        radius: 18,
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 1),
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          decoration: BoxDecoration(
            color: on ? cs.primary.withValues(alpha: 0.18) : null,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(text,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: on ? cs.primary : cs.onSurfaceVariant,
              )),
        ),
      ),
    );
  }
}
