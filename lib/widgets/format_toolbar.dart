import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/editor_mode.dart';
import '../state/document_controller.dart';
import '../state/workspace_controller.dart';

/// A movable, "tear-away" formatting palette (bold, italic, headings, lists,
/// link, table, …) that floats over the editor. It can be dragged anywhere
/// inside the window by its grip handle and remembers its position; it starts
/// docked at the top-left. It is hidden in Preview (nothing to edit).
///
/// It acts on the active document's editor:
///  * in **WYSIWYG** mode it drives the AppFlowy block editor;
///  * in **Split**/**Raw** mode it inserts Markdown syntax into the source field.
///
/// Must be placed as a direct child of a [Stack] (it returns a [Positioned]).
class FloatingFormatToolbar extends StatefulWidget {
  const FloatingFormatToolbar({
    super.key,
    required this.controller,
    required this.area,
  });

  final DocumentController controller;

  /// Size of the area the palette may be dragged within (the editor body).
  final Size area;

  @override
  State<FloatingFormatToolbar> createState() => _FloatingFormatToolbarState();
}

class _FloatingFormatToolbarState extends State<FloatingFormatToolbar> {
  static const _dock = Offset(12, 12);
  final GlobalKey _paletteKey = GlobalKey();

  late Offset _offset;

  /// Last measured size of the palette, used to clamp it on-screen. Updated
  /// after each layout; the seed is a reasonable estimate for the first frame.
  Size _measured = const Size(280, 48);

  DocumentController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    _offset = context.read<WorkspaceController>().toolbarOffset ?? _dock;
  }

  /// The largest top-left offset that still keeps the whole palette on-screen.
  Offset get _maxOffset => Offset(
        (widget.area.width - _measured.width).clamp(0.0, double.infinity),
        (widget.area.height - _measured.height).clamp(0.0, double.infinity),
      );

  void _measureAfterLayout() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final size = _paletteKey.currentContext?.size;
      if (size != null && size != _measured) {
        setState(() => _measured = size);
      }
    });
  }

  void _onPanUpdate(DragUpdateDetails d) {
    setState(() {
      final max = _maxOffset;
      _offset = Offset(
        (_offset.dx + d.delta.dx).clamp(0.0, max.dx),
        (_offset.dy + d.delta.dy).clamp(0.0, max.dy),
      );
    });
  }

  void _onPanEnd(DragEndDetails _) {
    context.read<WorkspaceController>().setToolbarOffset(_offset);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    _measureAfterLayout();
    // Keep the whole palette on-screen if the window shrank since it was last
    // placed — clamp by its actual measured size, not a fixed margin.
    final max = _maxOffset;
    final left = _offset.dx.clamp(0.0, max.dx);
    final top = _offset.dy.clamp(0.0, max.dy);
    final maxWidth = (widget.area.width - 16).clamp(120.0, 640.0).toDouble();

    return Positioned(
      left: left,
      top: top,
      child: Material(
        key: _paletteKey,
        elevation: 4,
        borderRadius: BorderRadius.circular(10),
        color: cs.surfaceContainerHigh,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Drag handle — only this grip moves the palette, so the buttons
              // stay tappable.
              MouseRegion(
                cursor: SystemMouseCursors.move,
                child: GestureDetector(
                  onPanUpdate: _onPanUpdate,
                  onPanEnd: _onPanEnd,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 2),
                    child: Icon(Icons.drag_indicator,
                        size: 18, color: cs.onSurfaceVariant),
                  ),
                ),
              ),
              Flexible(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: _buttons(context, cs),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _buttons(BuildContext context, ColorScheme cs) {
    return [
      _btn(Icons.format_bold, 'Bold',
          () => _inline(AppFlowyRichTextKeys.bold, '**', '**')),
      _btn(Icons.format_italic, 'Italic',
          () => _inline(AppFlowyRichTextKeys.italic, '*', '*')),
      _btn(Icons.format_underlined, 'Underline',
          () => _inline(AppFlowyRichTextKeys.underline, '<u>', '</u>')),
      _btn(Icons.format_strikethrough, 'Strikethrough',
          () => _inline(AppFlowyRichTextKeys.strikethrough, '~~', '~~')),
      _btn(Icons.code, 'Inline code',
          () => _inline(AppFlowyRichTextKeys.code, '`', '`')),
      _divider(cs),
      _btn(Icons.title, 'Heading 1', () => _heading(1, '# ')),
      _btn(Icons.text_fields, 'Heading 2', () => _heading(2, '## ')),
      _btn(Icons.text_format, 'Heading 3', () => _heading(3, '### ')),
      _divider(cs),
      _btn(Icons.format_list_bulleted, 'Bulleted list',
          () => _block('bulleted_list', '- ')),
      _btn(Icons.format_list_numbered, 'Numbered list',
          () => _block('numbered_list', '1. ')),
      _btn(Icons.checklist, 'Checklist', () => _block('todo_list', '- [ ] ')),
      _btn(Icons.format_quote, 'Quote', () => _block('quote', '> ')),
      _divider(cs),
      _btn(Icons.format_indent_decrease, 'Outdent', _outdent),
      _btn(Icons.format_indent_increase, 'Indent', _indent),
      _divider(cs),
      _btn(Icons.link, 'Insert link', _link),
      _btn(Icons.horizontal_rule, 'Divider', _divider2),
      _btn(Icons.grid_on, 'Insert table', _table),
      // Alignment and colour are block/inline attributes that standard Markdown
      // can't represent, so they only apply in the WYSIWYG block editor (and are
      // dropped when the document is saved to .md or shown as source). Hidden in
      // the source modes where they'd silently do nothing.
      if (controller.mode == EditorMode.wysiwyg) ...[
        _divider(cs),
        _btn(Icons.format_align_left, 'Align left', () => _align('left')),
        _btn(Icons.format_align_center, 'Align center', () => _align('center')),
        _btn(Icons.format_align_right, 'Align right', () => _align('right')),
        _divider(cs),
        _btn(Icons.format_color_text, 'Text colour',
            () => _color(AppFlowyRichTextKeys.textColor)),
        _btn(Icons.border_color, 'Highlight colour',
            () => _color(AppFlowyRichTextKeys.backgroundColor)),
      ],
    ];
  }

  Widget _divider(ColorScheme cs) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: SizedBox(
          height: 22,
          child: VerticalDivider(width: 1, color: cs.outlineVariant),
        ),
      );

  Widget _btn(IconData icon, String tip, VoidCallback onTap) {
    return IconButton(
      tooltip: tip,
      iconSize: 18,
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
      padding: EdgeInsets.zero,
      icon: Icon(icon),
      onPressed: onTap,
    );
  }

  /// Ensure we're in an editable mode. Returns true if the caller should
  /// proceed (WYSIWYG, Split or Raw); when in Preview, switches to WYSIWYG and
  /// returns false so the first tap just starts editing.
  bool _ensureEditable() {
    if (controller.mode == EditorMode.preview) {
      controller.setMode(EditorMode.wysiwyg);
      return false;
    }
    return true;
  }

  // --- Inline formatting ------------------------------------------------------

  void _inline(String attribute, String mdLeft, String mdRight) {
    if (!_ensureEditable()) return;
    if (controller.mode.isSource) {
      _wrapSource(mdLeft, mdRight);
      return;
    }
    final es = controller.editorState;
    if (es.selection == null) return;
    es.toggleAttribute(attribute);
  }

  // --- Block formatting -------------------------------------------------------

  void _heading(int level, String mdPrefix) {
    if (!_ensureEditable()) return;
    if (controller.mode.isSource) {
      _prefixSource(mdPrefix);
      return;
    }
    final es = controller.editorState;
    final selection = es.selection;
    if (selection == null) return;
    final node = es.getNodeAtPath(selection.start.path);
    if (node == null) return;
    final isSame = node.type == HeadingBlockKeys.type &&
        node.attributes[HeadingBlockKeys.level] == level;
    es.formatNode(
      selection,
      // Use each updated node's own delta (the selection may span blocks).
      (node) => node.copyWith(
        type: isSame ? ParagraphBlockKeys.type : HeadingBlockKeys.type,
        attributes: {
          HeadingBlockKeys.level: level,
          blockComponentDelta: (node.delta ?? Delta()).toJson(),
        },
      ),
    );
  }

  void _block(String type, String mdPrefix) {
    if (!_ensureEditable()) return;
    if (controller.mode.isSource) {
      _prefixSource(mdPrefix);
      return;
    }
    final es = controller.editorState;
    final selection = es.selection;
    if (selection == null) return;
    final node = es.getNodeAtPath(selection.start.path);
    if (node == null) return;
    final isSame = node.type == type;
    es.formatNode(
      selection,
      (node) => node.copyWith(
        type: isSame ? ParagraphBlockKeys.type : type,
      ),
    );
  }

  // --- Indent / outdent -------------------------------------------------------

  void _indent() {
    if (!_ensureEditable()) return;
    if (controller.mode.isSource) {
      _prefixSource('  ');
      return;
    }
    indentCommand.execute(controller.editorState);
  }

  void _outdent() {
    if (!_ensureEditable()) return;
    if (controller.mode.isSource) {
      _unprefixSource('  ');
      return;
    }
    outdentCommand.execute(controller.editorState);
  }

  // --- Link / divider / table -------------------------------------------------

  Future<void> _link() async {
    if (!_ensureEditable()) return;
    final source = controller.mode.isSource;
    final es = controller.editorState;
    final selection = es.selection;
    if (!source && selection == null) return;

    final url = await _promptUrl(context);
    if (url == null || url.isEmpty || !mounted) return;

    if (source) {
      final c = controller.sourceController;
      final sel = c.value.selection;
      // With no text selected, wrapping would yield `[](url)` — an empty,
      // invisible link. Insert the URL itself as the visible label instead.
      if (!sel.isValid || sel.isCollapsed) {
        _wrapSource('[$url](', '$url)');
      } else {
        _wrapSource('[', ']($url)');
      }
      return;
    }
    final sel = es.selection ?? selection!;
    if (sel.isCollapsed) {
      final node = es.getNodeAtPath(sel.start.path);
      if (node == null || node.delta == null) return;
      final transaction = es.transaction
        ..insertText(node, sel.startIndex, url,
            attributes: {AppFlowyRichTextKeys.href: url});
      await es.apply(transaction);
    } else {
      await es.formatDelta(sel, {AppFlowyRichTextKeys.href: url});
    }
  }

  // Named `_divider2` to avoid clashing with the [_divider] separator widget.
  void _divider2() {
    if (!_ensureEditable()) return;
    if (controller.mode.isSource) {
      _insertSourceBlock('---');
      return;
    }
    final es = controller.editorState;
    final selection = es.selection;
    if (selection == null || !selection.isCollapsed) return;
    final path = selection.end.path;
    final node = es.getNodeAtPath(path);
    final delta = node?.delta;
    if (node == null || delta == null) return;
    final insertedPath = delta.isEmpty ? path : path.next;
    final transaction = es.transaction
      ..insertNode(insertedPath, dividerNode())
      ..insertNode(insertedPath, paragraphNode())
      ..afterSelection = Selection.collapsed(Position(path: insertedPath.next));
    es.apply(transaction);
  }

  void _table() {
    if (!_ensureEditable()) return;
    if (controller.mode.isSource) {
      _insertSourceBlock('| Column 1 | Column 2 |\n'
          '| --- | --- |\n'
          '| Cell | Cell |');
      return;
    }
    final es = controller.editorState;
    final selection = es.selection;
    if (selection == null || !selection.isCollapsed) return;
    final path = selection.end.path;
    final node = es.getNodeAtPath(path);
    final delta = node?.delta;
    if (node == null) return;
    final insertedPath = (delta != null && delta.isEmpty) ? path : path.next;
    final table = TableNode.fromList(const [
      ['', ''],
      ['', ''],
    ]).node;
    // Also drop a paragraph after the table and land the caret there, so the
    // user can keep typing — AppFlowy clears the selection to afterSelection
    // when applying a transaction, so leaving it unset strands the cursor.
    // Same-path inserts keep their queued order, so insert the table first and
    // the trailing paragraph second (paragraph ends up at insertedPath.next).
    final transaction = es.transaction
      ..insertNode(insertedPath, table)
      ..insertNode(insertedPath, paragraphNode())
      ..afterSelection = Selection.collapsed(Position(path: insertedPath.next));
    es.apply(transaction);
  }

  // --- Alignment / colour (WYSIWYG-only — not representable in Markdown) -------

  void _align(String align) {
    if (controller.mode != EditorMode.wysiwyg) return;
    final es = controller.editorState;
    final selection = es.selection;
    if (selection == null) return;
    es.updateNode(
      selection,
      (node) => node.copyWith(
        attributes: {...node.attributes, blockComponentAlign: align},
      ),
    );
  }

  Future<void> _color(String attribute) async {
    if (controller.mode != EditorMode.wysiwyg) return;
    final es = controller.editorState;
    final selection = es.selection;
    if (selection == null || selection.isCollapsed) return;
    final hex = await _promptColor(context);
    if (hex == null || !mounted) return;
    // An empty result clears the attribute.
    await es.formatDelta(selection, {attribute: hex.isEmpty ? null : hex});
  }

  Future<String?> _promptColor(BuildContext context) {
    const swatches = <String, int>{
      'Black': 0xFF000000,
      'Red': 0xFFD32F2F,
      'Orange': 0xFFF57C00,
      'Yellow': 0xFFFBC02D,
      'Green': 0xFF388E3C,
      'Blue': 0xFF1976D2,
      'Purple': 0xFF7B1FA2,
      'Grey': 0xFF757575,
    };
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Pick a colour'),
        content: Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final e in swatches.entries)
              Tooltip(
                message: e.key,
                child: InkWell(
                  // AppFlowy stores colours as `rgba(r, g, b, a)` strings and
                  // parses them with tryFromRgbaString — a 0xAARRGGBB value
                  // wouldn't render. Color.toRgbaString() emits the right form.
                  onTap: () =>
                      Navigator.pop(ctx, Color(e.value).toRgbaString()),
                  child: Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: Color(e.value),
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.black26),
                    ),
                  ),
                ),
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, ''),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
  }

  Future<String?> _promptUrl(BuildContext context) async {
    final urlController = TextEditingController();
    try {
      return await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Insert link'),
          content: TextField(
            controller: urlController,
            autofocus: true,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(
              labelText: 'URL',
              hintText: 'https://example.com',
            ),
            onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, urlController.text.trim()),
              child: const Text('Insert'),
            ),
          ],
        ),
      );
    } finally {
      urlController.dispose();
    }
  }

  // --- Markdown source helpers (Split / Raw modes) ----------------------------

  void _wrapSource(String left, String right) {
    final c = controller.sourceController;
    final value = c.value;
    final sel = value.selection;
    final text = value.text;
    final start = sel.isValid ? sel.start : text.length;
    final end = sel.isValid ? sel.end : text.length;
    final selected = text.substring(start, end);
    final newText = text.replaceRange(start, end, '$left$selected$right');
    c.value = value.copyWith(
      text: newText,
      selection:
          TextSelection.collapsed(offset: end + left.length + right.length),
      composing: TextRange.empty,
    );
  }

  void _prefixSource(String prefix) {
    final c = controller.sourceController;
    final value = c.value;
    final sel = value.selection;
    final text = value.text;
    final pos = sel.isValid ? sel.start : text.length;
    final lineStart = pos == 0 ? 0 : text.lastIndexOf('\n', pos - 1) + 1;
    final newText = text.replaceRange(lineStart, lineStart, prefix);
    c.value = value.copyWith(
      text: newText,
      selection: TextSelection.collapsed(offset: pos + prefix.length),
      composing: TextRange.empty,
    );
  }

  /// Remove up to [prefix] worth of leading spaces from the current line.
  void _unprefixSource(String prefix) {
    final c = controller.sourceController;
    final value = c.value;
    final sel = value.selection;
    final text = value.text;
    final pos = sel.isValid ? sel.start : text.length;
    final lineStart = pos == 0 ? 0 : text.lastIndexOf('\n', pos - 1) + 1;
    var removed = 0;
    while (removed < prefix.length &&
        lineStart + removed < text.length &&
        text[lineStart + removed] == ' ') {
      removed++;
    }
    if (removed == 0) return;
    final newText = text.replaceRange(lineStart, lineStart + removed, '');
    final newPos = (pos - removed).clamp(lineStart, newText.length);
    c.value = value.copyWith(
      text: newText,
      selection: TextSelection.collapsed(offset: newPos),
      composing: TextRange.empty,
    );
  }

  /// Insert [block] as a standalone block, guaranteeing a **blank line** on each
  /// side. A single newline isn't enough: `Paragraph\n---` parses as a setext
  /// heading underline, and a table glued to the previous line won't parse, so
  /// we top the separation up to two newlines (an empty line) where there's
  /// adjacent text.
  void _insertSourceBlock(String block) {
    final c = controller.sourceController;
    final value = c.value;
    final sel = value.selection;
    final text = value.text;
    final pos = sel.isValid ? sel.start : text.length;

    // Number of newlines already present immediately before/after the caret.
    var nlBefore = 0;
    for (var i = pos - 1; i >= 0 && text[i] == '\n' && nlBefore < 2; i--) {
      nlBefore++;
    }
    var nlAfter = 0;
    for (var i = pos; i < text.length && text[i] == '\n' && nlAfter < 2; i++) {
      nlAfter++;
    }

    // No leading blank line needed at the very start of the document.
    final before = pos == 0 ? '' : '\n' * (2 - nlBefore);
    // At end of document a single trailing newline is plenty.
    final after = pos >= text.length ? '\n' : '\n' * (2 - nlAfter);

    final insert = '$before$block$after';
    final newText = text.replaceRange(pos, pos, insert);
    c.value = value.copyWith(
      text: newText,
      selection: TextSelection.collapsed(offset: pos + insert.length),
      composing: TextRange.empty,
    );
  }
}
