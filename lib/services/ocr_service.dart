import 'dart:ui' show Rect;

import 'package:flutter/foundation.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

/// One recognised line of text and where it sits in the source image.
///
/// Lines, not words, are the unit the OCR screen draws boxes for. ML Kit does
/// expose a finer `TextElement` level, but its element boundaries in Japanese
/// are not word boundaries — it splits an unspaced run at essentially
/// arbitrary points, so a box per element would promise a segmentation the
/// recogniser never actually performed. Word boundaries come from
/// [TextLookupService] instead, which has the dictionary to check against.
class OcrLine {
  const OcrLine({required this.text, required this.boundingBox});

  final String text;

  /// Bounds in **source-image pixel coordinates**, not screen coordinates.
  /// The screen maps them through the same fit it used to display the image.
  final Rect boundingBox;
}

/// Result of recognising one still image.
class OcrResult {
  const OcrResult({required this.lines});

  final List<OcrLine> lines;

  bool get isEmpty => lines.isEmpty;
}

/// Wraps ML Kit Text Recognition for the scan-a-photo lookup.
///
/// On-device and offline: unlike the handwriting ink model, the Japanese text
/// model is compiled into the APK (see `android/app/build.gradle.kts`), so
/// there is no download step, no Play-services dependency, and nothing to
/// show a "model unavailable" state for. Images never leave the phone.
///
/// Singleton for the same reason [HandwritingService] is — the native
/// recogniser is expensive to construct and is reused across scans.
class OcrService {
  static final OcrService _instance = OcrService._internal();

  factory OcrService() => _instance;

  OcrService._internal();

  TextRecognizer? _recognizer;

  /// Recognises Japanese text in the image at [path].
  ///
  /// Returns an empty result rather than throwing when recognition fails —
  /// to the user, "nothing was found in this photo" and "the recogniser
  /// errored" are the same dead end, and the screen offers the same retry.
  Future<OcrResult> recognizeFile(String path) async {
    try {
      final recognizer =
          _recognizer ??= TextRecognizer(script: TextRecognitionScript.japanese);
      final recognized = await recognizer.processImage(
        InputImage.fromFilePath(path),
      );

      final lines = <OcrLine>[];
      for (final block in recognized.blocks) {
        for (final line in block.lines) {
          final text = line.text.trim();
          if (text.isEmpty) continue;
          lines.add(OcrLine(text: text, boundingBox: line.boundingBox));
        }
      }
      return OcrResult(lines: lines);
    } catch (e) {
      debugPrint('OcrService: recognition failed: $e');
      return const OcrResult(lines: []);
    }
  }

  /// Releases the native recogniser.
  Future<void> dispose() async {
    await _recognizer?.close();
    _recognizer = null;
  }
}
