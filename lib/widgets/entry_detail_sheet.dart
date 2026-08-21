import 'package:flutter/material.dart';

import '../models/dictionary_entry.dart';
import '../screens/kanji_detail_screen.dart';
import '../services/database_service.dart';
import 'entry_badges.dart';
import 'favourite_button.dart';
import 'kanji_summary_card.dart';

/// Opens the entry detail sheet for [entry].
///
/// Lives outside `HomeScreen` because it is no longer only reachable from
/// search: the kanji screen's compound list opens it too, so word → kanji →
/// word browsing works the way it does in Shirabe Jisho. Each hop is a real
/// route, so Back walks the trail in reverse.
Future<void> showEntryDetailSheet(BuildContext context, DictionaryEntry entry) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (context) => EntryDetailSheet(entry: entry),
  );
}

class EntryDetailSheet extends StatefulWidget {
  const EntryDetailSheet({super.key, required this.entry});

  final DictionaryEntry entry;

  @override
  State<EntryDetailSheet> createState() => _EntryDetailSheetState();
}

class _EntryDetailSheetState extends State<EntryDetailSheet> {
  final DatabaseService _db = DatabaseService();

  /// Started once here rather than inline in the `FutureBuilder`s below: the
  /// sheet's builder re-runs on every drag frame, which would otherwise fire a
  /// fresh kanji and examples query each time the user resized it.
  late final Future<List<KanjiEntry>> _kanji;
  late final Future<List<ExampleSentence>> _examples;

  @override
  void initState() {
    super.initState();
    _kanji = _db.getKanjiForTerm(widget.entry.term);
    _examples = _db.getExamples(widget.entry.id);
  }

  @override
  Widget build(BuildContext context) {
    final entry = widget.entry;
    return DraggableScrollableSheet(
      initialChildSize: 0.7,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      expand: false,
      builder: (context, scrollController) {
        return SingleChildScrollView(
          controller: scrollController,
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    // The term and its badges are grouped inside one `Expanded`
                    // rather than sitting flat beside a `Spacer`. A `Spacer` is
                    // a flex child too, so it would split the free space with
                    // the term and clip long headwords at half the width they
                    // have available.
                    Expanded(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Flexible(
                            child: Text(
                              entry.term,
                              style: Theme.of(context)
                                  .textTheme
                                  .headlineMedium
                                  ?.copyWith(fontWeight: FontWeight.bold),
                            ),
                          ),
                          if (entry.isCommon) ...[
                            const SizedBox(width: 10),
                            const CommonBadge(),
                          ],
                          if (entry.jlpt != null) ...[
                            const SizedBox(width: 6),
                            JlptBadge(level: entry.jlpt!),
                          ],
                        ],
                      ),
                    ),
                    // Only when there's a `sequence` to key on: a star has to
                    // survive a dictionary rebuild, and `id` is an autoincrement
                    // that doesn't. No stable key, no star.
                    if (entry.sequence != null)
                      FavouriteButton(favouriteKey: 'v:${entry.sequence}'),
                  ],
                ),
                if (entry.reading != null && entry.reading!.isNotEmpty)
                  Text(
                    entry.reading!,
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          color: Theme.of(context).colorScheme.primary,
                        ),
                  ),
                const SizedBox(height: 16),
                if (entry.partsOfSpeechList.isNotEmpty) ...[
                  Text(
                    'Parts of Speech',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: entry.partsOfSpeechList
                        .map((pos) => Chip(label: Text(pos)))
                        .toList(),
                  ),
                  const SizedBox(height: 16),
                ],
                Text(
                  'Definitions',
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                ),
                const SizedBox(height: 8),
                ...entry.glossList.asMap().entries.map((e) {
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${e.key + 1}. ',
                          style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                                fontWeight: FontWeight.bold,
                              ),
                        ),
                        Expanded(
                          child: Text(
                            e.value,
                            style: Theme.of(context).textTheme.bodyLarge,
                          ),
                        ),
                      ],
                    ),
                  );
                }),
                _buildKanji(context),
                _buildExamples(context),
                if (entry.tagsList.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  Text(
                    'Tags',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: entry.tagsList.map((tag) {
                      return Chip(
                        label: Text(tag),
                        backgroundColor:
                            Theme.of(context).colorScheme.secondaryContainer,
                      );
                    }).toList(),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  /// Per-character breakdown, mirroring Shirabe Jisho's "Kanji" panel — for a
  /// word like 竜虎, one card per character with its own meanings and
  /// readings. Loaded lazily like examples, so opening a kana-only entry costs
  /// nothing. Each card opens that character's own screen.
  Widget _buildKanji(BuildContext context) {
    return FutureBuilder<List<KanjiEntry>>(
      future: _kanji,
      builder: (context, snapshot) {
        final kanji = snapshot.data ?? const [];
        if (kanji.isEmpty) return const SizedBox.shrink();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 16),
            Text(
              'Kanji',
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
            ),
            const SizedBox(height: 8),
            ...kanji.map((k) => KanjiSummaryCard(
                  kanji: k,
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => KanjiDetailScreen(kanji: k),
                    ),
                  ),
                )),
          ],
        );
      },
    );
  }

  Widget _buildExamples(BuildContext context) {
    return FutureBuilder<List<ExampleSentence>>(
      future: _examples,
      builder: (context, snapshot) {
        final examples = snapshot.data ?? const [];
        if (examples.isEmpty) return const SizedBox.shrink();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 16),
            Text(
              'Examples',
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
            ),
            const SizedBox(height: 8),
            ...examples.map((ex) {
              return Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      ex.ja,
                      style: Theme.of(context).textTheme.bodyLarge,
                    ),
                    if (ex.en.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          ex.en,
                          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant,
                              ),
                        ),
                      ),
                  ],
                ),
              );
            }),
          ],
        );
      },
    );
  }
}
