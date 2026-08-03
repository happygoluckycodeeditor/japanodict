import 'package:flutter/material.dart';

/// Attribution for the bundled data sources.
///
/// This screen is a licensing requirement, not a nicety: JMdict/Jitendex,
/// KANJIDIC2 and KanjiVG are all CC BY-SA, which permits commercial use but
/// obliges the app to credit them. Share-alike binds the *data*, not this
/// app's source, so shipping closed-source is fine as long as these credits
/// remain reachable in the released build.
class CreditsScreen extends StatelessWidget {
  const CreditsScreen({super.key});

  static const _sources = <_DataSource>[
    _DataSource(
      name: 'Jitendex / JMdict',
      description:
          'Japanese-English dictionary entries, readings and example sentences.',
      copyright: '© The Electronic Dictionary Research and Development Group',
      licence: 'CC BY-SA 4.0',
      url: 'https://jitendex.org',
    ),
    _DataSource(
      name: 'KANJIDIC2',
      description:
          'Per-character kanji data: meanings, on/kun readings, stroke '
          'counts, grades and frequency ranks.',
      copyright: '© Jim Breen and the EDRDG',
      licence: 'CC BY-SA 4.0',
      url: 'https://www.edrdg.org/wiki/index.php/KANJIDIC_Project',
    ),
    _DataSource(
      name: 'KanjiVG',
      description: 'Stroke-order outlines used by the animated diagrams.',
      copyright: '© Ulrich Apel',
      licence: 'CC BY-SA 3.0',
      url: 'https://kanjivg.tagaini.net',
    ),
    _DataSource(
      name: 'Tatoeba',
      description: 'Example sentences and their translations.',
      copyright: '© Tatoeba contributors',
      licence: 'CC BY 2.0 FR',
      url: 'https://tatoeba.org',
    ),
    _DataSource(
      name: 'JLPT vocabulary lists',
      description:
          'Unofficial community JLPT level tags — the JLPT organisation '
          'stopped publishing official vocabulary lists after 2010.',
      copyright: '© Tanos / community contributors',
      licence: 'MIT',
      url: 'https://www.tanos.co.uk/jlpt/',
    ),
    _DataSource(
      name: 'ML Kit Digital Ink Recognition',
      description:
          'On-device handwriting recognition for the draw pad. Strokes are '
          'processed on your device and are never sent to a server.',
      copyright: '© Google LLC',
      licence: 'Google APIs Terms of Service',
      url: 'https://developers.google.com/ml-kit',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Credits & Licences')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            'JapanoDict is built on open Japanese language data. '
            'Thank you to everyone who maintains it.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 20),
          ..._sources.map((source) => _buildSource(context, source)),
          const SizedBox(height: 8),
          Text(
            'CC BY-SA applies to the dictionary data itself. Modified data '
            'redistributed from this app must carry the same licence.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSource(BuildContext context, _DataSource source) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    source.name,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.secondaryContainer,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    source.licence,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSecondaryContainer,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(source.description, style: theme.textTheme.bodyMedium),
            const SizedBox(height: 8),
            Text(
              source.copyright,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            // Shown as plain text rather than a link: opening URLs would mean
            // adding url_launcher, and the address is what attribution
            // actually requires.
            SelectableText(
              source.url,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.primary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DataSource {
  const _DataSource({
    required this.name,
    required this.description,
    required this.copyright,
    required this.licence,
    required this.url,
  });

  final String name;
  final String description;
  final String copyright;
  final String licence;
  final String url;
}
