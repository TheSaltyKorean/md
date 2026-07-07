import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/text_search.dart';
import 'find_controller.dart';
import 'source_pane.dart';

/// A VS Code-style find & replace bar that overlays a source editor. It searches
/// and edits the raw Markdown in [target], highlights matches, scrolls the
/// matched text into view via [scroll], and (in replace mode) rewrites [target].
///
/// Place it as a `Positioned.fill` sibling *above* the source [TextField] in a
/// [Stack]; the highlight layer ignores pointer events so the editor stays
/// interactive, and only the control card in the top-right is hit-testable.
class FindReplaceBar extends StatefulWidget {
  const FindReplaceBar({
    super.key,
    required this.find,
    required this.target,
    required this.scroll,
  });

  final FindController find;
  final TextEditingController target;
  final ScrollController scroll;

  @override
  State<FindReplaceBar> createState() => _FindReplaceBarState();
}

class _FindReplaceBarState extends State<FindReplaceBar> {
  final TextEditingController _query = TextEditingController();
  final TextEditingController _replace = TextEditingController();
  final FocusNode _queryFocus = FocusNode();

  SearchOptions _options = const SearchOptions();
  List<TextMatch> _matches = const [];
  int _current = -1;
  String? _error;

  // Cached match rectangles in text-space (before scroll translation), so the
  // highlight layer can repaint cheaply on every scroll frame.
  List<Rect> _rects = const [];
  List<int> _rectMatch = const [];
  double _layoutWidth = 0;
  String _rectText = '';

  // Latest measured editor height, captured in build for scroll math.
  double _areaH = 0;

  // Text scale of the source field, so measurements line up under OS scaling.
  TextScaler _textScaler = TextScaler.noScaling;

  String _lastText = '';
  bool _selfEdit = false;

  @override
  void initState() {
    super.initState();
    _lastText = widget.target.text;
    widget.target.addListener(_onTargetChanged);
    widget.find.addListener(_onFindChanged);
    _recompute(moveToCaret: true);
    WidgetsBinding.instance.addPostFrameCallback((_) => _focusQuery());
  }

  @override
  void didUpdateWidget(covariant FindReplaceBar old) {
    super.didUpdateWidget(old);
    if (!identical(old.target, widget.target)) {
      old.target.removeListener(_onTargetChanged);
      widget.target.addListener(_onTargetChanged);
      _lastText = widget.target.text;
      _recompute(moveToCaret: true);
    }
    if (!identical(old.find, widget.find)) {
      old.find.removeListener(_onFindChanged);
      widget.find.addListener(_onFindChanged);
    }
  }

  @override
  void dispose() {
    widget.target.removeListener(_onTargetChanged);
    widget.find.removeListener(_onFindChanged);
    _query.dispose();
    _replace.dispose();
    _queryFocus.dispose();
    super.dispose();
  }

  void _onFindChanged() {
    // The bar is (re)opened — pull focus back to the query field and reselect.
    if (widget.find.visible) _focusQuery();
    // Reflect replace-row toggles even when no parent rebuilds us.
    if (mounted) setState(() {});
  }

  void _focusQuery() {
    if (!mounted) return;
    _queryFocus.requestFocus();
    _query.selection =
        TextSelection(baseOffset: 0, extentOffset: _query.text.length);
  }

  void _onTargetChanged() {
    if (_selfEdit) return;
    if (widget.target.text == _lastText) return; // selection-only change
    _lastText = widget.target.text;
    _recompute();
  }

  void _recompute({bool moveToCaret = false}) {
    final text = widget.target.text;
    final pattern = TextSearch.compile(_query.text, _options);
    setState(() {
      _error = pattern.error;
      _matches = TextSearch.matchesOf(text, pattern);
      if (_matches.isEmpty) {
        _current = -1;
      } else if (moveToCaret) {
        final caret =
            widget.target.selection.isValid ? widget.target.selection.start : 0;
        final at = _matches.indexWhere((m) => m.start >= caret);
        _current = at >= 0 ? at : 0;
      } else {
        _current = _current.clamp(0, _matches.length - 1);
      }
      _rebuildRects(text);
    });
    // Reveal the current match on the initial search / option change too, not
    // just on Next/Previous (no-op until the field has been laid out).
    _revealCurrent();
  }

  void _rebuildRects(String text) {
    if (_matches.isEmpty || _layoutWidth <= 0) {
      _rects = const [];
      _rectMatch = const [];
      _rectText = text;
      return;
    }
    final tp = TextPainter(
      text: TextSpan(text: text, style: kSourceTextStyle),
      textDirection: TextDirection.ltr,
      textScaler: _textScaler,
    )..layout(maxWidth: _layoutWidth);
    final rects = <Rect>[];
    final owner = <int>[];
    for (var i = 0; i < _matches.length; i++) {
      final m = _matches[i];
      for (final b in tp.getBoxesForSelection(
          TextSelection(baseOffset: m.start, extentOffset: m.end))) {
        rects.add(Rect.fromLTRB(b.left, b.top, b.right, b.bottom));
        owner.add(i);
      }
    }
    _rects = rects;
    _rectMatch = owner;
    _rectText = text;
  }

  // --- Navigation & reveal ----------------------------------------------------

  void _next() => _move(1);
  void _prev() => _move(-1);

  void _move(int delta) {
    if (_matches.isEmpty) return;
    setState(() {
      _current = (_current + delta) % _matches.length;
      if (_current < 0) _current += _matches.length;
    });
    _revealCurrent();
  }

  void _revealCurrent() {
    if (_current < 0 || _current >= _matches.length) return;
    final m = _matches[_current];
    // Set the field selection so the match is where the caret lands when the
    // user dismisses the bar and resumes editing.
    widget.target.selection =
        TextSelection(baseOffset: m.start, extentOffset: m.end);
    _lastText = widget.target.text; // selection set doesn't change text

    final scroll = widget.scroll;
    if (!scroll.hasClients || _layoutWidth <= 0) return;
    final tp = TextPainter(
      text: TextSpan(text: widget.target.text, style: kSourceTextStyle),
      textDirection: TextDirection.ltr,
      textScaler: _textScaler,
    )..layout(maxWidth: _layoutWidth);
    final caret =
        tp.getOffsetForCaret(TextPosition(offset: m.start), Rect.zero);
    final lineHeight = kSourceTextStyle.fontSize! * kSourceTextStyle.height!;
    final matchTop = caret.dy + kSourceContentPadding.top;
    final viewport = _areaH;
    final cur = scroll.offset;
    final max = scroll.position.maxScrollExtent;
    final visibleTop = cur + lineHeight;
    final visibleBottom = cur + viewport - lineHeight;
    if (matchTop < visibleTop || matchTop + lineHeight > visibleBottom) {
      final desired = (matchTop - viewport / 3).clamp(0.0, max);
      scroll.animateTo(desired,
          duration: const Duration(milliseconds: 160), curve: Curves.easeOut);
    }
  }

  // --- Replace ----------------------------------------------------------------

  void _replaceCurrent() {
    if (_current < 0 || _current >= _matches.length) return;
    final m = _matches[_current];
    final text = widget.target.text;
    // Guard against a stale match (text changed underneath us).
    if (m.end > text.length) {
      _recompute();
      return;
    }
    final replacement = _replace.text;
    final newText = TextSearch.replaceMatches(text, [m], replacement);
    final caretAfter = m.start + replacement.length;
    _applyText(newText, caretAfter);
    // Recompute and keep pointing at the first match at/after the edit.
    _recomputeAfterEdit(caretAfter);
  }

  void _replaceAll() {
    if (_matches.isEmpty) return;
    final text = widget.target.text;
    final replacement = _replace.text;
    final count = _matches.length;
    final newText = TextSearch.replaceMatches(text, _matches, replacement);
    _applyText(newText, newText.length);
    _recompute();
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.showSnackBar(SnackBar(
        content: Text('Replaced $count ${count == 1 ? "match" : "matches"}')));
  }

  void _applyText(String newText, int caret) {
    _selfEdit = true;
    widget.target.value = TextEditingValue(
      text: newText,
      selection:
          TextSelection.collapsed(offset: caret.clamp(0, newText.length)),
    );
    _lastText = newText;
    _selfEdit = false;
  }

  void _recomputeAfterEdit(int caret) {
    final text = widget.target.text;
    final pattern = TextSearch.compile(_query.text, _options);
    setState(() {
      _error = pattern.error;
      _matches = TextSearch.matchesOf(text, pattern);
      if (_matches.isEmpty) {
        _current = -1;
      } else {
        final at = _matches.indexWhere((m) => m.start >= caret);
        _current = at >= 0 ? at : 0;
      }
      _rebuildRects(text);
    });
    _revealCurrent();
  }

  void _setOptions(SearchOptions o) {
    _options = o;
    _recompute(moveToCaret: true);
  }

  KeyEventResult _onQueryKey(FocusNode node, KeyEvent event) {
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

  // --- UI ---------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        _areaH = constraints.maxHeight;
        // The scaler participates in the cache key: document zoom (or an OS
        // text-size change) resizes the source text, so the cached match
        // rectangles must be re-measured or the overlays drift.
        final scaler = MediaQuery.textScalerOf(context);
        final layoutWidth = w - kSourceContentPadding.horizontal;
        if (layoutWidth != _layoutWidth ||
            _rectText != widget.target.text ||
            scaler != _textScaler) {
          _layoutWidth = layoutWidth;
          _textScaler = scaler;
          _rebuildRects(widget.target.text);
        }
        return Stack(
          children: [
            Positioned.fill(
              child: IgnorePointer(
                child: AnimatedBuilder(
                  animation: widget.scroll,
                  builder: (context, _) => CustomPaint(
                    painter: _HighlightPainter(
                      rects: _rects,
                      rectMatch: _rectMatch,
                      current: _current,
                      scrollOffset:
                          widget.scroll.hasClients ? widget.scroll.offset : 0,
                      matchColor: cs.primary.withValues(alpha: 0.20),
                      currentColor: cs.primary.withValues(alpha: 0.42),
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              top: 8,
              right: 8,
              child: SizedBox(
                width: (w - 16).clamp(0.0, 440.0),
                child: _controls(cs),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _controls(ColorScheme cs) {
    final replace = widget.find.replaceVisible;
    return Material(
      elevation: 4,
      borderRadius: BorderRadius.circular(10),
      color: cs.surfaceContainerHigh,
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _findRow(cs),
            if (replace) ...[
              const SizedBox(height: 6),
              _replaceRow(cs),
            ],
          ],
        ),
      ),
    );
  }

  Widget _findRow(ColorScheme cs) {
    final count = _matches.isEmpty
        ? (_query.text.isEmpty ? '' : 'No results')
        : '${_current + 1} of ${_matches.length}';
    return Row(
      children: [
        _iconBtn(
          widget.find.replaceVisible
              ? Icons.expand_more_rounded
              : Icons.chevron_right_rounded,
          'Toggle replace (Ctrl+H)',
          widget.find.toggleReplace,
        ),
        Expanded(
          child: Focus(
            onKeyEvent: _onQueryKey,
            child: TextField(
              controller: _query,
              focusNode: _queryFocus,
              onChanged: (_) => _recompute(moveToCaret: true),
              decoration: InputDecoration(
                isDense: true,
                hintText: 'Find',
                errorText: _error != null ? 'Invalid regex' : null,
                border: const OutlineInputBorder(),
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              ),
            ),
          ),
        ),
        const SizedBox(width: 6),
        _toggle(
            cs,
            'Aa',
            'Match case',
            _options.caseSensitive,
            () => _setOptions(
                _options.copyWith(caseSensitive: !_options.caseSensitive))),
        _toggle(
            cs,
            'W',
            'Whole word',
            _options.wholeWord,
            () =>
                _setOptions(_options.copyWith(wholeWord: !_options.wholeWord))),
        _toggle(cs, '.*', 'Use regular expression', _options.regex,
            () => _setOptions(_options.copyWith(regex: !_options.regex))),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2),
          child: Text(
            count,
            style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
          ),
        ),
        _iconBtn(Icons.keyboard_arrow_up_rounded, 'Previous (Shift+Enter)',
            _matches.isEmpty ? null : _prev),
        _iconBtn(Icons.keyboard_arrow_down_rounded, 'Next (Enter)',
            _matches.isEmpty ? null : _next),
        _iconBtn(Icons.close_rounded, 'Close (Esc)', widget.find.hide),
      ],
    );
  }

  Widget _replaceRow(ColorScheme cs) {
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: _replace,
            decoration: const InputDecoration(
              isDense: true,
              hintText: 'Replace',
              border: OutlineInputBorder(),
              contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            ),
          ),
        ),
        const SizedBox(width: 6),
        _iconBtn(Icons.find_replace_rounded, 'Replace',
            _current < 0 ? null : _replaceCurrent),
        _iconBtn(Icons.done_all_rounded, 'Replace all',
            _matches.isEmpty ? null : _replaceAll),
      ],
    );
  }

  Widget _toggle(ColorScheme cs, String label, String tooltip, bool on,
      VoidCallback onTap) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 1),
          width: 26,
          height: 30,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: on ? cs.primary : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: on ? cs.onPrimary : cs.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }

  Widget _iconBtn(IconData icon, String tooltip, VoidCallback? onTap) {
    return IconButton(
      tooltip: tooltip,
      iconSize: 18,
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
      icon: Icon(icon),
      onPressed: onTap,
    );
  }
}

class _HighlightPainter extends CustomPainter {
  _HighlightPainter({
    required this.rects,
    required this.rectMatch,
    required this.current,
    required this.scrollOffset,
    required this.matchColor,
    required this.currentColor,
  });

  final List<Rect> rects;
  final List<int> rectMatch;
  final int current;
  final double scrollOffset;
  final Color matchColor;
  final Color currentColor;

  @override
  void paint(Canvas canvas, Size size) {
    if (rects.isEmpty) return;
    final dx = kSourceContentPadding.left;
    final dy = kSourceContentPadding.top - scrollOffset;
    final base = Paint()..color = matchColor;
    final cur = Paint()..color = currentColor;
    for (var i = 0; i < rects.length; i++) {
      final r = rects[i].shift(Offset(dx, dy));
      if (r.bottom < 0 || r.top > size.height) continue; // cull off-screen
      canvas.drawRRect(
        RRect.fromRectAndRadius(r.inflate(1), const Radius.circular(2)),
        rectMatch[i] == current ? cur : base,
      );
    }
  }

  @override
  bool shouldRepaint(_HighlightPainter old) =>
      old.current != current ||
      old.scrollOffset != scrollOffset ||
      !identical(old.rects, rects);
}
