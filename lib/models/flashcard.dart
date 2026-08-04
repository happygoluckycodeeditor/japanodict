import 'dictionary_entry.dart';

/// Which of the two independent data sources a deck is drawn from.
///
/// Vocabulary decks come from `dictionary` (JLPT N1–N5, from the Tanos word
/// lists); kanji decks come from `kanji` (KANJIDIC2 school grades). These are
/// *not* the same scale and deliberately aren't mixed inside one deck — see
/// the note on [Deck.kanjiDecks].
enum DeckKind { vocab, kanji }

/// A named, countable set of cards shown on the deck picker.
class Deck {
  const Deck({
    required this.id,
    required this.kind,
    required this.title,
    required this.subtitle,
    this.count = 0,
  });

  /// Stable identifier, also used as the query key: `N5`, `grade:1`,
  /// `grade:8`, `grade:9`, or [favouritesId].
  final String id;
  final DeckKind kind;
  final String title;
  final String subtitle;

  /// Number of cards, filled in from the database by
  /// `DatabaseService.getDeckCounts`. Decks with no cards aren't shown.
  final int count;

  static const String favouritesId = 'favourites';

  Deck withCount(int value) => Deck(
        id: id,
        kind: kind,
        title: title,
        subtitle: subtitle,
        count: value,
      );

  /// JLPT vocabulary decks, easiest first.
  ///
  /// N5→N1 rather than N1→N5: the levels count *down* as difficulty goes up,
  /// so listing them in numeric order would put the hardest deck at the top.
  static const List<Deck> vocabDecks = [
    Deck(id: 'N5', kind: DeckKind.vocab, title: 'N5', subtitle: 'Beginner vocabulary'),
    Deck(id: 'N4', kind: DeckKind.vocab, title: 'N4', subtitle: 'Upper beginner'),
    Deck(id: 'N3', kind: DeckKind.vocab, title: 'N3', subtitle: 'Intermediate'),
    Deck(id: 'N2', kind: DeckKind.vocab, title: 'N2', subtitle: 'Upper intermediate'),
    Deck(id: 'N1', kind: DeckKind.vocab, title: 'N1', subtitle: 'Advanced'),
  ];

  /// Kanji decks by KANJIDIC2 school grade, **not** by JLPT level.
  ///
  /// KANJIDIC2 has no N1–N5 figure — its only JLPT column (`jlpt_old`) is the
  /// pre-2010 four-level scale and covers barely a fifth of the characters, so
  /// labelling these decks "N5" would be quietly wrong. `grade` is the
  /// official MEXT curriculum data and is complete, so it's what these decks
  /// use until a real per-character N1–N5 list is imported.
  ///
  /// Grades 1–6 are the kyōiku kanji (one deck per school year); 8 is the
  /// remainder of the jōyō set; 9 and 10 are jinmeiyō (name-use) kanji and are
  /// merged, since the split between them isn't a difficulty distinction.
  static const List<Deck> kanjiDecks = [
    Deck(id: 'grade:1', kind: DeckKind.kanji, title: 'Grade 1', subtitle: 'First school year'),
    Deck(id: 'grade:2', kind: DeckKind.kanji, title: 'Grade 2', subtitle: 'Second school year'),
    Deck(id: 'grade:3', kind: DeckKind.kanji, title: 'Grade 3', subtitle: 'Third school year'),
    Deck(id: 'grade:4', kind: DeckKind.kanji, title: 'Grade 4', subtitle: 'Fourth school year'),
    Deck(id: 'grade:5', kind: DeckKind.kanji, title: 'Grade 5', subtitle: 'Fifth school year'),
    Deck(id: 'grade:6', kind: DeckKind.kanji, title: 'Grade 6', subtitle: 'Sixth school year'),
    Deck(id: 'grade:8', kind: DeckKind.kanji, title: 'Jōyō', subtitle: 'Rest of the general-use set'),
    Deck(id: 'grade:9', kind: DeckKind.kanji, title: 'Jinmeiyō', subtitle: 'Additional name-use kanji'),
  ];
}

/// One card in a session.
///
/// Holds the whole source row rather than pre-rendered strings so the back of
/// the card can show everything the detail sheet does — readings, parts of
/// speech, stroke order — without a second lookup.
class Flashcard {
  const Flashcard._({
    required this.kind,
    required this.favouriteKey,
    this.entry,
    this.kanji,
  });

  factory Flashcard.vocab(DictionaryEntry entry) => Flashcard._(
        kind: DeckKind.vocab,
        // Keyed by sequence, not row id: a word's rare kanji spellings are
        // separate rows sharing one sequence, and starring 車 shouldn't leave
        // its alternate spellings unstarred.
        favouriteKey: 'v:${entry.sequence}',
        entry: entry,
      );

  factory Flashcard.kanji(KanjiEntry kanji) => Flashcard._(
        kind: DeckKind.kanji,
        favouriteKey: 'k:${kanji.literal}',
        kanji: kanji,
      );

  final DeckKind kind;

  /// Stable across database rebuilds — `sequence` and `literal` are both
  /// upstream identifiers, unlike `dictionary.id`, which is an autoincrement
  /// that shifts every time the importer runs.
  final String favouriteKey;

  final DictionaryEntry? entry;
  final KanjiEntry? kanji;

  /// The prompt side of the card: the word, or the character.
  String get front => kind == DeckKind.vocab ? entry!.term : kanji!.literal;
}
