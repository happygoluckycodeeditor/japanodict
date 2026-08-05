import 'package:flutter/material.dart';

/// The small labels that sit next to a headword or a kanji.
///
/// They live here rather than in one screen because the same three now appear
/// on the results list, the entry sheet and the kanji screen, and a "common"
/// flag that is green in one place and grey in another reads as two different
/// things.

/// Jisho's "common word" flag — set at *sequence* level, so a rare spelling of
/// an everyday word carries it too.
class CommonBadge extends StatelessWidget {
  const CommonBadge({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: const Color(0xFF8DC63F),
        borderRadius: BorderRadius.circular(4),
      ),
      child: const Text(
        'common',
        style: TextStyle(
          color: Colors.white,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// A vocabulary JLPT level (`N5`…`N1`) from the Tanos word lists.
///
/// Only ever for `DictionaryEntry.jlpt`. The `kanji` table's `jlpt_old` is the
/// pre-2010 four-level scale and must not be drawn with this badge.
class JlptBadge extends StatelessWidget {
  const JlptBadge({super.key, required this.level});

  final String level;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: const Color(0xFF909DC0),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        level.toLowerCase(),
        style: const TextStyle(
          color: Colors.white,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// Neutral pill for a plain fact about a character (stroke count, grade,
/// frequency rank) — deliberately unlike the coloured badges above, which say
/// something about how worth learning a word is.
class InfoChip extends StatelessWidget {
  const InfoChip({super.key, required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}
