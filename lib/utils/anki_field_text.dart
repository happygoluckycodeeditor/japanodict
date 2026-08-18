/// Turns one Anki note field into plain text the dictionary can be pointed at.
///
/// Anki stores fields as **HTML fragments**, not as text: the note editor is a
/// contenteditable, so even a hand-typed field arrives wrapped in `<div>`s the
/// user never asked for. On top of that, several Anki conventions encode
/// non-text things inline — `[sound:x.mp3]` for audio, `漢字[かんじ]` for
/// furigana, `{{c1::…}}` for cloze deletions.
///
/// All of that has to go before [TextLookupService] sees the string, and for a
/// sharper reason than tidiness: the segmenter walks *runs of Japanese
/// characters* and tries progressively shorter substrings. A furigana reading
/// left in place makes 漢字かんじ one unbroken run, so the longest-match pass
/// starts from a string no dictionary entry can ever match, and every word in
/// the field shifts by however many kana the reading contributed.
///
/// Nothing here is a real HTML parser and it doesn't need to be — note fields
/// are fragments produced by a fixed set of editors, not arbitrary documents.
library;

class AnkiFieldText {
  AnkiFieldText._();

  /// The unit separator Anki uses between fields inside `notes.flds`, and
  /// between the components of a nested deck name in the schema-18
  /// `decks.name` column.
  static const String fieldSeparator = '\x1f';

  // Ruby readings, removed *content and all* rather than unwrapped: <ruby> is
  // how AnkiDroid and several popular note types render furigana, and the <rt>
  // holds the reading, which must not survive into the text (see the library
  // doc above).
  static final RegExp _rubyReading = RegExp(
    r'<r[tp]\b[^>]*>.*?</r[tp]>',
    caseSensitive: false,
    dotAll: true,
  );

  static final RegExp _styleOrScript = RegExp(
    r'<(style|script)\b[^>]*>.*?</\1>',
    caseSensitive: false,
    dotAll: true,
  );

  /// `[sound:foo.mp3]`, `[anki:tts …]` — media references, not text.
  static final RegExp _mediaTag = RegExp(
    r'\[(?:sound|anki):[^\]]*\]',
    caseSensitive: false,
  );

  /// `{{c1::答え}}` and `{{c1::答え::hint}}` — keep the answer, drop the
  /// bookkeeping. A cloze field is the only place the word actually lives, so
  /// dropping the whole construct would leave the card looking empty.
  static final RegExp _cloze = RegExp(r'\{\{c\d+::(.*?)(?:::.*?)?\}\}', dotAll: true);

  /// A closing block tag butted straight up against the matching opening one.
  ///
  /// This is what the Anki editor emits for consecutive lines —
  /// `<div>今日</div><div>寒い</div>` is two lines, not two lines with a blank
  /// between them. Collapsing the pair to one newline first is what stops the
  /// general rule below from doubling every line break, while leaving a
  /// genuinely empty `<div></div>` to produce the blank line it means.
  static final RegExp _adjacentBlockBoundary = RegExp(
    r'<\s*/\s*(div|p|li|tr|blockquote|h[1-6])\s*>\s*<\s*\1\b[^>]*>',
    caseSensitive: false,
  );

  /// Tags that end a visual line. Replaced with a newline before the general
  /// tag strip so that two fields' worth of `<div>`s don't run together into
  /// one word — 今日<div>寒い would otherwise become 今日寒い and invite a
  /// match straddling the boundary.
  static final RegExp _lineBreakTag = RegExp(
    r'<\s*/?\s*(br|div|p|li|tr|h[1-6]|blockquote)\b[^>]*>',
    caseSensitive: false,
  );

  static final RegExp _anyTag = RegExp(r'<[^>]*>');

  /// Anki's plain-text furigana: a base followed by its reading in brackets,
  /// as in `日本語[にほんご]`.
  ///
  /// Only brackets whose contents are **entirely kana** are stripped. A
  /// blanket `\[.*?\]` would also eat the English brackets that decks
  /// routinely use for glosses ("[transitive]", "[Godan verb]"), which are
  /// part of the meaning the user is reading.
  static final RegExp _furigana = RegExp(r'\[[ ぁ-ゟ゠-ヿ]+\]');

  static const Map<String, String> _entities = {
    '&nbsp;': ' ',
    '&amp;': '&',
    '&lt;': '<',
    '&gt;': '>',
    '&quot;': '"',
    '&apos;': "'",
    '&#39;': "'",
    '&#x27;': "'",
    '&ndash;': '–',
    '&mdash;': '—',
    '&hellip;': '…',
  };

  static final RegExp _entity = RegExp(r'&(?:#x?[0-9a-fA-F]+|[a-zA-Z]+);');
  static final RegExp _manyNewlines = RegExp(r'\n{3,}');
  static final RegExp _spacesAroundNewline = RegExp(r'[ \t]*\n[ \t]*');
  static final RegExp _runsOfSpaces = RegExp('[ \\t\\u00a0]{2,}');

  /// Plain text for [raw].
  ///
  /// [html] mirrors the `#html:` header of an Anki text export. When a deck
  /// was exported with HTML stripped, the field can legitimately contain a
  /// bare `<` or `>` (a maths note, a grammar note about brackets), and
  /// running the tag strip over it would silently delete the rest of the
  /// line — so markup removal is skipped and only the inline Anki
  /// conventions are resolved.
  static String clean(String raw, {bool html = true}) {
    var text = raw;

    if (html) {
      text = text
          .replaceAll(_styleOrScript, '')
          .replaceAll(_rubyReading, '')
          .replaceAllMapped(_adjacentBlockBoundary, (_) => '\n')
          .replaceAllMapped(_lineBreakTag, (_) => '\n')
          .replaceAll(_anyTag, '');
    }

    text = text
        .replaceAll(_mediaTag, '')
        .replaceAllMapped(_cloze, (m) => m.group(1) ?? '');

    if (html) text = _decodeEntities(text);

    // After entity decoding: a field can hold `日本語&#91;にほんご&#93;`, and
    // the brackets only look like brackets once they're decoded.
    text = text.replaceAll(_furigana, '');

    return _collapseWhitespace(text);
  }

  /// Splits a raw `notes.flds` value into its fields.
  static List<String> splitFields(String flds, {bool html = true}) {
    return flds.split(fieldSeparator).map((f) => clean(f, html: html)).toList();
  }

  static String _decodeEntities(String text) {
    if (!text.contains('&')) return text;
    return text.replaceAllMapped(_entity, (match) {
      final entity = match.group(0)!;
      final known = _entities[entity.toLowerCase()];
      if (known != null) return known;
      if (entity.startsWith('&#')) {
        final digits = entity.substring(2, entity.length - 1);
        final code = digits.startsWith('x') || digits.startsWith('X')
            ? int.tryParse(digits.substring(1), radix: 16)
            : int.tryParse(digits);
        // Rejects surrogates and out-of-range values, which would throw out of
        // String.fromCharCode rather than merely render oddly.
        if (code != null && code > 0 && code <= 0x10FFFF && !(code >= 0xD800 && code <= 0xDFFF)) {
          return String.fromCharCode(code);
        }
      }
      // An entity nobody recognises is more useful left as written than
      // deleted — it's usually a literal ampersand the exporter didn't escape.
      return entity;
    });
  }

  static String _collapseWhitespace(String text) {
    return text
        .replaceAll('\u00a0', ' ')
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .replaceAll(_runsOfSpaces, ' ')
        .replaceAll(_spacesAroundNewline, '\n')
        .replaceAll(_manyNewlines, '\n\n')
        .trim();
  }
}
