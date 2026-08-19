/// Character classification for walking OCR'd Japanese text.
///
/// Japanese is unspaced, so the scanner in `text_lookup_service.dart` finds
/// word boundaries by trying progressively shorter substrings. These helpers
/// tell it how far it is allowed to try — a run of kana/kanji is fair game,
/// but punctuation, Latin text and digits end a word for certain and must not
/// be swallowed into a candidate.
library;

class JpText {
  JpText._();

  /// True for characters that can appear inside a Japanese word: kana, CJK
  /// ideographs, the prolonged sound mark ー and the iteration mark 々.
  ///
  /// 々 and ー are included because they are word-internal (人々, コーヒー)
  /// even though neither is a kanji or a kana in its own right — 々 has no
  /// KANJIDIC2 entry, which is why [DatabaseService.extractKanji] excludes it
  /// while this does not.
  static bool isWordChar(int rune) {
    return isKana(rune) ||
        isKanji(rune) ||
        rune == 0x30FC || // ー prolonged sound mark
        rune == 0x3005; //  々 iteration mark
  }

  static bool isKana(int rune) {
    return (rune >= 0x3041 && rune <= 0x309F) || // hiragana
        (rune >= 0x30A0 && rune <= 0x30FF); //     katakana
  }

  static bool isKanji(int rune) {
    return (rune >= 0x4E00 && rune <= 0x9FFF) || // CJK Unified
        (rune >= 0x3400 && rune <= 0x4DBF) || //    Extension A
        (rune >= 0xF900 && rune <= 0xFAFF); //      Compatibility
  }

  /// True for a kana that can only ever *follow* another one, so a word
  /// boundary must never fall immediately before it.
  ///
  /// The small vowel kana (ゃゅょ and friends) are the second half of a
  /// digraph — しょ is one mora written with two code points — and ー only
  /// lengthens the vowel in front of it. No word begins with any of them.
  ///
  /// This is a real constraint on segmentation, not a nicety. Without it the
  /// greedy longest-match in `text_lookup_service.dart` split ぜせいしょち
  /// after ぜせいし, because that is the masu stem of 是正する and one
  /// character longer than ぜせい — leaving ょ orphaned and ち to match 血
  /// "blood". A candidate that ends mid-digraph is not a word, whatever the
  /// dictionary says about it.
  ///
  /// The sokuon っ is deliberately **not** here even though no ordinary word
  /// starts with one either: it is genuinely word-initial in the suffixes the
  /// deinflector strips (ソフトっぽい), so forbidding a boundary before it
  /// would lose matches rather than fix them.
  static bool isTrailingKana(int rune) => _trailingKana.contains(rune);

  static const Set<int> _trailingKana = {
    0x3041, 0x3043, 0x3045, 0x3047, 0x3049, // ぁぃぅぇぉ
    0x3083, 0x3085, 0x3087, 0x308E, //         ゃゅょゎ
    0x30A1, 0x30A3, 0x30A5, 0x30A7, 0x30A9, // ァィゥェォ
    0x30E3, 0x30E5, 0x30E7, 0x30EE, //         ャュョヮ
    0x30F5, 0x30F6, //                         ヵヶ
    0x30FC, //                                 ー
  };

  /// True if [text] holds at least one character worth looking up. Used to
  /// skip OCR lines that came back as pure punctuation or Latin.
  static bool hasJapanese(String text) {
    return text.runes.any(isWordChar);
  }

  /// True if [text] contains at least one CJK ideograph.
  ///
  /// Distinct from [hasJapanese], and the distinction carries weight: a run of
  /// kana with no kanji in it is where greedy longest-match segmentation is
  /// least reliable, because there are no ideographs to anchor a boundary.
  /// `AnkiNote.lookupFields` uses this to tell a card's reading field from its
  /// expression field without knowing what the note type called them.
  static bool hasKanji(String text) {
    return text.runes.any(isKanji);
  }

  /// Index of the first character at or after [start] that can begin a word,
  /// or -1 if the rest of [text] has none.
  ///
  /// Indices are UTF-16 offsets so they can be used directly with
  /// `String.substring`. Every character this returns is in the BMP (kana and
  /// the common kanji blocks all are), so no surrogate pair is ever split;
  /// rarer Extension B kanji simply aren't treated as word characters.
  static int nextWordStart(String text, int start) {
    for (var i = start; i < text.length; i++) {
      if (isWordChar(text.codeUnitAt(i))) return i;
    }
    return -1;
  }

  /// Length of the unbroken run of word characters beginning at [start],
  /// capped at [maxLength].
  ///
  /// The cap keeps a tap on a long unpunctuated line from generating
  /// deinflection candidates for a 40-character substring. 12 comfortably
  /// covers the longest real entries plus a stacked inflection
  /// (お待ちしております is 9).
  static int wordRunLength(String text, int start, {int maxLength = 12}) {
    var length = 0;
    for (var i = start; i < text.length && length < maxLength; i++) {
      if (!isWordChar(text.codeUnitAt(i))) break;
      length++;
    }
    return length;
  }
}
