package mpvuiexample.module

import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.foundation.layout.fillMaxSize
import androidx.activity.result.contract.ActivityResultContracts
import android.provider.OpenableColumns
import java.util.UUID
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner
import mpvui.*
import kotlinx.coroutines.*
import skip.foundation.ProcessInfo
import skip.ui.UIApplication

/** Activity, picker and presentation services for the session observed directly by Swift. */
class AndroidPlayback(autoPlay: Boolean, loop: Boolean, rate: Double, volume: Double,
                      start: Double, hasStart: Boolean, buffer: Double, cache: Double,
                      optionNames: skip.lib.Array<String>, optionValues: skip.lib.Array<String>) : DefaultLifecycleObserver, AutoCloseable {
    val player = MPVPlayer(ProcessInfo.processInfo.androidContext, PlayerConfiguration(
        videoOutput = VideoOutput.AUTOMATIC, nativeVideoFeaturePolicy = NativeVideoFeaturePolicy.PREFER_FEATURES,
        autoPlay = autoPlay, loop = loop, playbackRate = rate, volume = volume,
        startTime = if (hasStart) start else null, initialBufferSeconds = buffer, networkCacheSeconds = cache,
        additionalOptions = optionNames.zip(optionValues).associate { it.first to it.second },
    ))
    private val activity = UIApplication.shared.androidActivity!!
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val pip = MPVPictureInPictureController(activity, player)
    private var closed = false
    private var callback: ((Boolean, Boolean, Boolean, Boolean, String?) -> Unit)? = null
    private var pipError: String? = null
    private var resumeOnStart = false
    private var enteringPictureInPicture = false
    private var pipTimeout: Job? = null
    private var fileCallback: ((String, String) -> Unit)? = null
    private val filePicker = activity.activityResultRegistry.register("mpvui.media.${UUID.randomUUID()}", ActivityResultContracts.OpenDocument()) { uri ->
        val completion = fileCallback
        fileCallback = null
        if (uri != null) {
            val name = runCatching { activity.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use {
                if (it.moveToFirst()) it.getString(0) else null
            } }.getOrNull() ?: uri.lastPathSegment ?: "Selected media"
            completion?.invoke(uri.toString(), name)
        }
    }
    private val pipListener = androidx.core.util.Consumer<androidx.core.app.PictureInPictureModeChangedInfo> {
        enteringPictureInPicture = false
        pipTimeout?.cancel()
        emit()
    }
    init {
        player.setTextSubtitleInterceptionEnabled(true)
        (activity as LifecycleOwner).lifecycle.addObserver(this)
        activity.addOnPictureInPictureModeChangedListener(pipListener)
        scope.launch { pip.state.collect { emit() } }
    }
    fun retainSession(): Long = player.retainSharedSession()
    fun prepareLoad(autoPlay: Boolean): Boolean {
        resumeOnStart = false
        return player.prepareSharedLoad(autoPlay)
    }
    fun requestAudioFocus(): Boolean = player.requestSharedAudioFocus()
    fun cancelAudioResume() = player.cancelSharedAudioResume()
    fun observePictureInPicture(callback: (Boolean, Boolean, Boolean, Boolean, String?) -> Unit) {
        this.callback = callback
        emit()
    }
    private fun emit() {
        if (!closed) callback?.invoke(pip.state.value.isSupported, pip.isPossible, pip.isActive,
            enteringPictureInPicture, pipError ?: pip.lastError?.message)
    }
    fun openFile(callback: (String, String) -> Unit) {
        if (closed) return
        fileCallback = callback
        try {
            filePicker.launch(arrayOf("video/*", "audio/*", "image/*"))
        } catch (error: Exception) {
            fileCallback = null
            callback("", error.message ?: "Unable to open the document picker")
        }
    }
    fun startPictureInPicture() {
        pipError = null
        enteringPictureInPicture = true
        pip.start()
        if (pip.lastError != null || pip.isActive) enteringPictureInPicture = false
        emit()
        pipTimeout?.cancel()
        if (enteringPictureInPicture) pipTimeout = scope.launch {
            delay(1500)
            enteringPictureInPicture = false
            if (!pip.isActive) pipError = "Picture in picture did not become active."
            emit()
        }
    }
    fun clearPictureInPictureError() { pipError = null; pip.clearLastError(); emit() }
    @Composable fun Content(modifier: Modifier, showSurface: Boolean) {
        androidx.compose.foundation.layout.Box(modifier.fillMaxSize()) {
            if (showSurface) MPVVideoPlayer(player, Modifier.fillMaxSize())
        }
    }
    override fun onStart(owner: LifecycleOwner) {
        if (resumeOnStart) { resumeOnStart = false; player.play() }
        emit()
    }
    override fun onStop(owner: LifecycleOwner) {
        if (!pip.isActive && !enteringPictureInPicture) {
            val state = player.state.value
            resumeOnStart = !state.paused && state.state in setOf(mpvui.PlaybackState.PLAYING,
                mpvui.PlaybackState.BUFFERING, mpvui.PlaybackState.LOADING, mpvui.PlaybackState.SEEKING)
            player.pause()
        }
    }
    override fun onDestroy(owner: LifecycleOwner) = close()
    override fun close() {
        if (closed) return
        closed = true
        callback = null
        fileCallback = null
        filePicker.unregister()
        activity.removeOnPictureInPictureModeChangedListener(pipListener)
        scope.cancel()
        pip.close()
        player.close()
        (activity as LifecycleOwner).lifecycle.removeObserver(this)
    }
}
