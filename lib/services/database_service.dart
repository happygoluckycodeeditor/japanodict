import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path_provider/path_provider.dart';
import '../models/dictionary_entry.dart';
import '../utils/romaji.dart';

/// How far along the one-time copy of the bundled dictionary is.
///
/// The copy only runs on a first launch or after a [DatabaseService._dbVersion]
/// bump, so [idle] is what almost every launch reports.
class DbPreparation {
  const DbPreparation({
    required this.copying,
    this.copiedBytes = 0,
    this.totalBytes = 0,
  });

  static const idle = DbPreparation(copying: false);

  /// True while the asset is being unpacked — the point at which the UI has to
  /// say something, because nothing can be searched yet.
  final bool copying;
  final int copiedBytes;
  final int totalBytes;

  /// 0.0–1.0, or null when the total isn't known and the bar must stay
  /// indeterminate rather than inventing a figure.
  double? get fraction {
    if (totalBytes <= 0) return null;
    return (copiedBytes / totalBytes).clamp(0.0, 1.0);
  }
}

class DatabaseService {
  static final DatabaseService _instance = DatabaseService._internal();
  static Future<Database>? _databaseFuture;

  /// Channel implemented in MainActivity.kt — see [_copyDatabaseAsset].
  static const MethodChannel _dbChannel = MethodChannel('japanodict/db');

  /// Progress events from the native copy loop in MainActivity.kt.
  static const EventChannel _dbProgressChannel =
      EventChannel('japanodict/db_progress');

  /// Live state of the first-run copy, for the UI to render.
  ///
  /// A [ValueNotifier] rather than the copy future's own progress because the
  /// copy is kicked off with `unawaited` from `initState` — the widget needs
  /// something it can listen to, not something it has to await.
  static final ValueNotifier<DbPreparation> preparation =
      ValueNotifier<DbPreparation>(DbPreparation.idle);

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
  // v8 added the `dictionary.freq` corpus rank (scripts/build_freq_db.py).
  static const int _dbVersion = 9;
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

    // Subscribe *before* asking for the copy, so no early event is missed.
    // The listener is the only thing that makes the native side emit at all.
    preparation.value = const DbPreparation(copying: true);
    StreamSubscription<dynamic>? progress;
    try {
      progress = _dbProgressChannel.receiveBroadcastStream().listen(
        (event) {
          if (event is! Map) return;
          preparation.value = DbPreparation(
            copying: true,
            copiedBytes: (event['copied'] as num?)?.toInt() ?? 0,
            totalBytes: (event['total'] as num?)?.toInt() ?? 0,
          );
        },
        // Progress is decoration; losing it must never fail the copy.
        onError: (Object e) => debugPrint('DatabaseService: progress stream error: $e'),
      );
    } catch (e) {
      debugPrint('DatabaseService: could not subscribe to progress: $e');
    }

    try {
      await _dbChannel.invokeMethod<void>('copyAsset', {
        'assetKey': _dbAsset,
        'destPath': path,
      });
      debugPrint('DatabaseService: native asset copy took ${sw.elapsedMilliseconds}ms');
      return;
    } on MissingPluginException {
      debugPrint('DatabaseService: no native copy channel, falling back to rootBundle');
    } finally {
      unawaited(progress?.cancel());
      preparation.value = DbPreparation.idle;
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
  /// Carries `freq` even though [_columns] does not: the ranking sorts on it
  /// and an outer ORDER BY can only reach a column its subquery emitted. It is
  /// dropped again by the outer SELECT, so it never crosses to Dart.
  static const _ftsSelect =
      'd.id, d.term, d.reading, d.glosses, d.parts_of_speech, d.tags, d.score, d.is_common, d.jlpt, d.sequence, d.freq';

  /// Exclusive upper bound for a prefix range scan — [prefix] with its last
  /// character incremented, so `col >= prefix AND col < bound` selects exactly
  /// the rows that `col LIKE 'prefix%'` would.
  ///
  /// This exists because **`LIKE` cannot use an index here.** SQLite only
  /// rewrites `LIKE 'x%'` into a range constraint when the index collation
  /// agrees with the `case_sensitive_like` pragma, and the default (`OFF`,
  /// ASCII case-insensitive) does not agree with these BINARY indexes. So the
  /// prefix tier planned as a bare `SCAN dictionary` — all ~296k rows, on
  /// every keystroke, twice over for romaji input. The range form plans as
  /// `SEARCH dictionary USING COVERING INDEX idx_term`: ~37ms -> ~0.02ms.
  ///
  /// Returns null when no bound is representable, which leaves the caller on
  /// the `LIKE` path rather than silently scanning a wrong range.
  static String? _prefixUpperBound(String prefix) {
    if (prefix.isEmpty) return null;
    final runes = prefix.runes.toList();
    var last = runes.last + 1;
    // Never land inside the surrogate block: String.fromCharCodes would then
    // build an unpaired surrogate and the comparison would be meaningless.
    if (last >= 0xD800 && last <= 0xDFFF) last = 0xE000;
    if (last > 0x10FFFF) return null;
    runes[runes.length - 1] = last;
    return String.fromCharCodes(runes);
  }

  // -------------------------------------------------------------------
  // Gloss relevance — the ranking behind the FTS tiers
  // -------------------------------------------------------------------

  /// Rows asked of each tier per row the caller wants.
  ///
  /// The `sequence` collapse in `addAll` throws rows away *after* SQL has
  /// applied its `LIMIT`, so a tier that fetched exactly `limit` rows could
  /// hand back half a screen of cards. Three covers the worst spread seen
  /// (めでたい's four spellings) without materially widening the sort.
  static const _overfetch = 3;

  /// How many FTS hits get re-ranked; the rest are dropped unseen.
  ///
  /// A one-word English query can match thousands of entries ("one" matches
  /// 11,645) and the relevance keys below cost a string rewrite per row, so
  /// scoring the whole match set is work the user never sees past `LIMIT`.
  /// The inner query therefore takes a cheap first cut — common words, then
  /// score — and only that pool is ranked properly. It is a recall trade: a
  /// rare word buried behind 400 common ones cannot surface. The cut is
  /// generous in practice, since only 33k of the 296k rows are common at all.
  static const _rankCandidates = 400;

  /// Sentinel for "the query heads no gloss item" — larger than any real
  /// position, so `min()` across the probes still yields the right answer
  /// when only some of them hit.
  static const _noHead = 999999;

  /// `glosses` rewritten so every gloss item is bracketed by `'; '`:
  /// lower-cased, sense separators (` • `) turned into item separators, and
  /// one separator glued to each end. Probing *this* with `instr` is what
  /// lets the ranking ask "does the query start a definition" rather than
  /// only "does it appear inside one".
  static const _glossProbe =
      "'; ' || replace(lower(d.glosses), ' • ', '; ') || '; '";

  /// Relevance columns for a gloss match, computed over [_glossProbe] as `g`.
  ///
  /// `head_pos` is where the query first *heads* a gloss item, `any_pos`
  /// where it occurs at all, and `sense1_end` where the first sense stops.
  /// [_glossRankOrderBy] is built entirely from those three.
  ///
  /// The `to `-prefixed probes are not a nicety. JMdict writes every verb
  /// gloss in the infinitive — 食べる is `to eat` — so without them a search
  /// for "eat" ranks 食言 ("eat one's words") above it, the query heading
  /// that entry's definition and merely sitting inside 食べる's.
  static const _rankColumns = '''
        min(
          coalesce(nullif(instr(g, ?), 0), $_noHead),
          coalesce(nullif(instr(g, ?), 0), $_noHead),
          coalesce(nullif(instr(g, ?), 0), $_noHead),
          coalesce(nullif(instr(g, ?), 0), $_noHead)
        ) AS head_pos,
        instr(g, ?) AS any_pos,
        CASE instr(lower(glosses), ' • ')
          WHEN 0 THEN length(glosses) + 3
          ELSE instr(lower(glosses), ' • ') + 2
        END AS sense1_end''';

  /// Arguments for [_rankColumns]. [whole] distinguishes the whole-word tier,
  /// where the query has to end a gloss item as well as start it, from the
  /// prefix tier, where "beauti" legitimately heads "beautiful". The prefix
  /// form repeats its two probes so the SQL text — and so SQLite's statement
  /// cache entry — stays the same for both.
  static List<Object?> _rankArgs(String query, {required bool whole}) {
    final probes = whole
        ? ['; $query; ', '; $query ', '; to $query; ', '; to $query ']
        : ['; $query', '; to $query', '; $query', '; to $query'];
    return [...probes, query];
  }

  /// An FTS query that matches **every** word of a multi-word query, in any
  /// order and anywhere in the definition: `medical treatment` becomes
  /// `medical treatment*`. Null for a single-word query, which the tiers above
  /// already cover, and for anything with no usable token in it.
  ///
  /// The gloss tiers above search the query as a *phrase*, so they only reach
  /// a definition holding those words adjacent and in the order typed:
  /// "dealing with" finds 処置 and "with dealing" finds nothing at all. Nor
  /// does a user typing two words necessarily expect them adjacent —
  /// "measure treatment" is a reasonable way to grope for 処置 and matched
  /// nothing whatsoever. FTS4's default syntax ANDs bare tokens, which is
  /// exactly that weaker "all of these words" match.
  ///
  /// The last token keeps its `*` because search is live: the word under the
  /// cursor is usually half-typed, and "medical treat" has to match while the
  /// user is still going.
  ///
  /// Tokens are split on non-alphanumerics rather than escaped, which is both
  /// safer and more faithful. `"`, `*`, `^`, `-` and `:` are FTS operators, so
  /// a stray one is a syntax error the user cannot see the cause of — and
  /// splitting on them is what unicode61 did when it indexed the column, so
  /// "one's" tokenises here exactly as it did there.
  static String? ftsAllWordsQuery(String query) {
    final tokens = query
        .split(RegExp(r'[^\p{L}\p{N}]+', unicode: true))
        .where((t) => t.isNotEmpty)
        .toList();
    if (tokens.length < 2) return null;
    final last = tokens.removeLast();
    return '${tokens.join(' ')} $last*';
  }

  /// Ranks a gloss match by **how central the query is to the entry's
  /// meaning**.
  ///
  /// The ordering this replaced led with `is_common DESC, score DESC`, and
  /// neither column discriminates: 22,551 rows share `score` 200 and 33,070
  /// are common, so "happy" sorted ~226 effectively tied hits by nothing and
  /// opened on 慶事 "happy event" while 楽しい and 嬉しい fell off the list
  /// entirely. These keys break the tie with the match itself:
  ///
  /// 1. does the query *head* a definition, or is it buried inside one
  /// 2. is the word common
  /// 3. is the match in the entry's **first** sense — so 大石, whose second
  ///    sense is exactly "dragon", stays below 竜
  /// 4. is it near the front of that sense — one coarse bucket, not the exact
  ///    offset, because "happy" being 楽しい's fourth gloss should not
  ///    outweigh 楽しい being the commoner word
  /// 5. corpus frequency rank (`freq`), unranked words last
  /// 6. JLPT level, easiest first
  ///
  /// **Key 5 is what actually decides most searches**, because keys 1–4 tie
  /// constantly: "happy" arrives with ~226 hits that are all common, all
  /// score 200, and mostly all first-sense. `freq` is written by
  /// scripts/build_freq_db.py from wordfreq's Japanese corpus blend and is
  /// what orders 楽しい → 嬉しい → ハッピー → めでたい → 慶事 rather than
  /// leaving them in table order.
  ///
  /// `freq IS NULL` **must** lead it. NULL sorts smallest in SQLite, so
  /// `ORDER BY freq` alone would promote every word the corpus has never seen
  /// to the top of the list — the same trap the kanji decks document.
  ///
  /// Key 6 still earns its place: `freq` covers 88% of common words, and JLPT
  /// level orders the rest sensibly instead of dropping them on `score`.
  static const _glossRankOrderBy = '''
      ORDER BY
        (CASE WHEN head_pos < $_noHead THEN 0 ELSE 1 END),
        is_common DESC,
        (CASE WHEN min(head_pos, any_pos) < sense1_end THEN 0 ELSE 1 END),
        (CASE WHEN min(head_pos, any_pos) <= 40 THEN 0 ELSE 1 END),
        freq IS NULL, freq ASC,
        (CASE jlpt
          WHEN 'N5' THEN 0 WHEN 'N4' THEN 1 WHEN 'N3' THEN 2
          WHEN 'N2' THEN 3 WHEN 'N1' THEN 4 ELSE 5 END),
        min(head_pos, any_pos), score DESC, length(term) ASC, id ASC''';

  /// The whole gloss query: FTS match, cheap cut to [_rankCandidates], rank,
  /// cut to the caller's limit.
  ///
  /// Three nested levels because each needs the one below it: `g` has to
  /// exist before the probes can read it, and the probes have to exist before
  /// the ORDER BY can. The outer level re-selects only the entry columns, so
  /// the normalised gloss string never crosses the platform channel — an
  /// ORDER BY may still reference the subquery columns it drops.
  ///
  /// **Bind order is [_rankArgs], then the FTS query, then the row limit** —
  /// not the reading order of the tiers. SQLite numbers anonymous parameters
  /// by where they appear in the SQL *text*, and the probe columns are
  /// written above the `MATCH` they depend on.
  static final _glossRankQuery = '''
    SELECT ${_columns.join(', ')} FROM (
      SELECT c.*,
$_rankColumns
      FROM (
        SELECT $_ftsSelect, $_glossProbe AS g
        FROM dictionary_fts fts
        JOIN dictionary d ON d.id = fts.docid
        WHERE dictionary_fts MATCH ?
        ORDER BY d.is_common DESC, d.score DESC, d.id
        LIMIT $_rankCandidates
      ) c
    )
$_glossRankOrderBy
    LIMIT ?''';

  Future<List<DictionaryEntry>> searchEntries(String query, {int limit = 50}) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return [];

    final db = await database;
    final seenIds = <int>{};
    final seenSequences = <int>{};
    final results = <DictionaryEntry>[];

    /// Collapses each JMdict `sequence` to a single card.
    ///
    /// A word's spellings are separate rows sharing one sequence, so "happy"
    /// used to spend four of its first eight slots on 目出度い, 愛でたい and
    /// 芽出度い after めでたい — three ways of writing a word already on
    /// screen, pushing the words the user actually wanted off the bottom.
    /// The queries order the canonical spelling first (by score, then term
    /// length), so keeping the first row per sequence keeps the right one.
    ///
    /// Deliberately shared across tiers: an entry matched on its reading in
    /// tier 0 must not come back as a gloss match in tier 2.
    void addAll(List<Map<String, Object?>> rows) {
      for (final row in rows) {
        if (results.length >= limit) return;
        final sequence = row['sequence'] as int?;
        if (sequence != null && !seenSequences.add(sequence)) continue;
        if (!seenIds.add(row['id'] as int)) continue;
        results.add(DictionaryEntry.fromMap(row));
      }
    }

    // Latin input like "kuruma" is also converted to kana ("くるま") so it can
    // match the readings stored in the dictionary — the way Shirabe Jisho does.
    // The English text is still searched too (so "car" keeps working).
    // Folded to lower case because the range scan below compares with BINARY
    // collation, where the old `LIKE` was ASCII case-insensitive. `term` and
    // `reading` hold no upper-case character anywhere in the database (checked
    // against all 296k rows), so folding the *query* can only ever restore a
    // match the old path would have made — never lose one. A no-op for kana
    // and kanji input.
    final folded = trimmed.toLowerCase();
    final kana = Romaji.looksLikeRomaji(folded) ? Romaji.toHiragana(folded) : null;
    final termTargets = <String>{folded, if (kana != null && kana != folded) kana};

    // Tiers 0 and 1 — exact term/reading match, then prefix match — in a
    // single query. Common words (Jisho's "common word" flag) float to the top
    // of every tier so the everyday word lands first.
    //
    // The two are **emitted at different points** in the merge, though: an
    // exact match leads the list, but a *prefix* match ranks below the gloss
    // tier. See `_addTermPrefix` below for why. They stay one query because
    // splitting them is what the `tier` column already avoids.
    //
    // These used to be one query *per tier per target*, and romaji input has
    // two targets (the Latin text and its kana), so a keystroke cost four
    // round trips, each planning as a full table scan. Merging them keeps the
    // ordering the separate queries expressed — the `tier` column is what puts
    // exact matches ahead of prefixes — while touching the database once.
    //
    // `id ASC` closes the sort. Rows tied on every ranking key used to fall out
    // in table order because the plan was a full scan; an index range scan
    // emits them in term order instead, which would reshuffle the tail of the
    // list (and the cut at LIMIT) between builds for no reason. Pinning it
    // keeps results stable and matches what the scan used to return.
    final targets = termTargets.toList();
    final ranges = <String>[];
    final rangeArgs = <Object?>[];
    for (final target in targets) {
      final upper = _prefixUpperBound(target);
      if (upper != null) {
        ranges.add('(term >= ? AND term < ?) OR (reading >= ? AND reading < ?)');
        rangeArgs.addAll([target, upper, target, upper]);
      } else {
        // Unrepresentable bound: fall back rather than scan a wrong range.
        ranges.add('term LIKE ? OR reading LIKE ?');
        rangeArgs.addAll(['$target%', '$target%']);
      }
    }
    // For romaji input, the Latin text the user typed can *also* be the
    // English word — someone typing "kanji" wants 漢字, whose gloss is
    // literally "kanji; Chinese character", not 感じ "feeling", which the
    // corpus says is the commoner reading of かんじ. So when a query converted
    // to kana, entries whose definition contains the Latin form are preferred
    // among rows that are otherwise equally good matches.
    //
    // Only for romaji: on kana or kanji input this would be a `LIKE` over
    // glosses that essentially never hits, for nothing. The rows it runs
    // against are only the ones the indexed range already selected.
    final glossHit = kana != null ? '(CASE WHEN glosses LIKE ? THEN 0 ELSE 1 END),' : '';
    final glossHitArgs = kana != null ? <Object?>['%$folded%'] : const <Object?>[];

    final exactPlaceholders = List.filled(targets.length, '?').join(',');
    final termRows = await db.rawQuery('''
      SELECT ${_columns.join(', ')},
        (CASE WHEN term IN ($exactPlaceholders)
                OR reading IN ($exactPlaceholders) THEN 0 ELSE 1 END) AS tier
      FROM dictionary
      WHERE ${ranges.join(' OR ')}
      ORDER BY tier, is_common DESC, $glossHit freq IS NULL, freq ASC,
        score DESC, length(term) ASC, id ASC
      LIMIT ?
    ''', [
      ...targets, ...targets,   // the SELECT's exact-match CASE
      ...rangeArgs,             // the WHERE
      ...glossHitArgs,          // the ORDER BY — parameters bind in the order
      limit * _overfetch,       // they appear in the SQL text, not in tier order
    ]);

    // Split on the `tier` column the query just computed, and hold the prefix
    // half back until after the gloss tier.
    //
    // **This is the fix for searching an English word that also reads as
    // romaji.** "china" converts to ちな, which is a real entry, so the prefix
    // range matched 因みに, 血なまぐさい, 因む … and eleven kana words claimed
    // the screen while 中国 sat at position twelve. A prefix match on a
    // *guessed* kana spelling is the weakest evidence in the whole search, and
    // it was outranking an entry whose definition is literally the word typed.
    //
    // Exact matches stay on top, and that is deliberate rather than timid:
    // ranking the gloss tier above them too would mean "kuruma" opening on
    // 車海老 "kuruma prawn" instead of 車, "sushi" on ねた, and "sake" on 為
    // (whose gloss contains "for the sake of"). An exact term or reading match
    // is strong evidence in either language; a prefix is not.
    final exactRows = termRows.where((r) => r['tier'] == 0);
    final prefixRows = termRows.where((r) => r['tier'] != 0);
    addAll(exactRows.toList());

    // Tier 2/3: full-text search over definitions. Whole-word matches (e.g.
    // searching "car" hits the definition word "car") rank above mere prefix
    // matches (e.g. "card", "careful") so real hits like 車 surface first
    // instead of being buried among unrelated entries.
    //
    // Both tiers are ordered by [_glossRankOrderBy], which ranks by where in
    // the definition the query landed rather than by `is_common`/`score` —
    // see the comment there for why those two columns cannot do the job.
    final ftsQuery = trimmed.replaceAll('"', '');
    final foldedFts = ftsQuery.toLowerCase();
    if (results.length < limit && ftsQuery.isNotEmpty) {
      try {
        addAll(await db.rawQuery(_glossRankQuery, [
          ..._rankArgs(foldedFts, whole: true),
          '"$ftsQuery"',
          (limit - results.length) * _overfetch,
        ]));
      } catch (e) {
        debugPrint('FTS exact-word search failed: $e');
      }
    }

    // Only now the term/reading *prefix* matches, held back above.
    addAll(prefixRows.toList());

    if (results.length < limit && ftsQuery.isNotEmpty) {
      try {
        addAll(await db.rawQuery(_glossRankQuery, [
          ..._rankArgs(foldedFts, whole: false),
          '$ftsQuery*',
          (limit - results.length) * _overfetch,
        ]));
      } catch (e) {
        debugPrint('FTS prefix search failed: $e');
      }
    }

    // Tier 4: every word of a multi-word query, in any order. The two gloss
    // tiers above are phrase matches, so until here "measure treatment" and
    // "treatment for a disease" found nothing at all — see [ftsAllWordsQuery].
    // Single-word queries skip it: it would repeat tier 3 exactly.
    final allWords = ftsAllWordsQuery(foldedFts);
    if (results.length < limit && allWords != null) {
      try {
        addAll(await db.rawQuery(_glossRankQuery, [
          ..._rankArgs(foldedFts, whole: false),
          allWords,
          (limit - results.length) * _overfetch,
        ]));
      } catch (e) {
        debugPrint('FTS all-words search failed: $e');
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

  // -------------------------------------------------------------------
  // Proper names (JMnedict)
  // -------------------------------------------------------------------

  static const _nameColumns =
      ['id', 'sequence', 'term', 'reading', 'name_type', 'priority', 'glosses'];

  /// Proper-name matches for [query] — companies, products, works, characters,
  /// organizations and railway stations from JMnedict.
  ///
  /// **Deliberately not part of [searchEntries], and not a sixth tier of it.**
  /// JMdict holds no proper names at all, so 任天堂 and ゴジラ used to return a
  /// blank screen; the fix is a separate table and a separate query, because
  /// merging them would undo work the ranking depends on:
  ///
  ///   * names carry no `freq`, no `is_common` and no JLPT level, so they
  ///     cannot be ordered against words by any of the keys [_glossRankOrderBy]
  ///     uses — they would land wherever table order put them, in the middle of
  ///     a carefully ranked list;
  ///   * a name is a *different kind of answer*, not a worse one. The caller
  ///     renders these under their own heading, the way partial matches are
  ///     kept out of the main list.
  ///
  /// Ranking is [NameEntry.priority] (JMnedict's only signal — there is no
  /// frequency data for names), then the shortest term, then `id` to keep the
  /// tail of the list stable between builds the way the term tiers do.
  ///
  /// Returns an empty list rather than throwing when the `names` table is
  /// absent, so a database predating this import degrades to the old behaviour
  /// instead of taking search down with it.
  Future<List<NameEntry>> searchNames(String query, {int limit = 10}) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return [];

    final db = await database;
    final seenSequences = <int>{};
    final results = <NameEntry>[];

    void addAll(List<Map<String, Object?>> rows) {
      for (final row in rows) {
        if (results.length >= limit) return;
        // Collapse spellings to one card, exactly as `searchEntries` does.
        if (!seenSequences.add(row['sequence'] as int)) continue;
        results.add(NameEntry.fromMap(row));
      }
    }

    // Same two targets as the main search: the text as typed, and — for romaji
    // — its kana. The kana target earns its place on kanji names reached
    // through their reading ("nintendou" -> にんてんどう -> 任天堂). Katakana
    // names like ゴジラ are found by the English gloss tier below instead,
    // since [Romaji.toHiragana] produces hiragana.
    final folded = trimmed.toLowerCase();
    final kana = Romaji.looksLikeRomaji(folded) ? Romaji.toHiragana(folded) : null;
    final targets = <String>{folded, if (kana != null && kana != folded) kana};

    // Tier 0/1 — exact then prefix, in one query, split by a computed `tier`
    // column. Same shape and the same reason as the term tiers above: a range
    // comparison rather than `LIKE`, so this plans as an index search instead
    // of scanning all 17,854 rows on every keystroke.
    final ranges = <String>[];
    final exacts = <String>[];
    final exactArgs = <Object?>[];
    final rangeArgs = <Object?>[];
    for (final target in targets) {
      exacts.add('term = ? OR reading = ?');
      exactArgs.addAll([target, target]);
      final upper = _prefixUpperBound(target);
      if (upper != null) {
        ranges.add('(term >= ? AND term < ?) OR (reading >= ? AND reading < ?)');
        rangeArgs.addAll([target, upper, target, upper]);
      } else {
        // Unrepresentable bound: fall back rather than scan a wrong range.
        ranges.add('term LIKE ? OR reading LIKE ?');
        rangeArgs.addAll(['$target%', '$target%']);
      }
    }

    final termQuery = 'SELECT ${_nameColumns.join(', ')}, '
        'CASE WHEN ${exacts.map((e) => '($e)').join(' OR ')} THEN 0 ELSE 1 END AS tier '
        'FROM names '
        'WHERE ${ranges.map((r) => '($r)').join(' OR ')} '
        'ORDER BY tier ASC, priority DESC, length(term) ASC, id ASC '
        'LIMIT ?';

    try {
      addAll(await db.rawQuery(
        termQuery,
        [...exactArgs, ...rangeArgs, limit * _overfetch],
      ));
    } catch (e) {
      // No `names` table — a database copied before this import ran.
      debugPrint('Name search failed: $e');
      return const [];
    }

    // Tier 2 — the English translation. This is the tier that actually answers
    // "godzilla" and "nintendo", which is how these will nearly always arrive.
    // Quoted as a phrase, and `"` stripped first, for the same reason
    // [searchEntries] does it: the bare token would let a stray FTS operator
    // become a syntax error the user cannot see the cause of.
    final ftsQuery = trimmed.replaceAll('"', '');
    if (results.length < limit && ftsQuery.isNotEmpty) {
      // Rank on *where in the translation the query landed*, the same idea as
      // [_glossRankOrderBy] and for the same reason: JMnedict gives names no
      // frequency or commonness data at all, so without this key the tier
      // falls back to term length and "nintendo" opens on ６４ "Nintendo 64"
      // and Ｗｉｉ, with 任天堂 itself third. Whole-gloss matches first, then
      // names the query *heads*, then the ones merely mentioning it
      // ("Wario (Nintendo character)").
      final glossQuery = 'SELECT ${_nameColumns.map((c) => 'n.$c').join(', ')} '
          'FROM names_fts f JOIN names n ON n.id = f.docid '
          'WHERE names_fts MATCH ? '
          'ORDER BY CASE WHEN lower(n.glosses) = ? THEN 0 '
          '              WHEN lower(n.glosses) LIKE ? THEN 1 '
          '              ELSE 2 END, '
          'n.priority DESC, length(n.term) ASC, n.id ASC '
          'LIMIT ?';
      try {
        addAll(await db.rawQuery(
          glossQuery,
          [
            '"$ftsQuery"',
            folded,
            '$folded%',
            (limit - results.length) * _overfetch,
          ],
        ));
      } catch (e) {
        debugPrint('Name gloss search failed: $e');
      }
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

  /// The KANJIDIC2 entry for a single character, or null if it has none
  /// (readings-only JIS X 0212 characters were dropped at import time).
  Future<KanjiEntry?> getKanji(String literal) async {
    final db = await database;
    final rows = await db.query(
      'kanji',
      where: 'literal = ?',
      whereArgs: [literal],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return KanjiEntry.fromMap(rows.first);
  }

  /// Words written with [literal] anywhere in them — the "Compounds" list on
  /// the kanji detail screen (免 → 免許, 免疫, 御免 …).
  ///
  /// This has to be a `LIKE '%x%'` scan, which no index can serve. FTS isn't an
  /// option either: `dictionary_fts` uses the unicode61 tokenizer, which treats
  /// an unspaced run of CJK as a *single* token, so 免許 is never reachable by
  /// matching 免. The scan is ~300k rows and runs once, lazily, when the screen
  /// opens — the same budget as the examples query, not the search path.
  ///
  /// Grouped by `sequence` for the same reason the flashcard decks are (see
  /// [_deckSelect]): without it, 免許 would appear again as each of its rarer
  /// spellings. Common words come first, then words that *begin* with the
  /// character, then shorter ones — so the everyday compounds lead.
  Future<List<DictionaryEntry>> getCompoundsFor(String literal, {int limit = 60}) async {
    if (literal.isEmpty) return const [];
    final db = await database;
    final rows = await db.rawQuery('''
      SELECT * FROM (
        SELECT $_deckSelect
        FROM dictionary
        WHERE term LIKE ?
        GROUP BY sequence
      )
      ORDER BY is_common DESC, score DESC,
        (CASE WHEN term LIKE ? THEN 0 ELSE 1 END),
        length(term) ASC
      LIMIT ?
    ''', ['%$literal%', '$literal%', limit]);
    return rows.map(DictionaryEntry.fromMap).toList();
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

  /// Exact term-or-reading lookup for a batch of candidate strings.
  ///
  /// This is the OCR/text-scanning counterpart to [searchEntries], and it is
  /// deliberately *not* that method: search is five fuzzy tiers ending in a
  /// gloss `LIKE`, which is right when a human is typing and wrong here. A
  /// deinflection candidate is a hypothesis — 話る either is a dictionary form
  /// or it isn't — and letting it match on a gloss substring would confirm
  /// nonsense hypotheses and pick the wrong word for the sentence.
  ///
  /// Takes the whole candidate set at once so a tap costs one round trip
  /// rather than one per substring length. Both `term` and `reading` are
  /// indexed, so the `IN` scan is cheap.
  Future<List<DictionaryEntry>> lookupTerms(Iterable<String> terms) async {
    final unique = terms.where((t) => t.isNotEmpty).toSet().toList();
    if (unique.isEmpty) return const [];
    final db = await database;

    // SQLite's default host-parameter ceiling is 999 and each term is bound
    // twice (term and reading), so chunk well under half of it.
    const chunkSize = 400;
    final results = <DictionaryEntry>[];
    final seenIds = <int>{};
    for (var i = 0; i < unique.length; i += chunkSize) {
      final chunk = unique.sublist(
        i,
        i + chunkSize < unique.length ? i + chunkSize : unique.length,
      );
      final placeholders = List.filled(chunk.length, '?').join(',');
      final rows = await db.query(
        'dictionary',
        columns: _columns,
        where: 'term IN ($placeholders) OR reading IN ($placeholders)',
        whereArgs: [...chunk, ...chunk],
        orderBy: 'is_common DESC, score DESC',
      );
      for (final row in rows) {
        if (seenIds.add(row['id'] as int)) {
          results.add(DictionaryEntry.fromMap(row));
        }
      }
    }
    return results;
  }

  Future<void> close() async {
    final db = await database;
    await db.close();
  }
}
