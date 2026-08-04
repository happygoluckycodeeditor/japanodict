import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path_provider/path_provider.dart';
import '../models/dictionary_entry.dart';
import '../utils/romaji.dart';

class DatabaseService {
  static final DatabaseService _instance = DatabaseService._internal();
  static Future<Database>? _databaseFuture;

  /// Channel implemented in MainActivity.kt — see [_copyDatabaseAsset].
  static const MethodChannel _dbChannel = MethodChannel('japanodict/db');

  factory DatabaseService() {
    return _instance;
  }

  DatabaseService._internal();

  /// Memoizes the in-flight future, not just the finished [Database].
  ///
  /// Checking a `Database?` field only helps *after* init completes: two
  /// callers racing before that (HomeScreen's startup prefetch and the first
  /// search are milliseconds apart) would both see null and each start their
  /// own `_initDatabase()`, so the ~80MB copy ran twice against the same
  /// file. Sharing one future means every caller awaits the same init.
  Future<Database> get database {
    return _databaseFuture ??= _initDatabase().catchError((Object e) {
      // Don't poison the singleton with a rejected future — allow a retry.
      _databaseFuture = null;
      throw e;
    });
  }

  // Bump this whenever the bundled asset database changes. The copied copy in
  // app storage is refreshed whenever this version differs from the marker
  // written on the last successful copy, so users never get stuck on a stale
  // database after an update.
  // v6 added the KANJIDIC2 `kanji` table (scripts/build_kanji_db.py).
  // v7 added the KanjiVG `kanji_strokes` table (scripts/build_strokes_db.py).
  static const int _dbVersion = 7;
  static const String _dbAsset = 'assets/databases/jitendex.db';
  static const String _dbFile = 'jitendex.db';

  Future<Database> _initDatabase() async {
    final documentsDirectory = await getApplicationDocumentsDirectory();
    final path = join(documentsDirectory.path, _dbFile);
    final versionFile = File('$path.version');

    final exists = await databaseExists(path);
    final storedVersion = await versionFile.exists()
        ? int.tryParse((await versionFile.readAsString()).trim())
        : null;

    if (!exists || storedVersion != _dbVersion) {
      await _copyDatabaseAsset(path);
      // Written only after the copy succeeds, so a failed or interrupted
      // copy is retried on the next launch rather than being trusted.
      await versionFile.writeAsString('$_dbVersion', flush: true);

      // Remove the previous (much larger) flattened database if it's still
      // sitting in app storage from an earlier version.
      try {
        final legacy = File(join(dirname(path), 'jitendex_flattened.db'));
        if (await legacy.exists()) await legacy.delete();
      } catch (_) {}
    }

    return await openDatabase(path, readOnly: true);
  }

  /// Copies the bundled ~80MB database out of the APK to [path].
  ///
  /// Prefers the native `japanodict/db` channel (MainActivity.kt), which
  /// streams the asset on a background thread so the bytes never enter the
  /// Dart heap. The pure-Dart path below is the fallback for tests and any
  /// platform without that channel — it is the one that caused ANRs on
  /// Android, because `rootBundle.load` materialises the whole asset on the
  /// root isolate. (Moving *that* to a background isolate is not an option:
  /// `flutter/assets` isn't serviced through BackgroundIsolateBinaryMessenger
  /// and the reply arrives null.)
  static Future<void> _copyDatabaseAsset(String path) async {
    final sw = Stopwatch()..start();
    try {
      await _dbChannel.invokeMethod<void>('copyAsset', {
        'assetKey': _dbAsset,
        'destPath': path,
      });
      debugPrint('DatabaseService: native asset copy took ${sw.elapsedMilliseconds}ms');
      return;
    } on MissingPluginException {
      debugPrint('DatabaseService: no native copy channel, falling back to rootBundle');
    }

    try {
      await Directory(dirname(path)).create(recursive: true);
    } catch (_) {}
    final data = await rootBundle.load(_dbAsset);
    final bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    await File(path).writeAsBytes(bytes, flush: true);
    debugPrint('DatabaseService: Dart asset copy took ${sw.elapsedMilliseconds}ms');
  }

  static const _columns = ['id', 'term', 'reading', 'glosses', 'parts_of_speech', 'tags', 'score', 'is_common', 'jlpt', 'sequence'];
  static const _ftsSelect =
      'd.id, d.term, d.reading, d.glosses, d.parts_of_speech, d.tags, d.score, d.is_common, d.jlpt, d.sequence';

  Future<List<DictionaryEntry>> searchEntries(String query, {int limit = 50}) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return [];

    final db = await database;
    final seenIds = <int>{};
    final results = <DictionaryEntry>[];

    void addAll(List<Map<String, Object?>> rows) {
      for (final row in rows) {
        if (seenIds.add(row['id'] as int)) {
          results.add(DictionaryEntry.fromMap(row));
        }
      }
    }

    // Latin input like "kuruma" is also converted to kana ("くるま") so it can
    // match the readings stored in the dictionary — the way Shirabe Jisho does.
    // The English text is still searched too (so "car" keeps working).
    final kana = Romaji.looksLikeRomaji(trimmed) ? Romaji.toHiragana(trimmed) : null;
    final termTargets = <String>{trimmed, if (kana != null && kana != trimmed) kana};

    // Common words (Jisho's "common word" flag) are floated to the top of
    // every tier so the everyday word lands first.
    // Tier 0: exact term/reading match (e.g. typing 猫, ねこ, or "kuruma"→くるま).
    for (final target in termTargets) {
      addAll(await db.query(
        'dictionary',
        columns: _columns,
        where: 'term = ? OR reading = ?',
        whereArgs: [target, target],
        orderBy: 'is_common DESC, score DESC',
      ));
    }

    // Tier 1: term/reading prefix match, for live search as the user types.
    for (final target in termTargets) {
      if (results.length >= limit) break;
      addAll(await db.query(
        'dictionary',
        columns: _columns,
        where: 'term LIKE ? OR reading LIKE ?',
        whereArgs: ['$target%', '$target%'],
        orderBy: 'is_common DESC, score DESC, length(term) ASC',
        limit: limit - results.length,
      ));
    }

    // Tier 2/3: full-text search over definitions. Whole-word matches (e.g.
    // searching "car" hits the definition word "car") rank above mere
    // prefix matches (e.g. "card", "careful") so real hits like 車 surface
    // first instead of being buried among unrelated entries.
    //
    // Within whole-word matches, entries whose definition *starts* with the
    // query (e.g. 竜 = "dragon (esp...)") rank above entries that merely
    // mention it (e.g. 辰 = "the Dragon (fifth sign...)"), so the obvious word
    // lands first — the way Shirabe Jisho orders results.
    final ftsQuery = trimmed.replaceAll('"', '');
    if (results.length < limit && ftsQuery.isNotEmpty) {
      try {
        addAll(await db.rawQuery('''
          SELECT $_ftsSelect
          FROM dictionary_fts fts
          JOIN dictionary d ON d.id = fts.docid
          WHERE dictionary_fts MATCH ?
          ORDER BY d.is_common DESC, d.score DESC,
            (CASE WHEN d.glosses LIKE ? OR d.glosses LIKE ? THEN 0 ELSE 1 END),
            length(d.term) ASC
          LIMIT ?
        ''', ['"$ftsQuery"', '$ftsQuery%', '% • $ftsQuery%', limit - results.length]));
      } catch (e) {
        debugPrint('FTS exact-word search failed: $e');
      }
    }

    if (results.length < limit && ftsQuery.isNotEmpty) {
      try {
        addAll(await db.rawQuery('''
          SELECT $_ftsSelect
          FROM dictionary_fts fts
          JOIN dictionary d ON d.id = fts.docid
          WHERE dictionary_fts MATCH ?
          ORDER BY d.is_common DESC, d.score DESC, length(d.term) ASC
          LIMIT ?
        ''', ['$ftsQuery*', limit - results.length]));
      } catch (e) {
        debugPrint('FTS prefix search failed: $e');
      }
    }

    // Last resort if FTS is unavailable: plain substring search.
    if (results.isEmpty) {
      addAll(await db.query(
        'dictionary',
        columns: _columns,
        where: 'glosses LIKE ?',
        whereArgs: ['%$trimmed%'],
        orderBy: 'is_common DESC, score DESC, length(term) ASC',
        limit: limit,
      ));
    }

    return results;
  }

  Future<DictionaryEntry?> getEntryById(int id) async {
    final db = await database;
    final results = await db.query(
      'dictionary',
      where: 'id = ?',
      whereArgs: [id],
    );

    if (results.isEmpty) return null;
    return DictionaryEntry.fromMap(results.first);
  }

  /// Example sentences (Japanese + English) for an entry, loaded on demand
  /// for the detail view so they never weigh down search.
  Future<List<ExampleSentence>> getExamples(int entryId, {int limit = 5}) async {
    final db = await database;
    final rows = await db.query(
      'examples',
      columns: ['ja', 'en'],
      where: 'entry_id = ?',
      whereArgs: [entryId],
      limit: limit,
    );
    return rows.map((r) => ExampleSentence(
          ja: r['ja'] as String? ?? '',
          en: r['en'] as String? ?? '',
        )).toList();
  }

  /// Returns the KANJIDIC2 entry for each distinct kanji in [term], in the
  /// order the characters appear.
  ///
  /// Kana, punctuation and Latin characters are skipped, so a term like
  /// 見せる yields only 見, and a purely-kana term yields an empty list.
  /// Characters with no KANJIDIC2 row (readings-only JIS X 0212 entries were
  /// dropped at import time) are simply absent from the result.
  Future<List<KanjiEntry>> getKanjiForTerm(String term) async {
    final literals = extractKanji(term);
    if (literals.isEmpty) return const [];

    final db = await database;
    final placeholders = List.filled(literals.length, '?').join(',');
    final rows = await db.query(
      'kanji',
      where: 'literal IN ($placeholders)',
      whereArgs: literals,
    );

    // SQL gives no ordering guarantee for an IN clause, so re-order to match
    // the term. Reading 竜虎 as 虎竜 would be actively confusing.
    final byLiteral = {
      for (final row in rows) row['literal'] as String: KanjiEntry.fromMap(row),
    };
    return literals
        .map((l) => byLiteral[l])
        .whereType<KanjiEntry>()
        .toList();
  }

  /// Stroke-order outlines for [literal], or null if KanjiVG has no entry.
  ///
  /// KanjiVG covers ~6,700 characters against KANJIDIC2's ~10,400, so a
  /// missing row is normal for rarer kanji — callers must handle null rather
  /// than treating it as an error.
  Future<KanjiStrokes?> getStrokesFor(String literal) async {
    final db = await database;
    final rows = await db.query(
      'kanji_strokes',
      columns: ['literal', 'paths'],
      where: 'literal = ?',
      whereArgs: [literal],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return KanjiStrokes.fromMap(rows.first);
  }

  // ---------------------------------------------------------------------
  // Flashcard decks
  // ---------------------------------------------------------------------

  /// `MAX(score)` picks *which* spelling of a word becomes the card.
  ///
  /// This leans on SQLite's documented bare-column rule: in a query with a
  /// single `MAX()`, the non-aggregated columns come from the row that
  /// produced the maximum. Since a word's spellings are separate rows sharing
  /// one `sequence`, grouping without this would hand back an arbitrary one —
  /// a ばね card could show 撥条, and a 車 card 俥. Score ranks the canonical
  /// form highest (ばね 200 vs 発条 -101), so this picks the spelling a learner
  /// should actually recognise.
  static const String _deckSelect =
      'id, term, reading, glosses, parts_of_speech, tags, score, is_common, jlpt, sequence, MAX(score)';

  /// One card per word for a JLPT level (`N5`…`N1`), common words first.
  ///
  /// Deduplicated by `sequence`, which matters more than it looks: N1 alone is
  /// 4,882 rows but only 3,229 distinct words, so skipping this would pad the
  /// deck with hundreds of rare alternate spellings of words already in it.
  Future<List<DictionaryEntry>> getVocabDeck(String jlpt) async {
    final db = await database;
    final rows = await db.rawQuery('''
      SELECT $_deckSelect
      FROM dictionary
      WHERE jlpt = ?
      GROUP BY sequence
      ORDER BY is_common DESC, score DESC, term ASC
    ''', [jlpt]);
    return rows.map(DictionaryEntry.fromMap).toList();
  }

  /// One card per character for a KANJIDIC2 school grade.
  ///
  /// [grade] 1–6 are the kyōiku years and 8 is the rest of jōyō; passing 9
  /// returns both jinmeiyō sets (9 and 10 together), since that split is about
  /// which name-use list a character came from, not difficulty.
  ///
  /// Ordered by newspaper frequency so the characters worth knowing first come
  /// first; unranked characters sort last rather than being treated as rank 0.
  Future<List<KanjiEntry>> getKanjiDeck(int grade) async {
    final db = await database;
    final rows = await db.query(
      'kanji',
      where: grade == 9 ? 'grade IN (9, 10)' : 'grade = ?',
      whereArgs: grade == 9 ? null : [grade],
      orderBy: 'freq IS NULL, freq ASC, stroke_count ASC, literal ASC',
    );
    return rows.map(KanjiEntry.fromMap).toList();
  }

  /// Card counts for every deck, keyed by `Deck.id` (`N5`, `grade:1`, …).
  ///
  /// Two aggregate queries rather than one count per deck, so the picker isn't
  /// firing thirteen round trips at the database on open.
  Future<Map<String, int>> getDeckCounts() async {
    final db = await database;
    final counts = <String, int>{};

    final vocab = await db.rawQuery('''
      SELECT jlpt, COUNT(*) AS n FROM (
        SELECT jlpt FROM dictionary WHERE jlpt IS NOT NULL GROUP BY sequence
      ) GROUP BY jlpt
    ''');
    for (final row in vocab) {
      counts[row['jlpt'] as String] = row['n'] as int;
    }

    final kanji = await db.rawQuery('''
      SELECT grade, COUNT(*) AS n FROM kanji WHERE grade IS NOT NULL GROUP BY grade
    ''');
    for (final row in kanji) {
      final grade = row['grade'] as int;
      // 9 and 10 share the "Jinmeiyō" deck, so their counts add up.
      final key = grade == 10 ? 'grade:9' : 'grade:$grade';
      counts[key] = (counts[key] ?? 0) + (row['n'] as int);
    }

    return counts;
  }

  /// Rebuilds favourited vocabulary cards from stored JMdict [sequences].
  ///
  /// Returned in the order given (favourites are stored newest-first), because
  /// an `IN` clause has no ordering guarantee. Sequences with no surviving row
  /// — possible if a rebuild dropped an entry — are skipped rather than
  /// producing a blank card.
  Future<List<DictionaryEntry>> getEntriesBySequence(List<int> sequences) async {
    if (sequences.isEmpty) return const [];
    final db = await database;
    final placeholders = List.filled(sequences.length, '?').join(',');
    final rows = await db.rawQuery('''
      SELECT $_deckSelect
      FROM dictionary
      WHERE sequence IN ($placeholders)
      GROUP BY sequence
    ''', sequences);

    final bySequence = {
      for (final row in rows) row['sequence'] as int: DictionaryEntry.fromMap(row),
    };
    return sequences
        .map((s) => bySequence[s])
        .whereType<DictionaryEntry>()
        .toList();
  }

  /// Rebuilds favourited kanji cards from stored [literals], preserving order.
  Future<List<KanjiEntry>> getKanjiByLiterals(List<String> literals) async {
    if (literals.isEmpty) return const [];
    final db = await database;
    final placeholders = List.filled(literals.length, '?').join(',');
    final rows = await db.query(
      'kanji',
      where: 'literal IN ($placeholders)',
      whereArgs: literals,
    );
    final byLiteral = {
      for (final row in rows) row['literal'] as String: KanjiEntry.fromMap(row),
    };
    return literals
        .map((l) => byLiteral[l])
        .whereType<KanjiEntry>()
        .toList();
  }

  /// Distinct CJK ideographs in [text], in order of first appearance.
  ///
  /// Covers the CJK Unified Ideographs block plus Extension A and the
  /// compatibility block; deliberately excludes kana and the iteration mark 々
  /// (which has no KANJIDIC2 entry of its own).
  static List<String> extractKanji(String text) {
    final seen = <String>{};
    final out = <String>[];
    for (final rune in text.runes) {
      final isKanji = (rune >= 0x4E00 && rune <= 0x9FFF) ||
          (rune >= 0x3400 && rune <= 0x4DBF) ||
          (rune >= 0xF900 && rune <= 0xFAFF);
      if (!isKanji) continue;
      final char = String.fromCharCode(rune);
      if (seen.add(char)) out.add(char);
    }
    return out;
  }

  Future<void> close() async {
    final db = await database;
    await db.close();
  }
}
