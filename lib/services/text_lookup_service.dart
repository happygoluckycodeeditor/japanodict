import '../models/dictionary_entry.dart';
import '../utils/deinflect.dart';
import '../utils/jp_text.dart';
import 'database_service.dart';

/// One word found in running text, with the entries that confirm it.
class TokenMatch {
  const TokenMatch({
    required this.surface,
    required this.start,
    required this.entries,
    required this.reasons,
  });

  /// The text exactly as it was written — 食べました, not 食べる. Shown as the
  /// heading so the user can see what was matched in the image.
  final String surface;

  /// UTF-16 offset of [surface] within the line it came from.
  final int start;

  /// Confirmed entries, best first. More than one is normal and not an
  /// error: 待って alone genuinely could be 待つ or 待つ's homographs, and the
  /// scanner has no context to choose with.
  final List<DictionaryEntry> entries;

  /// Inflections stripped to reach [entries], outermost first — `['polite
  /// past']` for 食べました. Empty when the word was already in dictionary
  /// form.
  final List<String> reasons;

  int get end => start + surface.length;

  /// True when the word was written in a form other than the one the
  /// dictionary lists, so the UI can show "食べました → 食べる".
  bool get isInflected => reasons.isNotEmpty;

  DictionaryEntry get best => entries.first;
}

/// Finds dictionary words inside unspaced Japanese text.
///
/// The strategy is Yomitan's rather than a segmenter's: from a given
/// position, try the longest substring first and shorten until one deinflects
/// to something the dictionary confirms. That means no morphological analyser
/// and no extra asset — but it also means matches are local guesses with no
/// sentence context, so [segment] can mis-split in ways a real tokeniser
/// wouldn't. Tapping an individual character is the escape hatch.
class TextLookupService {
  TextLookupService([DatabaseService? database])
      : _db = database ?? DatabaseService();

  final DatabaseService _db;

  /// Longest word starting at [index] in [text], or null if nothing matches.
  ///
  /// Every substring length is deinflected up front and looked up in a single
  /// query, so one tap is one database round trip rather than a dozen.
  Future<TokenMatch?> lookupAt(String text, int index) async {
    if (index < 0 || index >= text.length) return null;
    final runLength = JpText.wordRunLength(text, index);
    if (runLength == 0) return null;

    // Candidate dictionary form -> the hypotheses that proposed it. One form
    // can arrive from several substring lengths at once (食べ and 食べる both
    // propose 食べる), so the longest surviving surface wins later.
    final hypotheses = <String, List<_Hypothesis>>{};
    for (var length = runLength; length >= 1; length--) {
      final surface = text.substring(index, index + length);
      for (final deinflection in Deinflector.deinflect(surface)) {
        (hypotheses[deinflection.term] ??= []).add(
          _Hypothesis(surface: surface, deinflection: deinflection),
        );
      }
    }

    final rows = await _db.lookupTerms(hypotheses.keys);
    if (rows.isEmpty) return null;

    // Confirm each row against the hypotheses that could have produced it,
    // keeping the longest surface it justifies. A row is reachable by its
    // written form or its reading, and the two can differ in length.
    final confirmed = <_Confirmation>[];
    for (final entry in rows) {
      final entryRules = Deinflector.rulesForPartsOfSpeech(entry.partsOfSpeech);
      _Hypothesis? bestFor;
      for (final key in [entry.term, entry.reading]) {
        if (key == null) continue;
        for (final hypothesis in hypotheses[key] ?? const <_Hypothesis>[]) {
          if (!hypothesis.deinflection.acceptsEntry(entryRules)) continue;
          if (bestFor == null || hypothesis.isBetterThan(bestFor)) {
            bestFor = hypothesis;
          }
        }
      }
      if (bestFor != null) {
        confirmed.add(_Confirmation(entry: entry, hypothesis: bestFor));
      }
    }
    if (confirmed.isEmpty) return null;

    // Longest match wins outright — 食べました must beat the 食べ that the
    // shorter substrings also confirm, or every verb would truncate to its
    // stem.
    final longest = confirmed
        .map((c) => c.hypothesis.surface.length)
        .reduce((a, b) => a > b ? a : b);
    final winners = confirmed
        .where((c) => c.hypothesis.surface.length == longest)
        .toList();

    // Within one surface, prefer the least contrived derivation, then let the
    // dictionary's own common/score ordering decide — the same precedence
    // search uses, so the everyday word lands first.
    winners.sort((a, b) {
      final byReasons = a.hypothesis.deinflection.reasons.length
          .compareTo(b.hypothesis.deinflection.reasons.length);
      if (byReasons != 0) return byReasons;
      final byCommon = (b.entry.isCommon ? 1 : 0) - (a.entry.isCommon ? 1 : 0);
      if (byCommon != 0) return byCommon;
      return (b.entry.score ?? 0).compareTo(a.entry.score ?? 0);
    });

    return TokenMatch(
      surface: winners.first.hypothesis.surface,
      start: index,
      entries: winners.map((w) => w.entry).toList(),
      reasons: winners.first.hypothesis.deinflection.reasons,
    );
  }

  /// Greedily splits [line] into the words it can confirm, left to right.
  ///
  /// Characters that match nothing are skipped rather than reported — OCR
  /// output contains punctuation, stray Latin and the occasional
  /// misrecognised glyph, and a list of failures would bury the words.
  ///
  /// Greedy longest-match has no lookahead, so a wrong long match can eat the
  /// start of the next word. That is the accepted cost of not shipping a
  /// morphological analyser; the per-character tap path exists for when it
  /// gets one wrong.
  Future<List<TokenMatch>> segment(String line) async {
    final matches = <TokenMatch>[];
    var index = JpText.nextWordStart(line, 0);
    while (index >= 0 && index < line.length) {
      final match = await lookupAt(line, index);
      if (match == null) {
        index = JpText.nextWordStart(line, index + 1);
        continue;
      }
      matches.add(match);
      index = JpText.nextWordStart(line, match.end);
    }
    return matches;
  }
}

class _Hypothesis {
  const _Hypothesis({required this.surface, required this.deinflection});

  final String surface;
  final Deinflection deinflection;

  /// Longer surfaces win; ties go to the derivation that assumed less.
  bool isBetterThan(_Hypothesis other) {
    if (surface.length != other.surface.length) {
      return surface.length > other.surface.length;
    }
    return deinflection.reasons.length < other.deinflection.reasons.length;
  }
}

class _Confirmation {
  const _Confirmation({required this.entry, required this.hypothesis});

  final DictionaryEntry entry;
  final _Hypothesis hypothesis;
}
