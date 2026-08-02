import 'dart:ui' show Size;

import 'package:flutter/foundation.dart';
import 'package:google_mlkit_digital_ink_recognition/google_mlkit_digital_ink_recognition.dart';

/// State of the on-device Japanese ink model.
///
/// ML Kit ships the model separately from the APK — it is fetched through
/// Google Play services the first time the user opens the draw pad, so the
/// pad has to render something sensible while that is still in flight.
enum InkModelStatus { unknown, missing, downloading, ready, failed }

/// Wraps ML Kit Digital Ink Recognition for single-character kanji/kana lookup.
///
/// Everything here runs on-device; strokes never leave the phone. The service
/// is a singleton so the model-download check and the native recognizer
/// instance are shared for the lifetime of the app rather than being rebuilt
/// every time the draw pad opens.
class HandwritingService {
  static final HandwritingService _instance = HandwritingService._internal();

  factory HandwritingService() => _instance;

  HandwritingService._internal();

  /// BCP-47 tag for the Japanese ink model. Note this is *not* `ja-JP`; ML Kit
  /// keys its base models on the bare language tag.
  static const String languageCode = 'ja';

  final DigitalInkRecognizerModelManager _modelManager =
      DigitalInkRecognizerModelManager();

  DigitalInkRecognizer? _recognizer;

  /// Broadcast so the draw pad can rebuild as the download progresses.
  final ValueNotifier<InkModelStatus> status =
      ValueNotifier<InkModelStatus>(InkModelStatus.unknown);

  Future<void>? _pendingEnsure;

  /// Downloads the Japanese model if it isn't already present.
  ///
  /// Safe to call repeatedly — concurrent callers share one in-flight future,
  /// so opening and closing the pad quickly won't kick off parallel downloads.
  Future<void> ensureModel() {
    if (status.value == InkModelStatus.ready) return Future.value();
    final pending = _pendingEnsure;
    if (pending != null) return pending;

    final future = _ensureModel();
    _pendingEnsure = future;
    return future.whenComplete(() => _pendingEnsure = null);
  }

  Future<void> _ensureModel() async {
    try {
      if (await _modelManager.isModelDownloaded(languageCode)) {
        status.value = InkModelStatus.ready;
        return;
      }

      status.value = InkModelStatus.downloading;
      // isWifiRequired defaults to true, which strands anyone on cellular with
      // a pad that never becomes usable. The model is only ~20MB, so allow it
      // over any connection.
      final ok = await _modelManager.downloadModel(
        languageCode,
        isWifiRequired: false,
      );
      status.value = ok ? InkModelStatus.ready : InkModelStatus.failed;
    } catch (e) {
      debugPrint('HandwritingService: model download failed: $e');
      status.value = InkModelStatus.failed;
    }
  }

  /// Recognises [strokes] and returns candidate characters, best match first.
  ///
  /// [strokes] are in the draw pad's local coordinate space; [writingAreaSize]
  /// is that pad's size, which ML Kit uses to reason about character scale.
  /// Returns an empty list if the model isn't ready or recognition fails —
  /// the pad treats that the same as "no guesses yet".
  Future<List<String>> recognize(
    List<List<InkPoint>> strokes,
    Size writingAreaSize,
  ) async {
    if (strokes.isEmpty) return const [];

    await ensureModel();
    if (status.value != InkModelStatus.ready) return const [];

    final ink = Ink()
      ..strokes = strokes.map((points) {
        return Stroke()
          ..points = points
              .map((p) => StrokePoint(x: p.x, y: p.y, t: p.t))
              .toList();
      }).toList();

    try {
      final recognizer =
          _recognizer ??= DigitalInkRecognizer(languageCode: languageCode);
      final candidates = await recognizer.recognize(
        ink,
        context: DigitalInkRecognitionContext(
          writingArea: WritingArea(
            width: writingAreaSize.width,
            height: writingAreaSize.height,
          ),
        ),
      );

      // ML Kit already returns candidates best-first (its score is inverted —
      // *lower* is more likely — so re-sorting on score would reverse them).
      // Just de-duplicate while preserving that order.
      final seen = <String>{};
      final results = <String>[];
      for (final candidate in candidates) {
        final text = candidate.text.trim();
        if (text.isEmpty || !seen.add(text)) continue;
        results.add(text);
      }
      return results;
    } catch (e) {
      debugPrint('HandwritingService: recognition failed: $e');
      return const [];
    }
  }

  /// Releases the native recognizer. The downloaded model is untouched.
  Future<void> dispose() async {
    await _recognizer?.close();
    _recognizer = null;
  }
}

/// A single captured touch point, in draw-pad local coordinates.
class InkPoint {
  const InkPoint(this.x, this.y, this.t);

  final double x;
  final double y;

  /// Milliseconds since epoch — ML Kit uses stroke timing as a recognition
  /// signal, so these must be real capture times, not synthesised.
  final int t;
}
