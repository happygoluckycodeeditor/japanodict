import 'package:flutter_test/flutter_test.dart';
import 'package:japanodict/services/anki_import_service.dart';

/// Pins the plain-text import path.
///
/// This is the format users are pointed at whenever a `.apkg` turns out to be
/// in Anki's newer package format, so it is the one that has to keep working;
/// it is also the only half of the importer that can be tested without a
/// device, since the package path needs sqflite's platform channel.
///
/// Every rule here is a guess about somebody else's exporter across a decade
/// of Anki versions — headers only appeared in 2.1.55, so a headerless file is
/// not a corner case, it is what a user's older export literally is.
void main() {
  group('parseTextExport', () {
    test('reads a headerless tab-separated export', () {
      final decks = AnkiImportService.parseTextExport(
        '食べる\tto eat\n飲む\tto drink\n',
        'my-deck',
      );
      expect(decks, hasLength(1));
      expect(decks.first.name, 'my-deck');
      expect(decks.first.notes, hasLength(2));
      expect(decks.first.notes.first.fields, ['食べる', 'to eat']);
    });

    test('honours the separator header', () {
      final decks = AnkiImportService.parseTextExport(
        '#separator:comma\n食べる,to eat\n',
        'my-deck',
      );
      expect(decks.first.notes.first.fields, ['食べる', 'to eat']);
    });

    test('sniffs the separator when no header declares one', () {
      final decks = AnkiImportService.parseTextExport(
        '食べる;to eat;ichidan\n',
        'my-deck',
      );
      expect(decks.first.notes.first.fields, ['食べる', 'to eat', 'ichidan']);
    });

    test('splits notes onto their own decks via the deck column', () {
      final decks = AnkiImportService.parseTextExport(
        '#separator:tab\n'
        '#deck column:1\n'
        'Japanese::N5\t食べる\tto eat\n'
        'Japanese::N4\t紹介\tintroduction\n',
        'ignored',
      );
      expect(decks.map((d) => d.name), ['Japanese::N4', 'Japanese::N5']);
      // The deck column is metadata, not content — it must not survive into
      // the fields, or every card would be headed by its own deck name.
      expect(decks.last.notes.first.fields, ['食べる', 'to eat']);
    });

    test('keeps metadata columns out of the fields and names', () {
      final decks = AnkiImportService.parseTextExport(
        '#separator:tab\n'
        '#columns:guid\tnotetype\tdeck\tExpression\tMeaning\ttags\n'
        '#guid column:1\n'
        '#notetype column:2\n'
        '#deck column:3\n'
        '#tags column:6\n'
        'abc123\tBasic\tCore\t食べる\tto eat\tverb ichidan\n',
        'ignored',
      );
      final note = decks.single.notes.single;
      expect(note.fields, ['食べる', 'to eat']);
      expect(note.fieldNames, ['Expression', 'Meaning']);
      expect(note.tags, 'verb ichidan');
      expect(decks.single.name, 'Core');
    });

    test('keeps a quoted multi-line field as one note', () {
      // Anki quotes any field containing a newline. Splitting on \n naively
      // would turn this single note into two malformed ones — and the second
      // would have no Japanese in it at all.
      final decks = AnkiImportService.parseTextExport(
        '#separator:tab\n'
        '食べる\t"to eat\nto consume"\n'
        '飲む\tto drink\n',
        'my-deck',
      );
      expect(decks.single.notes, hasLength(2));
      expect(decks.single.notes.first.fields[1], 'to eat\nto consume');
    });

    test('unescapes doubled quotes inside a quoted field', () {
      final decks = AnkiImportService.parseTextExport(
        '#separator:tab\n買う\t"to buy (""to purchase"")"\n',
        'my-deck',
      );
      expect(decks.single.notes.single.fields[1], 'to buy ("to purchase")');
    });

    test('strips HTML from fields by default', () {
      final decks = AnkiImportService.parseTextExport(
        '#separator:tab\n<div>食べる</div>\tto eat\n',
        'my-deck',
      );
      expect(decks.single.notes.single.fields.first, '食べる');
    });

    test('leaves markup alone when the export says html:false', () {
      final decks = AnkiImportService.parseTextExport(
        '#separator:tab\n#html:false\na < b\tless than\n',
        'my-deck',
      );
      expect(decks.single.notes.single.fields.first, 'a < b');
    });

    test('skips blank rows rather than storing empty notes', () {
      final decks = AnkiImportService.parseTextExport(
        '#separator:tab\n食べる\tto eat\n\n\t\n飲む\tto drink\n',
        'my-deck',
      );
      expect(decks.single.notes, hasLength(2));
    });

    test('a file with nothing importable in it is an error, not an empty deck',
        () {
      expect(
        () => AnkiImportService.parseTextExport('#separator:tab\n\n', 'd'),
        throwsA(isA<AnkiImportException>()),
      );
    });

    test('a leading BOM does not become part of the first field', () {
      final decks = AnkiImportService.parseTextExport(
        '﻿#separator:tab\n食べる\tto eat\n',
        'my-deck',
      );
      expect(decks.single.notes.single.fields.first, '食べる');
    });

    test('a header-only file is an error, not a crash', () {
      // No trailing newline leaves the body cursor one past the end of the
      // string. This threw RangeError rather than reporting an empty deck.
      expect(
        () => AnkiImportService.parseTextExport('#separator:tab', 'd'),
        throwsA(isA<AnkiImportException>()),
      );
    });

    test('#columns: is split with the separator even if declared before it', () {
      // Anki writes #separator: first, but nothing in the format guarantees
      // it — splitting eagerly gave one column named "Expression,Meaning".
      final decks = AnkiImportService.parseTextExport(
        '#columns:Expression,Meaning\n#separator:comma\n食べる,to eat\n',
        'my-deck',
      );
      expect(decks.single.notes.single.fieldNames, ['Expression', 'Meaning']);
    });

    test('a # inside the body is content, not a header', () {
      // Headers stop at the first line that is not one; a field starting with
      // '#' further down is just a field.
      final decks = AnkiImportService.parseTextExport(
        '#separator:tab\n食べる\tto eat\n#1 word\tthe best word\n',
        'my-deck',
      );
      expect(decks.single.notes, hasLength(2));
      expect(decks.single.notes.last.fields.first, '#1 word');
    });
  });
}
