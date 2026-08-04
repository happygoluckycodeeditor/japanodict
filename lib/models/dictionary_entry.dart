class DictionaryEntry {
  final int id;
  final String term;
  final String? reading;
  final String glosses;
  final String? partsOfSpeech;
  final String? tags;
  final int? score;
  final bool isCommon;
  final String? jlpt;

  /// JMdict entry sequence — groups the spellings and readings of one word
  /// (車/くるま and its rarer forms all share it). Unlike [id], which is an
  /// autoincrement that shifts every time the importer runs, this is stable
  /// across database rebuilds, so it's what flashcard favourites are keyed by.
  final int? sequence;

  DictionaryEntry({
    required this.id,
    required this.term,
    this.reading,
    required this.glosses,
    this.partsOfSpeech,
    this.tags,
    this.score,
    this.isCommon = false,
    this.jlpt,
    this.sequence,
  });

  factory DictionaryEntry.fromMap(Map<String, dynamic> map) {
    return DictionaryEntry(
      id: map['id'] as int,
      term: map['term'] as String,
      reading: map['reading'] as String?,
      glosses: map['glosses'] as String,
      partsOfSpeech: map['parts_of_speech'] as String?,
      tags: map['tags'] as String?,
      score: map['score'] as int?,
      isCommon: (map['is_common'] as int? ?? 0) == 1,
      jlpt: map['jlpt'] as String?,
      sequence: map['sequence'] as int?,
    );
  }

  List<String> get glossList {
    return glosses.split('•').map((g) => g.trim()).where((g) => g.isNotEmpty).toList();
  }

  List<String> get partsOfSpeechList {
    if (partsOfSpeech == null) return [];
    return partsOfSpeech!.split(',').map((p) => p.trim()).where((p) => p.isNotEmpty).toList();
  }

  List<String> get tagsList {
    if (tags == null) return [];
    return tags!.split(',').map((t) => t.trim()).where((t) => t.isNotEmpty).toList();
  }
}

/// A Tatoeba example sentence: the Japanese sentence and its English
/// translation, shown in the entry detail view.
class ExampleSentence {
  final String ja;
  final String en;

  const ExampleSentence({required this.ja, required this.en});
}

/// One character from KANJIDIC2, used for the per-character breakdown in the
/// entry detail view (e.g. 竜虎 → 竜 "dragon, imperial" + 虎 "tiger").
///
/// This is a separate source from the dictionary itself — Jitendex/JMdict is
/// vocabulary-level and has no per-character data. See
/// `scripts/build_kanji_db.py`.
class KanjiEntry {
  final String literal;

  /// School grade the character is taught at: 1–6 are the kyōiku kanji, 8 is
  /// the remainder of the jōyō set, 9/10 are jinmeiyō (name-use) kanji.
  final int? grade;
  final int? strokeCount;

  /// Frequency rank across a corpus of newspaper text — 1 is the most common
  /// of the ~2,500 ranked characters. Null means unranked, not "rare-ish".
  final int? freq;
  final String? onReadings;
  final String? kunReadings;
  final String meanings;
  final String? nanori;

  const KanjiEntry({
    required this.literal,
    this.grade,
    this.strokeCount,
    this.freq,
    this.onReadings,
    this.kunReadings,
    required this.meanings,
    this.nanori,
  });

  factory KanjiEntry.fromMap(Map<String, dynamic> map) {
    return KanjiEntry(
      literal: map['literal'] as String,
      grade: map['grade'] as int?,
      strokeCount: map['stroke_count'] as int?,
      freq: map['freq'] as int?,
      onReadings: map['on_readings'] as String?,
      kunReadings: map['kun_readings'] as String?,
      meanings: map['meanings'] as String,
      nanori: map['nanori'] as String?,
    );
  }

  List<String> get meaningList => _split(meanings);
  List<String> get onList => _split(onReadings);
  List<String> get kunList => _split(kunReadings);

  /// True for the jōyō kanji taught in compulsory schooling (grades 1–6) —
  /// used to show a "grade N" badge only where that number means something.
  bool get isKyoiku => grade != null && grade! >= 1 && grade! <= 6;

  static List<String> _split(String? value) {
    if (value == null) return const [];
    return value
        .split(',')
        .map((v) => v.trim())
        .where((v) => v.isNotEmpty)
        .toList();
  }
}

/// Stroke-order outlines for one character, from KanjiVG.
///
/// A third data source, independent of both Jitendex and KANJIDIC2 — the
/// latter has a stroke *count* but no geometry. See
/// `scripts/build_strokes_db.py`.
class KanjiStrokes {
  const KanjiStrokes({required this.literal, required this.outlines});

  final String literal;

  /// One SVG path per stroke, in writing order.
  final List<String> outlines;

  /// KanjiVG draws every character into this fixed square viewBox, so
  /// renderers must scale by `size / viewBox` rather than measuring bounds
  /// (measuring would make a small character like 一 fill the whole cell).
  static const double viewBox = 109.0;

  factory KanjiStrokes.fromMap(Map<String, dynamic> map) {
    return KanjiStrokes(
      literal: map['literal'] as String,
      outlines: (map['paths'] as String)
          .split('\n')
          .where((p) => p.trim().isNotEmpty)
          .toList(),
    );
  }
}
