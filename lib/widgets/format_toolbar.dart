import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:flutter/material.dart';

import '../models/editor_mode.dart';
import '../state/document_controller.dart';

/// A formatting toolbar (bold, italic, headings, lists, quote, …) shown on the
/// menu bar. It acts on the active document's editor:
///  * in **WYSIWYG** mode it drives the AppFlowy block editor;
///  * in **Split** mode it inserts Markdown syntax into the source field;
///  * in **Preview** mode the first tap switches to editing.
class FormatToolbar extends StatelessWidget {
  const FormatToolbar({super.key, required this.controller});

  final DocumentController controller;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      height: 48,
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        border: Border(bottom: BorderSide(color: cs.outlineVariant)),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            const SizedBox(width: 4),
            _btn(context, Icons.format_bold, 'Bold',
                () => _inline(AppFlowyRichTextKeys.bold, '**', '**')),
            _btn(context, Icons.format_italic, 'Italic',
                () => _inline(AppFlowyRichTextKeys.italic, '*', '*')),
            _btn(context, Icons.format_underlined, 'Underline',
                () => _inline(AppFlowyRichTextKeys.underline, '<u>', '</u>')),
            _btn(context, Icons.format_strikethrough, 'Strikethrough',
                () => _inline(AppFlowyRichTextKeys.strikethrough, '~~', '~~')),
            _btn(context, Icons.code, 'Inline code',
                () => _inline(AppFlowyRichTextKeys.code, '`', '`')),
            _divider(cs),
            _btn(context, Icons.title, 'Heading 1', () => _heading(1, '# ')),
            _btn(context, Icons.text_fields, 'Heading 2',
                () => _heading(2, '## ')),
            _btn(context, Icons.text_format, 'Heading 3',
                () => _heading(3, '### ')),
            _divider(cs),
            _btn(context, Icons.format_list_bulleted, 'Bulleted list',
                () => _block('bulleted_list', '- ')),
            _btn(context, Icons.format_list_numbered, 'Numbered list',
                () => _block('numbered_list', '1. ')),
            _btn(context, Icons.checklist, 'Checklist',
                () => _block('todo_list', '- [ ] ')),
            _btn(context, Icons.format_quote, 'Quote',
                () => _block('quote', '> ')),
            const SizedBox(width: 4),
          ],
        ),
      ),
    );
  }

  Widget _divider(ColorScheme cs) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: SizedBox(
          height: 24,
          child: VerticalDivider(width: 1, color: cs.outlineVariant),
        ),
      );

  Widget _btn(
      BuildContext context, IconData icon, String tip, VoidCallback onTap) {
    return IconButton(
      tooltip: tip,
      iconSize: 20,
      visualDensity: VisualDensity.compact,
      icon: Icon(icon),
      onPressed: onTap,
    );
  }

  /// Ensure we're in an editable mode. Returns true if the caller should
  /// proceed (we're in WYSIWYG or Split); when in Preview, switches to WYSIWYG
  /// and returns false so the first tap just starts editing.
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
    if (controller.mode == EditorMode.split) {
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
    if (controller.mode == EditorMode.split) {
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
    if (controller.mode == EditorMode.split) {
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

  // --- Markdown source helpers (Split mode) -----------------------------------

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
}
