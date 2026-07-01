import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:markdown_studio/widgets/find_controller.dart';
import 'package:markdown_studio/widgets/find_replace_bar.dart';

void main() {
  testWidgets('shows the match count, navigates, and replaces all',
      (tester) async {
    final target = TextEditingController(text: 'foo bar foo baz foo');
    final scroll = ScrollController();
    final fc = FindController()..openReplace();
    addTearDown(() {
      target.dispose();
      scroll.dispose();
      fc.dispose();
    });

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Stack(
          children: [
            Positioned.fill(
              child: FindReplaceBar(find: fc, target: target, scroll: scroll),
            ),
          ],
        ),
      ),
    ));
    await tester.pump();

    // Two fields: [0] = query, [1] = replace.
    final fields = find.byType(TextField);
    expect(fields, findsNWidgets(2));

    await tester.enterText(fields.at(0), 'foo');
    await tester.pump();
    expect(find.text('1 of 3'), findsOneWidget);

    // Next advances (with wrap).
    await tester.tap(find.byTooltip('Next (Enter)'));
    await tester.pump();
    expect(find.text('2 of 3'), findsOneWidget);

    // Replace all rewrites every match with the replacement text.
    await tester.enterText(fields.at(1), 'X');
    await tester.pump();
    await tester.tap(find.byTooltip('Replace all'));
    await tester.pump();
    expect(target.text, 'X bar X baz X');
  });

  testWidgets('reports no results and an invalid regex', (tester) async {
    final target = TextEditingController(text: 'hello world');
    final scroll = ScrollController();
    final fc = FindController()..openFind();
    addTearDown(() {
      target.dispose();
      scroll.dispose();
      fc.dispose();
    });

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Stack(
          children: [
            Positioned.fill(
              child: FindReplaceBar(find: fc, target: target, scroll: scroll),
            ),
          ],
        ),
      ),
    ));
    await tester.pump();

    await tester.enterText(find.byType(TextField).first, 'zzz');
    await tester.pump();
    expect(find.text('No results'), findsOneWidget);

    // Turn on regex and type an invalid pattern → an error is surfaced.
    await tester.tap(find.byTooltip('Use regular expression'));
    await tester.pump();
    await tester.enterText(find.byType(TextField).first, '(');
    await tester.pump();
    expect(find.text('Invalid regex'), findsOneWidget);
  });
}
