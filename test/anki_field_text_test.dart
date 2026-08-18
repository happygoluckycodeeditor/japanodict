import 'package:flutter_test/flutter_test.dart';
import 'package:japanodict/utils/anki_field_text.dart';

/// Pins what an Anki note field is allowed to become.
///
/// The stakes are higher than they look. Everything downstream — the word
/// list, the kanji chips, the in-deck search — runs on this output, and the
/// segmenter walks *runs of Japanese characters*: one surviving furigana
/// reading fuses two words into a run no dictionary entry can match, and the
/// card silently comes back with fewer words rather than with a visible error.
void main() {
  group('clean', () {
    test('strips the div soup the Anki editor produces', () {
      expect(
        AnkiFieldText.clean('<div>日本語を勉強します</div>'),
        '日本語を勉強します',
      );
    });

    test('keeps fields on separate lines instead of running them together', () {
      // 今日 and 寒い must not fuse into 今日寒い — a longest-match pass over
      // the join can produce a word that spans the boundary.
      expect(AnkiFieldText.clean('今日<br>寒い'), '今日\n寒い');
      expect(AnkiFieldText.clean('<div>今日</div><div>寒い</div>'), '今日\n寒い');
    });

    test('drops ruby readings, base text and all tags', () {
      expect(
        AnkiFieldText.clean('<ruby>漢字<rt>かんじ</rt></ruby>を書く'),
        '漢字を書く',
      );
    });

    test('drops Anki plain-text furigana but keeps English brackets', () {
      expect(AnkiFieldText.clean('日本語[にほんご]'), '日本語');
      // A gloss field routinely carries bracketed grammar notes, and deleting
      // those would be deleting the meaning the user is reading.
      expect(
        AnkiFieldText.clean('to study [transitive verb]'),
        'to study [transitive verb]',
      );
    });

    test('removes media references', () {
      expect(
        AnkiFieldText.clean('勉強[sound:study_1234.mp3]'),
        '勉強',
      );
    });

    test('unwraps cloze deletions, with and without a hint', () {
      expect(AnkiFieldText.clean('今日は{{c1::寒い}}です'), '今日は寒いです');
      expect(
        AnkiFieldText.clean('今日は{{c1::寒い::adjective}}です'),
        '今日は寒いです',
      );
    });

    test('decodes entities, including numeric ones', () {
      expect(AnkiFieldText.clean('a &amp; b'), 'a & b');
      expect(AnkiFieldText.clean('&#26085;&#26412;'), '日本');
      expect(AnkiFieldText.clean('&#x65E5;'), '日');
    });

    test('leaves an unrecognised entity alone rather than deleting it', () {
      expect(AnkiFieldText.clean('AT&T &notreal; end'), 'AT&T &notreal; end');
    });

    test('collapses the whitespace the editor leaves behind', () {
      expect(
        AnkiFieldText.clean('<div>今日</div><div><br></div><div>寒い</div>'),
        '今日\n\n寒い',
      );
      expect(AnkiFieldText.clean('a&nbsp;&nbsp;b'), 'a b');
    });

    test('html: false leaves angle brackets as written', () {
      // An export with HTML stripped can hold a literal '<'. Running the tag
      // strip over it would swallow the rest of the line.
      expect(
        AnkiFieldText.clean('a < b は正しい', html: false),
        'a < b は正しい',
      );
      // The inline Anki conventions are still resolved in that mode.
      expect(
        AnkiFieldText.clean('勉強[sound:x.mp3]', html: false),
        '勉強',
      );
    });

    test('splitFields cleans every field', () {
      expect(
        AnkiFieldText.splitFields(
          '<div>食べる</div>\x1fto eat<br>to consume',
        ),
        ['食べる', 'to eat\nto consume'],
      );
    });
  });
}
