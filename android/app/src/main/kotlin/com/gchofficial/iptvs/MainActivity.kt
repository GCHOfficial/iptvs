package com.gchofficial.iptvs

import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.content.pm.Signature
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import androidx.core.content.FileProvider
import androidx.media3.common.util.UnstableApi
import com.gchofficial.iptvs.player.SharedEngine
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.lang.ref.WeakReference
import java.security.MessageDigest

@UnstableApi
class MainActivity : FlutterActivity() {
    private lateinit var nativeHdrChannel: MethodChannel
    private lateinit var previewChannel: MethodChannel
    private lateinit var updatesChannel: MethodChannel

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        instance = WeakReference(this)
    }

    override fun onStop() {
        super.onStop()
        // Back-exit safety net: leaving the app must never strand the shared
        // preview engine playing audio behind the launcher. Dart also stops it
        // on lifecycle-pause, but the engine is process-global and outlives the
        // Flutter UI, so the finishing Activity enforces it too. Not adopted =
        // not owned by a fullscreen HdrPlayerActivity.
        if (isFinishing && !SharedEngine.adoptedByFullscreen) {
            SharedEngine.invalidate()
        }
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
                        // VOD resume point (ms), 0 = play from the top.
                        putExtra(
                            HdrPlayerActivity.EXTRA_RESUME_MS,
                            (args["resumeMs"] as? Number)?.toLong() ?: 0L,
                        )
                        // Favorite toggle (live channels): whether to show the
                        // star, and its seed state from the Dart favorites store.
                        putExtra(
                            HdrPlayerActivity.EXTRA_CAN_FAVORITE,
                            args["canFavorite"] as? Boolean ?: false,
                        )
                        putExtra(
                            HdrPlayerActivity.EXTRA_IS_FAVORITE,
                            args["isFavorite"] as? Boolean ?: false,
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

        // In-app update: launches the system package installer for a
        // downloaded release APK, and the "install unknown apps" settings.
        updatesChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "iptvs/updates",
        )
        updatesChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "installApk" -> {
                    val path = (call.arguments as? Map<*, *>)?.get("path") as? String
                    if (path.isNullOrBlank()) {
                        result.error("bad_args", "Missing APK path", null)
                        return@setMethodCallHandler
                    }
                    val apk = File(path)
                    try {
                        verifyUpdateApk(apk)
                    } catch (e: SecurityException) {
                        result.error("invalid_update", e.message, null)
                        return@setMethodCallHandler
                    }
                    // minSdk 26 → canRequestPackageInstalls() always applies.
                    if (!packageManager.canRequestPackageInstalls()) {
                        result.success("needs_permission")
                        return@setMethodCallHandler
                    }
                    try {
                        val uri = FileProvider.getUriForFile(
                            this,
                            "$packageName.fileprovider",
                            apk,
                        )
                        val intent = Intent(Intent.ACTION_VIEW).apply {
                            setDataAndType(uri, "application/vnd.android.package-archive")
                            addFlags(
                                Intent.FLAG_GRANT_READ_URI_PERMISSION or
                                    Intent.FLAG_ACTIVITY_NEW_TASK,
                            )
                        }
                        startActivity(intent)
                        result.success("launched")
                    } catch (e: Exception) {
                        result.error("install_failed", e.message, null)
                    }
                }

                "requestInstallPermission" -> {
                    try {
                        startActivity(
                            Intent(
                                Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                                Uri.parse("package:$packageName"),
                            ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                        )
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("settings_failed", e.message, null)
                    }
                }

                else -> result.notImplemented()
            }
        }
    }

    /**
     * Fails closed unless [apk] is a cache-owned APK for this exact application
     * and is signed by the same certificate as the installed build. Dart has
     * already verified the signed release-manifest digest; this native check
     * prevents a wrong-package or wrong-signer APK reaching Package Installer.
     */
    @Suppress("DEPRECATION")
    private fun verifyUpdateApk(apk: File) {
        val cachePath = cacheDir.canonicalFile.toPath()
        val apkPath = apk.canonicalFile.toPath()
        if (!apk.isFile || !apkPath.startsWith(cachePath)) {
            throw SecurityException("Update APK is outside the application cache")
        }
        val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            PackageManager.GET_SIGNING_CERTIFICATES
        } else {
            PackageManager.GET_SIGNATURES
        }
        val candidate = packageManager.getPackageArchiveInfo(apkPath.toString(), flags)
            ?: throw SecurityException("Update APK package metadata is unreadable")
        if (candidate.packageName != packageName) {
            throw SecurityException("Update APK package identity does not match")
        }
        val installed = packageManager.getPackageInfo(packageName, flags)
        val candidateSigners = signerDigests(candidate)
        val installedSigners = signerDigests(installed)
        if (candidateSigners.isEmpty() || candidateSigners != installedSigners) {
            throw SecurityException("Update APK signing certificate does not match")
        }
    }

    @Suppress("DEPRECATION")
    private fun signerDigests(info: PackageInfo): Set<String> {
        val signatures: Array<Signature> = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            info.signingInfo?.apkContentsSigners ?: emptyArray()
        } else {
            info.signatures ?: emptyArray()
        }
        return signatures.mapTo(mutableSetOf()) { signature ->
            MessageDigest.getInstance("SHA-256")
                .digest(signature.toByteArray())
                .joinToString(separator = "") { byte ->
                    (byte.toInt() and 0xff).toString(16).padStart(2, '0')
                }
        }
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == REQUEST_NATIVE_PLAYER && ::nativeHdrChannel.isInitialized) {
            // Relay the final VOD position (see HdrPlayerActivity.finish) so the
            // Dart side can persist the resume point, plus the final favorite
            // state so the channel list reflects an in-player toggle on return.
            // Null args = live with no favorite change / legacy.
            val positionMs = data?.getLongExtra(HdrPlayerActivity.RESULT_POSITION_MS, -1L) ?: -1L
            val durationMs = data?.getLongExtra(HdrPlayerActivity.RESULT_DURATION_MS, -1L) ?: -1L
            val hasFavorite = data?.hasExtra(HdrPlayerActivity.RESULT_FAVORITE) ?: false
            val map = buildMap<String, Any> {
                if (positionMs >= 0L && durationMs > 0L) {
                    put("positionMs", positionMs)
                    put("durationMs", durationMs)
                }
                if (hasFavorite && data != null) {
                    put("favorite", data.getBooleanExtra(HdrPlayerActivity.RESULT_FAVORITE, false))
                }
            }
            nativeHdrChannel.invokeMethod("nativeClosed", if (map.isEmpty()) null else map)
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
