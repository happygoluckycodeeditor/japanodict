import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:japanodict/utils/svg_path.dart';

/// Bounds of a KanjiVG stroke should land inside its 109x109 viewBox. A
/// parser that mishandles relative coordinates typically drifts far outside
/// it, so this catches the most likely class of bug.
void expectWithinViewBox(Path path, {double slack = 2.0}) {
  final bounds = path.getBounds();
  expect(bounds.left, greaterThanOrEqualTo(-slack));
  expect(bounds.top, greaterThanOrEqualTo(-slack));
  expect(bounds.right, lessThanOrEqualTo(109.0 + slack));
  expect(bounds.bottom, lessThanOrEqualTo(109.0 + slack));
}

void main() {
  test('parses an absolute moveto followed by relative cubics', () {
    // First stroke of 三 (KanjiVG 04e09-s1).
    final path = parseKanjiVgPath(
      'M27.5,23.65c3.09,0.73,6.29,0.36,9.4,0.06c10.2-1,27-2.94,'
      '38.97-3.57c3.06-0.16,6.09-0.2,9.14,0.23',
    );
    final bounds = path.getBounds();

    // Starts at the moveto and ends near the right side of the glyph.
    expect(bounds.left, closeTo(27.5, 0.5));
    expectWithinViewBox(path);
    expect(bounds.width, greaterThan(50));
    // A horizontal stroke should be wide and flat.
    expect(bounds.height, lessThan(10));
  });

  test('relative cubics accumulate from the current point', () {
    // Two chained relative cubics: the second must start where the first
    // ended (10,10), not back at the origin.
    final path = parseKanjiVgPath('M0,0c0,0,5,0,10,10c0,0,5,0,10,10');
    final bounds = path.getBounds();
    expect(bounds.right, closeTo(20, 0.01));
    expect(bounds.bottom, closeTo(20, 0.01));
  });

  test('implicitly repeated cubics reuse the previous command', () {
    final explicit = parseKanjiVgPath('M0,0c0,0,5,0,10,10c0,0,5,0,10,10');
    final implicit = parseKanjiVgPath('M0,0c0,0,5,0,10,10,0,0,5,0,10,10');
    expect(implicit.getBounds(), equals(explicit.getBounds()));
  });

  test('handles numbers run together by a minus sign', () {
    // "0.36,9.4-0.06" is three numbers with no separator before -0.06.
    final path = parseKanjiVgPath('M10,10c1,2,0.36,9.4-0.06,12');
    expect(path.getBounds().isEmpty, isFalse);
  });

  test('smooth cubic reflects the previous control point', () {
    // S with a preceding C should curve symmetrically; verify it advances to
    // the stated endpoint rather than collapsing.
    final path = parseKanjiVgPath('M0,0C10,0,20,10,30,10S50,20,60,20');
    final bounds = path.getBounds();
    expect(bounds.right, closeTo(60, 0.01));
    expect(bounds.bottom, closeTo(20, 0.01));
  });

  test('real KanjiVG strokes all stay inside the viewBox', () {
    // A spread of characters: simple, complex, and one with many strokes.
    const samples = <String>[
      // 三 stroke 3
      'M13,87.83c3.94,1.01,7.72,0.96,11.75,0.72c18.41-1.07,41.27-3.39,'
          '61.12-4.07c3.63-0.13,7.2-0.1,10.75,0.78',
      // 日 stroke 1
      'M31.5,24.5c1.12,1.12,1.74,2.75,1.74,4.75c0,1.6-0.16,38.11-0.24,'
          '55.5c-0.01,3.11-0.01,5.42-0.01,6.5',
      // 王 stroke 1
      'M29.5,21.22c2.7,0.62,5.55,0.08,8.24-0.28c10.59-1.42,22.63-2.85,'
          '32.51-3.62c2.52-0.2,5.01-0.32,7.5,0.19',
    ];

    for (final d in samples) {
      final path = parseKanjiVgPath(d);
      expect(path.getBounds().isEmpty, isFalse, reason: 'empty path for: $d');
      expectWithinViewBox(path);
    }
  });

  test('unknown commands do not hang the parser', () {
    // Arcs never appear in KanjiVG, but a malformed string must still
    // terminate rather than spin.
    final path = parseKanjiVgPath('M0,0A5,5,0,0,1,10,10z');
    expect(path, isA<Path>());
  });

  test('empty input yields an empty path', () {
    expect(parseKanjiVgPath('').getBounds().isEmpty, isTrue);
  });
}
