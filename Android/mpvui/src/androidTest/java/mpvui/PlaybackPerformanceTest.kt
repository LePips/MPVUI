package mpvui

import android.os.Debug
import android.os.PowerManager
import android.os.SystemClock
import android.view.WindowManager
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.launch
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.util.concurrent.atomic.AtomicLong

/** Opt in with `-e performanceLabel name`. Uses identical local media and wall-clock windows. */
@RunWith(AndroidJUnit4::class)
class PlaybackPerformanceTest {
    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()
    private fun await(message: String, predicate: () -> Boolean) {
        val deadline = SystemClock.elapsedRealtime() + 30_000
        while (!predicate() && SystemClock.elapsedRealtime() < deadline) Thread.sleep(20)
        assertTrue(message, predicate())
    }
    private data class WorkerCounters(val cpuNanos: Long, val switches: Long)
    private fun workerCounters(): WorkerCounters {
        val tasks = File("/proc/self/task").listFiles().orEmpty().filter {
            runCatching { File(it, "comm").readText().trim().startsWith("MPVUI ") }.getOrDefault(false)
        }
        assertTrue("Live player workers", tasks.isNotEmpty())
        val cpu = tasks.sumOf { File(it, "schedstat").readText().trim().split(Regex("\\s+"))[0].toLong() }
        val switches = tasks.sumOf { task -> File(task, "status").readLines().filter { it.startsWith("voluntary_ctxt_switches:") || it.startsWith("nonvoluntary_ctxt_switches:") }
            .sumOf { it.substringAfter(':').trim().toLong() } }
        return WorkerCounters(cpu, switches)
    }
    @Test fun benchmarkPlayback() {
        val args = InstrumentationRegistry.getArguments()
        val label = args.getString("performanceLabel")
        assumeTrue("Opt-in device performance measurement", !label.isNullOrBlank() && args.getString("performanceMedia") == null)
        require(label!!.matches(Regex("[A-Za-z0-9_-]+")))
        val seconds = args.getString("performanceSeconds")?.toLong() ?: 10L
        val rounds = args.getString("performanceRounds")?.toInt() ?: 3
        require(seconds in 1..120 && rounds in 1..20)
        val context = instrumentation.targetContext
        val results = JSONArray()
        val player = MPVPlayer(context, PlayerConfiguration(loop = true, audio = AudioConfiguration(AudioConfiguration.AudioSession.HOST_MANAGED), volume = 0.0))
        val scope = CoroutineScope(Dispatchers.Unconfined)
        val emissions = AtomicLong()
        val trackRebuilds = AtomicLong()
        val droppedFrames = AtomicLong()
        var lastDroppedFrames = 0L
        var lastTracks: List<MediaTrack>? = null
        scope.launch { player.state.collect {
            emissions.incrementAndGet()
            if (lastTracks !== it.tracks) trackRebuilds.incrementAndGet()
            lastTracks = it.tracks
            val dropped = (it.diagnostics.outputDroppedFrames ?: 0)
            droppedFrames.addAndGet(if (dropped >= lastDroppedFrames) dropped - lastDroppedFrames else dropped)
            lastDroppedFrames = dropped
        } }
        fun fixture(name: String): String = File(context.cacheDir, name).also { file ->
            instrumentation.context.assets.open(name).use { input -> file.outputStream().use { input.copyTo(it) } }
        }.absolutePath
        // Copy before measuring: asset extraction is unrelated to steady playback.
        val baseline = fixture("baseline.mp4")
        val multitrack = fixture("multitrack.mkv")
        val hd = fixture("performance-1080p60.mp4")
        fun measure(phase: String, round: Int) {
            Thread.sleep(1500)
            val thermal = context.getSystemService(PowerManager::class.java)
            fun thermalStatus() = thermal.currentThermalStatus
            val thermalStart = thermalStatus()
            val workerStart = workerCounters()
            val processStart = android.os.Process.getElapsedCpuTime()
            val allocationsStart = Debug.getRuntimeStat("art.gc.bytes-allocated").toLong()
            val gcStart = Debug.getRuntimeStat("art.gc.gc-count").toLong()
            val emissionsStart = emissions.get()
            val tracksStart = trackRebuilds.get()
            val dropsStart = droppedFrames.get()
            val timeStart = SystemClock.elapsedRealtimeNanos()
            Thread.sleep(seconds * 1000)
            val elapsed = (SystemClock.elapsedRealtimeNanos() - timeStart) / 1e9
            val allocated = Debug.getRuntimeStat("art.gc.bytes-allocated").toLong() - allocationsStart
            val gc = Debug.getRuntimeStat("art.gc.gc-count").toLong() - gcStart
            val processMs = android.os.Process.getElapsedCpuTime() - processStart
            val workerEnd = workerCounters()
            val snapshot = player.state.value
            assertNull("$phase playback error", snapshot.error)
            val result = JSONObject().put("phase", phase).put("round", round).put("seconds", elapsed)
                .put("processCpuMs", processMs).put("workerCpuMs", (workerEnd.cpuNanos - workerStart.cpuNanos) / 1e6)
                .put("workerContextSwitches", workerEnd.switches - workerStart.switches)
                .put("allocatedBytes", allocated).put("gcCount", gc)
                .put("stateEmissions", emissions.get() - emissionsStart).put("trackListRebuilds", trackRebuilds.get() - tracksStart)
                .put("droppedFrames", if (snapshot.isDiagnosticsEnabled) droppedFrames.get() - dropsStart else JSONObject.NULL)
                .put("decoder", snapshot.diagnostics.hardwareDecoder).put("output", snapshot.diagnostics.videoOutput)
                .put("thermalStart", thermalStart).put("thermalEnd", thermalStatus())
            results.put(result)
            android.util.Log.i("MPVUIPerformance", result.toString())
        }
        ActivityScenario.launch(PlaybackTestActivity::class.java).use { activity ->
            activity.onActivity { it.window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON); it.video.player = player }
            try {
                repeat(rounds) { round ->
                    player.stop()
                    await("stop") { player.state.value.state == PlaybackState.STOPPED }
                    measure("idle", round)
                    player.load(baseline)
                    await("baseline video") { player.state.value.hasVideoFrame && player.state.value.position > .1 }
                    player.pause()
                    await("pause") { player.state.value.paused }
                    measure("paused", round)
                    player.load(multitrack)
                    await("multitrack video") { player.state.value.hasVideoFrame && !player.state.value.paused && player.state.value.position > .1 }
                    measure("multitrack", round)
                    player.load(hd)
                    await("1080p60 video") { player.state.value.hasVideoFrame && !player.state.value.paused && player.state.value.position > .1 }
                    measure("1080p60", round)
                }
            } finally {
                activity.onActivity { it.video.player = null }
                scope.cancel()
                player.close()
                val report = JSONObject().put("label", label).put("model", android.os.Build.MODEL)
                    .put("sdk", android.os.Build.VERSION.SDK_INT).put("build", android.os.Build.FINGERPRINT).put("samples", results)
                File(context.getExternalFilesDir(null), "performance-$label.json").writeText(report.toString(2))
            }
        }
    }

    /** Benchmark a device-local file, including clips too large to bundle in the test APK. */
    @Test fun benchmarkMedia() {
        val args = InstrumentationRegistry.getArguments()
        val source = args.getString("performanceMedia")
        assumeTrue("Opt-in local media measurement", !source.isNullOrBlank())
        val label = requireNotNull(args.getString("performanceLabel"))
        require(label.matches(Regex("[A-Za-z0-9_-]+")))
        val seconds = args.getString("performanceSeconds")?.toInt() ?: 20
        val rounds = args.getString("performanceRounds")?.toInt() ?: 3
        require(seconds in 1..120 && rounds in 1..20)
        val options = JSONObject(args.getString("performanceOptions") ?: "{}")
        val context = instrumentation.targetContext
        val results = JSONArray()
        val player = MPVPlayer(context, PlayerConfiguration(audio = AudioConfiguration(AudioConfiguration.AudioSession.HOST_MANAGED), volume = 0.0,
            hardwareDecoding = HardwareDecoding.valueOf(args.getString("performanceHardwareDecoding") ?: "AUTOMATIC"),
            logLevel = LogLevel.fromMPV(args.getString("performanceLogLevel") ?: "info"),
            additionalOptions = options.keys().asSequence().associateWith { options.getString(it) }))
        player.setDiagnosticsEnabled(true)
        val scope = CoroutineScope(Dispatchers.Unconfined)
        val logs = java.util.concurrent.CopyOnWriteArrayList<String>()
        scope.launch { player.logs.collect { logs.add("${it.prefix}: ${it.message}") } }
        ActivityScenario.launch(PlaybackTestActivity::class.java).use { activity ->
            activity.onActivity { it.window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON); it.video.player = player }
            try {
                repeat(rounds) { round ->
                    player.load(source!!)
                    await("media starts: ${player.state.value}") { player.state.value.hasVideoFrame && player.state.value.position > 1 }
                    val thermal = context.getSystemService(PowerManager::class.java)
                    fun thermalStatus() = thermal.currentThermalStatus
                    val thermalStart = thermalStatus()
                    val startPosition = player.state.value.position
                    val startDrops = (player.state.value.diagnostics.outputDroppedFrames ?: 0)
                    val startCPU = android.os.Process.getElapsedCpuTime()
                    val startTime = SystemClock.elapsedRealtimeNanos()
                    repeat(seconds) {
                        player.command("expand-properties", "print-text", "MPVUIMetrics round=$round time=\${=time-pos} avsync=\${=avsync} decoderDrops=\${=decoder-frame-drop-count} voDrops=\${=frame-drop-count} delayed=\${=vo-delayed-frame-count}")
                        Thread.sleep(1000)
                    }
                    val snapshot = player.state.value
                    val result = JSONObject().put("round", round).put("seconds", (SystemClock.elapsedRealtimeNanos() - startTime) / 1e9)
                        .put("processCpuMs", android.os.Process.getElapsedCpuTime() - startCPU)
                        .put("positionStart", startPosition).put("positionEnd", snapshot.position)
                        .put("droppedFrames", (snapshot.diagnostics.outputDroppedFrames ?: 0) - startDrops)
                        .put("decoder", snapshot.diagnostics.hardwareDecoder).put("output", snapshot.diagnostics.videoOutput)
                        .put("thermalStart", thermalStart).put("thermalEnd", thermalStatus())
                    results.put(result)
                    assertNull("media playback error", snapshot.error)
                    assertEquals(PlaybackState.PLAYING, snapshot.state)
                    player.command("expand-properties", "print-text", "MPVUIPasses \${vo-passes}")
                    player.stop()
                    await("stop") { player.state.value.state == PlaybackState.STOPPED }
                }
            } finally {
                activity.onActivity { it.video.player = null }
                player.close()
                scope.cancel()
                val report = JSONObject().put("label", label).put("model", android.os.Build.MODEL)
                    .put("sdk", android.os.Build.VERSION.SDK_INT).put("options", options)
                    .put("samples", results).put("logs", JSONArray(logs))
                val codecs = JSONArray()
                android.media.MediaCodecList(android.media.MediaCodecList.ALL_CODECS).codecInfos.filter { !it.isEncoder }.forEach { codec ->
                    codec.supportedTypes.filter { it == "video/hevc" || it == "video/dolby-vision" }.forEach { type ->
                        codecs.put(JSONObject().put("name", codec.name).put("type", type)
                            .put("colorFormats", JSONArray(codec.getCapabilitiesForType(type).colorFormats.toList())))
                    }
                }
                report.put("codecs", codecs)
                File(context.getExternalFilesDir(null), "performance-$label.json").writeText(report.toString(2))
            }
        }
    }
}
