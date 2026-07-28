/// Converts Hepburn-style romaji (e.g. "kuruma", "nihon", "kippu") into
/// hiragana ("くるま", "にほん", "きっぷ") so English-keyboard input can match
/// the kana readings stored in the dictionary — the same behaviour as
/// Shirabe Jisho.
///
/// This is intentionally forgiving: unknown sequences are passed through
/// unchanged, so partial/al-in-progress input still produces a best-effort
/// reading as the user types.
class Romaji {
  // Longest keys first matters, so we check 3-char, then 2-char, then 1-char.
  static const Map<String, String> _map = {
    // youon (contracted sounds) — check these (3 chars) first
    'kya': 'きゃ', 'kyu': 'きゅ', 'kyo': 'きょ',
    'sha': 'しゃ', 'shu': 'しゅ', 'sho': 'しょ',
    'cha': 'ちゃ', 'chu': 'ちゅ', 'cho': 'ちょ',
    'nya': 'にゃ', 'nyu': 'にゅ', 'nyo': 'にょ',
    'hya': 'ひゃ', 'hyu': 'ひゅ', 'hyo': 'ひょ',
    'mya': 'みゃ', 'myu': 'みゅ', 'myo': 'みょ',
    'rya': 'りゃ', 'ryu': 'りゅ', 'ryo': 'りょ',
    'gya': 'ぎゃ', 'gyu': 'ぎゅ', 'gyo': 'ぎょ',
    'ja': 'じゃ', 'ju': 'じゅ', 'jo': 'じょ',
    'jya': 'じゃ', 'jyu': 'じゅ', 'jyo': 'じょ',
    'bya': 'びゃ', 'byu': 'びゅ', 'byo': 'びょ',
    'pya': 'ぴゃ', 'pyu': 'ぴゅ', 'pyo': 'ぴょ',
    'dya': 'ぢゃ', 'dyu': 'ぢゅ', 'dyo': 'ぢょ',
    // special two-char readings
    'shi': 'し', 'chi': 'ち', 'tsu': 'つ', 'fu': 'ふ',
    'shy': 'し', // partial
    // two-char kana
    'ka': 'か', 'ki': 'き', 'ku': 'く', 'ke': 'け', 'ko': 'こ',
    'sa': 'さ', 'si': 'し', 'su': 'す', 'se': 'せ', 'so': 'そ',
    'ta': 'た', 'ti': 'ち', 'tu': 'つ', 'te': 'て', 'to': 'と',
    'na': 'な', 'ni': 'に', 'nu': 'ぬ', 'ne': 'ね', 'no': 'の',
    'ha': 'は', 'hi': 'ひ', 'hu': 'ふ', 'he': 'へ', 'ho': 'ほ',
    'ma': 'ま', 'mi': 'み', 'mu': 'む', 'me': 'め', 'mo': 'も',
    'ya': 'や', 'yu': 'ゆ', 'yo': 'よ',
    'ra': 'ら', 'ri': 'り', 'ru': 'る', 're': 'れ', 'ro': 'ろ',
    'wa': 'わ', 'wo': 'を', 'wi': 'ゐ', 'we': 'ゑ',
    'ga': 'が', 'gi': 'ぎ', 'gu': 'ぐ', 'ge': 'げ', 'go': 'ご',
    'za': 'ざ', 'zi': 'じ', 'zu': 'ず', 'ze': 'ぜ', 'zo': 'ぞ',
    'da': 'だ', 'di': 'ぢ', 'du': 'づ', 'de': 'で', 'do': 'ど',
    'ba': 'ば', 'bi': 'び', 'bu': 'ぶ', 'be': 'べ', 'bo': 'ぼ',
    'pa': 'ぱ', 'pi': 'ぴ', 'pu': 'ぷ', 'pe': 'ぺ', 'po': 'ぽ',
    'ji': 'じ', 'fa': 'ふぁ', 'fi': 'ふぃ', 'fe': 'ふぇ', 'fo': 'ふぉ',
    'va': 'ゔぁ', 'vi': 'ゔぃ', 'vu': 'ゔ', 've': 'ゔぇ', 'vo': 'ゔぉ',
    // single vowels
    'a': 'あ', 'i': 'い', 'u': 'う', 'e': 'え', 'o': 'お',
    'n': 'ん',
  };

  /// Returns true if [input] contains only characters that could be romaji
  /// (ASCII letters and spaces). Used to decide whether kana conversion is
  /// worth attempting.
  static bool looksLikeRomaji(String input) {
    if (input.isEmpty) return false;
    return RegExp(r'^[a-zA-Z\s]+$').hasMatch(input);
  }

  /// Best-effort romaji → hiragana. Returns the converted string, or the
  /// original if nothing could be converted.
  static String toHiragana(String input) {
    final s = input.toLowerCase().trim();
    if (s.isEmpty) return input;

    final buffer = StringBuffer();
    var i = 0;
    while (i < s.length) {
      final ch = s[i];

      // Double consonant -> small tsu (っ), e.g. "kippu" -> きっぷ.
      // A consonant (not 'n') immediately followed by the same consonant.
      if (i + 1 < s.length &&
          ch == s[i + 1] &&
          _isConsonant(ch) &&
          ch != 'n') {
        buffer.write('っ');
        i += 1;
        continue;
      }

      // Syllabic 'n': "n" not followed by a vowel or 'y' becomes ん.
      if (ch == 'n' &&
          (i + 1 >= s.length || !_isVowelOrY(s[i + 1]))) {
        buffer.write('ん');
        i += 1;
        continue;
      }

      // Try 3-, then 2-, then 1-char matches.
      var matched = false;
      for (final len in [3, 2, 1]) {
        if (i + len <= s.length) {
          final chunk = s.substring(i, i + len);
          final kana = _map[chunk];
          if (kana != null) {
            buffer.write(kana);
            i += len;
            matched = true;
            break;
          }
        }
      }

      if (!matched) {
        // Pass through anything we can't convert (spaces, stray letters).
        buffer.write(ch);
        i += 1;
      }
    }

    return buffer.toString();
  }

  static bool _isConsonant(String c) => 'bcdfghjklmnpqrstvwxyz'.contains(c);

  static bool _isVowelOrY(String c) => 'aeiouy'.contains(c);
}
