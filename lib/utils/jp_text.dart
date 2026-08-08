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

  /// True if [text] holds at least one character worth looking up. Used to
  /// skip OCR lines that came back as pure punctuation or Latin.
  static bool hasJapanese(String text) {
    return text.runes.any(isWordChar);
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
