package com.gchofficial.iptvs

import android.content.Context
import android.graphics.Color
import android.view.Gravity
import android.view.SurfaceView
import android.view.View
import android.view.ViewGroup
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
 * The live preview's video surface: a [SurfaceView] the [SharedEngine] renders
 * into, letterboxed by an [AspectRatioFrameLayout] (the same layout PlayerView
 * uses internally).
 *
 * **A SurfaceView, and the Dart side must embed it with hybrid composition**
 * (`PlatformViewsService.initExpensiveAndroidView` — see `PreviewVideo`), or
 * this renders nothing at all: Flutter's default platform-view path hands back
 * a texture, and a SurfaceView has no texture to give.
 *
 * It was a TextureView, on the reasoning that texture content composes cleanly
 * inside Flutter's layer tree. That is true, and on a 4K50 HDR10 channel it is
 * also ruinous. A SurfaceView's buffers go straight to the system compositor —
 * usually a hardware overlay plane, zero copy, HDR metadata intact. A
 * TextureView's go through a `SurfaceTexture` into an external GL texture that
 * the app's GPU draws, which Flutter then composites again: two extra
 * full-frame passes at 3840x2160x10-bit, fifty times a second, on a set-top
 * box. An exported log measured the same codec instance on the same stream
 * holding 49.3 fps rendering into the fullscreen Activity's SurfaceView, while
 * a mostly-preview window managed about 11.7 fps.
 *
 * The root is deliberately **not focusable and blocks descendant focus**. Under
 * hybrid composition this is a real view in the Activity's hierarchy rather
 * than an offscreen one, so a focusable SurfaceView here would be a D-pad trap
 * the Flutter focus model knows nothing about (docs/tv-navigation.md).
 */
@UnstableApi
class PreviewPlatformView(context: Context) : PlatformView {
    private val surface = SurfaceView(context)

    private val aspectFrame = AspectRatioFrameLayout(context).apply {
        resizeMode = AspectRatioFrameLayout.RESIZE_MODE_FIT
        addView(
            surface,
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT,
            ),
        )
    }

    private val root = FrameLayout(context).apply {
        setBackgroundColor(Color.BLACK)
        // See the class doc: under hybrid composition this view really is in
        // the Activity's hierarchy, and the D-pad must never land in it.
        isFocusable = false
        isFocusableInTouchMode = false
        descendantFocusability = ViewGroup.FOCUS_BLOCK_DESCENDANTS
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
        SharedEngine.registerPreviewView(surface, aspectFrame)
        DebugCounters.incPreviewView()
    }

    override fun getView(): View = root

    override fun dispose() {
        SharedEngine.unregisterPreviewView(surface)
        DebugCounters.decPreviewView()
    }
}
