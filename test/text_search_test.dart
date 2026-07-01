import 'package:flutter_test/flutter_test.dart';
import 'package:markdown_studio/services/text_search.dart';

void main() {
  group('TextSearch.findAll', () {
    test('finds all non-overlapping literal matches', () {
      final m = TextSearch.findAll('ababab', 'ab', const SearchOptions());
      expect(m, const [TextMatch(0, 2), TextMatch(2, 4), TextMatch(4, 6)]);
    });

    test('is case-insensitive by default and case-sensitive on request', () {
      expect(TextSearch.findAll('Foo foo FOO', 'foo', const SearchOptions()),
          hasLength(3));
      expect(
        TextSearch.findAll(
            'Foo foo FOO', 'foo', const SearchOptions(caseSensitive: true)),
        const [TextMatch(4, 7)],
      );
    });

    test('whole-word only matches standalone words', () {
      final m = TextSearch.findAll(
          'cat category cat.', 'cat', const SearchOptions(wholeWord: true));
      // "cat" (0) and "cat" before the period (13), but not inside "category".
      expect(m, const [TextMatch(0, 3), TextMatch(13, 16)]);
    });

    test('regex mode matches patterns', () {
      final m =
          TextSearch.findAll('a1 b2 c3', r'\d', const SearchOptions(regex: true));
      expect(m, hasLength(3));
    });

    test('escapes the query when not in regex mode', () {
      // The dot is literal here, so it only matches a real period.
      final m = TextSearch.findAll('a.b axb', 'a.b', const SearchOptions());
      expect(m, const [TextMatch(0, 3)]);
    });

    test('skips zero-width matches so navigation makes progress', () {
      final m = TextSearch.findAll('baa', 'a*', const SearchOptions(regex: true));
      expect(m, const [TextMatch(1, 3)]);
    });

    test('empty query yields no matches', () {
      expect(TextSearch.findAll('anything', '', const SearchOptions()), isEmpty);
    });
  });

  group('TextSearch.compile', () {
    test('reports an invalid regex without throwing', () {
      final p = TextSearch.compile('(unterminated', const SearchOptions(regex: true));
      expect(p.isValid, isFalse);
      expect(p.error, isNotNull);
    });

    test('an empty query is not an error, just no pattern', () {
      final p = TextSearch.compile('', const SearchOptions());
      expect(p.isValid, isFalse);
      expect(p.error, isNull);
    });
  });

  group('TextSearch.replaceMatches', () {
    test('replaces every match with the literal replacement', () {
      const text = 'foo bar foo';
      final matches = TextSearch.findAll(text, 'foo', const SearchOptions());
      expect(TextSearch.replaceMatches(text, matches, 'X'), 'X bar X');
    });

    test('replaces a single targeted match', () {
      const text = 'foo bar foo';
      final matches = TextSearch.findAll(text, 'foo', const SearchOptions());
      expect(
          TextSearch.replaceMatches(text, [matches[1]], 'X'), 'foo bar X');
    });

    test('does not perform \$ group substitution (literal replacement)', () {
      const text = 'abc';
      final matches = TextSearch.findAll(text, 'b', const SearchOptions());
      expect(TextSearch.replaceMatches(text, matches, r'$1'), r'a$1c');
    });

    test('no matches leaves the text unchanged', () {
      expect(TextSearch.replaceMatches('abc', const [], 'X'), 'abc');
    });
  });
}
