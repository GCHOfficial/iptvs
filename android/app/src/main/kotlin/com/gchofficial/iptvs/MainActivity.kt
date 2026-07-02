package com.gchofficial.iptvs

import android.content.Intent
import android.os.Bundle
import androidx.media3.common.util.UnstableApi
import com.gchofficial.iptvs.player.SharedEngine
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.lang.ref.WeakReference

@UnstableApi
class MainActivity : FlutterActivity() {
    private lateinit var nativeHdrChannel: MethodChannel
    private lateinit var previewChannel: MethodChannel

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        instance = WeakReference(this)
    }

    override fun onDestroy() {
        if (instance?.get() === this) instance = null
        super.onDestroy()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // The live preview's video surface (a TextureView the shared ExoPlayer
        // engine renders into) — embedded in the Flutter channel list.
        flutterEngine.platformViewsController.registry.registerViewFactory(
            "iptvs/preview_view",
            PreviewViewFactory(),
        )

        // Drives the shared preview engine (see SharedEngine). Separate channel
        // from the fullscreen player's because each channel has one Dart-side
        // method-call handler, and PlayerScreen owns the other one.
        previewChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "iptvs/native_preview",
        )
        previewChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "open" -> {
                    val args = call.arguments as? Map<*, *>
                    val url = args?.get("url") as? String
                    if (url.isNullOrBlank()) {
                        result.error("bad_args", "Missing stream URL", null)
                        return@setMethodCallHandler
                    }
                    val headers = (args["headers"] as? Map<*, *> ?: emptyMap<Any, Any>())
                        .entries.mapNotNull { entry ->
                            val key = entry.key as? String
                            if (key.isNullOrBlank()) null else key to entry.value.toString()
                        }.toMap()
                    SharedEngine.onPreviewError = { message ->
                        previewChannel.invokeMethod(
                            "previewEvent",
                            mapOf("event" to "error", "message" to message),
                        )
                    }
                    SharedEngine.onPreviewUnsupported = {
                        previewChannel.invokeMethod(
                            "previewEvent",
                            mapOf("event" to "unsupported"),
                        )
                    }
                    SharedEngine.onPreviewLost = {
                        previewChannel.invokeMethod(
                            "previewEvent",
                            mapOf("event" to "lost"),
                        )
                    }
                    SharedEngine.openPreview(
                        this,
                        url,
                        headers,
                        args["muted"] as? Boolean ?: true,
                    )
                    result.success(true)
                }

                "play" -> {
                    SharedEngine.playPreview()
                    result.success(true)
                }

                "pause" -> {
                    SharedEngine.pausePreview()
                    result.success(true)
                }

                "setVolume" -> {
                    val args = call.arguments as? Map<*, *>
                    val volume = (args?.get("volume") as? Number)?.toFloat()
                    if (volume != null) SharedEngine.setPreviewVolume(volume.coerceIn(0f, 1f))
                    result.success(true)
                }

                "stop" -> {
                    SharedEngine.stopPreview()
                    result.success(true)
                }

                else -> result.notImplemented()
            }
        }

        nativeHdrChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "iptvs/native_hdr_player",
        )
        nativeHdrChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "open" -> {
                    val args = call.arguments as? Map<*, *>
                    val url = args?.get("url") as? String
                    if (url.isNullOrBlank()) {
                        result.error("bad_args", "Missing stream URL", null)
                        return@setMethodCallHandler
                    }

                    val headers = args["headers"] as? Map<*, *> ?: emptyMap<Any, Any>()
                    val headerPairs = headers.entries.mapNotNull { entry ->
                        val key = entry.key as? String
                        if (key.isNullOrBlank()) null else key to entry.value.toString()
                    }
                    val subtitles = args["subtitles"] as? List<*> ?: emptyList<Any>()
                    val subtitleRows = subtitles.mapNotNull { entry ->
                        val map = entry as? Map<*, *> ?: return@mapNotNull null
                        val url = map["url"] as? String
                        if (url.isNullOrBlank()) {
                            null
                        } else {
                            Triple(
                                url,
                                map["label"]?.toString() ?: "",
                                map["language"]?.toString() ?: "",
                            )
                        }
                    }
                    fun epochMs(key: String): Long = (args[key] as? Number)?.toLong() ?: -1L
                    val intent = Intent(this, HdrPlayerActivity::class.java).apply {
                        putExtra(HdrPlayerActivity.EXTRA_URL, url)
                        putExtra(HdrPlayerActivity.EXTRA_TITLE, args["title"] as? String ?: "")
                        putExtra(HdrPlayerActivity.EXTRA_IS_LIVE, args["isLive"] as? Boolean ?: false)
                        // Seamless handoff: adopt the shared preview engine already
                        // playing this stream instead of reloading it.
                        putExtra(
                            HdrPlayerActivity.EXTRA_ADOPT_SHARED,
                            args["adoptShared"] as? Boolean ?: false,
                        )
                        (args["sourceName"] as? String)?.let {
                            putExtra(HdrPlayerActivity.EXTRA_SOURCE_NAME, it)
                        }
                        // Live EPG now/next snapshot (epoch ms passed as doubles).
                        (args["epgNowTitle"] as? String)?.let {
                            putExtra(HdrPlayerActivity.EXTRA_EPG_NOW_TITLE, it)
                            putExtra(HdrPlayerActivity.EXTRA_EPG_NOW_START, epochMs("epgNowStartMs"))
                            putExtra(HdrPlayerActivity.EXTRA_EPG_NOW_STOP, epochMs("epgNowStopMs"))
                            (args["epgNowDesc"] as? String)?.let { d ->
                                putExtra(HdrPlayerActivity.EXTRA_EPG_NOW_DESC, d)
                            }
                        }
                        (args["epgNextTitle"] as? String)?.let {
                            putExtra(HdrPlayerActivity.EXTRA_EPG_NEXT_TITLE, it)
                            putExtra(HdrPlayerActivity.EXTRA_EPG_NEXT_START, epochMs("epgNextStartMs"))
                            putExtra(HdrPlayerActivity.EXTRA_EPG_NEXT_STOP, epochMs("epgNextStopMs"))
                        }
                        putStringArrayListExtra(
                            HdrPlayerActivity.EXTRA_HEADER_KEYS,
                            ArrayList(headerPairs.map { it.first }),
                        )
                        putStringArrayListExtra(
                            HdrPlayerActivity.EXTRA_HEADER_VALUES,
                            ArrayList(headerPairs.map { it.second }),
                        )
                        putStringArrayListExtra(
                            HdrPlayerActivity.EXTRA_SUBTITLE_URLS,
                            ArrayList(subtitleRows.map { it.first }),
                        )
                        putStringArrayListExtra(
                            HdrPlayerActivity.EXTRA_SUBTITLE_LABELS,
                            ArrayList(subtitleRows.map { it.second }),
                        )
                        putStringArrayListExtra(
                            HdrPlayerActivity.EXTRA_SUBTITLE_LANGUAGES,
                            ArrayList(subtitleRows.map { it.third }),
                        )
                    }
                    startActivityForResult(intent, REQUEST_NATIVE_PLAYER)
                    result.success(true)
                }

                else -> result.notImplemented()
            }
        }
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == REQUEST_NATIVE_PLAYER && ::nativeHdrChannel.isInitialized) {
            nativeHdrChannel.invokeMethod("nativeClosed", null)
        }
    }

    companion object {
        /**
         * Set while a MainActivity exists. Lets [HdrPlayerActivity] move the
         * *main* task behind its PiP window (once an Activity enters PiP it lives
         * in its own pinned task, so it can't move this one from there).
         */
        var instance: WeakReference<MainActivity>? = null
            private set

        private const val REQUEST_NATIVE_PLAYER = 4120
    }
}
