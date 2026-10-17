package mpvui

import android.app.Activity
import android.app.PictureInPictureParams
import android.content.pm.PackageManager
import android.util.Rational
import android.app.PendingIntent
import android.app.RemoteAction
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.graphics.drawable.Icon
import androidx.core.app.OnPictureInPictureModeChangedProvider
import androidx.core.app.PictureInPictureModeChangedInfo
import androidx.core.util.Consumer
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.distinctUntilChanged
import java.util.UUID
import kotlin.math.roundToInt

// Stay inside Android's inclusive bounds after rational rounding.
private fun VideoDimensions.pipAspect() = Rational((aspectRatio.coerceIn(.42f, 2.38f) * 10000).roundToInt(), 10000)

/** Observable Activity PiP state. Only system callbacks establish [isActive]. */
data class PictureInPictureState(
    val isSupported: Boolean = false, val isPossible: Boolean = false,
    val isActive: Boolean = false, val lastError: PlayerError? = null,
)

/** PiP transport actions track playback state. Closed automatically with LifecycleOwner hosts.
 * Activity hosts declare supportsPictureInPicture and handle configuration changes.
 * Single-player hosts use launchMode="singleTask" so relaunching reuses the playback Activity.
 */
class MPVPictureInPictureController(private val activity: Activity, private val player: MPVPlayer) : DefaultLifecycleObserver, AutoCloseable {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val action = "${activity.packageName}.mpvui.pip.${UUID.randomUUID()}"
    private var closed = false
    private val mutableState = MutableStateFlow(PictureInPictureState())
    val state: StateFlow<PictureInPictureState> = mutableState.asStateFlow()
    val isPossible: Boolean get() = state.value.isPossible
    val isActive: Boolean get() = state.value.isActive
    val lastError: PlayerError? get() = state.value.lastError
    private val modeListener = Consumer<PictureInPictureModeChangedInfo> { onPictureInPictureModeChanged(it.isInPictureInPictureMode) }

    /** Plain Activity hosts forward their system callback here. ComponentActivity hosts are registered automatically. */
    fun onPictureInPictureModeChanged(active: Boolean) {
        if (!closed) {
            mutableState.value = state.value.copy(isActive = active)
            refreshState()
        }
    }

    private fun refreshState() {
        val supported = activity.packageManager.hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE)
        mutableState.value = state.value.copy(isSupported = supported,
            isPossible = !closed && supported && !activity.isFinishing && !activity.isDestroyed && player.state.value.hasVideoFrame && player.state.value.state !in setOf(PlaybackState.FAILED, PlaybackState.STOPPED, PlaybackState.LOADING, PlaybackState.IDLE))
    }
    private val intents = (0..2).map { command ->
        PendingIntent.getBroadcast(activity, command, Intent(action).setPackage(activity.packageName).putExtra("command", command), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
    }
    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (closed || intent?.action != action) return
            when (intent.getIntExtra("command", -1)) {
                0 -> if (player.state.value.seekable) player.seekBy(-10.0)
                1 -> player.togglePlayback()
                2 -> if (player.state.value.seekable) player.seekBy(10.0)
            }
        }
    }
    init {
        activity.registerReceiver(receiver, IntentFilter(action), Context.RECEIVER_NOT_EXPORTED)
        (activity as? LifecycleOwner)?.lifecycle?.addObserver(this)
        (activity as? OnPictureInPictureModeChangedProvider)?.addOnPictureInPictureModeChangedListener(modeListener)
        mutableState.value = state.value.copy(isActive = activity.isInPictureInPictureMode)
        refreshState()
        scope.launch { player.state.map {
            Triple(Triple(it.dimensions.aspectRatio, it.paused || it.state == PlaybackState.ENDED, it.seekable), it.hasVideoFrame, it.state)
        }.distinctUntilChanged().collect {
            refreshState()
            if (activity.isInPictureInPictureMode) runCatching { activity.setPictureInPictureParams(parameters()) }
                .onFailure { mutableState.value = state.value.copy(lastError = PlayerError.PictureInPictureFailed(PlayerError.PictureInPictureOperation.START, it.message.orEmpty())) }
        } }
    }
    private fun parameters(): PictureInPictureParams {
        val snapshot = player.state.value
        val paused = snapshot.paused || snapshot.state == PlaybackState.ENDED
        fun control(icon: Int, label: String, index: Int) = RemoteAction(Icon.createWithResource(activity, icon), label, label, intents[index]).apply {
            isEnabled = index == 1 || snapshot.seekable
        }
        return PictureInPictureParams.Builder().setAspectRatio(snapshot.dimensions.pipAspect()).setActions(listOf(
            control(android.R.drawable.ic_media_rew, "Back 10 seconds", 0),
            control(if (paused) android.R.drawable.ic_media_play else android.R.drawable.ic_media_pause, if (paused) "Play" else "Pause", 1),
            control(android.R.drawable.ic_media_ff, "Forward 10 seconds", 2),
        )).setSeamlessResizeEnabled(true).build()
    }
    /** Requests PiP; observe [state] for the actual system transition and any error. */
    fun start() {
        refreshState()
        val error = when {
            closed || !state.value.isSupported -> PlayerError.PictureInPictureUnsupported
            !state.value.isPossible -> PlayerError.PictureInPictureNotReady
            state.value.isActive -> null
            else -> runCatching {
                if (activity.enterPictureInPictureMode(parameters())) null
                else PlayerError.PictureInPictureFailed(PlayerError.PictureInPictureOperation.START, "Android declined picture in picture")
            }.getOrElse { PlayerError.PictureInPictureFailed(PlayerError.PictureInPictureOperation.START, it.message.orEmpty()) }
        }
        mutableState.value = state.value.copy(lastError = error)
    }
    fun clearLastError() { mutableState.value = state.value.copy(lastError = null) }
    override fun onResume(owner: LifecycleOwner) {
        onPictureInPictureModeChanged(activity.isInPictureInPictureMode)
    }
    override fun onDestroy(owner: LifecycleOwner) = close()
    override fun close() {
        if (closed) return
        closed = true
        mutableState.value = state.value.copy(isPossible = false, isActive = false)
        (activity as? OnPictureInPictureModeChangedProvider)?.removeOnPictureInPictureModeChangedListener(modeListener)
        scope.cancel()
        activity.unregisterReceiver(receiver)
        intents.forEach { it.cancel() }
        (activity as? LifecycleOwner)?.lifecycle?.removeObserver(this)
    }
}
