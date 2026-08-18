import 'package:flutter_test/flutter_test.dart';
import 'package:japanodict/models/anki_note.dart';

AnkiNote _note(List<String> fields, {List<String> names = const []}) {
  return AnkiNote(
    id: 1,
    deckId: 1,
    fields: fields,
    fieldNames: names,
    tags: '',
  );
}

void main() {
  group('lookupFields', () {
    test('drops the reading field when another field carries kanji', () {
      // The observed failure: mining きのうはさむかったです alongside the
      // expression made the card offer 機能 "function" and はさむ "to hold
      // between chopsticks" for a sentence about cold weather.
      final note = _note([
        '昨日は寒かったです。',
        'It was cold yesterday.',
        'きのうはさむかったです',
      ]);
      expect(note.lookupFields.map((f) => f.key), [0]);
    });

    test('keeps everything when no field has kanji', () {
      // A beginner deck written entirely in kana must still yield its words —
      // there is no kanji field standing in for them.
      final note = _note(['たべる', 'to eat']);
      expect(note.lookupFields.map((f) => f.value), ['たべる']);
    });

    test('keeps every kanji-bearing field', () {
      final note = _note(['勉強', 'to study', '毎日勉強しています']);
      expect(note.lookupFields.map((f) => f.key), [0, 2]);
    });

    test('ignores fields with no Japanese at all', () {
      final note = _note(['食べる', 'to eat', 'ichidan verb']);
      expect(note.lookupFields.map((f) => f.key), [0]);
    });

    test('a skipped reading field is still shown on the card', () {
      // lookupFields governs the word list only. Every Japanese field stays in
      // japaneseFields, which is what keeps it rendered and tappable — that is
      // the escape hatch that makes dropping it acceptable.
      final note = _note(['昨日は寒かった', 'cold', 'きのうはさむかった']);
      expect(note.japaneseFields.map((f) => f.key), [0, 2]);
      expect(note.lookupFields.map((f) => f.key), [0]);
    });
  });

  group('heading', () {
    test('picks the first Japanese field, not the first field', () {
      // Plenty of note types lead with an id or the English side; a list of
      // English headings makes a Japanese deck unrecognisable at a glance.
      final note = _note(['12345', 'to eat', '食べる']);
      expect(note.heading, '食べる');
    });

    test('falls back to the first non-empty field when there is no Japanese',
        () {
      expect(_note(['', 'to eat']).heading, 'to eat');
    });
  });

  group('labelFor', () {
    test('uses the note type name when there is one', () {
      final note = _note(['食べる'], names: ['Expression']);
      expect(note.labelFor(0), 'Expression');
    });

    test('falls back to a position when the export carried no names', () {
      expect(_note(['食べる']).labelFor(0), 'Field 1');
    });
  });
}
