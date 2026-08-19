import 'package:flutter_test/flutter_test.dart';
import 'package:japanodict/services/database_service.dart';

void main() {
  group('ftsAllWordsQuery', () {
    test('ANDs the words of a multi-word query, last one open-ended', () {
      // Live search means the last word is usually half-typed.
      expect(
        DatabaseService.ftsAllWordsQuery('medical treatment'),
        'medical treatment*',
      );
      expect(DatabaseService.ftsAllWordsQuery('to eat rice'), 'to eat rice*');
    });

    test('is null for a single word — the phrase tiers already cover it', () {
      expect(DatabaseService.ftsAllWordsQuery('treatment'), isNull);
      expect(DatabaseService.ftsAllWordsQuery('  spaced  '), isNull);
      // An unspaced CJK compound is one token here, as it is to unicode61.
      expect(DatabaseService.ftsAllWordsQuery('是正処置'), isNull);
    });

    test('is null when nothing tokenisable is left', () {
      expect(DatabaseService.ftsAllWordsQuery(''), isNull);
      expect(DatabaseService.ftsAllWordsQuery('- ... -'), isNull);
    });

    test('splits on punctuation the way the indexer did', () {
      // unicode61 tokenised "one's" into `one` and `s` when it built the
      // index, so keeping the apostrophe (or deleting it, giving `ones`)
      // would search for a token that is not in there.
      expect(DatabaseService.ftsAllWordsQuery("one's own"), 'one s own*');
      expect(DatabaseService.ftsAllWordsQuery('e-mail address'), 'e mail address*');
    });

    test('strips FTS operators out of the query text', () {
      // A stray quote or caret is a syntax error the user cannot see the
      // cause of, so the characters never reach SQLite.
      expect(DatabaseService.ftsAllWordsQuery('"car" ^stop'), 'car stop*');
      expect(DatabaseService.ftsAllWordsQuery('a:b c*'), 'a b c*');
    });

    test('collapses runs of whitespace', () {
      expect(DatabaseService.ftsAllWordsQuery('happy   event'), 'happy event*');
      expect(DatabaseService.ftsAllWordsQuery('happy\tevent\n'), 'happy event*');
    });
  });
}
