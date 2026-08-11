import 'package:flutter/foundation.dart';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

/// Persists recent search queries for the home screen's "Recent" list.
///
/// **A third database file, and deliberately so.** It cannot live in
/// `jitendex.db` — that file is opened `readOnly: true` and is deleted and
/// re-copied on every `DatabaseService._dbVersion` bump, so the table would be
/// silently wiped by a dictionary update. It is kept out of `favourites.db`
/// too, so that "clear history" and a corrupt-history recovery can never put
/// starred cards at risk; the two features have no reason to share a file.
///
/// Rows are the raw query text the user typed ("kuruma", "dragon", 勉強), not
/// entry ids, so replaying one just refills the search field and re-runs the
/// normal debounced search path.
class HistoryService extends ChangeNotifier {
  static final HistoryService _instance = HistoryService._internal();
  factory HistoryService() => _instance;
  HistoryService._internal();

  static const String _dbFile = 'history.db';

  /// How many queries are kept. Anything past this is trimmed oldest-first on
  /// every write, so the table can't grow without bound.
  static const int maxEntries = 30;

  Database? _db;
  Future<void>? _loading;

  /// Mirrors the table in memory, newest first, so the list can be built
  /// synchronously and a tap can reorder it without awaiting a write.
  final List<String> _entries = <String>[];

  List<String> get entries => List.unmodifiable(_entries);
  bool get isEmpty => _entries.isEmpty;

  /// Opens the store and reads it into memory. Safe to call repeatedly;
  /// concurrent callers share one in-flight load.
  Future<void> load() => _loading ??= _load();

  Future<void> _load() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      _db = await openDatabase(
        join(dir.path, _dbFile),
        version: 1,
        onCreate: (db, _) => db.execute('''
          CREATE TABLE searches (
            query TEXT PRIMARY KEY,
            searched_at INTEGER NOT NULL
          )
        '''),
      );
      final rows = await _db!.query(
        'searches',
        columns: ['query'],
        orderBy: 'searched_at DESC',
        limit: maxEntries,
      );
      _entries
        ..clear()
        ..addAll(rows.map((r) => r['query'] as String));
      notifyListeners();
    } catch (e) {
      // History is a convenience; a broken file must not take searching down
      // with it. Recent queries simply won't stick this session.
      debugPrint('HistoryService: load failed: $e');
      _loading = null;
      rethrow;
    }
  }

  /// Records [query] as the most recent search.
  ///
  /// Live search means the caller sees the query grow a character at a time, so
  /// this collapses **prefix runs**: if the newest entry and [query] are a
  /// prefix of one another, the shorter is dropped and only the longer is kept.
  /// Typing `k → ku → kuruma` therefore leaves one row, not three, and
  /// backspacing from `kuruma` to `kurum` doesn't downgrade what was stored.
  Future<void> record(String query) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return;

    final text = trimmed;

    // Set when this query extends the one above it, so the shorter row can be
    // dropped from the table after the longer one lands.
    String? superseded;
    if (_entries.isNotEmpty) {
      final newest = _entries.first;
      if (newest == text) {
        // Already at the top; nothing to reorder and nothing to write.
        return;
      }
      if (newest.startsWith(text)) {
        // Backspaced into a prefix of what is already stored. The longer
        // string is the better record of the search — leave the row as is.
        return;
      }
      if (text.startsWith(newest)) {
        superseded = newest;
        _entries.removeAt(0);
      }
    }

    _entries
      ..remove(text)
      ..insert(0, text);
    final overflow = <String>[if (superseded != null) superseded];
    while (_entries.length > maxEntries) {
      overflow.add(_entries.removeLast());
    }
    notifyListeners();

    try {
      await load();
      final db = _db;
      if (db == null) return;
      await db.insert(
        'searches',
        {'query': text, 'searched_at': DateTime.now().millisecondsSinceEpoch},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      for (final old in overflow) {
        await db.delete('searches', where: 'query = ?', whereArgs: [old]);
      }
    } catch (e) {
      debugPrint('HistoryService: record failed for $text: $e');
    }
  }

  /// Removes a single query — the ✕ on a history row.
  Future<void> remove(String query) async {
    if (!_entries.remove(query)) return;
    notifyListeners();
    await _delete(query);
  }

  /// Empties the list — "Clear all".
  Future<void> clear() async {
    if (_entries.isEmpty) return;
    _entries.clear();
    notifyListeners();
    try {
      await load();
      await _db?.delete('searches');
    } catch (e) {
      debugPrint('HistoryService: clear failed: $e');
    }
  }

  Future<void> _delete(String query) async {
    try {
      await load();
      await _db?.delete('searches', where: 'query = ?', whereArgs: [query]);
    } catch (e) {
      debugPrint('HistoryService: delete failed for $query: $e');
    }
  }
}
