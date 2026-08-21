import 'package:flutter/foundation.dart';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

/// Persists starred flashcards.
///
/// **This is deliberately a second database, not a table inside
/// `jitendex.db`.** The dictionary is opened `readOnly: true`, and
/// `DatabaseService` deletes and re-copies the whole ~87MB file whenever
/// `_dbVersion` changes — so anything stored in there would be silently wiped
/// by the next dictionary update. Favourites live in their own small file that
/// the copy logic never touches.
///
/// Rows are keyed by [Flashcard.favouriteKey] (`v:<sequence>` / `k:<literal>`),
/// both upstream identifiers that survive a database rebuild.
class FavouritesService extends ChangeNotifier {
  static final FavouritesService _instance = FavouritesService._internal();
  factory FavouritesService() => _instance;
  FavouritesService._internal();

  static const String _dbFile = 'favourites.db';

  Database? _db;
  Future<void>? _loading;

  /// Mirrors the table in memory so the star can be drawn synchronously while
  /// building a card, and toggled without awaiting a write.
  final Set<String> _keys = <String>{};

  Set<String> get keys => Set.unmodifiable(_keys);
  int get count => _keys.length;
  bool isFavourite(String key) => _keys.contains(key);

  /// Opens the store and reads every key into memory. Safe to call repeatedly;
  /// concurrent callers share one in-flight load.
  Future<void> load() => _loading ??= _load();

  Future<void> _load() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      _db = await openDatabase(
        join(dir.path, _dbFile),
        version: 1,
        onCreate: (db, _) => db.execute('''
          CREATE TABLE favourites (
            key TEXT PRIMARY KEY,
            kind TEXT NOT NULL,
            ref TEXT NOT NULL,
            added_at INTEGER NOT NULL
          )
        '''),
      );
      final rows = await _db!.query('favourites', columns: ['key']);
      _keys
        ..clear()
        ..addAll(rows.map((r) => r['key'] as String));
      notifyListeners();
    } catch (e) {
      // A broken favourites file must not take the whole feature down — the
      // decks themselves don't depend on it. Starring just won't stick.
      debugPrint('FavouritesService: load failed: $e');
      _loading = null;
      rethrow;
    }
  }

  /// Adds or removes [key], returning the new state.
  ///
  /// The in-memory set is updated and listeners notified *before* the write, so
  /// the star responds on the same frame as the tap; a failed write rolls it
  /// back rather than leaving the UI lying about what was saved.
  Future<bool> toggle(String key) async {
    final nowFavourite = !_keys.contains(key);
    if (nowFavourite) {
      _keys.add(key);
    } else {
      _keys.remove(key);
    }
    notifyListeners();

    try {
      await load();
      final db = _db;
      if (db == null) return nowFavourite;
      if (nowFavourite) {
        final separator = key.indexOf(':');
        await db.insert(
          'favourites',
          {
            'key': key,
            'kind': key.substring(0, separator),
            'ref': key.substring(separator + 1),
            'added_at': DateTime.now().millisecondsSinceEpoch,
          },
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      } else {
        await db.delete('favourites', where: 'key = ?', whereArgs: [key]);
      }
      // A *second* notify, once the row is actually committed.
      //
      // The one above is what makes the star fill on the tap's own frame, and
      // it fires while the write is still in flight — fine for listeners that
      // read [_keys], wrong for any that re-read the table. `FavouritesScreen`
      // re-resolves its rows from `jitendex.db` via [vocabRefs]/[kanjiRefs],
      // which query *this* database, so with only the optimistic notify it
      // reliably re-read the row it had just deleted and redrew it.
      notifyListeners();
    } catch (e) {
      debugPrint('FavouritesService: toggle failed for $key: $e');
      if (nowFavourite) {
        _keys.remove(key);
      } else {
        _keys.add(key);
      }
      notifyListeners();
    }
    return _keys.contains(key);
  }

  /// Favourited vocabulary, as JMdict sequence numbers, newest star first.
  Future<List<int>> vocabRefs() => _refs('v').then(
        (refs) => refs.map(int.tryParse).whereType<int>().toList(),
      );

  /// Favourited kanji, as literal characters, newest star first.
  Future<List<String>> kanjiRefs() => _refs('k');

  Future<List<String>> _refs(String kind) async {
    await load();
    final db = _db;
    if (db == null) return const [];
    final rows = await db.query(
      'favourites',
      columns: ['ref'],
      where: 'kind = ?',
      whereArgs: [kind],
      orderBy: 'added_at DESC',
    );
    return rows.map((r) => r['ref'] as String).toList();
  }
}
