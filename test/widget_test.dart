import 'dart:convert';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:flutter/widgets.dart' show Size, TextSelection;
import 'package:flutter_test/flutter_test.dart';
import 'package:markdown_studio/app.dart';
import 'package:markdown_studio/models/editor_mode.dart';
import 'package:markdown_studio/models/print_profile.dart';
import 'package:markdown_studio/services/file_association_service.dart';
import 'package:markdown_studio/services/markdown_pdf_builder.dart';
import 'package:markdown_studio/services/print_profile_service.dart';
import 'package:markdown_studio/state/document_controller.dart';
import 'package:markdown_studio/state/theme_controller.dart';
import 'package:markdown_studio/state/workspace_controller.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Standard built-in PDF fonts, so PDF-render tests never touch the network.
PdfFontSet _standardFonts() => PdfFontSet(
      base: pw.Font.helvetica(),
      bold: pw.Font.helveticaBold(),
      italic: pw.Font.helveticaOblique(),
      boldItalic: pw.Font.helveticaBoldOblique(),
      mono: pw.Font.courier(),
    );

void main() {
  testWidgets('App boots and shows the mode selector', (tester) async {
    // Desktop-sized surface (this is a desktop-first app; the default 800x600
    // test surface is narrower than any real window).
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    // Pre-decide the association prompt so the boot stays hermetic (no OS calls).
    SharedPreferences.setMockInitialValues({'assoc_prompt_done': true});
    final prefs = await SharedPreferences.getInstance();

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider(create: (_) => ThemeController(prefs)),
          ChangeNotifierProvider(create: (_) => PrintProfileService(prefs)),
          ChangeNotifierProvider(create: (_) => WorkspaceController(prefs)),
          Provider(create: (_) => FileAssociationService(prefs)),
        ],
        child: const MarkdownStudioApp(),
      ),
    );
    await tester.pumpAndSettle();

    // The mode toggle is icon-only; each segment carries a tooltip naming it.
    expect(find.byTooltip('Edit'), findsOneWidget);
    expect(find.byTooltip('Split'), findsOneWidget);
    expect(find.byTooltip('Raw'), findsOneWidget);
    expect(find.byTooltip('Preview'), findsOneWidget);
  });

  test('Print profiles seed with built-ins', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final service = PrintProfileService(prefs);

    expect(service.profiles.length, greaterThanOrEqualTo(2));
    expect(service.profiles.any((p) => p.name == 'Work'), isTrue);
    expect(service.profiles.any((p) => p.name == 'Personal'), isTrue);
  });

  test('New built-in seeds merge into a pre-existing saved profile list',
      () async {
    // A pre-existing install whose saved profiles predate Court Filing, with no
    // seeded-ids marker yet.
    final saved = PrintProfile.encodeList(
        const [PrintProfile.personal, PrintProfile.work]);
    SharedPreferences.setMockInitialValues({'print_profiles': saved});
    final prefs = await SharedPreferences.getInstance();
    final service = PrintProfileService(prefs);

    expect(service.profiles.any((p) => p.id == 'court-filing'), isTrue);
    expect(service.profiles.any((p) => p.id == 'work'), isTrue);
  });

  test('A deliberately-deleted built-in seed is not resurrected on reload',
      () async {
    final saved = PrintProfile.encodeList(const [PrintProfile.personal]);
    SharedPreferences.setMockInitialValues({
      'print_profiles': saved,
      // Marker records personal+work as already introduced (work was deleted).
      'seeded_profile_ids': jsonEncode(['personal', 'work']),
    });
    final prefs = await SharedPreferences.getInstance();
    final service = PrintProfileService(prefs);

    expect(service.profiles.any((p) => p.id == 'work'), isFalse);
    // A genuinely new seed still arrives.
    expect(service.profiles.any((p) => p.id == 'court-filing'), isTrue);
  });

  test('Court Filing seed carries the legal formatting defaults', () {
    final court =
        PrintProfile.seeds.firstWhere((p) => p.id == 'court-filing');
    expect(court.legalMode, isTrue);
    expect(court.justifyBody, isTrue);
    expect(court.centerHeadings, isTrue);
    expect(court.lineSpacingMultiple, 2.0);
    expect(court.firstLineIndentIn, 0.5);
  });

  test('New legal fields survive a JSON round-trip (and clamp on import)', () {
    const p = PrintProfile(
      id: 'x',
      name: 'X',
      legalMode: true,
      justifyBody: true,
      centerHeadings: true,
      lineSpacingMultiple: 1.5,
      firstLineIndentIn: 0.5,
    );
    final back = PrintProfile.fromJson(
        jsonDecode(jsonEncode(p.toJson())) as Map<String, dynamic>);
    expect(back.legalMode, isTrue);
    expect(back.justifyBody, isTrue);
    expect(back.centerHeadings, isTrue);
    expect(back.lineSpacingMultiple, 1.5);
    expect(back.firstLineIndentIn, 0.5);

    // Out-of-range imports clamp into the editor's slider ranges.
    final clamped = PrintProfile.fromJson({
      'id': 'y',
      'name': 'Y',
      'lineSpacingMultiple': 9.0,
      'firstLineIndentIn': -3.0,
    });
    expect(clamped.lineSpacingMultiple, 2.0);
    expect(clamped.firstLineIndentIn, 0.0);
  });

  test('Inline <span> fill-in lines and labels never leak as literal HTML', () {
    final builder = MarkdownPdfBuilder(
        profile: PrintProfile.personal, fonts: _standardFonts());

    String literal(List<pw.InlineSpan> spans) {
      final sb = StringBuffer();
      void walk(pw.InlineSpan s) {
        if (s is pw.TextSpan) {
          if (s.text != null) sb.write(s.text);
          for (final c in s.children ?? const <pw.InlineSpan>[]) {
            walk(c);
          }
        }
      }

      for (final s in spans) {
        walk(s);
      }
      return sb.toString();
    }

    // A signature/date blank: a span with a bottom border and only whitespace.
    final blank = builder.renderInlineText(
      'Name: <span style="display:inline-block; min-width:150px; '
      'border-bottom:1px solid #555;"> </span> Date',
    );
    final blankText = literal(blank);
    expect(blankText.contains('<span'), isFalse);
    expect(blankText.contains('min-width'), isFalse);
    expect(blankText.contains('Name:'), isTrue);
    expect(blankText.contains('Date'), isTrue);
    // The blank line itself is drawn as a widget, not text.
    expect(blank.any((s) => s is pw.WidgetSpan), isTrue);

    // A styled label span keeps its text but drops the markup.
    final label = builder.renderInlineText(
        'A <span style="color:#c00; font-weight:bold;">label</span> here.');
    final labelText = literal(label);
    expect(labelText.contains('<span'), isFalse);
    expect(labelText.contains('label'), isTrue);
    expect(label.every((s) => s is! pw.WidgetSpan), isTrue);

    // Uppercase / mixed-case tags are handled (HTML tags are case-insensitive).
    final upper = builder.renderInlineText('X <SPAN>Y</SPAN> Z');
    final upperText = literal(upper);
    expect(upperText.contains('SPAN'), isFalse);
    expect(upperText, contains('Y'));

    // Nested spans must not leak the outer </span>.
    final nested = builder.renderInlineText(
        'p <span style="color:#c00;">a <span style="font-weight:bold;">b</span> c</span> q');
    final nestedText = literal(nested);
    expect(nestedText.contains('span'), isFalse);
    expect(nestedText.contains('<'), isFalse);
    expect(nestedText, contains('q'));

    // A single unclosed span (truncated export) must not leak either.
    final unclosed =
        builder.renderInlineText('Name: <span style="min-width:150px">');
    final unclosedText = literal(unclosed);
    expect(unclosedText.contains('span'), isFalse);
    expect(unclosedText.contains('min-width'), isFalse);
    expect(unclosedText, contains('Name:'));

    // A blank wrapped in an outer styling span still renders as a blank line.
    final wrappedBlank = builder.renderInlineText(
        '<span style="color:#555;"><span style="min-width:150px; '
        'border-bottom:1px solid;"> </span></span>');
    expect(wrappedBlank.any((s) => s is pw.WidgetSpan), isTrue);
    expect(literal(wrappedBlank).contains('span'), isFalse);

    // A stray closing tag before a later span must not leak.
    final stray = builder.renderInlineText(
        '</span> <span style="min-width:150px; border-bottom:1px solid;"> '
        '</span>');
    expect(literal(stray).contains('span'), isFalse);
    expect(stray.any((s) => s is pw.WidgetSpan), isTrue);

    // HTML entities in span-adjacent text are decoded (not shown literally).
    final ent = builder.renderInlineText(
        'AT&amp;T <span style="color:#333;">x</span>');
    expect(literal(ent), contains('AT&T'));
    expect(literal(ent).contains('&amp;'), isFalse);

    // An explicit zero-width blank collapses (no visible rule).
    final zero = builder
        .renderInlineText('<span style="width:0; border-bottom:1px solid;"> '
            '</span>');
    expect(zero.any((s) => s is pw.WidgetSpan), isFalse);

    // A borderless empty span contributes nothing (no stray space).
    final empty = builder.renderInlineText('X<span id="bookmark"></span>Y');
    expect(literal(empty), 'XY');

    // The bordered (blank) span is the *outer* one; its whitespace is wrapped in
    // a nested span. The fill-in line must still be drawn.
    final outerBlank = builder.renderInlineText(
        '<span style="min-width:150px; border-bottom:1px solid;">'
        '<span>&nbsp;</span></span>');
    expect(outerBlank.any((s) => s is pw.WidgetSpan), isTrue);
    expect(literal(outerBlank).contains('span'), isFalse);

    // A zero-percent width collapses like an absolute zero.
    final zeroPct = builder.renderInlineText(
        '<span style="width:0%; border-bottom:1px solid;"> </span>');
    expect(zeroPct.any((s) => s is pw.WidgetSpan), isFalse);

    // A whitespace-only styled span is a separator — keep the space.
    final sep = builder
        .renderInlineText('First<span style="color:#555;">&nbsp;</span>Last');
    expect(literal(sep), 'First Last');

    // A colourless border with a transparent currentColor stays invisible.
    final invisible = builder.renderInlineText(
        '<span style="color:transparent; border-bottom:1px solid;"> </span>');
    expect(invisible.any((s) => s is pw.WidgetSpan), isFalse);

    // Transparency inherited from a wrapper span keeps a nested blank invisible.
    final wrapInvisible = builder.renderInlineText(
        '<span style="color:transparent;"><span style="border-bottom:1px '
        'solid; min-width:120px;"> </span></span>');
    expect(wrapInvisible.any((s) => s is pw.WidgetSpan), isFalse);

    // width:50% with a min-width:0 reset must NOT collapse (falls back default).
    final pctReset = builder.renderInlineText(
        '<span style="width:50%; min-width:0; border-bottom:1px solid;"> '
        '</span>');
    expect(pctReset.any((s) => s is pw.WidgetSpan), isTrue);

    // A self-closing bookmark span must not swallow a following fill-in line.
    final selfClose = builder.renderInlineText(
        'A<span id="bm"/> <span style="min-width:120px; '
        'border-bottom:1px solid;"> </span>');
    expect(selfClose.any((s) => s is pw.WidgetSpan), isTrue);
    expect(literal(selfClose).contains('span'), isFalse);
    expect(literal(selfClose), contains('A'));

    // A later border-bottom shorthand resets an earlier explicit colour, so the
    // transparent currentColor makes the blank invisible.
    final shorthandReset = builder.renderInlineText(
        '<span style="color:transparent; border-bottom-color:#555; '
        'border-bottom:1px solid;"> </span>');
    expect(shorthandReset.any((s) => s is pw.WidgetSpan), isFalse);

    // Transparent label text is hidden, not printed in the inherited colour.
    final redacted =
        builder.renderInlineText('A<span style="color:transparent;">secret'
            '</span>B');
    expect(literal(redacted).contains('secret'), isFalse);
    expect(literal(redacted), contains('A'));

    // Transparent wrapper hides its plain text too, not just a nested span.
    final wrapHide = builder.renderInlineText(
        '<span style="color:transparent;">secret <span>x</span> tail</span>');
    final wrapText = literal(wrapHide);
    expect(wrapText.contains('secret'), isFalse);
    expect(wrapText.contains('tail'), isFalse);

    // A self-closing bordered span is a fill-in line, not a skipped bookmark.
    final selfBlank = builder.renderInlineText(
        '<span style="min-width:150px; border-bottom:1px solid #555;" />');
    expect(selfBlank.any((s) => s is pw.WidgetSpan), isTrue);

    // A <span> used as a Markdown link label must not leak its markup.
    final linkSpan = builder.build(
        '[<span style="color:#c00;">label</span>](https://example.com)');
    String widgetLiteral(pw.InlineSpan s) {
      final sb = StringBuffer();
      if (s is pw.TextSpan) {
        if (s.text != null) sb.write(s.text);
        for (final c in s.children ?? const <pw.InlineSpan>[]) {
          sb.write(widgetLiteral(c));
        }
      }
      return sb.toString();
    }

    // The paragraph is a Padding → RichText; dig out the RichText span text.
    final para = linkSpan.first;
    final rich = para is pw.Padding ? para.child : para;
    if (rich is pw.RichText) {
      final t = widgetLiteral(rich.text);
      expect(t.contains('<span'), isFalse);
      expect(t, contains('label'));
    }
  });

  test('Table cells render inline <span> instead of leaking the markup',
      () async {
    final builder = MarkdownPdfBuilder(
        profile: PrintProfile.personal, fonts: _standardFonts());
    // A form-row table with a fill-in blank in a cell.
    final widgets = builder.build(
      '| Field | Value |\n'
      '|---|---|\n'
      '| Signed | <span style="min-width:150px; border-bottom:1px solid #555;"> '
      '</span> |\n'
      // A cell with inline code that mentions a span tag must keep it literal.
      '| Code | `<span>x</span>` |\n',
    );
    expect(widgets, isNotEmpty);
    // Lays out end-to-end (the cell's WidgetSpan blank would otherwise throw).
    final doc = pw.Document();
    doc.addPage(pw.MultiPage(build: (_) => widgets));
    expect(await doc.save(), isNotEmpty);
  });

  test('PDF builder renders a double-spaced, justified, indented body',
      () async {
    // Exercises the justify + first-line-indent WidgetSpan + centred-heading
    // paths; a layout crash in any of them would fail here.
    final court =
        PrintProfile.seeds.firstWhere((p) => p.id == 'court-filing');
    final builder =
        MarkdownPdfBuilder(profile: court, fonts: _standardFonts());
    final widgets = builder.build(
      '# In re: Example Matter\n\n'
      'This is a body paragraph long enough to wrap onto several lines so '
      'that justification, double spacing and the first-line indent all take '
      'effect during layout. It keeps going to force at least one wrap.\n\n'
      'A second paragraph with **bold** text and a [link](https://example.com).\n\n'
      'Signed: <span style="min-width:180px; border-bottom:1px solid #555;"> '
      '</span>',
    );
    expect(widgets, isNotEmpty);

    final doc = pw.Document();
    doc.addPage(pw.MultiPage(build: (_) => widgets));
    final bytes = await doc.save();
    expect(bytes, isNotEmpty);
  });

  test('Visiting Edit mode without editing preserves the exact source', () {
    // Regression: AppFlowy's Markdown round-trip drops blank lines and rewrites
    // markers, so a no-op Edit → back visit used to reformat untouched text.
    final doc = DocumentController(isAutoReloadEnabled: () => false);
    addTearDown(doc.dispose);
    const source =
        '# Title\n\n* one\n* two\n\nSome __bold__ and *italic* text.\n';
    doc.loadMarkdown(source);

    doc.setMode(EditorMode.wysiwyg); // enter the block editor…
    doc.setMode(EditorMode.preview); // …and leave without editing

    expect(doc.currentMarkdown(), source);
  });

  test('Reloading in Edit mode does not reformat the untouched buffer',
      () async {
    final doc = DocumentController(isAutoReloadEnabled: () => false);
    addTearDown(doc.dispose);
    doc.loadMarkdown('# Title\n\n* one\n* two\n');
    doc.setMode(EditorMode.wysiwyg);

    // Make a genuine WYSIWYG edit so the "edited" flag is set.
    final node = doc.editorState.getNodeAtPath([0])!;
    await doc.editorState
        .apply(doc.editorState.transaction..insertText(node, 0, 'X'));
    await Future<void>.delayed(Duration.zero);
    expect(doc.isDirty, isTrue); // precondition: the edit registered

    // An external reload arrives while still in Edit mode.
    const reloaded = '# Reloaded\n\n* a\n* b\n\nPlain __text__.\n';
    doc.loadMarkdown(reloaded);

    // Leaving Edit must not round-trip the freshly-loaded, untouched buffer.
    doc.setMode(EditorMode.preview);
    expect(doc.currentMarkdown(), reloaded);
  });

  test('Selection-only changes in the source do not mark the doc dirty', () {
    // Find & replace reveals a match by selecting it; navigating matches must
    // not create unsaved-changes state on a clean document.
    final doc = DocumentController(isAutoReloadEnabled: () => false);
    addTearDown(doc.dispose);
    doc.loadMarkdown('hello world hello');
    doc.setMode(EditorMode.raw);
    expect(doc.isDirty, isFalse);

    // Move/select the caret only — no text change.
    doc.sourceController.selection =
        const TextSelection(baseOffset: 0, extentOffset: 5);
    expect(doc.isDirty, isFalse);

    // A genuine text edit still marks it dirty.
    doc.sourceController.text = 'hello world goodbye';
    expect(doc.isDirty, isTrue);
  });

  test('Workspace starts with one tab and manages tabs', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final ws = WorkspaceController(prefs);

    expect(ws.documents.length, 1);

    // Opening into a pristine untitled tab replaces it rather than stacking.
    ws.openDocument('# Hello', path: '/tmp/a.md');
    expect(ws.documents.length, 1);
    expect(ws.active.filePath, '/tmp/a.md');

    // A second distinct file adds a tab.
    ws.openDocument('# Second', path: '/tmp/b.md');
    expect(ws.documents.length, 2);
    expect(ws.activeIndex, 1);

    // Re-opening an already-open file just focuses it.
    ws.openDocument('# Hello', path: '/tmp/a.md');
    expect(ws.documents.length, 2);
    expect(ws.activeIndex, 0);

    // Closing always leaves at least one tab.
    ws.closeAt(0);
    ws.closeAt(0);
    expect(ws.documents.length, 1);
  });

  test('Reorder inserts before the target and supports the end', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final ws = WorkspaceController(prefs);
    ws.openDocument('a', path: '/a.md');
    ws.openDocument('b', path: '/b.md');
    ws.openDocument('c', path: '/c.md');
    expect(ws.documents.map((d) => d.filePath), ['/a.md', '/b.md', '/c.md']);

    ws.reorder(0, 2); // move A before C
    expect(ws.documents.map((d) => d.filePath), ['/b.md', '/a.md', '/c.md']);

    ws.reorder(0, 3); // move B to the end
    expect(ws.documents.map((d) => d.filePath), ['/a.md', '/c.md', '/b.md']);
  });

  test('Auto-reload defaults on and persists when toggled', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final ws = WorkspaceController(prefs);

    expect(ws.autoReload, isTrue);
    await ws.setAutoReload(false);
    expect(ws.autoReload, isFalse);
    expect(prefs.getBool('auto_reload'), isFalse);

    final reloaded = WorkspaceController(prefs);
    expect(reloaded.autoReload, isFalse);
  });
}
