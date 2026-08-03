package com.happygoluckycodeeditor.japanodict.japanodict

import io.flutter.FlutterInjector
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
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

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

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
                assets.open(lookupKey).use { input ->
                    temp.outputStream().use { output ->
                        input.copyTo(output, COPY_BUFFER_BYTES)
                        output.fd.sync()
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

    override fun onDestroy() {
        io.shutdown()
        super.onDestroy()
    }

    companion object {
        private const val CHANNEL = "japanodict/db"
        private const val COPY_BUFFER_BYTES = 256 * 1024
    }
}
