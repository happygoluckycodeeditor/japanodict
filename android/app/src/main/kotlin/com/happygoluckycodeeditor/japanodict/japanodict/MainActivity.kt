package com.happygoluckycodeeditor.japanodict.japanodict

import io.flutter.FlutterInjector
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors

/**
 * Hosts a small channel used to copy the bundled dictionary out of the APK.
 *
 * Doing this in Dart means `rootBundle.load` materialises the whole ~80MB
 * asset in the Dart heap on the root isolate, which stalls the UI long enough
 * for Android to raise an ANR. It can't simply be moved to a background
 * isolate either: the `flutter/assets` channel isn't serviced through
 * `BackgroundIsolateBinaryMessenger`, so the reply comes back null.
 *
 * Streaming the copy here keeps the bytes entirely on the native side, off
 * both the Dart heap and the platform thread.
 */
class MainActivity : FlutterActivity() {
    private val io = Executors.newSingleThreadExecutor()

    /// Sink for copy progress, if Dart is listening. The copy runs regardless —
    /// progress is reporting, never a precondition — so every use is
    /// null-guarded rather than the copy waiting for a subscriber.
    private var progressSink: EventChannel.EventSink? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            PROGRESS_CHANNEL,
        ).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                progressSink = events
            }

            override fun onCancel(arguments: Any?) {
                progressSink = null
            }
        })

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CHANNEL,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "copyAsset" -> {
                    val assetKey = call.argument<String>("assetKey")
                    val destPath = call.argument<String>("destPath")
                    if (assetKey == null || destPath == null) {
                        result.error("bad_args", "assetKey and destPath are required", null)
                    } else {
                        copyAsset(assetKey, destPath, result)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun copyAsset(assetKey: String, destPath: String, result: MethodChannel.Result) {
        io.execute {
            try {
                // Flutter asset keys are relative to flutter_assets/ inside the
                // APK; FlutterLoader owns that mapping.
                val lookupKey = FlutterInjector.instance()
                    .flutterLoader()
                    .getLookupKeyForAsset(assetKey)

                val dest = File(destPath)
                dest.parentFile?.mkdirs()

                // Write to a temp file and rename, so an interrupted copy can
                // never leave a half-written database that later looks
                // complete to the version check.
                val temp = File("$destPath.tmp")

                // `assets.openFd` gives the uncompressed length without
                // reading the asset, which is what makes the progress bar
                // *determinate*. It throws for a compressed asset, so a
                // failure here degrades to an indeterminate bar (total 0)
                // rather than failing the copy.
                val total = try {
                    assets.openFd(lookupKey).use { it.length }
                } catch (e: Exception) {
                    0L
                }
                emitProgress(0L, total)

                assets.open(lookupKey).use { input ->
                    temp.outputStream().use { output ->
                        val buffer = ByteArray(COPY_BUFFER_BYTES)
                        var copied = 0L
                        var lastEmit = 0L
                        while (true) {
                            val read = input.read(buffer)
                            if (read < 0) break
                            output.write(buffer, 0, read)
                            copied += read
                            // Throttle: one event per PROGRESS_STEP_BYTES, not
                            // one per 256KB buffer. The channel hop marshals to
                            // the UI thread, and ~340 of them for an 87MB file
                            // would cost more than the copy they describe.
                            if (copied - lastEmit >= PROGRESS_STEP_BYTES) {
                                lastEmit = copied
                                emitProgress(copied, total)
                            }
                        }
                        output.fd.sync()
                        emitProgress(copied, total)
                    }
                }
                if (dest.exists() && !dest.delete()) {
                    throw IllegalStateException("could not replace $destPath")
                }
                if (!temp.renameTo(dest)) {
                    throw IllegalStateException("could not rename ${temp.path} to $destPath")
                }

                runOnUiThread { result.success(null) }
            } catch (e: Exception) {
                runOnUiThread { result.error("copy_failed", e.message, null) }
            }
        }
    }

    /// Posts a progress event to Dart, if anything is listening.
    ///
    /// EventSink is not thread-safe and the copy runs on [io], so this hops to
    /// the UI thread — the same thread the sink was handed to us on.
    private fun emitProgress(copied: Long, total: Long) {
        val sink = progressSink ?: return
        runOnUiThread {
            // Re-read: the subscription can be cancelled between the hop being
            // posted and it running.
            progressSink?.success(mapOf("copied" to copied, "total" to total))
        }
    }

    override fun onDestroy() {
        io.shutdown()
        super.onDestroy()
    }

    companion object {
        private const val CHANNEL = "japanodict/db"
        private const val PROGRESS_CHANNEL = "japanodict/db_progress"
        private const val COPY_BUFFER_BYTES = 256 * 1024
        private const val PROGRESS_STEP_BYTES = 2 * 1024 * 1024
    }
}
