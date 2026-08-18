import 'package:flutter/foundation.dart';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../models/anki_note.dart';
import '../utils/anki_field_text.dart';
import 'anki_import_service.dart';

/// Stores the decks the user has imported from Anki.
///
/// **A fourth database file**, for the same reason `favourites.db` and
/// `history.db` are their own: `jitendex.db` is opened `readOnly: true` and is
/// deleted and re-copied whenever `DatabaseService._dbVersion` changes, so
/// anything of the user's kept inside it is wiped by the next dictionary
/// update. An imported deck is user data that cannot be regenerated — the
/// source file may be long gone off the phone — which makes it the *least*
/// acceptable thing to lose that way.
///
/// It is kept out of `favourites.db` as well: deleting a deck is a routine,
/// bulk, user-initiated operation, and starred cards should never be within
/// reach of it.
///
/// Only text is stored. Fields land already cleaned by [AnkiFieldText], so
/// browsing a deck costs one query and no parsing; re-importing is the way to
/// pick up an improved cleaner, which is cheap and is what a user would do
/// anyway when their deck changes.
class AnkiLibraryService extends ChangeNotifier {
  static final AnkiLibraryService _instance = AnkiLibraryService._internal();
  factory AnkiLibraryService() => _instance;
  AnkiLibraryService._internal();

  static const String _dbFile = 'anki.db';

  /// Notes inserted per transaction while saving. Keeps a 20,000-note deck
  /// from being one enormous statement batch, and gives the import screen
  /// something to report between chunks.
  static const int _writeChunkSize = 500;

  Future<Database>? _opening;

  Future<Database> _open() => _opening ??= _openDatabase().catchError((Object e) {
        // Don't poison the singleton with a rejected future — a failed open
        // (no storage, corrupt file) should be retryable next time.
        _opening = null;
        throw e;
      });

  Future<Database> _openDatabase() async {
    final directory = await getApplicationDocumentsDirectory();
    final db = await openDatabase(
      join(directory.path, _dbFile),
      version: 1,
      onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
      onCreate: (db, _) async {
        await db.execute('''
          CREATE TABLE decks (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            source TEXT NOT NULL,
            imported_at INTEGER NOT NULL,
            note_count INTEGER NOT NULL
          )
        ''');
        await db.execute('''
          CREATE TABLE notes (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            deck_id INTEGER NOT NULL REFERENCES decks(id) ON DELETE CASCADE,
            position INTEGER NOT NULL,
            fields TEXT NOT NULL,
            field_names TEXT,
            tags TEXT,
            search_text TEXT NOT NULL
          )
        ''');
        // Covers both the browse query (deck, in order) and the count.
        await db.execute(
          'CREATE INDEX idx_notes_deck ON notes(deck_id, position)',
        );
      },
    );
    return db;
  }

  /// Every imported deck, newest import first.
  ///
  /// Throws rather than returning an empty list on failure, unlike the read
  /// paths below. An empty list is a *meaningful* answer here — it renders as
  /// the "no decks yet" onboarding — so swallowing a failed open would tell a
  /// user with five imported decks that their decks are gone. The screen shows
  /// an error with a retry instead.
  Future<List<AnkiDeck>> decks() async {
    final db = await _open();
    final rows = await db.query('decks', orderBy: 'imported_at DESC, id DESC');
    return rows.map(_deckFromRow).toList();
  }

  /// Writes [deck] and returns the stored row.
  ///
  /// Duplicate names are allowed on purpose: importing the same deck twice
  /// makes a second, separate copy the user can compare and delete, rather
  /// than a merge whose result nobody asked for.
  Future<AnkiDeck> saveDeck(
    ImportedDeck deck, {
    required String source,
    void Function(String status)? onProgress,
  }) async {
    final db = await _open();
    final importedAt = DateTime.now();

    final deckId = await db.insert('decks', {
      'name': deck.name,
      'source': source,
      'imported_at': importedAt.millisecondsSinceEpoch,
      'note_count': deck.notes.length,
    });

    var written = 0;
    for (var offset = 0; offset < deck.notes.length; offset += _writeChunkSize) {
      final end = (offset + _writeChunkSize).clamp(0, deck.notes.length);
      await db.transaction((txn) async {
        final batch = txn.batch();
        for (var i = offset; i < end; i++) {
          final note = deck.notes[i];
          batch.insert('notes', {
            'deck_id': deckId,
            'position': i,
            'fields': note.fields.join(AnkiFieldText.fieldSeparator),
            'field_names': note.fieldNames.isEmpty
                ? null
                : note.fieldNames.join(AnkiFieldText.fieldSeparator),
            'tags': note.tags,
            // Denormalised so in-deck search is one LIKE over a column rather
            // than a scan that has to split every row's fields first.
            'search_text': note.fields.join(' '),
          });
        }
        await batch.commit(noResult: true);
      });
      written = end;
      onProgress?.call('Saving… $written of ${deck.notes.length}');
      await Future<void>.delayed(Duration.zero);
    }

    notifyListeners();
    return AnkiDeck(
      id: deckId,
      name: deck.name,
      source: source,
      importedAt: importedAt,
      noteCount: deck.notes.length,
    );
  }

  /// A page of notes from [deckId], in import order.
  ///
  /// Paged rather than loaded whole: shared decks run to tens of thousands of
  /// notes, and the list only ever shows a screenful.
  Future<List<AnkiNote>> notes(
    int deckId, {
    int limit = 100,
    int offset = 0,
    String query = '',
  }) async {
    try {
      final db = await _open();
      final trimmed = query.trim();
      final rows = await db.query(
        'notes',
        where: trimmed.isEmpty
            ? 'deck_id = ?'
            : 'deck_id = ? AND search_text LIKE ?',
        whereArgs: trimmed.isEmpty ? [deckId] : [deckId, '%$trimmed%'],
        orderBy: 'position ASC',
        limit: limit,
        offset: offset,
      );
      return rows.map(_noteFromRow).toList();
    } catch (e) {
      debugPrint('AnkiLibraryService: notes($deckId) failed: $e');
      return const [];
    }
  }

  /// How many notes [deckId] has, optionally narrowed by the same [query]
  /// [notes] takes — so the header can say "12 of 3,229" while filtering.
  Future<int> noteCount(int deckId, {String query = ''}) async {
    try {
      final db = await _open();
      final trimmed = query.trim();
      final rows = await db.rawQuery(
        trimmed.isEmpty
            ? 'SELECT COUNT(*) FROM notes WHERE deck_id = ?'
            : 'SELECT COUNT(*) FROM notes WHERE deck_id = ? AND search_text LIKE ?',
        trimmed.isEmpty ? [deckId] : [deckId, '%$trimmed%'],
      );
      return Sqflite.firstIntValue(rows) ?? 0;
    } catch (e) {
      debugPrint('AnkiLibraryService: noteCount($deckId) failed: $e');
      return 0;
    }
  }

  Future<void> deleteDeck(int deckId) async {
    try {
      final db = await _open();
      // Explicit, rather than relying on the cascade: `PRAGMA foreign_keys` is
      // per-connection, and a future refactor that opens this file without the
      // onConfigure above would otherwise orphan every note silently.
      await db.delete('notes', where: 'deck_id = ?', whereArgs: [deckId]);
      await db.delete('decks', where: 'id = ?', whereArgs: [deckId]);
      notifyListeners();
    } catch (e) {
      debugPrint('AnkiLibraryService: deleteDeck($deckId) failed: $e');
    }
  }

  static AnkiDeck _deckFromRow(Map<String, Object?> row) {
    return AnkiDeck(
      id: row['id'] as int,
      name: row['name'] as String? ?? 'Untitled deck',
      source: row['source'] as String? ?? '',
      importedAt: DateTime.fromMillisecondsSinceEpoch(
        row['imported_at'] as int? ?? 0,
      ),
      noteCount: row['note_count'] as int? ?? 0,
    );
  }

  static AnkiNote _noteFromRow(Map<String, Object?> row) {
    final names = row['field_names'] as String?;
    return AnkiNote(
      id: row['id'] as int,
      deckId: row['deck_id'] as int,
      fields: (row['fields'] as String? ?? '')
          .split(AnkiFieldText.fieldSeparator),
      fieldNames: names == null || names.isEmpty
          ? const <String>[]
          : names.split(AnkiFieldText.fieldSeparator),
      tags: row['tags'] as String? ?? '',
    );
  }
}
