import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../utils/anki_field_text.dart';

/// A failure the user can act on, as opposed to a bug.
///
/// Every throw site here is something a real deck file can legitimately be —
/// wrong format, newer export, not actually an Anki file — so the message is
/// written to be shown verbatim on screen. [detail] carries the follow-up
/// instruction where there is one.
class AnkiImportException implements Exception {
  const AnkiImportException(this.message, {this.detail});

  final String message;
  final String? detail;

  @override
  String toString() => detail == null ? message : '$message $detail';
}

/// One note as it came out of the file, before it is given an id.
class ImportedNote {
  const ImportedNote({
    required this.fields,
    required this.fieldNames,
    required this.tags,
  });

  final List<String> fields;
  final List<String> fieldNames;
  final String tags;

  bool get isEmpty => fields.every((f) => f.trim().isEmpty);
}

/// One deck's worth of notes, ready to be written to `anki.db`.
class ImportedDeck {
  ImportedDeck(this.name) : notes = <ImportedNote>[];

  final String name;
  final List<ImportedNote> notes;
}

/// Reads an Anki export into memory.
///
/// Two input shapes are supported, and the split is not arbitrary:
///
/// * **`.apkg` / `.colpkg`** — a zip with a SQLite collection inside. This is
///   what people actually have, because it is what AnkiWeb serves and what the
///   share button produces.
/// * **plain text / CSV** — the escape hatch, and the only thing guaranteed to
///   work forever. It is what the user is pointed at when a package turns out
///   to be in the newer format (see [_openPackage]).
///
/// Media is ignored outright. A card's images and audio have nothing to
/// contribute to a dictionary lookup, and carrying them would turn a 200KB
/// import into the tens of megabytes a Core deck's audio weighs.
class AnkiImportService {
  /// Extensions offered in the picker and accepted by [parse].
  static const List<String> supportedExtensions = [
    'apkg',
    'colpkg',
    'txt',
    'tsv',
    'csv',
  ];

  /// Notes read per round trip. Small enough that the cleaning pass between
  /// chunks never holds the UI thread for a visible beat, large enough that a
  /// 6,000-note deck is a dozen queries rather than thousands.
  static const int _chunkSize = 500;

  /// Reads [path] and groups its notes by the deck they belonged to.
  ///
  /// [onProgress] is called with human-readable status; the import screen
  /// shows it, because a large package takes several seconds and a bare
  /// spinner over an unknown wait reads as a hang.
  Future<List<ImportedDeck>> parse(
    String path, {
    String? fileName,
    required Directory workDirectory,
    void Function(String status)? onProgress,
  }) async {
    final name = fileName ?? p.basename(path);
    final extension = p.extension(name).replaceFirst('.', '').toLowerCase();
    final fallbackDeckName = p.basenameWithoutExtension(name);

    if (extension == 'apkg' || extension == 'colpkg') {
      return _parsePackage(
        path,
        fallbackDeckName: fallbackDeckName,
        workDirectory: workDirectory,
        onProgress: onProgress,
      );
    }
    onProgress?.call('Reading $name…');
    // Text parsing is pure Dart string work with no platform channels in it,
    // so the whole thing goes to a worker isolate. A 6,000-line export is
    // several hundred milliseconds of splitting and regex work — well past
    // the point where doing it inline drops frames.
    final decks = await Isolate.run(
      () => _parseTextExportSync(path, fallbackDeckName),
    );
    return decks;
  }

  // ---------------------------------------------------------------------
  // .apkg / .colpkg
  // ---------------------------------------------------------------------

  Future<List<ImportedDeck>> _parsePackage(
    String path, {
    required String fallbackDeckName,
    required Directory workDirectory,
    void Function(String status)? onProgress,
  }) async {
    onProgress?.call('Unpacking…');

    final destination = p.join(workDirectory.path, 'anki_import_collection.db');
    // Unzipping is the one genuinely blocking step: the collection inside a
    // Core-sized package inflates to tens of megabytes. It is plain file I/O,
    // available in any isolate, so it goes to a worker — the same reasoning
    // that put the dictionary asset copy on a background thread.
    await Isolate.run(() => _openPackage(path, destination));

    Database? db;
    try {
      onProgress?.call('Reading notes…');
      db = await openDatabase(
        destination,
        readOnly: true,
        // The path is reused on every import, so the singleton cache would
        // otherwise hand back a handle to the *previous* deck's collection.
        singleInstance: false,
      );
      return await _readCollection(
        db,
        fallbackDeckName: fallbackDeckName,
        onProgress: onProgress,
      );
    } finally {
      await db?.close();
      try {
        final file = File(destination);
        if (await file.exists()) await file.delete();
      } catch (e) {
        debugPrint('AnkiImportService: could not clean up $destination: $e');
      }
    }
  }

  /// Extracts the collection database out of the package at [archivePath].
  ///
  /// Runs in a worker isolate, so everything it touches is `dart:io` and
  /// `package:archive` — no platform channels.
  static void _openPackage(String archivePath, String destination) {
    final input = InputFileStream(archivePath);
    try {
      final Archive archive;
      try {
        archive = ZipDecoder().decodeStream(input);
      } catch (e) {
        throw AnkiImportException(
          'That file could not be opened as an Anki deck package.',
          detail: 'A .apkg is a zip archive; this one did not decode ($e).',
        );
      }

      // Anki 2.1.50+ writes the collection zstd-compressed as
      // `collection.anki21b` unless the exporter is told to stay compatible.
      // There is no zstd decoder in pure Dart, so this is a real wall rather
      // than a shortcut not taken — say so, and say what to do about it,
      // because the fix takes the user one checkbox.
      if (archive.find('collection.anki21b') != null) {
        throw const AnkiImportException(
          'This deck uses Anki\'s newer package format, which JapanoDict '
          'can\'t read.',
          detail: 'Re-export it from Anki with "Support older Anki versions" '
              'ticked, or use File → Export → Notes in Plain Text.',
        );
      }

      // anki21 is the newer schema and takes precedence: when a package holds
      // both, the .anki2 is a downgraded copy kept for old clients.
      for (final candidate in const ['collection.anki21', 'collection.anki2']) {
        final file = archive.find(candidate);
        if (file == null) continue;
        final output = OutputFileStream(destination);
        try {
          file.writeContent(output);
        } finally {
          output.closeSync();
        }
        return;
      }

      throw const AnkiImportException(
        'No Anki collection was found inside that file.',
        detail: 'It unzipped, but has no collection.anki2 — is it really a '
            'deck export?',
      );
    } finally {
      input.closeSync();
    }
  }

  Future<List<ImportedDeck>> _readCollection(
    Database db, {
    required String fallbackDeckName,
    void Function(String status)? onProgress,
  }) async {
    if (!await _tableExists(db, 'notes')) {
      throw const AnkiImportException(
        'That collection has no notes table.',
        detail: 'The file unpacked, but it is not an Anki collection.',
      );
    }

    final deckNames = await _readDeckNames(db);
    final fieldNames = await _readFieldNames(db);
    final noteDecks = await _readNoteDecks(db);

    final total = Sqflite.firstIntValue(
          await db.rawQuery('SELECT COUNT(*) FROM notes'),
        ) ??
        0;
    if (total == 0) {
      throw const AnkiImportException('That deck has no notes in it.');
    }

    final decks = <String, ImportedDeck>{};
    var read = 0;
    for (var offset = 0; offset < total; offset += _chunkSize) {
      final rows = await db.rawQuery(
        'SELECT id, mid, flds, tags FROM notes ORDER BY id LIMIT ? OFFSET ?',
        [_chunkSize, offset],
      );
      if (rows.isEmpty) break;

      for (final row in rows) {
        final flds = row['flds'] as String? ?? '';
        if (flds.isEmpty) continue;

        final noteId = row['id'] as int? ?? 0;
        final deckId = noteDecks[noteId];
        final deckName = deckNames[deckId] ?? fallbackDeckName;

        final note = ImportedNote(
          fields: AnkiFieldText.splitFields(flds),
          fieldNames: fieldNames[row['mid'] as int? ?? 0] ?? const <String>[],
          tags: (row['tags'] as String? ?? '').trim(),
        );
        if (note.isEmpty) continue;
        (decks[deckName] ??= ImportedDeck(deckName)).notes.add(note);
      }

      read += rows.length;
      onProgress?.call('Reading notes… $read of $total');
      // Hands the frame back between chunks. Without this the cleaning pass
      // for a large deck runs as one uninterrupted block and the progress
      // text never actually paints.
      await Future<void>.delayed(Duration.zero);
    }

    final result = decks.values.where((d) => d.notes.isNotEmpty).toList()
      ..sort((a, b) => a.name.compareTo(b.name));
    if (result.isEmpty) {
      throw const AnkiImportException('That deck has no notes in it.');
    }
    return result;
  }

  /// Deck id → name, across both collection schemas.
  ///
  /// Schema 18 has a real `decks` table; schema 11 keeps the whole deck tree
  /// as a JSON blob in `col.decks`. Both are still in circulation — a package
  /// exported for compatibility is schema 11 by definition, which is exactly
  /// the case this importer asks users to produce.
  Future<Map<int, String>> _readDeckNames(Database db) async {
    if (await _tableExists(db, 'decks')) {
      try {
        // No ORDER BY, and that is not an oversight. Schema 18 declares
        // `name text not null collate unicase` — a collation Anki registers in
        // its own process and no other SQLite has. Reading the column is fine;
        // *sorting* by it makes SQLite resolve the collation and fail with
        // "no such collation sequence", which would drop every deck name in
        // every modern collection back to the filename. Sort in Dart if it is
        // ever needed.
        final rows = await db.rawQuery('SELECT id, name FROM decks');
        final names = <int, String>{};
        for (final row in rows) {
          final id = row['id'] as int?;
          if (id == null) continue;
          names[id] = _normalizeDeckName(row['name'] as String? ?? '');
        }
        if (names.isNotEmpty) return names;
      } catch (e) {
        debugPrint('AnkiImportService: decks table unreadable: $e');
      }
    }

    try {
      final rows = await db.rawQuery('SELECT decks FROM col LIMIT 1');
      final raw = rows.isEmpty ? null : rows.first['decks'] as String?;
      if (raw != null && raw.length > 2) {
        final decoded = jsonDecode(raw) as Map<String, dynamic>;
        final names = <int, String>{};
        decoded.forEach((key, value) {
          final id = int.tryParse(key);
          if (id == null || value is! Map) return;
          names[id] = _normalizeDeckName(value['name'] as String? ?? '');
        });
        return names;
      }
    } catch (e) {
      debugPrint('AnkiImportService: col.decks unreadable: $e');
    }
    return const {};
  }

  /// Schema 18 separates nested deck levels with the unit separator; the JSON
  /// schema uses `::`. Normalising to `::` lets [AnkiDeck.leafName] have one
  /// rule.
  static String _normalizeDeckName(String raw) {
    final name = raw.replaceAll(AnkiFieldText.fieldSeparator, '::').trim();
    return name.isEmpty ? 'Untitled deck' : name;
  }

  /// Note type id → field names in template order.
  Future<Map<int, List<String>>> _readFieldNames(Database db) async {
    if (await _tableExists(db, 'fields')) {
      try {
        // Ordering by the integer columns only — `name` carries the same
        // `unicase` collation as `decks.name`; see [_readDeckNames].
        final rows = await db.rawQuery(
          'SELECT ntid, ord, name FROM fields ORDER BY ntid, ord',
        );
        final names = <int, List<String>>{};
        for (final row in rows) {
          final id = row['ntid'] as int?;
          if (id == null) continue;
          (names[id] ??= <String>[]).add(row['name'] as String? ?? '');
        }
        if (names.isNotEmpty) return names;
      } catch (e) {
        debugPrint('AnkiImportService: fields table unreadable: $e');
      }
    }

    try {
      final rows = await db.rawQuery('SELECT models FROM col LIMIT 1');
      final raw = rows.isEmpty ? null : rows.first['models'] as String?;
      if (raw != null && raw.length > 2) {
        final decoded = jsonDecode(raw) as Map<String, dynamic>;
        final names = <int, List<String>>{};
        decoded.forEach((key, value) {
          final id = int.tryParse(key);
          if (id == null || value is! Map) return;
          final fields = value['flds'];
          if (fields is! List) return;
          // `ord` is authoritative; the array's own order has been wrong in
          // collections that survived a field reorder in an old Anki.
          final sorted = fields.whereType<Map>().toList()
            ..sort((a, b) => ((a['ord'] as num?) ?? 0)
                .compareTo((b['ord'] as num?) ?? 0));
          names[id] = sorted.map((f) => f['name'] as String? ?? '').toList();
        });
        return names;
      }
    } catch (e) {
      debugPrint('AnkiImportService: col.models unreadable: $e');
    }
    return const {};
  }

  /// Note id → deck id, taken from the note's cards.
  ///
  /// A note's cards can sit in different decks, and the first one wins — there
  /// is no better answer, and the alternative (listing the note once per deck)
  /// would show the same Japanese twice.
  Future<Map<int, int>> _readNoteDecks(Database db) async {
    if (!await _tableExists(db, 'cards')) return const {};
    for (final query in const [
      // `odid` is the card's home deck while it sits in a filtered deck. Using
      // `did` alone would file half a user's collection under "Custom Study
      // Session" — which is what they'd see the moment they imported mid-review.
      'SELECT nid, did, odid FROM cards ORDER BY nid, ord',
      'SELECT nid, did FROM cards ORDER BY nid',
    ]) {
      try {
        final rows = await db.rawQuery(query);
        final decks = <int, int>{};
        for (final row in rows) {
          final noteId = row['nid'] as int?;
          if (noteId == null || decks.containsKey(noteId)) continue;
          final original = row['odid'] as int? ?? 0;
          final deckId = original != 0 ? original : row['did'] as int?;
          if (deckId != null) decks[noteId] = deckId;
        }
        return decks;
      } catch (e) {
        debugPrint('AnkiImportService: "$query" failed: $e');
      }
    }
    return const {};
  }

  static Future<bool> _tableExists(Database db, String name) async {
    final rows = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table' AND name=? LIMIT 1",
      [name],
    );
    return rows.isNotEmpty;
  }

  // ---------------------------------------------------------------------
  // Plain text / CSV
  // ---------------------------------------------------------------------

  /// Parses an Anki "Notes in Plain Text" export.
  ///
  /// Modern Anki writes `#`-prefixed headers describing the separator, whether
  /// fields hold HTML, and which columns are metadata rather than content.
  /// Older versions wrote nothing at all, so every header is optional and the
  /// separator is sniffed when it is missing.
  ///
  /// Runs in a worker isolate; must stay free of platform channels.
  static List<ImportedDeck> _parseTextExportSync(
    String path,
    String fallbackDeckName,
  ) {
    final bytes = File(path).readAsBytesSync();
    if (bytes.isEmpty) {
      throw const AnkiImportException('That file is empty.');
    }
    // allowMalformed rather than a throw: a stray bad byte in one note is not
    // a reason to refuse a 3,000-note deck.
    return parseTextExport(utf8.decode(bytes, allowMalformed: true), fallbackDeckName);
  }

  /// The parsing half of [_parseTextExportSync], split out so it can be
  /// exercised without a file on disk — every rule below is a guess about
  /// somebody else's exporter, which is exactly the kind of thing that should
  /// be pinned by a test.
  @visibleForTesting
  static List<ImportedDeck> parseTextExport(
    String source,
    String fallbackDeckName,
  ) {
    var text = source;
    if (text.startsWith('\uFEFF')) text = text.substring(1);

    String? separator;
    var html = true;
    int? deckColumn;
    int? tagsColumn;
    final specialColumns = <int>{};
    String? rawColumns;
    var bodyStart = 0;

    // Headers only run until the first line that isn't one — a field can
    // legitimately begin with '#' further down.
    while (bodyStart < text.length && text[bodyStart] == '#') {
      var lineEnd = text.indexOf('\n', bodyStart);
      if (lineEnd < 0) lineEnd = text.length;
      final line = text.substring(bodyStart + 1, lineEnd).trim();
      bodyStart = lineEnd + 1;

      final colon = line.indexOf(':');
      if (colon <= 0) continue;
      final key = line.substring(0, colon).trim().toLowerCase();
      final value = line.substring(colon + 1);

      switch (key) {
        case 'separator':
          separator = _resolveSeparator(value.trim());
        case 'html':
          html = value.trim().toLowerCase() != 'false';
        case 'columns':
          // Kept unsplit until the whole header block has been read: Anki
          // writes #separator: first, but nothing guarantees it, and splitting
          // eagerly on a not-yet-known separator yields one column named
          // "Expression,Meaning".
          rawColumns = value;
        case 'deck column':
          deckColumn = _columnIndex(value);
          if (deckColumn != null) specialColumns.add(deckColumn);
        case 'tags column':
          tagsColumn = _columnIndex(value);
          if (tagsColumn != null) specialColumns.add(tagsColumn);
        case 'notetype column':
        case 'guid column':
          final index = _columnIndex(value);
          if (index != null) specialColumns.add(index);
      }
    }

    // Clamped: a file that is nothing but headers, with no trailing newline,
    // leaves bodyStart one past the end and substring would throw.
    final body = bodyStart >= text.length ? '' : text.substring(bodyStart);
    final sep = separator ?? _sniffSeparator(body);
    final columnNames = rawColumns?.split(sep);
    final rows = _splitRows(body, sep);
    if (rows.isEmpty) {
      throw const AnkiImportException('No notes were found in that file.');
    }

    // Field names come from #columns: minus whatever the metadata columns
    // claimed, so they stay parallel to the fields actually kept.
    final fieldNames = <String>[];
    if (columnNames != null) {
      for (var i = 0; i < columnNames.length; i++) {
        if (specialColumns.contains(i)) continue;
        fieldNames.add(columnNames[i].trim());
      }
    }

    final decks = <String, ImportedDeck>{};
    for (final row in rows) {
      final fields = <String>[];
      for (var i = 0; i < row.length; i++) {
        if (specialColumns.contains(i)) continue;
        fields.add(AnkiFieldText.clean(row[i], html: html));
      }
      final note = ImportedNote(
        fields: fields,
        fieldNames: fieldNames,
        tags: tagsColumn != null && tagsColumn < row.length
            ? row[tagsColumn].trim()
            : '',
      );
      if (note.isEmpty) continue;

      final deckName = deckColumn != null &&
              deckColumn < row.length &&
              row[deckColumn].trim().isNotEmpty
          ? _normalizeDeckName(row[deckColumn])
          : fallbackDeckName;
      (decks[deckName] ??= ImportedDeck(deckName)).notes.add(note);
    }

    final result = decks.values.where((d) => d.notes.isNotEmpty).toList()
      ..sort((a, b) => a.name.compareTo(b.name));
    if (result.isEmpty) {
      throw const AnkiImportException('No notes were found in that file.');
    }
    return result;
  }

  static const Map<String, String> _namedSeparators = {
    'tab': '\t',
    'comma': ',',
    'semicolon': ';',
    'colon': ':',
    'space': ' ',
    'pipe': '|',
  };

  static String _resolveSeparator(String value) {
    final named = _namedSeparators[value.toLowerCase()];
    if (named != null) return named;
    return value.isEmpty ? '\t' : value[0];
  }

  /// Picks the separator for a headerless export by counting candidates in the
  /// first line. Anki wrote no `#separator:` header before 2.1.55, and those
  /// files are exactly the ones users still have lying around.
  static String _sniffSeparator(String body) {
    var lineEnd = body.indexOf('\n');
    if (lineEnd < 0) lineEnd = body.length;
    final line = body.substring(0, lineEnd);
    var best = '\t';
    var bestCount = 0;
    for (final candidate in const ['\t', ',', ';', '|']) {
      final count = candidate.allMatches(line).length;
      if (count > bestCount) {
        best = candidate;
        bestCount = count;
      }
    }
    return best;
  }

  /// Header column references are 1-based; everything downstream is 0-based.
  static int? _columnIndex(String value) {
    final parsed = int.tryParse(value.trim());
    if (parsed == null || parsed < 1) return null;
    return parsed - 1;
  }

  /// Splits [body] into rows of fields, honouring RFC-4180 quoting.
  ///
  /// Quoting is not optional to support: Anki quotes any field containing a
  /// newline, and a multi-line "Notes" field is common. Splitting on `\n`
  /// naively turns one such note into two malformed ones.
  static List<List<String>> _splitRows(String body, String separator) {
    final rows = <List<String>>[];
    var row = <String>[];
    final field = StringBuffer();
    var inQuotes = false;
    var fieldStarted = false;

    void endField() {
      row.add(field.toString());
      field.clear();
      fieldStarted = false;
    }

    void endRow() {
      endField();
      if (row.any((f) => f.trim().isNotEmpty)) rows.add(row);
      row = <String>[];
    }

    for (var i = 0; i < body.length; i++) {
      final char = body[i];
      if (inQuotes) {
        if (char == '"') {
          // A doubled quote inside a quoted field is an escaped quote.
          if (i + 1 < body.length && body[i + 1] == '"') {
            field.write('"');
            i++;
          } else {
            inQuotes = false;
          }
        } else {
          field.write(char);
        }
        continue;
      }

      if (char == '"' && !fieldStarted) {
        inQuotes = true;
        fieldStarted = true;
      } else if (char == separator) {
        endField();
      } else if (char == '\n') {
        endRow();
      } else if (char == '\r') {
        continue;
      } else {
        field.write(char);
        fieldStarted = true;
      }
    }
    if (field.isNotEmpty || row.isNotEmpty) endRow();

    return rows;
  }
}
