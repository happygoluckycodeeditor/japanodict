import 'package:flutter_test/flutter_test.dart';
import 'package:japanodict/utils/jp_text.dart';

void main() {
  group('isWordChar', () {
    test('accepts kana and kanji', () {
      for (final c in ['あ', 'ン', 'ゃ', '日', '々', 'ー']) {
        expect(JpText.isWordChar(c.codeUnitAt(0)), isTrue, reason: c);
      }
    });

    test('rejects anything that ends a word', () {
      // Japanese punctuation, ASCII and full-width digits all mean the word
      // stopped — swallowing them would build candidates like 「寒い。」.
      for (final c in ['。', '、', '「', '　', ' ', 'a', '5', '５', '！']) {
        expect(JpText.isWordChar(c.codeUnitAt(0)), isFalse, reason: c);
      }
    });
  });

  test('hasJapanese screens out non-Japanese OCR lines', () {
    expect(JpText.hasJapanese('東京'), isTrue);
    expect(JpText.hasJapanese('EXIT 2F'), isFalse);
    expect(JpText.hasJapanese('2F 出口'), isTrue);
    expect(JpText.hasJapanese(''), isFalse);
  });

  group('nextWordStart', () {
    test('skips leading punctuation and Latin', () {
      expect(JpText.nextWordStart('「寒い」', 0), 1);
      expect(JpText.nextWordStart('JR 新宿駅', 0), 3);
    });

    test('returns -1 when nothing is left', () {
      expect(JpText.nextWordStart('寒い。', 3), -1);
      expect(JpText.nextWordStart('ABC', 0), -1);
    });
  });

  group('wordRunLength', () {
    test('stops at the first non-word character', () {
      expect(JpText.wordRunLength('寒いですね。あつい', 0), 5);
      expect(JpText.wordRunLength('東京駅', 0), 3);
    });

    test('is capped so one tap cannot scan a whole line', () {
      final long = '本' * 40;
      expect(JpText.wordRunLength(long, 0), 12);
      expect(JpText.wordRunLength(long, 0, maxLength: 4), 4);
    });

    test('is zero when the position is not a word character', () {
      expect(JpText.wordRunLength('。寒い', 0), 0);
    });
  });

  group('isTrailingKana', () {
    test('accepts the kana that can only follow another', () {
      // Small vowels are the second half of a digraph and ー only lengthens
      // what precedes it, so a word boundary can never fall before one.
      for (final c in ['ゃ', 'ゅ', 'ょ', 'ぁ', 'ぅ', 'ャ', 'ョ', 'ヶ', 'ー']) {
        expect(JpText.isTrailingKana(c.codeUnitAt(0)), isTrue, reason: c);
      }
    });

    test('rejects full-size kana, kanji and the sokuon', () {
      // っ is excluded on purpose: it really does start the suffixes the
      // deinflector strips (ソフトっぽい).
      for (final c in ['あ', 'し', 'ヤ', 'ン', 'っ', 'ッ', '日', 'a']) {
        expect(JpText.isTrailingKana(c.codeUnitAt(0)), isFalse, reason: c);
      }
    });
  });
}
