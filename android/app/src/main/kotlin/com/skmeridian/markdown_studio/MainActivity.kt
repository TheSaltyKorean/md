package com.skmeridian.markdown_studio

import android.content.Intent
import android.net.Uri
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channelName = "markdown_studio/open_file"
    private var channel: MethodChannel? = null

    // Files received before Dart registered its handler (queued for getInitialFile).
    private val pendingFiles = mutableListOf<Map<String, Any?>>()
    private var dartReady = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
        channel!!.setMethodCallHandler { call, result ->
            if (call.method == "getInitialFile") {
                dartReady = true
                result.success(if (pendingFiles.isEmpty()) null else ArrayList(pendingFiles))
                pendingFiles.clear()
            } else {
                result.notImplemented()
            }
        }
        // The intent that launched the activity (cold start).
        readIntent(intent)?.let { pendingFiles.add(it) }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        readIntent(intent)?.let { data ->
            // Only push once Dart's handler is registered; otherwise queue it so
            // an open during startup isn't dropped (Flutter buffers only one).
            if (dartReady) {
                channel?.invokeMethod("openFile", data)
            } else {
                pendingFiles.add(data)
            }
        }
    }

    private fun readIntent(intent: Intent?): Map<String, Any?>? {
        if (intent?.action != Intent.ACTION_VIEW) return null
        val uri = intent.data ?: return null
        return try {
            val content = contentResolver.openInputStream(uri)
                ?.bufferedReader()
                ?.use { it.readText() }
            mapOf("content" to content, "name" to queryDisplayName(uri))
        } catch (e: Exception) {
            null
        }
    }

    private fun queryDisplayName(uri: Uri): String? {
        var name: String? = null
        try {
            contentResolver.query(uri, null, null, null, null)?.use { c ->
                val idx = c.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (idx >= 0 && c.moveToFirst()) name = c.getString(idx)
            }
        } catch (_: Exception) {
        }
        return name
    }
}
