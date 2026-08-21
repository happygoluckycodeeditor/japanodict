import 'package:flutter_test/flutter_test.dart';
import 'package:japanodict/models/dictionary_entry.dart';

/// Row shapes as `scripts/build_names_db.py` writes them, so these pin the
/// contract between the importer and the model rather than the model alone.
NameEntry _row({
  required String term,
  String? reading,
  required String glosses,
  String? nameType,
  int priority = 0,
  int sequence = 5000000,
}) {
  return NameEntry.fromMap({
    'id': 1,
    'sequence': sequence,
    'term': term,
    'reading': reading,
    'name_type': nameType,
    'priority': priority,
    'glosses': glosses,
  });
}

void main() {
  group('NameEntry.displayReading', () {
    test('is null for a kana-only name, which is stored as its own reading', () {
      // The importer keeps `reading` populated for kana headwords so the
      // reading index and the FTS both match them. Rendering it verbatim
      // would print ゴジラ【ゴジラ】.
      final godzilla = _row(term: 'ゴジラ', reading: 'ゴジラ', glosses: 'Godzilla');
      expect(godzilla.displayReading, isNull);
    });

    test('is the reading when it says something the term does not', () {
      final nintendo = _row(
        term: '任天堂',
        reading: 'にんてんどう',
        glosses: 'Nintendo',
      );
      expect(nintendo.displayReading, 'にんてんどう');
    });

    test('is null when the importer wrote no reading at all', () {
      expect(_row(term: 'Ｗｉｉ', glosses: 'Wii').displayReading, isNull);
      expect(_row(term: 'Ｗｉｉ', reading: '', glosses: 'Wii').displayReading,
          isNull);
    });
  });

  group('NameEntry.typeLabel', () {
    test('spells out a JMnedict tag', () {
      expect(_row(term: '任天堂', glosses: 'Nintendo', nameType: 'company')
          .typeLabel, 'Company');
      expect(_row(term: 'ゴジラ', glosses: 'Godzilla', nameType: 'char')
          .typeLabel, 'Character');
      expect(_row(term: '東京駅', glosses: 'Tokyo Station', nameType: 'station')
          .typeLabel, 'Station');
    });

    test('shows only the first of several tags', () {
      // An entry can carry more than one — ゴジラ is a `char` and the films
      // are a `work`. Rendering all of them pushes the name off the row.
      final multi = _row(
        term: 'ゴジラ',
        glosses: 'Godzilla',
        nameType: 'char,work',
      );
      expect(multi.typeLabel, 'Character');
    });

    test('falls back to the raw tag rather than dropping it', () {
      // A future JMnedict release can add a type. Showing the unknown tag is
      // better than showing nothing, and it is the tell that the map needs
      // extending.
      expect(_row(term: 'x', glosses: 'y', nameType: 'newtype').typeLabel,
          'newtype');
    });

    test('is null when there is no tag', () {
      expect(_row(term: 'x', glosses: 'y').typeLabel, isNull);
      expect(_row(term: 'x', glosses: 'y', nameType: '').typeLabel, isNull);
    });
  });

  group('NameEntry.glossList', () {
    test('splits senses on the bullet the importer joins them with', () {
      // Same convention as DictionaryEntry: '; ' within a sense, ' • ' between.
      final entry = _row(
        term: 'ドラゴンクエスト',
        glosses: 'Dragon Quest (video game); Dragon Warrior • something else',
      );
      expect(entry.glossList, [
        'Dragon Quest (video game); Dragon Warrior',
        'something else',
      ]);
    });

    test('is a single item for the common one-sense case', () {
      expect(_row(term: '任天堂', glosses: 'Nintendo').glossList, ['Nintendo']);
    });
  });
}
