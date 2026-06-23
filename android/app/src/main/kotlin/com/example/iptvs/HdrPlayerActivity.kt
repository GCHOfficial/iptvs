package com.example.iptvs

import android.app.Activity
import android.net.Uri
import android.os.Bundle
import android.util.Log
import android.view.KeyEvent
import android.view.View
import android.view.WindowManager
import android.widget.FrameLayout
import android.widget.Toast
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.VideoSize
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.ui.AspectRatioFrameLayout
import androidx.media3.ui.PlayerView

@UnstableApi
class HdrPlayerActivity : Activity() {
    private var player: ExoPlayer? = null
    private lateinit var playerView: PlayerView
    private var controllerVisible = true

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        hideSystemUi()

        val url = intent.getStringExtra(EXTRA_URL)
        if (url.isNullOrBlank()) {
            finish()
            return
        }

        title = intent.getStringExtra(EXTRA_TITLE).orEmpty()
        playerView = PlayerView(this).apply {
            useController = true
            resizeMode = AspectRatioFrameLayout.RESIZE_MODE_FIT
            setShowBuffering(PlayerView.SHOW_BUFFERING_WHEN_PLAYING)
            setControllerAutoShow(true)
            setControllerHideOnTouch(true)
            setControllerShowTimeoutMs(if (intent.getBooleanExtra(EXTRA_IS_LIVE, false)) 4500 else 3500)
            setControllerVisibilityListener(
                PlayerView.ControllerVisibilityListener { visibility ->
                    controllerVisible = visibility == View.VISIBLE
                    if (visibility == View.GONE) hideSystemUi()
                },
            )
        }
        setContentView(
            playerView,
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT,
            ),
        )

        val headers = requestHeaders()
        val httpFactory = DefaultHttpDataSource.Factory()
            .setAllowCrossProtocolRedirects(true)
            .setDefaultRequestProperties(headers)
        val mediaSourceFactory = DefaultMediaSourceFactory(this)
            .setDataSourceFactory(httpFactory)

        player = ExoPlayer.Builder(this)
            .setMediaSourceFactory(mediaSourceFactory)
            .build()
            .also { exoPlayer ->
                playerView.player = exoPlayer
                exoPlayer.addListener(object : Player.Listener {
                    override fun onVideoSizeChanged(videoSize: VideoSize) {
                        Log.i(
                            TAG,
                            "video ${videoSize.width}x${videoSize.height} " +
                                "ratio=${videoSize.pixelWidthHeightRatio}",
                        )
                    }

                    override fun onPlayerError(error: PlaybackException) {
                        Log.e(TAG, "playback failed", error)
                        Toast.makeText(
                            this@HdrPlayerActivity,
                            error.localizedMessage ?: "Playback failed",
                            Toast.LENGTH_LONG,
                        ).show()
                    }
                })
                exoPlayer.setMediaItem(mediaItem(url))
                exoPlayer.prepare()
                exoPlayer.playWhenReady = true
            }
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) hideSystemUi()
    }

    override fun onKeyDown(keyCode: Int, event: KeyEvent?): Boolean {
        val exoPlayer = player
        if (exoPlayer != null) {
            when (keyCode) {
                KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE,
                KeyEvent.KEYCODE_SPACE -> {
                    if (exoPlayer.isPlaying) exoPlayer.pause() else exoPlayer.play()
                    return true
                }

                KeyEvent.KEYCODE_DPAD_CENTER,
                KeyEvent.KEYCODE_ENTER -> {
                    if (controllerVisible) return super.onKeyDown(keyCode, event)
                    playerView.showController()
                    return true
                }

                KeyEvent.KEYCODE_MEDIA_PLAY -> {
                    exoPlayer.play()
                    return true
                }

                KeyEvent.KEYCODE_MEDIA_PAUSE -> {
                    exoPlayer.pause()
                    return true
                }

                KeyEvent.KEYCODE_DPAD_LEFT -> {
                    if (controllerVisible) return super.onKeyDown(keyCode, event)
                    if (!intent.getBooleanExtra(EXTRA_IS_LIVE, false)) {
                        exoPlayer.seekTo((exoPlayer.currentPosition - 10_000).coerceAtLeast(0))
                    }
                    playerView.showController()
                    return true
                }

                KeyEvent.KEYCODE_DPAD_RIGHT -> {
                    if (controllerVisible) return super.onKeyDown(keyCode, event)
                    if (!intent.getBooleanExtra(EXTRA_IS_LIVE, false)) {
                        exoPlayer.seekTo(exoPlayer.currentPosition + 10_000)
                    }
                    playerView.showController()
                    return true
                }

                KeyEvent.KEYCODE_DPAD_UP,
                KeyEvent.KEYCODE_DPAD_DOWN -> {
                    if (!controllerVisible) playerView.showController()
                    return super.onKeyDown(keyCode, event)
                }

                KeyEvent.KEYCODE_MEDIA_REWIND -> {
                    if (!intent.getBooleanExtra(EXTRA_IS_LIVE, false)) {
                        exoPlayer.seekTo((exoPlayer.currentPosition - 10_000).coerceAtLeast(0))
                    }
                    return true
                }

                KeyEvent.KEYCODE_MEDIA_FAST_FORWARD -> {
                    if (!intent.getBooleanExtra(EXTRA_IS_LIVE, false)) {
                        exoPlayer.seekTo(exoPlayer.currentPosition + 10_000)
                    }
                    return true
                }
            }
        }
        return super.onKeyDown(keyCode, event)
    }

    @Deprecated("Deprecated in Java")
    override fun onBackPressed() {
        if (controllerVisible) {
            playerView.hideController()
            hideSystemUi()
            return
        }
        super.onBackPressed()
    }

    override fun onStop() {
        super.onStop()
        player?.pause()
    }

    override fun onDestroy() {
        playerView.player = null
        player?.release()
        player = null
        super.onDestroy()
    }

    private fun requestHeaders(): Map<String, String> {
        val keys = intent.getStringArrayListExtra(EXTRA_HEADER_KEYS).orEmpty()
        val values = intent.getStringArrayListExtra(EXTRA_HEADER_VALUES).orEmpty()
        return keys.mapIndexedNotNull { index, key ->
            val value = values.getOrNull(index)
            if (key.isBlank() || value.isNullOrBlank()) null else key to value
        }.toMap()
    }

    private fun mediaItem(url: String): MediaItem {
        val subtitles = subtitleConfigurations()
        return MediaItem.Builder()
            .setUri(url)
            .setSubtitleConfigurations(subtitles)
            .build()
    }

    private fun subtitleConfigurations(): List<MediaItem.SubtitleConfiguration> {
        val urls = intent.getStringArrayListExtra(EXTRA_SUBTITLE_URLS).orEmpty()
        val labels = intent.getStringArrayListExtra(EXTRA_SUBTITLE_LABELS).orEmpty()
        val languages = intent.getStringArrayListExtra(EXTRA_SUBTITLE_LANGUAGES).orEmpty()
        return urls.mapIndexedNotNull { index, url ->
            if (url.isBlank()) {
                null
            } else {
                MediaItem.SubtitleConfiguration.Builder(Uri.parse(url))
                    .setMimeType(subtitleMimeType(url))
                    .setLabel(labels.getOrNull(index)?.ifBlank { null })
                    .setLanguage(languages.getOrNull(index)?.ifBlank { null })
                    .build()
            }
        }
    }

    private fun subtitleMimeType(url: String): String {
        val clean = url.substringBefore('?').substringBefore('#').lowercase()
        return when {
            clean.endsWith(".vtt") || clean.endsWith(".webvtt") -> MimeTypes.TEXT_VTT
            clean.endsWith(".ssa") || clean.endsWith(".ass") -> MimeTypes.TEXT_SSA
            clean.endsWith(".ttml") || clean.endsWith(".dfxp") -> MimeTypes.APPLICATION_TTML
            else -> MimeTypes.APPLICATION_SUBRIP
        }
    }

    private fun hideSystemUi() {
        window.decorView.systemUiVisibility =
            View.SYSTEM_UI_FLAG_FULLSCREEN or
                View.SYSTEM_UI_FLAG_HIDE_NAVIGATION or
                View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY or
                View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN or
                View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION or
                View.SYSTEM_UI_FLAG_LAYOUT_STABLE
    }

    companion object {
        const val EXTRA_URL = "url"
        const val EXTRA_TITLE = "title"
        const val EXTRA_IS_LIVE = "is_live"
        const val EXTRA_HEADER_KEYS = "header_keys"
        const val EXTRA_HEADER_VALUES = "header_values"
        const val EXTRA_SUBTITLE_URLS = "subtitle_urls"
        const val EXTRA_SUBTITLE_LABELS = "subtitle_labels"
        const val EXTRA_SUBTITLE_LANGUAGES = "subtitle_languages"
        private const val TAG = "iptvs.hdr"
    }
}
