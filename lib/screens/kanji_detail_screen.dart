import 'package:flutter/material.dart';

import '../models/dictionary_entry.dart';
import '../services/database_service.dart';
import '../widgets/entry_badges.dart';
import '../widgets/entry_detail_sheet.dart';
import '../widgets/favourite_button.dart';
import '../widgets/stroke_order_diagram.dart';

/// Everything KANJIDIC2 knows about one character, plus the words written with
/// it — reached by tapping a character in the entry sheet's "Kanji" panel.
///
/// This is a pushed route rather than another bottom sheet on purpose: the
/// compound list is long, and each compound opens a word sheet of its own, so
/// word → kanji → word needs a real navigation stack for Back to unwind.
///
/// Radicals, components and "similar kanji" are the obvious things missing
/// against a full kanji dictionary. They aren't oversights — `scripts/
/// build_kanji_db.py` doesn't import KANJIDIC2's radical fields, and component
/// decomposition isn't in KANJIDIC2 at all. Adding them means a re-import and a
/// `DatabaseService._dbVersion` bump.
class KanjiDetailScreen extends StatefulWidget {
  const KanjiDetailScreen({super.key, required this.kanji});

  final KanjiEntry kanji;

  @override
  State<KanjiDetailScreen> createState() => _KanjiDetailScreenState();
}

class _KanjiDetailScreenState extends State<KanjiDetailScreen> {
  late final Future<List<DictionaryEntry>> _compounds;

  @override
  void initState() {
    super.initState();
    _compounds = DatabaseService().getCompoundsFor(widget.kanji.literal);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final kanji = widget.kanji;

    return Scaffold(
      appBar: AppBar(
        title: Text(kanji.literal),
        backgroundColor: theme.colorScheme.primaryContainer,
        actions: [
          FavouriteButton(favouriteKey: 'k:${kanji.literal}'),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: [
          _buildHeader(context),
          const SizedBox(height: 24),
          _sectionTitle(context, 'Info'),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (kanji.strokeCount != null)
                InfoChip(label: '${kanji.strokeCount} strokes'),
              if (kanji.gradeLabel != null) InfoChip(label: kanji.gradeLabel!),
              // Newspaper frequency rank — only ~2,500 characters have one, and
              // "unranked" isn't a rank, so no chip at all when it's null.
              if (kanji.freq != null)
                InfoChip(label: 'Frequency #${kanji.freq}'),
              // Spelled out because this is the pre-2010 four-level exam, a
              // different scale from the N5–N1 badge on words.
              if (kanji.jlptOld != null)
                InfoChip(label: 'Old JLPT level ${kanji.jlptOld}'),
            ],
          ),
          const SizedBox(height: 24),
          _sectionTitle(context, 'Compounds'),
          const SizedBox(height: 8),
          _buildCompounds(context),
        ],
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    final theme = Theme.of(context);
    final kanji = widget.kanji;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                KanjiStrokeView(literal: kanji.literal, size: 132),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        kanji.meanings,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 12),
                      // Kun before on, as kanji dictionaries print them.
                      _readingRow(context, 'Kun', kanji.kunReadings),
                      _readingRow(
                        context,
                        'On',
                        kanji.onReadings,
                        color: theme.colorScheme.primary,
                      ),
                      _readingRow(context, 'Nanori', kanji.nanori),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'Tap the diagram to replay the stroke order.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// One labelled line of readings, or nothing at all — most characters have no
  /// nanori, and plenty have only one of kun/on.
  Widget _readingRow(
    BuildContext context,
    String label,
    String? readings, {
    Color? color,
  }) {
    if (readings == null || readings.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: RichText(
        text: TextSpan(
          style: theme.textTheme.bodyMedium,
          children: [
            TextSpan(
              text: '$label  ',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            TextSpan(text: readings, style: TextStyle(color: color)),
          ],
        ),
      ),
    );
  }

  Widget _buildCompounds(BuildContext context) {
    return FutureBuilder<List<DictionaryEntry>>(
      future: _compounds,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Center(child: CircularProgressIndicator()),
          );
        }
        final compounds = snapshot.data ?? const <DictionaryEntry>[];
        if (compounds.isEmpty) {
          return Text(
            'No dictionary words use this character.',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: compounds.map((e) => _compoundRow(context, e)).toList(),
        );
      },
    );
  }

  Widget _compoundRow(BuildContext context, DictionaryEntry entry) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: () => showEntryDetailSheet(context, entry),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Flexible(
                  child: RichText(
                    text: TextSpan(
                      style: theme.textTheme.titleMedium,
                      children: [
                        TextSpan(
                          text: entry.term,
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                        if (entry.reading != null && entry.reading!.isNotEmpty)
                          TextSpan(
                            text: '  【${entry.reading}】',
                            style: TextStyle(color: theme.colorScheme.primary),
                          ),
                      ],
                    ),
                  ),
                ),
                if (entry.isCommon) ...[
                  const SizedBox(width: 8),
                  const CommonBadge(),
                ],
                if (entry.jlpt != null) ...[
                  const SizedBox(width: 6),
                  JlptBadge(level: entry.jlpt!),
                ],
              ],
            ),
            const SizedBox(height: 2),
            Text(
              // One line per word: the senses joined back up, since this is a
              // browsing list, not the entry itself.
              entry.glossList.join('; '),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sectionTitle(BuildContext context, String text) {
    return Text(
      text,
      style: Theme.of(context).textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.bold,
          ),
    );
  }
}
