import 'package:flutter/material.dart';

import '../models/dictionary_entry.dart';
import '../screens/kanji_detail_screen.dart';
import '../services/database_service.dart';
import 'kanji_summary_card.dart';

/// Opens the detail sheet for a proper name.
///
/// Separate from [showEntryDetailSheet] rather than a flag on it, for the same
/// reason `searchNames` is a separate query: a JMnedict row has no parts of
/// speech, no JLPT level, no common-word flag and no example sentences, so
/// half that sheet would render as empty space. What it *does* share is the
/// per-character breakdown — `kanji` is keyed by character and comes from
/// KANJIDIC2, which knows nothing about which dictionary sent the word, so 任
/// 天 堂 resolve exactly as they would in an ordinary entry. That is the whole
/// point of making these tappable: 任天堂 is precisely the kind of word a
/// learner meets on a sign and wants the characters of.
Future<void> showNameDetailSheet(BuildContext context, NameEntry name) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (context) => NameDetailSheet(name: name),
  );
}

class NameDetailSheet extends StatefulWidget {
  const NameDetailSheet({super.key, required this.name});

  final NameEntry name;

  @override
  State<NameDetailSheet> createState() => _NameDetailSheetState();
}

class _NameDetailSheetState extends State<NameDetailSheet> {
  final DatabaseService _db = DatabaseService();

  /// Started once here, not inline in the [FutureBuilder]s: the sheet's
  /// builder re-runs on every drag frame, which would otherwise fire a fresh
  /// query each time the user resized it. Same trap as [EntryDetailSheet].
  late final Future<List<KanjiEntry>> _kanji;
  late final Future<List<NameEntry>> _spellings;

  @override
  void initState() {
    super.initState();
    _kanji = _db.getKanjiForTerm(widget.name.term);
    _spellings = _db.getNamesBySequence(widget.name.sequence);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final name = widget.name;
    final reading = name.displayReading;
    final glosses = name.glossList;

    // Sized by whether there is a kanji panel coming. A JMnedict row is
    // otherwise three lines long, and ゴジラ opening at the same height as
    // 任天堂 is two thirds empty sheet. Decided synchronously from the term —
    // waiting for the query would open small and then jump.
    final hasKanji = DatabaseService.extractKanji(name.term).isNotEmpty;
    return DraggableScrollableSheet(
      initialChildSize: hasKanji ? 0.7 : 0.4,
      minChildSize: 0.3,
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
                Text(
                  name.term,
                  style: theme.textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                if (reading != null)
                  Text(
                    reading,
                    style: theme.textTheme.titleLarge?.copyWith(
                      color: theme.colorScheme.primary,
                    ),
                  ),
                // Every type tag here, unlike the result card, which shows only
                // the first so the name itself keeps the row: ゴジラ is a
                // `char` *and* a `work`, and the sheet has room to say so.
                if (name.typeLabels.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: name.typeLabels
                        .map((label) => Chip(label: Text(label)))
                        .toList(),
                  ),
                ],
                const SizedBox(height: 16),
                Text(
                  glosses.length > 1 ? 'Translations' : 'Translation',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                ...glosses.asMap().entries.map((e) {
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${e.key + 1}. ',
                          style: theme.textTheme.bodyLarge?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Expanded(
                          child: Text(
                            e.value,
                            style: theme.textTheme.bodyLarge,
                          ),
                        ),
                      ],
                    ),
                  );
                }),
                _buildSpellings(context),
                _buildKanji(context),
              ],
            ),
          ),
        );
      },
    );
  }

  /// The other rows sharing this entry's `sequence`.
  ///
  /// Search collapses spellings to one card, so ニンテンドウ is found by
  /// searching for it and then never shown — this is the only place the app
  /// can say that the two are the same entry.
  Widget _buildSpellings(BuildContext context) {
    final theme = Theme.of(context);
    return FutureBuilder<List<NameEntry>>(
      future: _spellings,
      builder: (context, snapshot) {
        final others = (snapshot.data ?? const <NameEntry>[])
            .where((n) => n.term != widget.name.term)
            .toList();
        if (others.isEmpty) return const SizedBox.shrink();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 8),
            Text(
              'Also written',
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: others.map((other) {
                final otherReading = other.displayReading;
                return ActionChip(
                  label: Text(
                    otherReading == null
                        ? other.term
                        : '${other.term}　$otherReading',
                  ),
                  // Replaces the sheet rather than stacking a second one on
                  // top: these are spellings of the same name, not a step
                  // deeper into the dictionary, so Back should return to the
                  // results list either way.
                  onPressed: () {
                    // The navigator is captured first: `context` here belongs
                    // to the sheet being popped, and reusing it to open the
                    // replacement leans on the pop animation not having
                    // unmounted it yet.
                    final navigator = Navigator.of(context);
                    navigator.pop();
                    showNameDetailSheet(navigator.context, other);
                  },
                );
              }).toList(),
            ),
          ],
        );
      },
    );
  }

  /// Per-character breakdown, identical to the entry sheet's "Kanji" panel and
  /// deliberately so — a name's characters are ordinary kanji, and the whole
  /// reason to open this sheet is usually to read them.
  Widget _buildKanji(BuildContext context) {
    return FutureBuilder<List<KanjiEntry>>(
      future: _kanji,
      builder: (context, snapshot) {
        final kanji = snapshot.data ?? const <KanjiEntry>[];
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
}
