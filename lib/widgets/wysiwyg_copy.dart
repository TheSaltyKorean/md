import 'dart:async';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show KeyEventResult;
import 'package:super_clipboard/super_clipboard.dart';

/// Copy support for the WYSIWYG editor that preserves formatting.
///
/// AppFlowy's built-in copy computes an HTML rendition of the selection but then
/// drops it: `AppFlowyClipboard.setData` only writes plain text through
/// Flutter's text-only clipboard. So pasting into Word / Google Docs / email
/// lost all formatting. [wysiwygCopyCommand] replaces the default Ctrl/Cmd+C so
/// a copy places BOTH flavors on the system clipboard via super_clipboard:
///
///  * **Markdown source** as the plain-text flavor — pastes cleanly into other
///    Markdown editors, GitHub, chat, code.
///  * **HTML** as the rich flavor — pastes with bold / headings / lists / links
///    intact into rich editors.
///
/// The selection is sliced to exactly what's highlighted (AppFlowy's
/// [EditorState.getSelectedNodes] trims the first/last blocks to the range).

/// The Markdown + HTML renditions of the current selection, or null when
/// nothing is selected (a collapsed or empty selection).
({String markdown, String html})? wysiwygSelectionFormats(
    EditorState editorState) {
  final selection = editorState.selection?.normalized;
  if (selection == null || selection.isCollapsed) return null;
  final nodes = editorState.getSelectedNodes(selection: selection);
  if (nodes.isEmpty) return null;
  final document = Document.blank()..insert([0], nodes);
  return (
    markdown: documentToMarkdown(document),
    html: documentToHTML(document),
  );
}

/// Ctrl/Cmd+C for the WYSIWYG editor: copy the selection as Markdown + HTML.
/// Swap this in for AppFlowy's [copyCommand] (see [wysiwygCommandShortcutEvents]).
final CommandShortcutEvent wysiwygCopyCommand = CommandShortcutEvent(
  key: 'copy the selection as Markdown and HTML',
  getDescription: () => 'Copy (keeps formatting)',
  command: 'ctrl+c',
  macOSCommand: 'cmd+c',
  handler: (editorState) {
    final formats = wysiwygSelectionFormats(editorState);
    if (formats == null) return KeyEventResult.ignored;
    // Fire-and-forget, mirroring AppFlowy's own copy handler.
    unawaited(writeRichClipboard(formats.markdown, formats.html));
    return KeyEventResult.handled;
  },
);

/// AppFlowy's default command set with the plain-text copy replaced by the
/// formatting-preserving [wysiwygCopyCommand].
List<CommandShortcutEvent> wysiwygCommandShortcutEvents() => [
      for (final e in standardCommandShortcutEvents)
        if (e != copyCommand) e,
      wysiwygCopyCommand,
    ];

/// Write [markdown] (plain-text flavor) and [html] (rich flavor) to the system
/// clipboard. Falls back to Markdown-as-plain-text on platforms without rich
/// clipboard support (super_clipboard's [SystemClipboard.instance] is null).
Future<void> writeRichClipboard(String markdown, String html) async {
  final clipboard = SystemClipboard.instance;
  if (clipboard == null) {
    await Clipboard.setData(ClipboardData(text: markdown));
    return;
  }
  final item = DataWriterItem();
  if (html.isNotEmpty) item.add(Formats.htmlText(html));
  item.add(Formats.plainText(markdown));
  await clipboard.write([item]);
}
