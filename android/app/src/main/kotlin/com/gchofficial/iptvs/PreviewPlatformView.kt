package com.gchofficial.iptvs

import android.content.Context
import android.graphics.Color
import android.view.Gravity
import android.view.TextureView
import android.view.View
import android.widget.FrameLayout
import androidx.media3.common.util.UnstableApi
import androidx.media3.ui.AspectRatioFrameLayout
import com.gchofficial.iptvs.player.DebugCounters
import com.gchofficial.iptvs.player.SharedEngine
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory

/** Factory for the live-preview platform view (`iptvs/preview_view`). */
@UnstableApi
class PreviewViewFactory : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
    override fun create(context: Context, viewId: Int, args: Any?): PlatformView =
        PreviewPlatformView(context)
}

/**
 * The live preview's video surface: a [TextureView] the [SharedEngine] renders
 * into, letterboxed by an [AspectRatioFrameLayout] (same layout PlayerView uses
 * internally). A TextureView — not a SurfaceView — because texture content
 * composes cleanly inside Flutter's platform-view layer; the fullscreen
 * Activity's own SurfaceView is where HDR happens.
 */
@UnstableApi
class PreviewPlatformView(context: Context) : PlatformView {
    private val texture = TextureView(context)

    private val aspectFrame = AspectRatioFrameLayout(context).apply {
        resizeMode = AspectRatioFrameLayout.RESIZE_MODE_FIT
        addView(
            texture,
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT,
            ),
        )
    }

    private val root = FrameLayout(context).apply {
        setBackgroundColor(Color.BLACK)
        addView(
            aspectFrame,
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT,
                Gravity.CENTER,
            ),
        )
    }

    init {
        SharedEngine.registerPreviewView(texture, aspectFrame)
        DebugCounters.incPreviewView()
    }

    override fun getView(): View = root

    override fun dispose() {
        SharedEngine.unregisterPreviewView(texture)
        DebugCounters.decPreviewView()
    }
}
