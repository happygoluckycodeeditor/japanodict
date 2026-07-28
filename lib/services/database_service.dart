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
  static Database? _database;

  factory DatabaseService() {
    return _instance;
  }

  DatabaseService._internal();

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDatabase();
    return _database!;
  }

  // Bump this whenever the bundled asset database changes. The copied copy in
  // app storage is refreshed whenever this version differs from the marker
  // written on the last successful copy, so users never get stuck on a stale
  // database after an update.
  static const int _dbVersion = 5;
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
      try {
        await Directory(dirname(path)).create(recursive: true);
      } catch (_) {}

      // Copy the current database from assets, replacing any stale copy.
      final data = await rootBundle.load(_dbAsset);
      final bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
      await File(path).writeAsBytes(bytes, flush: true);
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

  static const _columns = ['id', 'term', 'reading', 'glosses', 'parts_of_speech', 'tags', 'score', 'is_common', 'jlpt'];
  static const _ftsSelect =
      'd.id, d.term, d.reading, d.glosses, d.parts_of_speech, d.tags, d.score, d.is_common, d.jlpt';

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

  Future<void> close() async {
    final db = await database;
    await db.close();
  }
}
