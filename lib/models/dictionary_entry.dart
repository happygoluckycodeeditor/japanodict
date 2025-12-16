class DictionaryEntry {
  final int id;
  final String term;
  final String? reading;
  final String glosses;
  final String? partsOfSpeech;
  final String? tags;
  final int? score;

  DictionaryEntry({
    required this.id,
    required this.term,
    this.reading,
    required this.glosses,
    this.partsOfSpeech,
    this.tags,
    this.score,
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
    );
  }

  List<String> get glossList {
    return glosses.split('|').where((g) => g.isNotEmpty).toList();
  }

  List<String> get partsOfSpeechList {
    if (partsOfSpeech == null) return [];
    return partsOfSpeech!.split('|').where((p) => p.isNotEmpty).toList();
  }

  List<String> get tagsList {
    if (tags == null) return [];
    return tags!.split('|').where((t) => t.isNotEmpty).toList();
  }
}
