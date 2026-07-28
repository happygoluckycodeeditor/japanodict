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
