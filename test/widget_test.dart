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
import 'package:pdf/pdf.dart' show PdfColors;
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

/// Walk the layout-widget tree (the container types the builder emits) so tests
/// can assert structure without rendering.
Iterable<pw.Widget> _allWidgets(pw.Widget w) sync* {
  yield w;
  if (w is pw.Padding && w.child != null) {
    yield* _allWidgets(w.child!);
  } else if (w is pw.SizedBox && w.child != null) {
    yield* _allWidgets(w.child!);
  } else if (w is pw.Column) {
    for (final c in w.children) {
      yield* _allWidgets(c);
    }
  } else if (w is pw.Row) {
    for (final c in w.children) {
      yield* _allWidgets(c);
    }
  }
}

Iterable<pw.Widget> _walk(List<pw.Widget> ws) => ws.expand(_allWidgets);

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
    final court = PrintProfile.seeds.firstWhere((p) => p.id == 'court-filing');
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
    final ent =
        builder.renderInlineText('AT&amp;T <span style="color:#333;">x</span>');
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
    final selfClose = builder
        .renderInlineText('A<span id="bm"/> <span style="min-width:120px; '
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
    final linkSpan = builder
        .build('[<span style="color:#c00;">label</span>](https://example.com)');
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

    // A forced colour (white table headers) overrides a styled span's own
    // colour, so header links/labels don't go dark-on-fill.
    final forced = builder.renderInlineText(
        '<span style="color:#111111;">Docs</span>',
        forceColor: PdfColors.white);
    final forcedSpan =
        forced.whereType<pw.TextSpan>().firstWhere((s) => s.text == 'Docs');
    expect(forcedSpan.style?.color, PdfColors.white);

    // An inline-code link label that references a span tag stays literal.
    final codeLink = builder.build('[`<span>x</span>`](https://example.com)');
    final cpara = codeLink.first;
    final crich = cpara is pw.Padding ? cpara.child : cpara;
    if (crich is pw.RichText) {
      expect(widgetLiteral(crich.text), contains('<span>x</span>'));
    }

    // A transparent span inside a link is still hidden (not forced visible).
    final linkHidden = builder.build(
        'A [<span style="color:transparent;">secret</span>](https://example.com) B');
    final lhpara = linkHidden.first;
    final lhrich = lhpara is pw.Padding ? lhpara.child : lhpara;
    if (lhrich is pw.RichText) {
      expect(widgetLiteral(lhrich.text).contains('secret'), isFalse);
    }

    // An unbalanced opening span before a balanced fill-in span must not eat it.
    final truncated = builder.renderInlineText(
        'A <span style="color:#555;">note <span style="min-width:120px; '
        'border-bottom:1px solid;"> </span>');
    expect(truncated.any((s) => s is pw.WidgetSpan), isTrue);

    // A code link label keeps the link underline affordance.
    final codeUnderline = builder.build('[`code`](https://example.com)');
    final cupara = codeUnderline.first;
    final curich = cupara is pw.Padding ? cupara.child : cupara;
    if (curich is pw.RichText) {
      pw.TextSpan? codeSpan;
      void find(pw.InlineSpan s) {
        if (s is pw.TextSpan) {
          if (s.text == 'code') codeSpan = s;
          for (final c in s.children ?? const <pw.InlineSpan>[]) {
            find(c);
          }
        }
      }

      find(curich.text);
      expect(codeSpan?.style?.decoration, isNotNull);
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
    final court = PrintProfile.seeds.firstWhere((p) => p.id == 'court-filing');
    final builder = MarkdownPdfBuilder(profile: court, fonts: _standardFonts());
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

  test('A text-align:center <div> renders a centered Text block', () async {
    final builder = MarkdownPdfBuilder(
        profile: PrintProfile.personal, fonts: _standardFonts());
    final ws = builder
        .build('<div style="text-align:center">IN THE CIRCUIT COURT OF BENTON '
            'COUNTY, ARKANSAS<br>DOMESTIC RELATIONS DIVISION</div>');
    final texts = _walk(ws).whereType<pw.Text>();
    expect(texts.any((t) => t.textAlign == pw.TextAlign.center), isTrue);
    // Centered text is stretched to full width so alignment positions it.
    expect(
        _walk(ws)
            .whereType<pw.SizedBox>()
            .any((b) => b.width == double.infinity),
        isTrue);
    // Lays out without a crash.
    final doc = pw.Document()..addPage(pw.MultiPage(build: (_) => ws));
    expect(await doc.save(), isNotEmpty);
  });

  test('A display:flex; space-between <div> renders a two-column Row',
      () async {
    final builder = MarkdownPdfBuilder(
        profile: PrintProfile.personal, fonts: _standardFonts());
    final ws = builder
        .build('<div style="display:flex; justify-content:space-between">'
            '<div>MEGHAN MAIN</div><div>PLAINTIFF</div></div>');
    final row = _walk(ws).whereType<pw.Row>().first;
    expect(row.mainAxisAlignment, pw.MainAxisAlignment.spaceBetween);
    expect(row.children.length, 2);
    final doc = pw.Document()..addPage(pw.MultiPage(build: (_) => ws));
    expect(await doc.save(), isNotEmpty);
  });

  test('A plain <div> still renders left-aligned and un-stretched (regression)',
      () {
    final builder = MarkdownPdfBuilder(
        profile: PrintProfile.personal, fonts: _standardFonts());
    final ws = builder.build('<div>Plain left text</div>');
    final texts = _walk(ws).whereType<pw.Text>().toList();
    expect(texts, isNotEmpty);
    expect(texts.every((t) => t.textAlign == pw.TextAlign.left), isTrue);
    // No full-width stretch box was introduced for an unstyled div.
    expect(
        _walk(ws)
            .whereType<pw.SizedBox>()
            .any((b) => b.width == double.infinity),
        isFalse);
  });

  test('display:flex; flex-direction:column stacks (not a row)', () async {
    final builder = MarkdownPdfBuilder(
        profile: PrintProfile.personal, fonts: _standardFonts());
    final ws = builder.build('<div style="display:flex; flex-direction:column">'
        '<div>A</div><div>B</div></div>');
    // A column direction must not become a horizontal Row.
    expect(_walk(ws).whereType<pw.Row>(), isEmpty);
    final doc = pw.Document()..addPage(pw.MultiPage(build: (_) => ws));
    expect(await doc.save(), isNotEmpty);
  });

  test('A nested wrapper + aligned grandchild inside a flex row lays out',
      () async {
    final builder = MarkdownPdfBuilder(
        profile: PrintProfile.personal, fonts: _standardFonts());
    // The 2nd column wraps a centered grandchild — it must shrink-wrap, not
    // take the full-width path (which would overflow the Row and throw).
    final ws = builder
        .build('<div style="display:flex; justify-content:space-between">'
            '<div>MEGHAN MAIN</div>'
            '<div><div style="text-align:center">v.</div></div></div>');
    // No full-width stretch box leaked into the row context.
    expect(
        _walk(ws)
            .whereType<pw.SizedBox>()
            .any((b) => b.width == double.infinity),
        isFalse);
    final doc = pw.Document()..addPage(pw.MultiPage(build: (_) => ws));
    expect(await doc.save(), isNotEmpty);
  });

  test('A fill-in blank inside a flex row is bounded (no overflow)', () async {
    final builder = MarkdownPdfBuilder(
        profile: PrintProfile.personal, fonts: _standardFonts());
    final ws = builder
        .build('<div style="display:flex; justify-content:space-between">'
            '<div>Signed:</div>'
            '<div style="border-bottom:1px solid; width:150px"></div></div>');
    // The blank is a bounded finite-width rule (150px → 112.5pt), not a
    // full-width / Expanded rule that would overflow the Row.
    expect(
        _walk(ws)
            .whereType<pw.SizedBox>()
            .any((b) => b.width != null && b.width!.isFinite && b.width! > 0),
        isTrue);
    expect(
        _walk(ws)
            .whereType<pw.SizedBox>()
            .any((b) => b.width == double.infinity),
        isFalse);
    final doc = pw.Document()..addPage(pw.MultiPage(build: (_) => ws));
    expect(await doc.save(), isNotEmpty);
  });

  test('legalMode paragraphs carry the full spaced block gap', () async {
    final court = PrintProfile.seeds.firstWhere((p) => p.id == 'court-filing');
    final builder = MarkdownPdfBuilder(profile: court, fonts: _standardFonts());
    final ws = builder.build('First paragraph of the motion.\n\n'
        'Second paragraph of the motion.\n\n'
        '- first ground\n- second ground');
    // Uniform rhythm: bottom gap == in-paragraph leading, so the
    // baseline-to-baseline distance across a paragraph break equals the
    // double-spaced line height (2.5 + 11 × (multiple − 1) = 13.5 at 2.0).
    final expected = 2.5 + 11.0 * (court.lineSpacingMultiple - 1.0);
    final bottoms = _walk(ws)
        .whereType<pw.Padding>()
        .map((p) => (p.padding as pw.EdgeInsets).bottom)
        .toList();
    expect(bottoms.where((b) => b == expected).length, greaterThanOrEqualTo(4),
        reason: 'paragraphs and list items share the spaced gap');
    expect(bottoms.contains(8.0), isFalse,
        reason: 'no legal block keeps the single-spaced 8pt gap');
    final doc = pw.Document()..addPage(pw.MultiPage(build: (_) => ws));
    expect(await doc.save(), isNotEmpty);
  });

  test('Non-legal paragraphs keep the historical 8pt gap (regression)', () {
    final builder = MarkdownPdfBuilder(
        profile: PrintProfile.personal, fonts: _standardFonts());
    final ws = builder.build('First paragraph.\n\nSecond paragraph.');
    final bottoms = _walk(ws)
        .whereType<pw.Padding>()
        .map((p) => (p.padding as pw.EdgeInsets).bottom);
    expect(bottoms.where((b) => b == 8.0).length, 2);
  });

  test('Page-break divs and hrs emit a top-level pw.NewPage', () async {
    final court = PrintProfile.seeds.firstWhere((p) => p.id == 'court-filing');
    final builder = MarkdownPdfBuilder(profile: court, fonts: _standardFonts());

    final ws = builder.build('Body of the motion.\n\n'
        '<div style="page-break-before:always"></div>\n\n'
        '#### <u>CERTIFICATE OF SERVICE</u>\n\nI hereby certify…');
    expect(ws.whereType<pw.NewPage>().length, 1,
        reason: 'a bare page-break div becomes a NewPage');
    // The break contributes no visible content of its own.
    final doc = pw.Document()..addPage(pw.MultiPage(build: (_) => ws));
    expect(await doc.save(), isNotEmpty);

    // <hr> with the directive, and the CSS-3 fragmentation spelling.
    expect(
        builder
            .build('A\n\n<hr style="page-break-after:always">\n\nB')
            .whereType<pw.NewPage>()
            .length,
        1);
    expect(
        builder
            .build('A\n\n<div style="break-before:page"></div>\n\nB')
            .whereType<pw.NewPage>()
            .length,
        1);

    // A plain thematic break (---) still renders a divider, not a page break.
    expect(builder.build('A\n\n---\n\nB').whereType<pw.NewPage>(), isEmpty);
    // A bare div without the directive is unchanged too.
    expect(
        builder
            .build('<div style="height:12px"></div>')
            .whereType<pw.NewPage>(),
        isEmpty);
  });

  test('A literal <br> in a heading renders as a line break, not text', () {
    final builder = MarkdownPdfBuilder(
        profile: PrintProfile.personal, fonts: _standardFonts());
    final ws = builder.build(
        '# IN THE CIRCUIT COURT OF BENTON COUNTY, ARKANSAS<br>DOMESTIC RELATIONS DIVISION');

    String literal(pw.InlineSpan s) {
      final sb = StringBuffer();
      void walk(pw.InlineSpan x) {
        if (x is pw.TextSpan) {
          if (x.text != null) sb.write(x.text);
          for (final c in x.children ?? const <pw.InlineSpan>[]) {
            walk(c);
          }
        }
      }

      walk(s);
      return sb.toString();
    }

    final headingText =
        _walk(ws).whereType<pw.RichText>().map((r) => literal(r.text)).join();
    expect(headingText.contains('<br'), isFalse);
    expect(headingText.contains('\n'), isTrue);
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
    expect(ws.activeDocument?.filePath, '/tmp/a.md');

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

  test('Print preview opens as a tab and refreshes in place', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final ws = WorkspaceController(prefs);
    ws.openDocument('# Hello', path: '/tmp/a.md');

    ws.openPrintPreview(markdown: '# Hello', title: 'a', docPath: '/tmp/a.md');
    expect(ws.tabs.length, 2);
    expect(ws.activeTab, isA<PrintPreviewTab>());
    // Previews are not documents: no dirty state, no save, no watcher.
    expect(ws.documents.length, 1);
    expect(ws.activeDocument, isNull);

    // Printing the same file again refreshes the existing preview in place.
    ws.openPrintPreview(
        markdown: '# Hello v2', title: 'a', docPath: '/tmp/a.md');
    expect(ws.tabs.length, 2);
    final preview = ws.activeTab as PrintPreviewTab;
    expect(preview.markdown, '# Hello v2');
    expect(preview.epoch, 1);

    // A different document gets its own preview tab.
    ws.openPrintPreview(markdown: '# B', title: 'b', docPath: '/tmp/b.md');
    expect(ws.tabs.length, 3);

    // Closing a preview never touches the document tabs.
    ws.closeAt(ws.activeIndex);
    expect(ws.tabs.length, 2);
    expect(ws.documents.length, 1);
  });

  test('Pathless documents with the same title get their own previews',
      () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final ws = WorkspaceController(prefs);
    // Two unsaved documents — both are titled "Untitled".
    final docA = ws.activeDocument!;
    ws.newDocument();
    final docB = ws.activeDocument!;

    ws.openPrintPreview(
        markdown: 'A', title: docA.title, docPath: null, sourceKey: docA);
    ws.openPrintPreview(
        markdown: 'B', title: docB.title, docPath: null, sourceKey: docB);
    expect(ws.tabs.whereType<PrintPreviewTab>().length, 2);

    // Re-printing doc A refreshes A's preview, not B's.
    ws.openPrintPreview(
        markdown: 'A v2', title: docA.title, docPath: null, sourceKey: docA);
    expect(ws.tabs.whereType<PrintPreviewTab>().length, 2);
    expect((ws.activeTab as PrintPreviewTab).markdown, 'A v2');

    // Closing doc A orphans its preview: printing a fresh pathless document
    // opens a new tab instead of hijacking the orphan.
    ws.closeAt(ws.tabs.indexWhere((t) => t is DocumentTab && t.doc == docA));
    ws.newDocument();
    final docC = ws.activeDocument!;
    ws.openPrintPreview(
        markdown: 'C', title: docC.title, docPath: null, sourceKey: docC);
    expect(ws.tabs.whereType<PrintPreviewTab>().length, 3);
  });

  test('A preview follows its document through Save As', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final ws = WorkspaceController(prefs);
    final doc = ws.activeDocument!;

    // Printed while unsaved: preview is matched by document identity.
    ws.openPrintPreview(
        markdown: 'draft', title: doc.title, docPath: null, sourceKey: doc);
    expect(ws.tabs.whereType<PrintPreviewTab>().length, 1);

    // After Save As, printing again refreshes the same preview (no
    // duplicate) and the preview adopts the new path.
    ws.openPrintPreview(
        markdown: 'saved', title: 'a', docPath: '/tmp/a.md', sourceKey: doc);
    final previews = ws.tabs.whereType<PrintPreviewTab>().toList();
    expect(previews.length, 1);
    expect(previews.single.docPath, '/tmp/a.md');
    expect(previews.single.markdown, 'saved');
    expect(previews.single.epoch, 1);
  });

  test('A sole pristine Untitled is replaced even with previews open',
      () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final ws = WorkspaceController(prefs);
    final untitled = ws.activeDocument!;
    ws.openPrintPreview(
        markdown: '',
        title: untitled.title,
        docPath: null,
        sourceKey: untitled);
    expect(ws.tabs.length, 2);

    // Opening a real file replaces the pristine Untitled document rather
    // than stacking a third tab next to it.
    ws.openDocument('# Hello', path: '/tmp/a.md');
    expect(ws.documents.length, 1);
    expect(ws.documents.single.filePath, '/tmp/a.md');
    expect(ws.tabs.length, 2);
    expect(ws.activeDocument?.filePath, '/tmp/a.md');
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
