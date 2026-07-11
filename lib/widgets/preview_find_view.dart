import 'package:flutter/material.dart';

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

  RegExp? _regex() {
    final q = _queryCtl.text;
    if (q.isEmpty) return null;
    final body = RegExp.escape(q);
    return RegExp(_wholeWord ? '\\b$body\\b' : body,
        caseSensitive: _caseSensitive);
  }

  void _recompute() {
    final re = _regex();
    final count = re == null ? 0 : re.allMatches(widget.markdown).length;
    setState(() {
      _matchCount = count;
      _current = count == 0 ? 0 : _current.clamp(0, count - 1);
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
          ),
        ),
        if (visible) Positioned(top: 8, right: 8, child: _bar(context)),
      ],
    );
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
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 200,
              child: TextField(
                controller: _queryCtl,
                focusNode: _queryFocus,
                decoration: const InputDecoration(
                  isDense: true,
                  border: InputBorder.none,
                  hintText: 'Find in preview',
                ),
                onSubmitted: (_) => _next(),
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
