import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:image/image.dart' as img;
import 'package:flutter/material.dart'
    show DropdownButtonFormField, MaterialApp, Scaffold;
import 'package:flutter/widgets.dart'
    show Size, SizedBox, TextSelection, Widget;
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
import 'package:markdown_studio/widgets/print_preview_view.dart';
import 'package:pdf/pdf.dart' show PdfColors, PdfPageFormat;
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
  } else if (w is pw.Align && w.child != null) {
    yield* _allWidgets(w.child!);
  } else if (w is pw.Container && w.child != null) {
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

/// All literal text reachable from the given widgets' RichText spans.
String _literalText(Iterable<pw.Widget> ws) {
  final sb = StringBuffer();
  void walkSpan(pw.InlineSpan s) {
    if (s is pw.TextSpan) {
      if (s.text != null) sb.write(s.text);
      for (final c in s.children ?? const <pw.InlineSpan>[]) {
        walkSpan(c);
      }
    }
  }

  for (final w in ws) {
    if (w is pw.RichText) walkSpan(w.text);
  }
  return sb.toString();
}

Iterable<pw.Widget> _walk(List<pw.Widget> ws) => ws.expand(_allWidgets);

/// Lay [widgets] into an A4 MultiPage with 2cm margins and return the bytes —
/// throws if any single widget can't fit/paginate (the bug these tests guard).
Future<Uint8List> _renderA4(List<pw.Widget> widgets) async {
  final doc = pw.Document();
  doc.addPage(pw.MultiPage(
    pageFormat: PdfPageFormat.a4.copyWith(
      marginLeft: 2 * PdfPageFormat.cm,
      marginRight: 2 * PdfPageFormat.cm,
      marginTop: 2 * PdfPageFormat.cm,
      marginBottom: 2 * PdfPageFormat.cm,
    ),
    build: (_) => widgets,
  ));
  return doc.save();
}

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

  testWidgets('Selecting a profile in the preview is saved with the document',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final service = PrintProfileService(prefs);

    Future<void> pump(String? docPath) => tester.pumpWidget(MultiProvider(
          providers: [
            ChangeNotifierProvider<PrintProfileService>.value(value: service),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: PrintPreviewView(
                  markdown: '# Hello', title: 'a', docPath: docPath),
            ),
          ),
        ));

    await pump('/tmp/a.md');
    await tester.pump(const Duration(seconds: 1));

    // Choosing a profile in the dropdown IS the association — no pin needed.
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.text('Work').last);
    await tester.pump(const Duration(seconds: 1));
    expect(service.assignedId('/tmp/a.md'), 'work');

    // It survives a restart (fresh service over the same prefs).
    await service.pendingWrites;
    expect(PrintProfileService(prefs).forDocument('/tmp/a.md').id, 'work');

    // The pin now clears the association.
    await tester.tap(find
        .byTooltip('Always using this profile for this file — tap to stop'));
    await tester.pump(const Duration(seconds: 1));
    expect(service.assignedId('/tmp/a.md'), isNull);

    // And an explicit clear is final: a later Save As must not resurrect
    // the association the user just removed.
    await pump('/tmp/a-renamed.md');
    await tester.pump(const Duration(seconds: 1));
    expect(service.assignedId('/tmp/a-renamed.md'), isNull);
  });

  testWidgets('A profile chosen for an unsaved doc sticks after Save As',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final service = PrintProfileService(prefs);

    Widget app(String? docPath) => MultiProvider(
          providers: [
            ChangeNotifierProvider<PrintProfileService>.value(value: service),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: PrintPreviewView(
                  markdown: '# Hello', title: 'a', docPath: docPath),
            ),
          ),
        );

    // Unsaved: selection is session-local (nothing durable to key on).
    await tester.pumpWidget(app(null));
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.text('Work').last);
    await tester.pump(const Duration(seconds: 1));
    expect(prefs.getString('doc_print_profile_map'), isNull);

    // Save As + print again: same preview, now with a path — the chosen
    // profile is remembered for the file.
    await tester.pumpWidget(app('/tmp/b.md'));
    await tester.pump(const Duration(seconds: 1));
    expect(service.assignedId('/tmp/b.md'), 'work');
  });

  testWidgets('Save As never pins a default the user did not choose',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final service = PrintProfileService(prefs);

    Widget app(String? docPath) => MultiProvider(
          providers: [
            ChangeNotifierProvider<PrintProfileService>.value(value: service),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: PrintPreviewView(
                  markdown: '# Hello', title: 'a', docPath: docPath),
            ),
          ),
        );

    // Preview an unsaved doc without ever touching the dropdown, then
    // Save As: the (default) profile must NOT become a file binding — the
    // document keeps following future default changes.
    await tester.pumpWidget(app(null));
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpWidget(app('/tmp/c.md'));
    await tester.pump(const Duration(seconds: 1));
    expect(service.assignedId('/tmp/c.md'), isNull);

    // But an existing binding follows the document through Save As to a new
    // path, even with no in-session selection. (Fresh preview, as the app
    // would create for the already-bound document.)
    await tester.pumpWidget(const SizedBox());
    await service.assignToDocument('/tmp/d.md', 'work');
    await tester.pumpWidget(app('/tmp/d.md'));
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpWidget(app('/tmp/e.md'));
    await tester.pump(const Duration(seconds: 1));
    expect(service.assignedId('/tmp/e.md'), 'work');
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
    // (The trailing block's own gap is trimmed at the document end, so this
    // doc ends with a closing paragraph to keep four inter-block gaps.)
    final ws = builder.build('First paragraph of the motion.\n\n'
        'Second paragraph of the motion.\n\n'
        '- first ground\n- second ground\n\n'
        'Respectfully submitted.');
    // Uniform rhythm: the inter-block gap == in-paragraph leading, so the
    // baseline-to-baseline distance across a paragraph break equals the
    // double-spaced line height (2.5 + 12 × (multiple − 1) = 14.5 at 2.0,
    // derived from the 12pt legal body). Flowing blocks carry the gap as a
    // sibling SizedBox (a padding wrapper would waste the gap's height at
    // every page split).
    final expected = 2.5 + 12.0 * (court.lineSpacingMultiple - 1.0);
    final gaps = ws
        .whereType<pw.SizedBox>()
        .where((s) => s.height == expected && s.width == null);
    expect(gaps.length, 4,
        reason: 'both paragraphs and both list items carry the spaced gap');
    final bottoms = _walk(ws)
        .whereType<pw.Padding>()
        .map((p) => (p.padding as pw.EdgeInsets).bottom)
        .toList();
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

  test('legalMode body text and plain <div>s render at 12pt', () {
    final court = PrintProfile.seeds.firstWhere((p) => p.id == 'court-filing');
    final legal = MarkdownPdfBuilder(profile: court, fonts: _standardFonts());
    final plain = MarkdownPdfBuilder(
        profile: PrintProfile.personal, fonts: _standardFonts());

    // Every text-span font size reachable from the built widgets.
    Iterable<double> spanSizes(List<pw.Widget> ws) sync* {
      Iterable<double> walk(pw.InlineSpan s) sync* {
        if (s is pw.TextSpan) {
          final size = s.style?.fontSize;
          if (size != null) yield size;
          for (final c in s.children ?? const <pw.InlineSpan>[]) {
            yield* walk(c);
          }
        }
      }

      for (final r in _walk(ws).whereType<pw.RichText>()) {
        yield* walk(r.text);
      }
    }

    // Body paragraphs: 12pt in legal mode, historical 11pt otherwise.
    final legalBody =
        spanSizes(legal.build('Comes now the Defendant.')).toList();
    expect(legalBody, isNotEmpty);
    expect(legalBody.every((s) => s == 12.0), isTrue);
    final plainBody = spanSizes(plain.build('A plain paragraph.')).toList();
    expect(plainBody, isNotEmpty);
    expect(plainBody.every((s) => s == 11.0), isTrue);

    // A <div> with no font-size matches the body in legal mode (12pt), keeps
    // the historical 10pt otherwise; an explicit font-size still wins.
    final legalDiv = spanSizes(legal.build('<div>MEGHAN MAIN</div>')).toList();
    expect(legalDiv, isNotEmpty);
    expect(legalDiv.every((s) => s == 12.0), isTrue);
    final plainDiv = spanSizes(plain.build('<div>MEGHAN MAIN</div>')).toList();
    expect(plainDiv, isNotEmpty);
    expect(plainDiv.every((s) => s == 10.0), isTrue);
    final explicit =
        spanSizes(legal.build('<div style="font-size:14pt">Exhibit A</div>'))
            .toList();
    expect(explicit, isNotEmpty);
    expect(explicit.every((s) => s == 14.0), isTrue);
  });

  test('legalMode paragraphs and list items flow across page boundaries',
      () async {
    final court = PrintProfile.seeds.firstWhere((p) => p.id == 'court-filing');
    final builder = MarkdownPdfBuilder(profile: court, fonts: _standardFonts());
    const sentence =
        'The hearing in this matter is currently set for a date on which the '
        'Defendant is unavailable for reasons entirely beyond his control. ';

    Future<int> pageCount(List<pw.Widget> ws) async {
      final doc = pw.Document()..addPage(pw.MultiPage(build: (_) => ws));
      final bytes = await doc.save();
      return RegExp(r'/Type\s*/Page\b')
          .allMatches(String.fromCharCodes(bytes))
          .length;
    }

    // A single paragraph taller than a page must split across the boundary
    // (as an atomic block this used to throw "Widget won't fit").
    final long = builder.build(sentence * 60);
    expect(
        _walk(long)
            .whereType<pw.RichText>()
            .any((r) => r.overflow == pw.TextOverflow.span),
        isTrue);
    final longPages = await pageCount(long);
    expect(longPages, greaterThanOrEqualTo(2));

    // A single numbered item taller than a page flows the same way, with its
    // marker inline.
    final item = builder.build('1. ${sentence * 60}');
    expect(_literalText(_walk(item)).contains('1.'), isTrue);
    final itemPages = await pageCount(item);
    expect(itemPages, greaterThanOrEqualTo(2));

    // Filled pages: an intro plus four ~⅔-page paragraphs (~2.7 pages of
    // text) fits in three flowing pages; placed atomically each paragraph
    // would demand a fresh page (four total, each ending in a blank band).
    final chunk = sentence * 10;
    final filled = await pageCount(
        builder.build('Intro.\n\n$chunk\n\n$chunk\n\n$chunk\n\n$chunk'));
    expect(filled, lessThanOrEqualTo(3));

    // The final block's gap is trimmed: the document never ends in a bare
    // spacer that could spill onto a blank trailing page.
    bool bareGap(pw.Widget w) =>
        w is pw.SizedBox && w.width == null && w.child == null;
    expect(bareGap(builder.build('Only paragraph.').last), isFalse);

    // A gap is also trimmed directly before a forced page break…
    final broken =
        builder.build('A\n\n<div style="page-break-before:always"></div>\n\nB');
    final breakAt = broken.indexWhere((w) => w is pw.NewPage);
    expect(breakAt, greaterThan(0));
    expect(bareGap(broken[breakAt - 1]), isFalse);

    // …and prose sharing a raw block with the break directive still flows
    // (it must be able to split across pages like any legal paragraph).
    final sharedBlock = builder
        .build('<div style="page-break-before:always"></div>\n${sentence * 3}');
    expect(sharedBlock.whereType<pw.NewPage>().length, 1);
    expect(
        _walk(sharedBlock)
            .whereType<pw.RichText>()
            .any((r) => r.overflow == pw.TextOverflow.span),
        isTrue);
  });

  test('Captions, signature divs and headings stay atomic in legal mode', () {
    final court = PrintProfile.seeds.firstWhere((p) => p.id == 'court-filing');
    final builder = MarkdownPdfBuilder(profile: court, fonts: _standardFonts());
    final ws = builder
        .build('<div style="display:flex; justify-content:space-between">'
            '<div>MEGHAN MAIN</div><div>PLAINTIFF</div></div>\n\n'
            '<div style="width:40%; border-bottom:1px solid #000"></div>\n\n'
            '#### <u>MOTION FOR CONTINUANCE</u>');
    // Nothing in these blocks is page-spanning text, and the caption is
    // still a Row.
    expect(
        _walk(ws)
            .whereType<pw.RichText>()
            .any((r) => r.overflow == pw.TextOverflow.span),
        isFalse);
    expect(_walk(ws).whereType<pw.Row>().isNotEmpty, isTrue);
  });

  test('Non-legal documents never emit page-spanning text (regression)', () {
    final builder = MarkdownPdfBuilder(
        profile: PrintProfile.personal, fonts: _standardFonts());
    final ws =
        builder.build('A paragraph.\n\nAnother paragraph.\n\n1. one\n2. two');
    expect(
        _walk(ws)
            .whereType<pw.RichText>()
            .any((r) => r.overflow == pw.TextOverflow.span),
        isFalse);
    // Lists keep their single-widget Column structure.
    expect(_walk(ws).whereType<pw.Column>().isNotEmpty, isTrue);
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

    // Adjacent HTML blocks with no blank line: package:markdown keeps them in
    // one text node — the break must still be found and the caption rendered.
    final adjacent = builder.build('<div style="page-break-before:always">'
        '</div>\n<div style="text-align:center">CERTIFICATE OF SERVICE</div>');
    expect(adjacent.whereType<pw.NewPage>().length, 1);
    expect(
        _walk(adjacent).whereType<pw.Text>().any((t) =>
            ((t.text as pw.TextSpan).text ?? '').contains('CERTIFICATE')),
        isTrue);

    // A visible element carrying the directive breaks AND still renders: a
    // signature line with page-break-before starts a page, then draws.
    final withLine = builder.build('<div style="page-break-before:always; '
        'border-bottom:1px solid; width:150px"></div>');
    expect(withLine.whereType<pw.NewPage>().length, 1);
    expect(_walk(withLine).whereType<pw.Container>().isNotEmpty, isTrue,
        reason: 'the signature rule survives the break');
    expect(withLine.first, isA<pw.NewPage>(),
        reason: '…-before breaks before the element renders');

    // A CSS priority suffix is accepted.
    expect(
        builder
            .build('A\n\n<div style="page-break-before: always !important">'
                '</div>\n\nB')
            .whereType<pw.NewPage>()
            .length,
        1);

    // A break div nested inside a wrapper is NOT split out of it: the wrapper
    // renders intact (no leaked </div>), and no page break is emitted.
    final nestedBreak = builder.build('<div style="text-align:center">'
        '<div style="page-break-before:always"></div>CERTIFICATE</div>');
    expect(nestedBreak.whereType<pw.NewPage>(), isEmpty);
    final nestedText = _literalText(_walk(nestedBreak));
    expect(nestedText.contains('</div'), isFalse);
    expect(nestedText.contains('CERTIFICATE'), isTrue);

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

    // Inside a styled span the <br> survives as a line break too (it used to
    // be flattened to a space).
    final label = builder
        .renderInlineText(
            '<span style="font-weight:bold">Line 1<br>Line 2</span>')
        .map(literal)
        .join();
    expect(label.contains('<br'), isFalse);
    expect(label.contains('Line 1\nLine 2'), isTrue);
  });

  test('A long code block paginates instead of overflowing the page', () async {
    final builder = MarkdownPdfBuilder(
        profile: PrintProfile.personal, fonts: _standardFonts());
    final code =
        '```\n${List.generate(90, (i) => 'line $i of code').join('\n')}\n```';
    // Before the fix this threw "Widget won't fit into the page…".
    expect(await _renderA4(builder.build(code)), isNotEmpty);
  });

  test('A long multi-paragraph blockquote paginates', () async {
    final builder = MarkdownPdfBuilder(
        profile: PrintProfile.personal, fonts: _standardFonts());
    final quote =
        List.generate(60, (i) => '> Paragraph $i of the quoted passage.')
            .join('\n>\n');
    expect(await _renderA4(builder.build(quote)), isNotEmpty);
  });

  test('A tall image is capped to one page (no overflow)', () async {
    final tmp = Directory.systemTemp.createTempSync('mdimg');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final tall = img.Image(width: 400, height: 3000);
    img.fill(tall, color: img.ColorRgb8(120, 120, 200));
    File('${tmp.path}/tall.png')
        .writeAsBytesSync(Uint8List.fromList(img.encodePng(tall)));

    final builder = MarkdownPdfBuilder(
        profile: PrintProfile.personal,
        fonts: _standardFonts(),
        baseDir: tmp.path,
        maxImageHeight: 600);
    final ws = builder.build('before\n\n![tall](tall.png)\n\nafter');
    // Without the cap the 3000px image exceeds a page and MultiPage throws.
    expect(await _renderA4(ws), isNotEmpty);

    // The cap must never UPSCALE: capped images render with scaleDown so a
    // small inline image keeps its intrinsic size instead of filling the
    // bounded box.
    bool usesScaleDown(pw.Widget w) =>
        w is pw.Padding &&
        w.child is pw.ConstrainedBox &&
        ((w.child as pw.ConstrainedBox).child as pw.Image).fit ==
            pw.BoxFit.scaleDown;
    expect(_walk(ws).any(usesScaleDown), isTrue);
  });

  test('legalMode keeps one gap for blockquotes and nested lists', () {
    final court = PrintProfile.seeds.firstWhere((p) => p.id == 'court-filing');
    final builder = MarkdownPdfBuilder(profile: court, fonts: _standardFonts());
    final gap = 2.5 + 12.0 * (court.lineSpacingMultiple - 1.0);

    // The quote's outer bottom padding is the single gap to the next block;
    // the paragraph inside must not add a second one (a blank band in the
    // box). (The quote is a Padding around a Column of per-child decorated
    // containers so tall quotes can paginate.)
    final quote = builder.build('> quoted authority\n\nnext paragraph').first
        as pw.Padding;
    final innerBottoms = _allWidgets(quote.child!)
        .whereType<pw.Padding>()
        .map((p) => (p.padding as pw.EdgeInsets).bottom);
    expect(innerBottoms.any((b) => b == gap), isFalse,
        reason: 'no double gap inside the quote');
    expect((quote.padding as pw.EdgeInsets).bottom, gap);

    // Nested list: the item with children keeps the atomic layout (parent row
    // + child item carry one padding gap each); the plain 'next' item flows
    // and carries its gap as a sibling SizedBox. (A trailing paragraph keeps
    // that gap from being trimmed as the document tail.)
    final list = builder.build('- parent\n  - child\n- next\n\ntail');
    final bottoms = _walk(list)
        .whereType<pw.Padding>()
        .map((p) => (p.padding as pw.EdgeInsets).bottom)
        .where((b) => b == gap);
    expect(bottoms.length, 2);
    expect(
        list
            .whereType<pw.SizedBox>()
            .where((s) => s.height == gap && s.width == null)
            .length,
        1);

    // A quote that *ends in a list* sheds the last item's gap too (the trim
    // descends through the list's zero-gap wrapper).
    final listQuote =
        builder.build('> - cited point\n\nnext paragraph').first as pw.Padding;
    final listQuoteBottoms = _allWidgets(listQuote.child!)
        .whereType<pw.Padding>()
        .map((p) => (p.padding as pw.EdgeInsets).bottom);
    expect(listQuoteBottoms.any((b) => b == gap), isFalse,
        reason: 'no gap band inside a quote ending in a list');
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
