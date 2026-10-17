package mpvui

import android.content.Context
import android.net.Uri
import android.view.Surface
import mpvui.internal.*
import kotlinx.coroutines.CancellableContinuation
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.suspendCancellableCoroutine
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/** Android player for one shared Swift playback session. Close to release its native resources. */
class MPVPlayer(context: Context, val configuration: PlayerConfiguration = PlayerConfiguration()) : AutoCloseable {
    private val context = context.applicationContext
    private val worker = Executors.newSingleThreadExecutor { task -> Thread(task, "MPVUI player").apply { isDaemon = true } }
    private val closed = AtomicBoolean(false)
    private var handle = 0L
    private var dispatcher: Thread? = null
    private var surfaceOwner: Any? = null
    private var nextQuery = 1L
    private val queries = mutableMapOf<Long, CancellableContinuation<List<TimedTextSubtitleSnapshot>>>()
    private val mutableState = MutableStateFlow(PlaybackSnapshot())
    private val mutableLogs = MutableSharedFlow<LogMessage>(extraBufferCapacity = 100)
    private val audioFocus = AudioFocusController(this.context, this, configuration.audio.audioSession == AudioConfiguration.AudioSession.AUTOMATIC)
    val state: StateFlow<PlaybackSnapshot> = mutableState.asStateFlow()
    val logs: SharedFlow<LogMessage> = mutableLogs.asSharedFlow()
    /** Last source generation accepted by the shared session. */
    @Volatile private var acceptedGeneration: Long = 0
    val loadGeneration: Long get() = if (closed.get()) acceptedGeneration else try {
        // A barrier returns the core identity for all commands submitted before
        // this read, without maintaining another source-generation counter.
        worker.submit<Long> { acceptedGeneration }.get()
    } catch (_: RejectedExecutionException) { acceptedGeneration }

    /** Transfers one retained native Swift session reference to a Swift platform adapter.
     * The recipient must consume it exactly once with MPVAndroidSession.consumeRetainedHandle.
     */
    fun retainSharedSession(): Long = worker.submit<Long> {
        check(!closed.get() && handle != 0L) { "Shared playback session is unavailable" }
        NativeBridge.retainSessionAddress(handle)
    }.get()

    init {
        worker.execute {
            if (closed.get()) return@execute
            try {
                val lowPower = this.context.getSystemService(android.os.PowerManager::class.java).isPowerSaveMode
                handle = NativeBridge.create(this.context, configuration.coreRecord(this.context),
                    when (configuration.videoOutput) { VideoOutput.NATIVE_SURFACE -> 1; VideoOutput.AUTOMATIC -> 2; VideoOutput.GPU -> 0 },
                    configuration.hardwareDecoding.ordinal, lowPower, configuration.dolbyVisionPolicy == DolbyVisionPolicy.PROFILE7_COMPATIBILITY)
                val nativeHandle = handle
                dispatcher = Thread({
                    while (NativeBridge.waitForEvents(nativeHandle)) {
                        val event = NativeBridge.event(nativeHandle) ?: continue
                        try { worker.submit {
                            if (!closed.get()) try { receive(event) }
                            catch (error: Exception) {
                                mutableState.value = mutableState.value.copy(state = PlaybackState.FAILED,
                                    error = PlayerError.PlaybackFailed(-1, "Invalid core event: ${error.message}"))
                            }
                        }.get() }
                        catch (_: RejectedExecutionException) { break }
                        catch (_: InterruptedException) { break }
                    }
                }, "MPVUI delivery").apply { isDaemon = true; start() }
            } catch (error: Throwable) {
                if (error !is Exception && error !is LinkageError) throw error
                mutableState.value = PlaybackSnapshot(state = PlaybackState.FAILED,
                    error = PlayerError.InitializationFailed("Create shared session", -1, error.message.orEmpty()))
            }
        }
    }

    private fun execute(action: () -> Unit) {
        if (closed.get()) return
        try { worker.execute {
            if (!closed.get() && handle != 0L) try { action() }
            catch (error: Exception) { mutableLogs.tryEmit(LogMessage("mpvui/bridge", LogLevel.ERROR, error.message.orEmpty())) }
        } } catch (_: RejectedExecutionException) { /* Closing owns the queue. */ }
    }
    private fun send(kind: Int, flags: Int = 0, track: TrackIdentifier? = null, role: Int = 0,
                     value: Double = 0.0, hasValue: Boolean = false, strings: Array<String> = emptyArray()) = execute {
        val identity = NativeBridge.send(handle, kind, flags, track?.type?.ordinal ?: 0, role, track?.mpvId?.toLong() ?: -1,
            value, hasValue, strings)
        acceptedGeneration = identity[1]
    }
    private fun receive(event: CoreEvent) {
        when (event.type) {
            1 -> {
                val snapshot = CoreWire.snapshot(event.record)
                if (snapshot.loadGeneration >= acceptedGeneration) {
                    acceptedGeneration = snapshot.loadGeneration
                    mutableState.value = snapshot
                }
            }
            2 -> mutableLogs.tryEmit(CoreWire.log(event.record))
            3, 4, 5 -> {
                NativeBridge.releaseQuery(handle, event.query)
                val continuation = queries.remove(event.query) ?: return
                if (!continuation.isActive) return
                when (event.type) {
                    3 -> continuation.resume(CoreWire.timeline(event.record))
                    4 -> continuation.cancel(CancellationException("Subtitle query cancelled by the shared session"))
                    else -> continuation.resumeWithException(IllegalStateException(CoreWire.failure(CoreWire.decode(event.record))?.message))
                }
            }
        }
    }

    /** Applies Android audio focus before a native Swift adapter submits its load. */
    fun prepareSharedLoad(autoPlay: Boolean): Boolean = audioFocus.beforeLoad(autoPlay)
    /** Requests Android audio focus for a native Swift adapter's play command. */
    fun requestSharedAudioFocus(): Boolean = audioFocus.request()
    /** Cancels focus-driven resume before a native Swift adapter pauses. */
    fun cancelSharedAudioResume() = audioFocus.cancelResume()

    fun load(uri: Uri) = load(uri.toString())
    /** Loads a URI or local path using shared source replacement and autoplay rules. */
    @JvmOverloads fun load(source: String, autoPlay: Boolean? = null, startTime: Double? = null) {
        val play = audioFocus.beforeLoad(autoPlay ?: configuration.autoPlay)
        send(1, flags = if (play) 1 else 0, value = startTime ?: 0.0, hasValue = startTime != null, strings = arrayOf(source))
    }
    fun play() { if (audioFocus.request()) send(2) }
    fun pause() { audioFocus.cancelResume(); send(3) }
    internal fun pauseForFocus() = send(3)
    fun togglePlayback() {
        if (state.value.paused || state.value.state == PlaybackState.ENDED) {
            if (audioFocus.request()) send(4)
        } else { audioFocus.cancelResume(); send(4) }
    }
    fun stop() { audioFocus.abandon(); send(5) }
    fun seekTo(seconds: Double) = send(6, value = seconds)
    fun seekBy(seconds: Double) = send(7, value = seconds)
    fun stepForward() = send(8)
    fun stepBackward() = send(8, flags = 1)
    fun setVolume(value: Double) = send(9, value = value)
    fun setMuted(value: Boolean) = send(10, flags = if (value) 1 else 0)
    fun toggleMute() = send(21)
    fun setPlaybackRate(value: Double) = send(11, value = value)
    fun selectTrack(id: TrackIdentifier) = send(12, track = id)
    fun selectSubtitle(id: TrackIdentifier?, role: SubtitleRole = SubtitleRole.PRIMARY) = send(13, track = id, role = role.ordinal)
    fun disableTrack(type: TrackType) = send(14, track = TrackIdentifier(type, -1))
    fun setTextSubtitleInterceptionEnabled(enabled: Boolean) = send(15, flags = if (enabled) 1 else 0)
    fun setDiagnosticsEnabled(enabled: Boolean) = send(16, flags = if (enabled) 1 else 0)
    fun setProperty(name: String, value: String) = send(17, strings = arrayOf(name, value))
    fun command(name: String, vararg arguments: String) = send(18, strings = arrayOf(name, *arguments))
    fun loadExternalTrack(uri: Uri, type: TrackType, select: Boolean = true) = send(19, flags = if (select) 1 else 0,
        track = TrackIdentifier(type, -1), strings = arrayOf(uri.toString()))
    fun loadExternalSubtitle(uri: Uri, role: SubtitleRole? = SubtitleRole.PRIMARY) = send(19, flags = if (role == null) 0 else 1,
        track = TrackIdentifier(TrackType.SUBTITLE, -1), role = role?.ordinal ?: -1, strings = arrayOf(uri.toString()))
    fun clearLastError() = send(20)
    fun setAudioDelay(seconds: Double) = setProperty("audio-delay", seconds.toString())
    fun setSubtitleDelay(seconds: Double, role: SubtitleRole = SubtitleRole.PRIMARY) = setProperty("${role.prefix}sub-delay", seconds.toString())
    fun setSubtitlesVisible(visible: Boolean, role: SubtitleRole = SubtitleRole.PRIMARY) = setProperty("${role.prefix}sub-visibility", if (visible) "yes" else "no")
    fun nextChapter() = command("add", "chapter", "1")
    fun previousChapter() = command("add", "chapter", "-1")
    val textSubtitleStream: Flow<TextSubtitleSnapshot> = state.map { it.subtitles }.distinctUntilChanged()
    val videoTracks: List<MediaTrack> get() = state.value.videoTracks
    fun selectedSubtitle(role: SubtitleRole = SubtitleRole.PRIMARY): MediaTrack? = state.value.selectedSubtitle(role)
    private fun currentSnapshot(): PlaybackSnapshot = if (closed.get()) state.value else try {
        worker.submit<PlaybackSnapshot> {
            if (handle == 0L) state.value else CoreWire.snapshot(NativeBridge.snapshot(handle))
        }.get()
    } catch (_: RejectedExecutionException) { state.value }
    val videoFeatureCapabilities: VideoFeatureCapabilities get() = currentSnapshot().videoFeatureCapabilities
    val videoFeatureRequestResult: VideoFeatureRequestResult? get() = currentSnapshot().videoFeatureRequestResult
    fun requestVideoFeatures(features: Set<VideoFeature>): VideoFeatureRequestResult = worker.submit<VideoFeatureRequestResult> {
        check(!closed.get() && handle != 0L) { "Player unavailable" }
        CoreWire.featureRequestResult(CoreWire.decode(NativeBridge.requestFeatures(handle,
            features.fold(0) { mask, feature -> mask or (1 shl feature.ordinal) })))!!
    }.get()

    suspend fun textSubtitleSnapshot(track: TrackIdentifier, at: Double): TextSubtitleSnapshot =
        textSubtitleSnapshots(track).firstOrNull { it.contains(at) }?.snapshot ?: TextSubtitleSnapshot()
    suspend fun textSubtitleSnapshots(track: TrackIdentifier): List<TimedTextSubtitleSnapshot> = suspendCancellableCoroutine { continuation ->
        if (closed.get()) { continuation.cancel(CancellationException("Player closed")); return@suspendCancellableCoroutine }
        try { worker.execute {
            if (!continuation.isActive) return@execute
            if (closed.get() || handle == 0L) { continuation.cancel(CancellationException("Player unavailable")); return@execute }
            val id = nextQuery++
            queries[id] = continuation
            continuation.invokeOnCancellation { execute { queries.remove(id); NativeBridge.releaseQuery(handle, id) } }
            try { NativeBridge.querySubtitles(handle, track.type.ordinal, track.mpvId.toLong(), id) }
            catch (error: Exception) { queries.remove(id); if (continuation.isActive) continuation.resumeWithException(error) }
        } } catch (error: RejectedExecutionException) { continuation.cancel(CancellationException("Player closed", error)) }
    }

    internal fun attachSurface(surface: Surface, display: DisplayCapabilities, owner: Any = surface) = execute {
        surfaceOwner = owner; NativeBridge.surface(handle, surface, display.coreRecord())
    }
    internal fun resizeSurface(width: Int, height: Int, owner: Any? = null) = execute {
        if (owner == null || surfaceOwner === owner) NativeBridge.resize(handle, width, height)
    }
    internal fun detachSurface(owner: Any? = null) = execute {
        if (owner == null || surfaceOwner === owner) {
            surfaceOwner = null; NativeBridge.surface(handle, null, DisplayCapabilities().coreRecord())
        }
    }
    override fun close() {
        if (!closed.compareAndSet(false, true)) return
        audioFocus.close()
        worker.execute {
            queries.values.forEach { it.cancel() }; queries.clear()
            if (handle != 0L) {
                NativeBridge.stopEvents(handle); dispatcher?.interrupt(); dispatcher?.join(); dispatcher = null
                NativeBridge.destroy(handle); handle = 0
            }
        }
        worker.shutdown()
    }
}
