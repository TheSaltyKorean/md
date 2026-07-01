/// Pure, UI-independent text search used by the find & replace bar. Kept
/// separate from the widgets so the matching/replacement rules can be unit
/// tested without pumping any UI.
library;

/// A single match as a half-open character range `[start, end)` into the
/// searched text.
class TextMatch {
  const TextMatch(this.start, this.end);

  final int start;
  final int end;

  @override
  bool operator ==(Object other) =>
      other is TextMatch && other.start == start && other.end == end;

  @override
  int get hashCode => Object.hash(start, end);

  @override
  String toString() => 'TextMatch($start, $end)';
}

/// Options controlling how a query is interpreted.
class SearchOptions {
  const SearchOptions({
    this.caseSensitive = false,
    this.wholeWord = false,
    this.regex = false,
  });

  final bool caseSensitive;
  final bool wholeWord;
  final bool regex;

  SearchOptions copyWith({
    bool? caseSensitive,
    bool? wholeWord,
    bool? regex,
  }) =>
      SearchOptions(
        caseSensitive: caseSensitive ?? this.caseSensitive,
        wholeWord: wholeWord ?? this.wholeWord,
        regex: regex ?? this.regex,
      );
}

/// Result of compiling a query into a pattern.
class SearchPattern {
  const SearchPattern._(this.regExp, this.error);

  /// The compiled expression, or null when the query is empty or invalid.
  final RegExp? regExp;

  /// A human-readable error when [regExp] is null because the regex was
  /// invalid (null for an empty query).
  final String? error;

  bool get isValid => regExp != null;
}

/// Stateless helpers for finding and replacing text.
class TextSearch {
  const TextSearch._();

  /// Compile [query] under [options] into a [SearchPattern]. An empty query
  /// yields a pattern with a null [SearchPattern.regExp] and no error; an
  /// invalid regex yields a null expression with an [SearchPattern.error].
  static SearchPattern compile(String query, SearchOptions options) {
    if (query.isEmpty) return const SearchPattern._(null, null);
    var body = options.regex ? query : RegExp.escape(query);
    if (options.wholeWord) {
      // Word boundaries only make sense around word characters; wrap the whole
      // pattern so "cat" doesn't match inside "category".
      body = '(?<![\\w])(?:$body)(?![\\w])';
    }
    try {
      return SearchPattern._(
        RegExp(body, caseSensitive: options.caseSensitive, multiLine: true),
        null,
      );
    } on FormatException catch (e) {
      return SearchPattern._(null, e.message);
    }
  }

  /// All non-overlapping, non-empty matches of [query] in [text].
  static List<TextMatch> findAll(
    String text,
    String query,
    SearchOptions options,
  ) {
    final pattern = compile(query, options);
    return matchesOf(text, pattern);
  }

  /// All non-overlapping, non-empty matches for an already-compiled [pattern].
  static List<TextMatch> matchesOf(String text, SearchPattern pattern) {
    final re = pattern.regExp;
    if (re == null || text.isEmpty) return const [];
    final out = <TextMatch>[];
    for (final m in re.allMatches(text)) {
      // Skip zero-width matches (e.g. a regex like `a*`) so navigation and
      // replacement always make progress.
      if (m.end > m.start) out.add(TextMatch(m.start, m.end));
    }
    return out;
  }

  /// Return [text] with each range in [matches] replaced by [replacement]
  /// (inserted literally — no `$1` group substitution). [matches] must be
  /// sorted and non-overlapping, as produced by [findAll].
  static String replaceMatches(
    String text,
    List<TextMatch> matches,
    String replacement,
  ) {
    if (matches.isEmpty) return text;
    final b = StringBuffer();
    var last = 0;
    for (final m in matches) {
      if (m.start < last) continue; // defensive: skip any overlap
      b.write(text.substring(last, m.start));
      b.write(replacement);
      last = m.end;
    }
    b.write(text.substring(last));
    return b.toString();
  }
}
