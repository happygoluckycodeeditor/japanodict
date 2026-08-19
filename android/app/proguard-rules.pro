# R8/ProGuard rules for release builds.
#
# google_mlkit_text_recognition's Java plugin references the option classes for
# every script it supports — Latin, Chinese, Devanagari, Japanese and Korean —
# from a single `initialize` switch. This app only links the *Japanese*
# recogniser (see the `text-recognition-japanese` dependency in
# build.gradle.kts and the note above it), so the other three script artifacts
# genuinely are not on the classpath and R8 fails the build over the dangling
# references.
#
# `-dontwarn` is the correct answer rather than adding the missing artifacts:
# the code paths that touch them are unreachable — OcrService only ever asks
# for TextRecognitionScript.japanese — and pulling in Chinese, Devanagari and
# Korean would add their models to the APK for nothing.
#
# Adding a script here means removing the matching -dontwarn line *and* adding
# the com.google.mlkit:text-recognition-<script> dependency.
-dontwarn com.google.mlkit.vision.text.chinese.ChineseTextRecognizerOptions
-dontwarn com.google.mlkit.vision.text.chinese.ChineseTextRecognizerOptions$Builder
-dontwarn com.google.mlkit.vision.text.devanagari.DevanagariTextRecognizerOptions
-dontwarn com.google.mlkit.vision.text.devanagari.DevanagariTextRecognizerOptions$Builder
-dontwarn com.google.mlkit.vision.text.korean.KoreanTextRecognizerOptions
-dontwarn com.google.mlkit.vision.text.korean.KoreanTextRecognizerOptions$Builder
