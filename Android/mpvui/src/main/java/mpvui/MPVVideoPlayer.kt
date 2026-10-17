package mpvui

import android.content.Context
import android.util.AttributeSet
import android.hardware.display.DisplayManager
import android.view.Surface
import android.view.Display
import android.view.SurfaceHolder
import android.view.SurfaceView
import androidx.compose.runtime.Composable
import androidx.compose.runtime.key
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.ui.Alignment
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.compose.ui.Modifier
import androidx.compose.ui.viewinterop.AndroidView
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map

/** SurfaceView keeps Android's native video/HDR composition available. One view per player. */
class MPVPlayerView @JvmOverloads constructor(context: Context, attrs: AttributeSet? = null) : SurfaceView(context, attrs), SurfaceHolder.Callback {
    var player: MPVPlayer? = null
        set(value) {
            if (field === value) return
            field?.detachSurface(this)
            field = value
            observePresentation()
            if (holder.surface.isValid) attach()
        }
    private var presentationScope: CoroutineScope? = null
    private var presentation = SurfacePresentation()
    private var appliedRate: Float? = null
    private var appliedHeadroom = 0f
    private val displayManager = context.getSystemService(DisplayManager::class.java)
    private val displayListener = object : DisplayManager.DisplayListener {
        override fun onDisplayAdded(displayId: Int) = Unit
        override fun onDisplayRemoved(displayId: Int) = Unit
        override fun onDisplayChanged(displayId: Int) {
            if (display?.displayId == displayId) updatePresentation()
        }
    }
    private fun observePresentation() {
        presentationScope?.cancel()
        presentationScope = null
        resetPresentation()
        val current = player ?: return
        if (!isAttachedToWindow) return
        presentationScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate).also { scope ->
            scope.launch {
                current.state.map { it.surfacePresentation(current.configuration) }.distinctUntilChanged().collect {
                    presentation = it
                    updatePresentation()
                }
            }
        }
    }
    private fun updatePresentation() {
        if (!isAttachedToWindow) return
        keepScreenOn = presentation.keepScreenOn
        if (appliedHeadroom != presentation.hdrHeadroom) {
            setDesiredHdrHeadroom(presentation.hdrHeadroom)
            appliedHeadroom = presentation.hdrHeadroom
        }
        // On ARR displays, the video surface supplies the exact fixed-source rate.
        // Keep this View's redraws from adding a competing UI frame-rate vote.
        requestedFrameRate = if (presentation.frameRate > 0f && display?.hasArrSupport() == true)
            REQUESTED_FRAME_RATE_CATEGORY_NO_PREFERENCE else REQUESTED_FRAME_RATE_CATEGORY_DEFAULT
        if (!holder.surface.isValid || appliedRate == presentation.frameRate) return
        val policy = player?.configuration?.displayMatching ?: DisplayMatching.DISABLED
        holder.surface.setFrameRate(presentation.frameRate,
            if (presentation.frameRate > 0f) Surface.FRAME_RATE_COMPATIBILITY_FIXED_SOURCE else Surface.FRAME_RATE_COMPATIBILITY_DEFAULT,
            if (policy == DisplayMatching.ALWAYS) Surface.CHANGE_FRAME_RATE_ALWAYS else Surface.CHANGE_FRAME_RATE_ONLY_IF_SEAMLESS)
        appliedRate = presentation.frameRate
    }
    private fun resetPresentation() {
        presentation = SurfacePresentation()
        keepScreenOn = false
        requestedFrameRate = REQUESTED_FRAME_RATE_CATEGORY_DEFAULT
        if (appliedHeadroom != 0f) { setDesiredHdrHeadroom(0f); appliedHeadroom = 0f }
        if (appliedRate != null && appliedRate != 0f && holder.surface.isValid)
            holder.surface.setFrameRate(0f, Surface.FRAME_RATE_COMPATIBILITY_DEFAULT)
        appliedRate = null
    }
    override fun onAttachedToWindow() {
        super.onAttachedToWindow()
        displayManager.registerDisplayListener(context.mainExecutor, DisplayManager.EVENT_TYPE_DISPLAY_CHANGED, displayListener)
        observePresentation()
    }
    override fun onDetachedFromWindow() {
        displayManager.unregisterDisplayListener(displayListener)
        presentationScope?.cancel(); presentationScope = null
        resetPresentation()
        super.onDetachedFromWindow()
    }
    init { holder.addCallback(this); setBackgroundColor(android.graphics.Color.TRANSPARENT) }
    private fun attach() {
        val types = display?.mode?.supportedHdrTypes ?: intArrayOf()
        player?.attachSurface(holder.surface, DisplayCapabilities(
            hdr10 = Display.HdrCapabilities.HDR_TYPE_HDR10 in types,
            hlg = Display.HdrCapabilities.HDR_TYPE_HLG in types,
            dolbyVision = Display.HdrCapabilities.HDR_TYPE_DOLBY_VISION in types,
            wideGamut = display?.isWideColorGamut == true,
            refreshRate = display?.refreshRate?.toDouble(),
        ), this)
        player?.resizeSurface(width, height, this)
    }
    override fun surfaceCreated(holder: SurfaceHolder) { appliedRate = null; attach(); updatePresentation() }
    // EGL can set a buffer geometry that differs from the View bounds. Always
    // resize from layout, including paused PiP and split-screen transitions.
    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
        super.onSizeChanged(w, h, oldw, oldh)
        player?.resizeSurface(w, h, this)
    }
    override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) { player?.resizeSurface(this.width, this.height, this) }
    override fun surfaceDestroyed(holder: SurfaceHolder) { appliedRate = null; player?.detachSurface(this) }
}

/** Attach an owned player to Compose. The host controls playback lifecycle and closes the player. */
@Composable
fun MPVVideoPlayer(player: MPVPlayer, modifier: Modifier = Modifier) {
    // Position, buffering and diagnostics ticks do not change the video View.
    val presentation = remember(player) { player.state.map { it.videoPresentation() }.distinctUntilChanged() }
    val initial = remember(player) { player.state.value.videoPresentation() }
    val state by presentation.collectAsStateWithLifecycle(initialValue = initial)
    key(player) {
        Box(modifier) {
            val surfaceModifier = if (state.native) Modifier.align(Alignment.Center).aspectRatio(state.aspectRatio) else Modifier.matchParentSize()
            AndroidView(factory = { MPVPlayerView(it).also { view -> view.player = player } }, modifier = surfaceModifier,
                onRelease = { it.player = null })
            if (state.interceptsSubtitles) {
                MPVTextSubtitleOverlay(state.subtitles, Modifier.matchParentSize(), state.aspectRatio)
            }
        }
    }
}

internal data class VideoPresentation(val native: Boolean, val aspectRatio: Float,
    val interceptsSubtitles: Boolean, val subtitles: TextSubtitleSnapshot)
internal fun PlaybackSnapshot.videoPresentation(): VideoPresentation {
    val native = diagnostics.videoOutput == "mediacodec_embed"
    val intercepts = interceptsTextSubtitles
    return VideoPresentation(native, dimensions.aspectRatio, intercepts, if (intercepts) subtitles else TextSubtitleSnapshot())
}
