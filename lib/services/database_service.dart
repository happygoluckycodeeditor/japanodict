import 'dart:io';
import 'package:flutter/services.dart';
import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path_provider/path_provider.dart';
import '../models/dictionary_entry.dart';

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

  Future<Database> _initDatabase() async {
    final documentsDirectory = await getApplicationDocumentsDirectory();
    final path = join(documentsDirectory.path, 'jitendex_flattened.db');

    // Check if the database exists
    final exists = await databaseExists(path);

    if (!exists) {
      // Copy from assets
      try {
        await Directory(dirname(path)).create(recursive: true);
      } catch (_) {}

      // Load database from asset
      ByteData data = await rootBundle.load('assets/databases/jitendex_flattened.db');
      List<int> bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);

      // Write to file
      await File(path).writeAsBytes(bytes, flush: true);
    }

    // Open the database
    return await openDatabase(path, readOnly: true);
  }

  Future<List<DictionaryEntry>> searchEntries(String query, {int limit = 50}) async {
    if (query.isEmpty) return [];

    final db = await database;

    try {
      // Use FTS4 for better search results (FTS4 is available on Android)
      // The MATCH operator supports prefix search with *
      final results = await db.rawQuery('''
        SELECT d.id, d.term, d.reading, d.glosses, d.parts_of_speech, d.tags, d.score
        FROM dictionary_fts fts
        JOIN dictionary d ON d.id = fts.docid
        WHERE dictionary_fts MATCH ?
        ORDER BY d.score DESC, length(d.term) ASC
        LIMIT ?
      ''', ['$query*', limit]);

      if (results.isNotEmpty) {
        return results.map((map) => DictionaryEntry.fromMap(map)).toList();
      }
    } catch (e) {
      // FTS search failed, fall through to LIKE search
      print('FTS search failed: $e');
    }

    // Fallback to LIKE search
    // Use multiple queries for better results
    final exactResults = await db.query(
      'dictionary',
      where: 'term = ? OR reading = ?',
      whereArgs: [query, query],
      orderBy: 'score DESC',
      limit: limit ~/ 2,
    );

    final partialResults = await db.query(
      'dictionary',
      where: '(term LIKE ? OR reading LIKE ? OR glosses LIKE ?) AND term != ? AND reading != ?',
      whereArgs: ['%$query%', '%$query%', '%$query%', query, query],
      orderBy: 'score DESC, length(term) ASC',
      limit: limit - exactResults.length,
    );

    final allResults = [...exactResults, ...partialResults];
    return allResults.map((map) => DictionaryEntry.fromMap(map)).toList();
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

  Future<void> close() async {
    final db = await database;
    await db.close();
  }
}
