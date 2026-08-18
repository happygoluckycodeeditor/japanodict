import '../utils/anki_field_text.dart';
import '../utils/jp_text.dart';

/// A deck the user has imported from an Anki export, as stored in `anki.db`.
///
/// This is **not** a [Deck] from `models/flashcard.dart`. Those are built-in,
/// derived from the bundled dictionary, and reviewed. These are user data with
/// arbitrary fields, and nothing here reviews them — the deck is a corpus to
/// look words up in, not a study queue.
class AnkiDeck {
  const AnkiDeck({
    required this.id,
    required this.name,
    required this.source,
    required this.importedAt,
    required this.noteCount,
  });

  /// Local autoincrement id in `anki.db`. Anki's own deck id is deliberately
  /// not kept: re-importing the same deck should produce a second, separate
  /// copy the user can delete, not silently merge into the first.
  final int id;

  /// Deck name as Anki had it, with `::` still separating subdeck levels.
  final String name;

  /// File the deck was read out of, shown so a user with several similar
  /// decks can tell which import is which.
  final String source;

  final DateTime importedAt;
  final int noteCount;

  /// The last component of a nested name — `Core 2k::Stage 3` displays as
  /// "Stage 3" with "Core 2k" as the parent.
  String get leafName {
    final parts = name.split('::');
    return parts.isEmpty ? name : parts.last;
  }

  String? get parentName {
    final parts = name.split('::');
    return parts.length > 1 ? parts.sublist(0, parts.length - 1).join(' · ') : null;
  }
}

/// One imported note: its fields, already cleaned to plain text.
///
/// Anki's own unit is the *card* (a note rendered through one template), but a
/// note's cards all draw on the same fields, so importing cards would list the
/// same Japanese two or three times over. The rows here are notes.
class AnkiNote {
  const AnkiNote({
    required this.id,
    required this.deckId,
    required this.fields,
    required this.fieldNames,
    required this.tags,
  });

  final int id;
  final int deckId;

  /// Field values in note-type order, HTML and furigana already stripped by
  /// [AnkiFieldText] at import time.
  final List<String> fields;

  /// Names from the note type, parallel to [fields]. Empty when the export
  /// didn't carry them — a plain-text export without a `#columns:` header has
  /// no field names anywhere in it.
  final List<String> fieldNames;

  final String tags;

  /// Label for the field at [index], falling back to a position when the
  /// note type's names weren't available.
  String labelFor(int index) {
    if (index < fieldNames.length && fieldNames[index].trim().isNotEmpty) {
      return fieldNames[index];
    }
    return 'Field ${index + 1}';
  }

  /// The field the deck list shows as the row heading: the first one with
  /// Japanese in it.
  ///
  /// Not simply `fields.first` — plenty of note types lead with a sort field,
  /// an id, or the English side, and a list of English headings would make a
  /// Japanese deck unrecognisable at a glance.
  String get heading {
    for (final field in fields) {
      if (field.isNotEmpty && JpText.hasJapanese(field)) return field;
    }
    return fields.firstWhere((f) => f.isNotEmpty, orElse: () => '');
  }

  /// The rest of the note, for the row's second line.
  String get subheading {
    final head = heading;
    final rest = fields.where((f) => f.isNotEmpty && f != head);
    return rest.join(' · ');
  }

  /// Every field that has Japanese in it, in note-type order, paired with its
  /// index so the card view can label them.
  ///
  /// Fields are kept **separate** rather than joined into one string: the
  /// segmenter's longest-match pass has no idea where a field ended, so
  /// concatenating an expression field onto a notes field invites a match
  /// straddling two unrelated pieces of text.
  List<MapEntry<int, String>> get japaneseFields {
    final out = <MapEntry<int, String>>[];
    for (var i = 0; i < fields.length; i++) {
      if (fields[i].isNotEmpty && JpText.hasJapanese(fields[i])) {
        out.add(MapEntry(i, fields[i]));
      }
    }
    return out;
  }

  bool get hasJapanese => japaneseFields.isNotEmpty;

  /// The fields the card's word list is built from — [japaneseFields] minus
  /// the ones that are only a reading of another field.
  ///
  /// Note types overwhelmingly carry the same content twice: 昨日は寒かった
  /// です in an expression field, きのうはさむかったです in a reading field.
  /// Mining both is not merely redundant, it is actively wrong. Kana-only text
  /// has no ideographs to anchor a boundary, so greedy longest-match splits
  /// きのうはさむかったです into きのう + はさむ + …, and the card confidently
  /// offers 機能 "function; facility" and はさむ "to hold between chopsticks"
  /// for a sentence about cold weather. The kanji field gives the right answer
  /// for the same text.
  ///
  /// The rule is structural rather than a list of field names — note types are
  /// user-defined and localised, so "Reading", "かな" and "Furigana" are three
  /// of countless spellings. A field is dropped only when *another* field in
  /// the note carries kanji, so a genuinely kana-only note (a beginner deck of
  /// たべる / to eat) still gets its words.
  ///
  /// The cost is a kana-only field holding real content of its own — a notes
  /// field reading とてもおいしい alongside a kanji expression — which stops
  /// being listed. It does not stop being reachable: every Japanese field
  /// stays tappable per character, which runs the same lookup from wherever
  /// the user points.
  List<MapEntry<int, String>> get lookupFields {
    final japanese = japaneseFields;
    final withKanji =
        japanese.where((f) => JpText.hasKanji(f.value)).toList();
    return withKanji.isEmpty ? japanese : withKanji;
  }

  List<String> get tagList =>
      tags.split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList();
}
