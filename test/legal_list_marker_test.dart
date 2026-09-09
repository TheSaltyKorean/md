import 'package:flutter_test/flutter_test.dart';
import 'package:markdown_studio/models/print_profile.dart';
import 'package:markdown_studio/services/markdown_pdf_builder.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

/// One drawn text run in the page content stream: its position and its text.
typedef _Run = ({double x, double y, String text});

/// Renders [markdown] with the Court Filing profile (legal mode + justified
/// body + 0.5in first-line indent) and returns every text run drawn on the
/// page, in page-content coordinates (0,0 = the top-left inside the margin).
///
/// Uses the base-14 fonts so the runs stay readable Latin1 in an uncompressed
/// content stream — the real app supplies TTFs, which subset to glyph ids.
Future<List<_Run>> _render(String markdown) async {
  final fonts = PdfFontSet(
    base: pw.Font.times(),
    bold: pw.Font.timesBold(),
    italic: pw.Font.timesItalic(),
    boldItalic: pw.Font.timesBoldItalic(),
    mono: pw.Font.courier(),
  );
  final widgets =
      MarkdownPdfBuilder(profile: PrintProfile.courtFiling, fonts: fonts)
          .build(markdown);

  final doc = pw.Document(compress: false);
  doc.addPage(
    pw.MultiPage(
      pageTheme: pw.PageTheme(
        pageFormat: PdfPageFormat.letter.copyWith(
          marginLeft: 72,
          marginRight: 72,
          marginTop: 72,
          marginBottom: 72,
        ),
        theme: pw.ThemeData.withFont(
          base: fonts.base,
          bold: fonts.bold,
          italic: fonts.italic,
          boldItalic: fonts.boldItalic,
        ),
      ),
      build: (context) => widgets,
    ),
  );

  final bytes = await doc.save();
  final stream = String.fromCharCodes(bytes);
  final re = RegExp(r'([-\d.]+) ([-\d.]+) Td \[\((.*?)\)\]TJ');
  return [
    for (final m in re.allMatches(stream))
      (
        x: double.parse(m.group(1)!),
        y: double.parse(m.group(2)!),
        text: m.group(3)!,
      ),
  ];
}

void main() {
  // A long first line (justified to the full measure) and a short one, so both
  // the stretched and the unstretched case are covered.
  const longItem = 'Comes now the plaintiff and respectfully shows the Court '
      'that the defendant did wilfully and repeatedly fail to perform under '
      'the agreement described above.';

  test('flowed ordered-list markers align regardless of justification',
      () async {
    final md = StringBuffer();
    for (var i = 1; i <= 13; i++) {
      md.writeln('$i. ${i % 4 == 0 ? 'Short item.' : longItem}');
      md.writeln();
    }
    final runs = await _render(md.toString());

    // Marker draws come first on their line, so the run right after a marker
    // is that item's first word. (Local y coordinates repeat between items, so
    // the runs must be paired by stream order, not by position.)
    final markerIndexes = [
      for (var i = 0; i < runs.length; i++)
        if (RegExp(r'^\d+\.$').hasMatch(runs[i].text) && runs[i].x < 72) i,
    ];
    final markers = [for (final i in markerIndexes) runs[i]];
    expect(markers.length, 13, reason: 'one marker per item');
    // Every marker — one- and two-digit alike — sits exactly at the 0.5in
    // first-line indent, never nudged right by justification.
    for (final m in markers) {
      expect(m.x, closeTo(36, 0.01), reason: 'marker "${m.text}" x');
    }

    // The item text starts just after the 0.5in marker box (1.0in in), give or
    // take the single justification gap the line's spans still share.
    final firstWords = [for (final i in markerIndexes) runs[i + 1]];
    for (final w in firstWords) {
      expect(w.x, greaterThanOrEqualTo(72.0));
      expect(w.x, lessThan(74.0));
    }

    // The marker shares the baseline of the text beside it (the marker box is
    // zero-height and paints on the line's baseline).
    for (var i = 0; i < markers.length; i++) {
      expect(markers[i].y, firstWords[i].y);
    }
  });
}
