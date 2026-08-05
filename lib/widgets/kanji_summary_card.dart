import 'package:flutter/material.dart';

import '../models/dictionary_entry.dart';
import 'entry_badges.dart';
import 'stroke_order_diagram.dart';

/// One character of a word, as it appears in the entry sheet's "Kanji" panel:
/// stroke-order animation, meanings, readings and a few facts.
///
/// Tapping opens the full kanji screen — the card itself doesn't know that, so
/// the same card can stay inert where there's nowhere to go.
class KanjiSummaryCard extends StatelessWidget {
  const KanjiSummaryCard({super.key, required this.kanji, this.onTap});

  final KanjiEntry kanji;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(12.0),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              KanjiStrokeView(literal: kanji.literal),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      kanji.meanings,
                      style: theme.textTheme.bodyLarge?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    // Kun before on, matching how kanji dictionaries print them.
                    if (kanji.kunReadings != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          kanji.kunReadings!,
                          style: theme.textTheme.bodyMedium,
                        ),
                      ),
                    if (kanji.onReadings != null)
                      Text(
                        kanji.onReadings!,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.primary,
                        ),
                      ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: [
                        if (kanji.strokeCount != null)
                          InfoChip(label: '${kanji.strokeCount} strokes'),
                        // Only grades 1–6 are a meaningful "taught in year N";
                        // 8/9/10 are set membership, not a year.
                        if (kanji.isKyoiku)
                          InfoChip(label: 'grade ${kanji.grade}'),
                        if (kanji.freq != null)
                          InfoChip(label: 'freq #${kanji.freq}'),
                      ],
                    ),
                  ],
                ),
              ),
              if (onTap != null)
                Icon(
                  Icons.chevron_right,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
            ],
          ),
        ),
      ),
    );
  }
}
