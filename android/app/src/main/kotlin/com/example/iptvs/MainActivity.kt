package com.example.iptvs

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "iptvs/native_hdr_player",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "open" -> {
                    val args = call.arguments as? Map<*, *>
                    val url = args?.get("url") as? String
                    if (url.isNullOrBlank()) {
                        result.error("bad_args", "Missing stream URL", null)
                        return@setMethodCallHandler
                    }

                    val headers = args["headers"] as? Map<*, *> ?: emptyMap<Any, Any>()
                    val intent = Intent(this, HdrPlayerActivity::class.java).apply {
                        putExtra(HdrPlayerActivity.EXTRA_URL, url)
                        putExtra(HdrPlayerActivity.EXTRA_TITLE, args["title"] as? String ?: "")
                        putExtra(HdrPlayerActivity.EXTRA_IS_LIVE, args["isLive"] as? Boolean ?: false)
                        putStringArrayListExtra(
                            HdrPlayerActivity.EXTRA_HEADER_KEYS,
                            ArrayList(headers.keys.mapNotNull { it as? String }),
                        )
                        putStringArrayListExtra(
                            HdrPlayerActivity.EXTRA_HEADER_VALUES,
                            ArrayList(headers.values.map { it?.toString() ?: "" }),
                        )
                    }
                    startActivity(intent)
                    result.success(true)
                }

                else -> result.notImplemented()
            }
        }
    }
}
