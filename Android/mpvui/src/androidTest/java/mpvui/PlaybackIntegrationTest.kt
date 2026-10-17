package mpvui

import android.graphics.Bitmap
import android.graphics.Rect
import android.os.Handler
import android.os.Looper
import android.net.Uri
import android.view.PixelCopy
import android.view.ViewGroup
import android.widget.LinearLayout
import androidx.test.core.app.ActivityScenario
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.ext.junit.runners.AndroidJUnit4
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.flow.first
import org.junit.Assert.*
import org.junit.Test
import org.junit.Assume.assumeTrue
import org.junit.runner.RunWith
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.net.ServerSocket
import kotlin.concurrent.thread

@RunWith(AndroidJUnit4::class)
class PlaybackIntegrationTest {
    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()
    private fun fixture(name: String): String {
        val file = File(instrumentation.targetContext.cacheDir, name)
        instrumentation.context.assets.open(name).use { input -> file.outputStream().use { input.copyTo(it) } }
        return file.absolutePath
    }
    private fun await(message: String, timeout: Long = 20000, details: (() -> Any?)? = null, predicate: () -> Boolean) {
        val deadline = System.nanoTime() + timeout * 1_000_000
        while (!predicate() && System.nanoTime() < deadline) Thread.sleep(40)
        assertTrue("$message: ${details?.invoke() ?: ""}", predicate())
    }
    private fun session(block: (MPVPlayer, ActivityScenario<PlaybackTestActivity>) -> Unit) {
        val player = MPVPlayer(instrumentation.targetContext, PlayerConfiguration(hardwareDecoding = HardwareDecoding.DISABLED, audio = AudioConfiguration(AudioConfiguration.AudioSession.HOST_MANAGED)))
        ActivityScenario.launch(PlaybackTestActivity::class.java).use { activity ->
            activity.onActivity { it.video.player = player }
            try { block(player, activity) }
            finally { runCatching { activity.onActivity { it.video.player = null } }; player.close() }
        }
    }
    @Test fun featureRequestsResolveAfterAttachmentAndResetWithTheItem() {
        val player = MPVPlayer(instrumentation.targetContext, PlayerConfiguration(hardwareDecoding = HardwareDecoding.DISABLED,
            audio = AudioConfiguration(AudioConfiguration.AudioSession.HOST_MANAGED)))
        try {
            player.load(fixture("baseline.mp4"), autoPlay = false)
            val request = player.requestVideoFeatures(setOf(VideoFeature.NATIVE_SUBTITLES, VideoFeature.ZOOM_AND_PAN))
            assertEquals(VideoFeatureRequestResult.Outcome.AWAITING_VIDEO_METADATA, request.outcome)
            ActivityScenario.launch(PlaybackTestActivity::class.java).use { activity ->
                activity.onActivity { it.video.player = player }
                await("feature requests resolve when the current item's renderer is known") {
                    player.state.value.hasVideoFrame && player.videoFeatureRequestResult?.outcome == VideoFeatureRequestResult.Outcome.AVAILABLE
                }
                assertEquals(VideoOutput.GPU, player.videoFeatureCapabilities.backend)
                assertTrue(player.state.value.diagnostics.fallbackReasons.isEmpty())
                player.load(fixture("baseline.mp4"), autoPlay = false)
                assertNull(player.videoFeatureRequestResult)
                player.requestVideoFeatures(setOf(VideoFeature.INLINE_OVERLAYS))
                assertEquals(setOf(VideoFeature.INLINE_OVERLAYS), player.videoFeatureRequestResult?.requestedFeatures)
                player.stop()
                assertNull(player.videoFeatureRequestResult)
            }
        } finally { player.close() }
    }
    @Test fun pauseBeforeSurfaceAttachmentPreventsAutoplay() {
        val player = MPVPlayer(instrumentation.targetContext, PlayerConfiguration(audio = AudioConfiguration(AudioConfiguration.AudioSession.HOST_MANAGED)))
        try {
            player.load(fixture("baseline.mp4"))
            player.pause()
            ActivityScenario.launch(PlaybackTestActivity::class.java).use { activity ->
                activity.onActivity { it.video.player = player }
                await("pending load respects pause", details = { player.state.value }) { player.state.value.state == PlaybackState.PAUSED && player.state.value.duration > 0 }
                val position = player.state.value.position
                Thread.sleep(400)
                assertEquals(position, player.state.value.position, .05)
                player.play()
                await("explicit resume") { player.state.value.position > .2 }
            }
        } finally { player.close() }
    }
    @Test fun perLoadOptionsOverrideDefaultsAndResetForReplacement() {
        val player = MPVPlayer(instrumentation.targetContext,
            PlayerConfiguration(hardwareDecoding = HardwareDecoding.DISABLED, audio = AudioConfiguration(AudioConfiguration.AudioSession.HOST_MANAGED), autoPlay = true, startTime = 1.0,
                logLevel = LogLevel.DEBUG, additionalOptions = mapOf("log-file" to File(instrumentation.targetContext.getExternalFilesDir(null), "replacement.log").absolutePath)))
        val source = fixture("baseline.mp4")
        try {
            player.load(source, autoPlay = false, startTime = 4.0)
            ActivityScenario.launch(PlaybackTestActivity::class.java).use { activity ->
                activity.onActivity { it.video.player = player }
                await("per-load options survive delayed surface attachment", details = { player.state.value }) {
                    player.state.value.paused && player.state.value.duration > 0 &&
                        kotlin.math.abs(player.state.value.position - 4.0) < .2
                }
                Thread.sleep(350)
                assertEquals(4.0, player.state.value.position, .2)
                player.load(source)
                await("replacement restores configured autoplay and start time", details = {
                    player.state.value.toString() + "\n" + File(instrumentation.targetContext.getExternalFilesDir(null), "replacement.log").takeIf { it.exists() }?.readText()?.takeLast(16000)
                }) {
                    !player.state.value.paused && player.state.value.position in 1.1..3.0
                }
                player.load(source, autoPlay = false, startTime = -5.0)
                await("negative start time clamps to zero") {
                    player.state.value.paused && player.state.value.duration > 0 &&
                        player.state.value.position < .2
                }
            }
        } finally { player.close() }
    }
    @Test fun oldViewCannotDetachReplacementSurface() = session { player, activity ->
        player.load(fixture("baseline.mp4"))
        await("initial video") { player.state.value.hasVideoFrame && player.state.value.position > .2 }
        val replacementOwner = Any()
        activity.onActivity {
            player.attachSurface(it.video.holder.surface, DisplayCapabilities(), replacementOwner)
            // A stale view is dismantled after a replacement has acquired the player.
            it.video.player = null
        }
        player.seekTo(1.0)
        await("replacement remains active") { player.state.value.position > 1.2 && player.state.value.diagnostics.videoOutput == "gpu-next" }
        assertFrame(activity, "replacement surface")
        player.detachSurface(replacementOwner)
    }
    @Test fun videoKeepsScreenAwakeOnlyWhilePlaying() = session { player, activity ->
        fun keepsScreenOn(): Boolean {
            var awake = false
            activity.onActivity { awake = it.video.keepScreenOn }
            return awake
        }
        player.load(fixture("baseline.mp4"))
        await("video keeps display awake") { keepsScreenOn() }
        player.pause()
        await("pause releases display") { !keepsScreenOn() }
        player.play()
        await("resume restores display request") { keepsScreenOn() }
        player.stop()
        await("stop releases display") { !keepsScreenOn() }
    }
    @Test fun adaptiveRefreshViewVoteFollowsPlaybackAndViewLifetime() = session { player, activity ->
        fun hasExpectedVote(playing: Boolean): Boolean {
            var matches = false
            activity.onActivity {
                val vote = it.video.requestedFrameRate
                matches = if (playing && it.video.display.hasArrSupport())
                    vote == android.view.View.REQUESTED_FRAME_RATE_CATEGORY_NO_PREFERENCE else vote.isNaN()
            }
            return matches
        }
        player.load(fixture("baseline.mp4"))
        await("playing video") { player.state.value.position > .2 && player.state.value.hasVideoFrame }
        await("video surface owns the ARR cadence") { hasExpectedVote(true) }
        player.pause()
        await("paused frame releases ARR vote") { player.state.value.paused && hasExpectedVote(false) }
        player.play()
        await("resumed video restores ARR vote") { !player.state.value.paused && hasExpectedVote(true) }
        activity.recreate()
        activity.onActivity { it.video.player = player }
        await("recreated view restores presentation") { hasExpectedVote(true) }
        activity.onActivity { it.video.player = null }
        assertTrue("removing the player restores the View default", hasExpectedVote(false))
    }
    @Test fun nativeHeadroomAcceptsPausedFramesAndSurfaceRecreation() {
        val player = MPVPlayer(instrumentation.targetContext, PlayerConfiguration(
            videoOutput = VideoOutput.NATIVE_SURFACE, desiredHDRHeadroom = 2f,
            audio = AudioConfiguration(AudioConfiguration.AudioSession.HOST_MANAGED)))
        try {
            ActivityScenario.launch(PlaybackTestActivity::class.java).use { activity ->
                var supportsHDR10 = false
                activity.onActivity {
                    supportsHDR10 = android.view.Display.HdrCapabilities.HDR_TYPE_HDR10 in it.video.display.mode.supportedHdrTypes
                }
                assumeTrue("Native HDR headroom validation requires an HDR10 display", supportsHDR10)
                activity.onActivity { it.video.player = player }
                player.load(fixture("color-hdr10.mkv"), autoPlay = false)
                await("paused native frame", details = { player.state.value }) {
                    player.state.value.hasVideoFrame && player.state.value.diagnostics.videoOutput == "mediacodec_embed"
                }
                assertFrame(activity, "native frame with requested headroom")
                activity.recreate()
                activity.onActivity { it.video.player = player }
                player.seekTo(1.0)
                await("native frame after recreation") { player.state.value.position > .9 && player.state.value.hasVideoFrame }
                assertFrame(activity, "recreated native headroom surface")
                activity.onActivity { it.video.player = null }
            }
        } finally { player.close() }
    }
    @Test fun typedDeinterlacingAndQualityRenderThroughGPU() {
        DeinterlacePolicy.Algorithm.entries.forEach { algorithm ->
            val player = MPVPlayer(instrumentation.targetContext, PlayerConfiguration(
                audio = AudioConfiguration(AudioConfiguration.AudioSession.HOST_MANAGED), videoOutput = VideoOutput.AUTOMATIC,
                deinterlace = DeinterlacePolicy(mode = DeinterlacePolicy.Mode.FORCED, algorithm = algorithm,
                    fieldOrder = DeinterlacePolicy.FieldOrder.TOP_FIRST),
                renderingQuality = RenderingQuality(preset = RenderingQuality.Preset.HIGH_QUALITY)))
            try {
                ActivityScenario.launch(PlaybackTestActivity::class.java).use { activity ->
                    activity.onActivity { it.video.player = player }
                    player.load(fixture("interlaced-576i-top.mkv"))
                    await("$algorithm deinterlacing progresses") { player.state.value.position > .2 || player.state.value.error != null }
                    assertNull("$algorithm: ${player.state.value.error}", player.state.value.error)
                    assertEquals("gpu-next", player.state.value.diagnostics.videoOutput)
                    assertTrue((player.state.value.videoFeatureCapabilities[VideoFeature.BAKED_OVERLAYS].availability == VideoFeatureCapabilities.Availability.AVAILABLE))
                    assertFrame(activity, "$algorithm deinterlacing")
                }
            } finally { player.close() }
        }
    }
    @Test fun detailedCountersAndTextSubtitlesFollowExplicitOptIn() = session { player, _ ->
        player.load(fixture("multitrack.mkv"), autoPlay = false, startTime = 1.5)
        await("paused with media") { player.state.value.hasVideoFrame && player.state.value.paused }
        assertFalse(player.state.value.isDiagnosticsEnabled)
        assertNull(player.state.value.diagnostics.outputDroppedFrames)
        assertTrue(player.state.value.subtitles.regions.isEmpty())
        player.setDiagnosticsEnabled(true)
        player.setTextSubtitleInterceptionEnabled(true)
        await("enabled diagnostics and text") {
            player.state.value.diagnostics.outputDroppedFrames != null && player.state.value.subtitles.regions.isNotEmpty()
        }
        player.setDiagnosticsEnabled(false)
        player.setTextSubtitleInterceptionEnabled(false)
        await("disabled diagnostics and text") {
            !player.state.value.isDiagnosticsEnabled && !player.state.value.interceptsTextSubtitles && player.state.value.subtitles.regions.isEmpty()
        }
        assertNotNull(player.state.value.diagnostics.outputDroppedFrames)
        player.setProperty("sub-text-intercept", "yes")
        await("interception is owned by the explicit API") {
            (player.state.value.error as? PlayerError.ReservedProperty)?.name == "sub-text-intercept"
        }
        assertFalse(player.state.value.interceptsTextSubtitles)
        player.clearLastError()
        await("interception ownership error cleared") { player.state.value.error == null }
        player.command("set", "options/sub-text-intercept", "yes")
        await("commands cannot bypass interception ownership") {
            (player.state.value.error as? PlayerError.ReservedProperty)?.name == "sub-text-intercept"
        }
        assertFalse(player.state.value.interceptsTextSubtitles)
        player.command("set", "options/vo", "null")
        await("renderer ownership error") { (player.state.value.error as? PlayerError.ReservedProperty)?.name == "vo" }
        assertEquals("gpu-next", player.state.value.diagnostics.videoOutput)
    }

    @Test fun explicitNativeOutputReportsFailureWithoutSwitchingToGpu() {
        val player = MPVPlayer(instrumentation.targetContext, PlayerConfiguration(videoOutput = VideoOutput.NATIVE_SURFACE,
            audio = AudioConfiguration(AudioConfiguration.AudioSession.HOST_MANAGED)))
        try {
            ActivityScenario.launch(PlaybackTestActivity::class.java).use { activity ->
                activity.onActivity { it.video.player = player }
                player.load(fixture("image-webp-animated.webp"))
                await("unsupported explicit native output reports error") { player.state.value.state == PlaybackState.FAILED }
                assertTrue(player.state.value.error is PlayerError.NativeVideoOutputUnavailable)
                assertNotEquals("gpu-next", player.state.value.diagnostics.videoOutput)
            }
        } finally { player.close() }
    }

    @Test fun eventDeliverySurvivesIdleBurstsAndRepeatedClose() = session { player, _ ->
        // No playback timer is running here. Commands must still wake event delivery.
        Thread.sleep(300)
        player.setVolume(37.0)
        await("idle property update") { player.state.value.volume == 37.0 }
        player.load(fixture("multitrack.mkv"))
        await("load") { player.state.value.position > .2 }
        player.pause(); await("pause") { player.state.value.paused }
        Thread.sleep(300)
        repeat(150) { player.setVolume((it % 100).toDouble()) }
        player.setVolume(42.0); player.seekTo(2.0)
        await("burst and paused seek") { player.state.value.volume == 42.0 && kotlin.math.abs(player.state.value.position - 2.0) < .15 }
        player.play(); await("resume after idle") { player.state.value.position > 2.2 }
        player.close()
        val context = instrumentation.targetContext
        repeat(12) {
            val temporary = MPVPlayer(context, PlayerConfiguration(audio = AudioConfiguration(AudioConfiguration.AudioSession.HOST_MANAGED)))
            temporary.close(); temporary.close()
        }
        await("closed players release all worker and event threads") {
            Thread.getAllStackTraces().keys.none { it.isAlive && it.name.startsWith("MPVUI ") }
        }
    }
    @Test fun detailedDiagnosticsAreOptInAndStopChangingWhilePaused() = session { player, _ ->
        player.load(fixture("baseline.mp4"))
        await("playback") { player.state.value.position > .2 }
        assertTrue(player.state.value.diagnostics.renderPasses.isEmpty())
        assertNotNull(player.state.value.diagnostics.videoCodec)
        player.setDiagnosticsEnabled(true)
        await("requested GPU diagnostics") { player.state.value.diagnostics.renderPasses.isNotEmpty() }
        player.pause()
        await("paused") { player.state.value.paused }
        Thread.sleep(300)
        val diagnostics = player.state.value.diagnostics
        Thread.sleep(1100)
        assertSame("Paused playback does not rebuild diagnostics", diagnostics, player.state.value.diagnostics)
        player.setDiagnosticsEnabled(false)
        await("detailed diagnostics disabled") { !player.state.value.isDiagnosticsEnabled }
        assertEquals(diagnostics.renderPasses, player.state.value.diagnostics.renderPasses)
        player.play()
        await("resumed") { player.state.value.position > 1.5 }
        assertEquals(diagnostics.renderPasses, player.state.value.diagnostics.renderPasses)
    }
    @Test fun replacingPlayingMediaResetsDecoderForTheNewItem() {
        val player = MPVPlayer(instrumentation.targetContext, PlayerConfiguration(audio = AudioConfiguration(AudioConfiguration.AudioSession.HOST_MANAGED)))
        try {
            ActivityScenario.launch(PlaybackTestActivity::class.java).use { activity ->
                activity.onActivity { it.video.player = player }
                val baseline = fixture("baseline.mp4")
                val multitrack = fixture("multitrack.mkv")
                for (source in listOf(baseline, multitrack, baseline)) {
                    player.load(source)
                    await("replacement loads its own tracks and advances", 30000) {
                        val state = player.state.value
                        val matches = if (source == multitrack) state.audioTracks.size >= 2 else state.audioTracks.size == 1 && state.subtitleTracks.isEmpty()
                        matches && state.position > .2 && state.hasVideoFrame
                    }
                    assertNull(player.state.value.error)
                    assertFrame(activity, "playing media replacement")
                }
            }
        } finally { player.close() }
    }
    @Test fun codecMatrixDecodesAndAdvancesOnRealSurface() = session { player, activity ->
        val fixtures = listOf("baseline.mp4", "video-hevc-8bit.mkv", "video-vp9.mkv", "video-av1-10bit.mkv", "color-hdr10.mkv", "color-hlg.mkv", "video-h264-120fps.mkv", "image-webp-animated.webp", "interlaced-480i-bottom.mkv", "interlaced-576i-top.mkv", "interlaced-1080i-top.mkv", "audio-ac3-stereo.mka", "audio-eac3-stereo.mka", "audio-ac3-5.1.mka", "audio-eac3-5.1.mka", "audio-pcm-mono.mka", "audio-pcm-stereo.mka", "audio-pcm-5.1.mka", "audio-pcm-7.1.mka")
        fixtures.forEach { name ->
            player.load(fixture(name))
            await("$name failed to advance: ${player.state.value}", 30000) { (player.state.value.position > 0.1 && (name.endsWith("mka") || player.state.value.hasVideoFrame)) || player.state.value.error != null }
            assertNull("$name: ${player.state.value.error}", player.state.value.error)
            assertTrue(name, player.state.value.tracks.isNotEmpty())
            assertTrue(name, player.state.value.duration > 0)
            if (!name.endsWith("mka")) {
                assertTrue(name, player.state.value.dimensions.width > 0)
                assertFrame(activity, name)
            }
            player.stop()
            await("stop $name") { player.state.value.state == PlaybackState.STOPPED }
        }
    }
    private fun assertFrame(activity: ActivityScenario<PlaybackTestActivity>, name: String) {
        val bitmap = Bitmap.createBitmap(160, 90, Bitmap.Config.ARGB_8888)
        val latch = CountDownLatch(1)
        var result = -1
        activity.onActivity { PixelCopy.request(it.video, bitmap, { status -> result = status; latch.countDown() }, Handler(Looper.getMainLooper())) }
        assertTrue(latch.await(5, TimeUnit.SECONDS))
        assertEquals("$name has no rendered frame", PixelCopy.SUCCESS, result)
        val pixels = IntArray(bitmap.width * bitmap.height)
        bitmap.getPixels(pixels, 0, bitmap.width, 0, 0, bitmap.width, bitmap.height)
        // The WebP fixture intentionally contains solid primary frames.
        assertTrue("$name is a blank frame", pixels.any { (it and 0x00FFFFFF) > 0x00101010 })
        bitmap.recycle()
    }
    @Test fun seekTracksSubtitlesAndSurfaceRecreation() = session { player, activity ->
        player.load(fixture("multitrack.mkv"))
        await("load multitrack") { player.state.value.position > .2 }
        player.pause(); await("pause") { player.state.value.state == PlaybackState.PAUSED }
        player.setPlaybackRate(1.5); player.setVolume(42.0); player.setMuted(true)
        await("audio controls") { player.state.value.playbackRate == 1.5 && player.state.value.volume == 42.0 && player.state.value.muted }
        assertTrue(player.state.value.audioTracks.size >= 2)
        val audio = player.state.value.audioTracks.last(); player.selectTrack(audio.id)
        await("audio selection") { player.state.value.audioTracks.any { it.id == audio.id && it.isSelected } }
        player.seekTo(1.5); await("seek") { kotlin.math.abs(player.state.value.position - 1.5) < .15 }
        val subs = player.state.value.subtitleTracks
        assertTrue(subs.size >= 2)
        player.selectSubtitle(subs[0].id); player.selectSubtitle(subs[1].id, SubtitleRole.SECONDARY)
        await("dual subtitle selection") { player.state.value.subtitleTracks.count { it.isSelected } == 2 }
        player.selectSubtitle(subs[0].id, SubtitleRole.SECONDARY)
        await("selecting the same subtitle in another slot moves it") {
            player.state.value.subtitleTracks.none { it.subtitleRole == SubtitleRole.PRIMARY } &&
                player.state.value.subtitleTracks.any { it.id == subs[0].id && it.subtitleRole == SubtitleRole.SECONDARY }
        }
        player.selectSubtitle(subs[0].id); player.selectSubtitle(subs[1].id, SubtitleRole.SECONDARY)
        await("both subtitle slots can be restored") { player.state.value.subtitleTracks.count { it.isSelected } == 2 }
        player.setTextSubtitleInterceptionEnabled(true)
        val cues = runBlocking { player.textSubtitleSnapshots(subs[0].id) }
        assertTrue("timed cue query", cues.isNotEmpty())
        val wrongType = runCatching { runBlocking {
            player.textSubtitleSnapshots(TrackIdentifier(TrackType.AUDIO, subs[0].id.mpvId))
        } }
        assertTrue("track type survives transport to the shared query validator", wrongType.isFailure)
        activity.recreate()
        activity.onActivity { it.video.player = player }
        player.play(); await("resume after recreation") { player.state.value.position > 1.7 }
        assertFrame(activity, "recreated surface")
    }
    @Test fun gpuInterceptionDeliversBothRolesAndClearsOnDisableAndReplacement() = session { player, _ ->
        player.setTextSubtitleInterceptionEnabled(true)
        player.load(fixture("multitrack.mkv"), autoPlay = false, startTime = 1.0)
        val generation = player.loadGeneration
        await("interception enabled before the first paused frame") {
            player.state.value.loadGeneration == generation && player.state.value.hasVideoFrame && player.state.value.interceptsTextSubtitles
        }
        val subtitles = player.state.value.subtitleTracks
        player.selectSubtitle(subtitles[0].id)
        player.selectSubtitle(subtitles[1].id, SubtitleRole.SECONDARY)
        await("both intercepted cues are delivered while paused") { player.state.value.subtitles.regions.map { it.role }.toSet().size == 2 }
        val streamed = runBlocking { player.textSubtitleStream.first() }
        assertEquals(player.state.value.subtitles, streamed)
        assertTrue(player.state.value.subtitles.regions.any { it.text.contains("first cue") })
        assertTrue(player.state.value.subtitles.regions.any { it.text.contains("EN track cue 1") })
        player.seekTo(5.0)
        await("paused seek refreshes cues") { player.state.value.subtitles.regions.any { it.text.contains("EN track cue 2") } }
        player.setSubtitlesVisible(false)
        await("primary visibility is respected") { player.state.value.subtitles.regions.none { it.role == SubtitleRole.PRIMARY } }
        player.selectSubtitle(null, SubtitleRole.SECONDARY)
        await("secondary Off removes the last cue") { player.state.value.subtitles.regions.isEmpty() }
        player.load(fixture("baseline.mp4"), autoPlay = false)
        await("new media clears subtitles and carries its load identity") {
            player.state.value.loadGeneration == player.loadGeneration && player.state.value.hasVideoFrame && player.state.value.subtitleTracks.isEmpty()
        }
        assertTrue(player.state.value.subtitles.regions.isEmpty())
        assertTrue(player.state.value.interceptsTextSubtitles)
        await("metadata and diagnostics are exposed") {
            val state = player.state.value
            state.container != null && state.fileSize != null && state.diagnostics.audioOutput != null && state.diagnostics.startLatencySeconds != null
        }
        assertEquals("gpu-next", player.state.value.diagnostics.videoOutput)
        assertNull(player.state.value.error)
    }
    @Test fun invalidMediaRecoversAndClosedPlayerDoesNotCrash() = session { player, _ ->
        player.load("/definitely-missing-mpvui.mkv")
        await("invalid media error") { player.state.value.state == PlaybackState.FAILED }
        assertTrue(player.state.value.error is PlayerError.LoadFailed)
        player.load(fixture("baseline.mp4"))
        await("recovery") { player.state.value.position > .2 }
        assertNull(player.state.value.error)
        player.close(); player.close(); player.play(); player.seekTo(1.0)
    }
    @Test fun scopedContentUriPreservesUnicodeAndCanSeek() = session { player, activity ->
        val original = File(fixture("baseline.mp4"))
        val media = File(original.parentFile, "日本語 🎬.mp4").also { original.copyTo(it, overwrite = true) }
        val uri = Uri.Builder().scheme("content").authority("${instrumentation.targetContext.packageName}.mpvui-fixtures").appendPath(media.name).build()
        player.load(uri)
        await("content URI playback") { player.state.value.position > .2 || player.state.value.error != null }
        assertNull(player.state.value.error)
        player.pause(); player.seekTo(1.0)
        await("content URI seek") { kotlin.math.abs(player.state.value.position - 1.0) < .15 }
        assertFrame(activity, "content URI")
    }

    @Test fun apkAssetWithoutAnAuthorityCanLoadAndSeek() = session { player, _ ->
        player.load("asset:/baseline.mp4", autoPlay = false, startTime = 1.0)
        await("APK asset opens through the shared Swift source adapter", details = { player.state.value }) {
            player.state.value.hasVideoFrame && player.state.value.paused
        }
        assertNull(player.state.value.error)
        player.seekTo(3.0)
        await("APK asset can seek") { kotlin.math.abs(player.state.value.position - 3.0) < .15 }
    }
    @Test fun networkStreamDecodesThroughLibmpv() = session { player, _ ->
        val bytes = File(fixture("baseline.mp4")).readBytes()
        ServerSocket(0).use { server ->
            val handler = thread(isDaemon = true) {
                try { while (!server.isClosed) server.accept().use { socket ->
                    val reader = socket.getInputStream().bufferedReader()
                    var range = 0
                    while (true) {
                        val line = reader.readLine() ?: break
                        if (line.isEmpty()) break
                        if (line.startsWith("Range: bytes=", ignoreCase = true)) range = line.substringAfter('=').substringBefore('-').toIntOrNull() ?: 0
                    }
                    val out = socket.getOutputStream()
                    val header = "HTTP/1.1 206 Partial Content\r\nContent-Type: video/mp4\r\nAccept-Ranges: bytes\r\nContent-Range: bytes $range-${bytes.size - 1}/${bytes.size}\r\nContent-Length: ${bytes.size - range}\r\nConnection: close\r\n\r\n"
                    out.write(header.toByteArray()); out.write(bytes, range, bytes.size - range); out.flush()
                } } catch (_: Exception) { /* socket closes when the test finishes */ }
            }
            player.load("http://127.0.0.1:${server.localPort}/baseline.mp4")
            await("HTTP stream playback") { player.state.value.position > .2 || player.state.value.error != null }
            assertNull(player.state.value.error)
            player.stop()
            server.close(); handler.join(2000)
        }
    }
    @Test fun automaticDecoderAndMultiplePlayersRemainIndependent() = session { first, activity ->
        val second = MPVPlayer(instrumentation.targetContext, PlayerConfiguration(audio = AudioConfiguration(AudioConfiguration.AudioSession.HOST_MANAGED), logLevel = LogLevel.DEBUG, additionalOptions = mapOf("log-file" to File(instrumentation.targetContext.getExternalFilesDir(null), "automatic-decoder.log").absolutePath)))
        var secondView: MPVPlayerView? = null
        activity.onActivity {
            val original = it.video
            (original.parent as ViewGroup).removeView(original)
            val layout = LinearLayout(it).apply { orientation = LinearLayout.VERTICAL }
            layout.addView(original, LinearLayout.LayoutParams(-1, 0, 1f))
            secondView = MPVPlayerView(it).apply { player = second }
            layout.addView(secondView, LinearLayout.LayoutParams(-1, 0, 1f))
            it.setContentView(layout)
        }
        try {
            val media = fixture("baseline.mp4")
            first.load(media); second.load(media)
            try { await("both independent players render", 30000) { first.state.value.hasVideoFrame && second.state.value.hasVideoFrame } }
            catch (e: AssertionError) {
                System.err.println(File(instrumentation.targetContext.getExternalFilesDir(null), "automatic-decoder.log").readText().takeLast(7000))
                throw AssertionError("first=${first.state.value}; second=${second.state.value}", e)
            }
            first.pause(); second.setVolume(23.0)
            await("independent commands") { first.state.value.paused && second.state.value.volume == 23.0 }
            assertFalse(second.state.value.paused)
            assertEquals(100.0, first.state.value.volume, .01)
            second.close()
            first.seekTo(1.0); first.play()
            await("closing one player leaves the other alive") { first.state.value.position > 1.2 }
            assertNull(first.state.value.error)
        } finally { runCatching { activity.onActivity { secondView?.player = null } }; second.close() }
    }
    @Test fun styledAndBitmapSubtitlesAreComposited() = session { player, activity ->
        player.setTextSubtitleInterceptionEnabled(true)
        player.load(fixture("subtitles.mkv"))
        await("subtitle fixture") { player.state.value.position > .3 && player.state.value.hasVideoFrame }
        player.pause()
        val tracks = player.state.value.subtitleTracks
        assertEquals(setOf("ass", "hdmv_pgs_subtitle", "dvd_subtitle", "dvb_subtitle"), tracks.map { it.codec }.toSet())
        fun brightPixels(): Int {
            val bitmap = Bitmap.createBitmap(160, 90, Bitmap.Config.ARGB_8888)
            val latch = CountDownLatch(1)
            var status = -1
            activity.onActivity { PixelCopy.request(it.video, bitmap, { status = it; latch.countDown() }, Handler(Looper.getMainLooper())) }
            assertTrue(latch.await(5, TimeUnit.SECONDS)); assertEquals(PixelCopy.SUCCESS, status)
            var count = 0
            for (y in 0 until bitmap.height) for (x in 0 until bitmap.width) {
                val pixel = bitmap.getPixel(x, y)
                if ((pixel shr 16 and 255) > 200 && (pixel shr 8 and 255) > 200 && (pixel and 255) > 200) count++
            }
            bitmap.recycle()
            return count
        }
        tracks.forEach { track ->
            player.selectSubtitle(null); player.seekTo(1.0)
            await("${track.codec} clear previous subtitle") { brightPixels() == 0 }
            player.selectSubtitle(track.id); player.seekTo(1.0)
            await("${track.codec} must composite white subtitle pixels") { brightPixels() > 4 }
            assertNull(player.state.value.error)
        }
    }
    @Test fun pausedSurfaceResizeKeepsVideoCentered() = session { player, activity ->
        player.load(fixture("subtitles.mkv"))
        await("resize fixture") { player.state.value.position > .3 && player.state.value.hasVideoFrame }
        player.pause(); player.selectSubtitle(null)
        await("paused") { player.state.value.paused }
        activity.onActivity { it.video.layoutParams = it.video.layoutParams.apply { width = 480; height = 270 } }
        await("paused video must redraw centered in its new bounds") {
            val bitmap = Bitmap.createBitmap(160, 90, Bitmap.Config.ARGB_8888)
            val latch = CountDownLatch(1)
            var status = -1
            activity.onActivity { PixelCopy.request(it.video, bitmap, { status = it; latch.countDown() }, Handler(Looper.getMainLooper())) }
            assertTrue(latch.await(5, TimeUnit.SECONDS)); assertEquals(PixelCopy.SUCCESS, status)
            val center = bitmap.getPixel(80, 45)
            val corner = bitmap.getPixel(5, 5)
            bitmap.recycle()
            (center and 255) > 25 && (center shr 8 and 255) > 15 && (corner and 0xFFFFFF) < 0x050505
        }
        assertTrue(player.state.value.paused)
    }
    @Test fun bitmapSubtitleColorsPreserveChannelOrder() = session { player, activity ->
        player.setTextSubtitleInterceptionEnabled(true)
        player.load(fixture("subtitles.mkv"), autoPlay = false, startTime = 1.0)
        await("colored bitmap frame") { player.state.value.hasVideoFrame }
        player.selectSubtitle(player.state.value.subtitleTracks.single { it.title == "Color channel order" }.id)
        player.seekTo(1.0)
        await("PGS preserves red and blue in their authored positions") {
            val bitmap = Bitmap.createBitmap(320, 180, Bitmap.Config.ARGB_8888)
            val latch = CountDownLatch(1)
            var status = -1
            activity.onActivity { PixelCopy.request(it.video, bitmap, { status = it; latch.countDown() }, Handler(Looper.getMainLooper())) }
            assertTrue(latch.await(5, TimeUnit.SECONDS)); assertEquals(PixelCopy.SUCCESS, status)
            var red = 0; var blue = 0; var redX = 0; var blueX = 0
            for (y in 0 until bitmap.height) for (x in 0 until bitmap.width) {
                val pixel = bitmap.getPixel(x, y)
                val r = pixel shr 16 and 255; val g = pixel shr 8 and 255; val b = pixel and 255
                if (r > 180 && g < 100 && b < 100) { red++; redX += x }
                if (b > 180 && g < 100 && r < 100) { blue++; blueX += x }
            }
            bitmap.recycle()
            red > 4 && blue > 4 && redX.toDouble() / red < blueX.toDouble() / blue
        }
        assertNull(player.state.value.error)
    }
    @Test fun nativeOutputFallsBackForUnsupportedCodec() {
        val player = MPVPlayer(instrumentation.targetContext, PlayerConfiguration(videoOutput = VideoOutput.AUTOMATIC, audio = AudioConfiguration(AudioConfiguration.AudioSession.HOST_MANAGED)))
        ActivityScenario.launch(PlaybackTestActivity::class.java).use { activity ->
            try {
                // Exercise native-output failure even on the SDR emulator.
                await("surface ready") {
                    var valid = false
                    activity.onActivity { valid = it.video.holder.surface.isValid }
                    valid
                }
                activity.onActivity { player.attachSurface(it.video.holder.surface, DisplayCapabilities(hdr10 = true)); player.resizeSurface(it.video.width, it.video.height) }
                player.load(fixture("image-webp-animated.webp"))
                await("unsupported native codec must render using GPU: ${player.state.value}") { player.state.value.hasVideoFrame || player.state.value.error != null }
                assertNull(player.state.value.error)
                assertEquals("gpu-next", player.state.value.diagnostics.videoOutput)
                assertFrame(activity, "native codec fallback")
            } finally { player.close() }
        }
    }
    @Test fun nativeVideoFailureRecoversAndSubtitleSelectionPreservesText() {
        val player = MPVPlayer(instrumentation.targetContext, PlayerConfiguration(videoOutput = VideoOutput.AUTOMATIC,
            nativeVideoFeaturePolicy = NativeVideoFeaturePolicy.PREFER_FEATURES, audio = AudioConfiguration(AudioConfiguration.AudioSession.HOST_MANAGED)))
        player.setTextSubtitleInterceptionEnabled(true)
        ActivityScenario.launch(PlaybackTestActivity::class.java).use { activity ->
            try {
                await("surface ready") {
                    var valid = false
                    activity.onActivity { valid = it.video.holder.surface.isValid }
                    valid
                }
                // Test renderer selection on the emulator; this does not claim physical HDR output.
                activity.onActivity {
                    player.attachSurface(it.video.holder.surface, DisplayCapabilities(hdr10 = true))
                    player.resizeSurface(it.video.width, it.video.height)
                }
                player.load(fixture("multitrack.mkv"), autoPlay = false, startTime = 1.5)
                try {
                    await("native video and intercepted text") { player.state.value.hasVideoFrame && player.state.value.subtitles.regions.isNotEmpty() }
                } catch (error: AssertionError) { throw AssertionError("Native startup: ${player.state.value}", error) }
                val initialOutput = player.state.value.diagnostics.videoOutput
                assertTrue("fallback preserves pause", player.state.value.paused)
                assertEquals("fallback preserves position", 1.5, player.state.value.position, .1)
                if (initialOutput != "mediacodec_embed") {
                    assertEquals("gpu-next", initialOutput)
                    assertTrue(player.state.value.diagnostics.fallbackReasons.any { it.contains("Native video decoder unavailable") })
                }
                val tracks = player.state.value.subtitleTracks
                player.selectSubtitle(tracks.first { it.codec == "subrip" }.id, SubtitleRole.SECONDARY)
                await("text selection remains native") { player.state.value.subtitles.regions.any { it.role == SubtitleRole.SECONDARY } }
                assertEquals(initialOutput, player.state.value.diagnostics.videoOutput)
                player.selectSubtitle(tracks.first { it.codec == "ass" }.id)
                await("styled subtitles switch to the compositor") { player.state.value.diagnostics.videoOutput == "gpu-next" }
                if (initialOutput == "mediacodec_embed") {
                    player.play()
                    await("GPU playback advances after feature switch") { player.state.value.position > 2.0 }
                    assertTrue("A subtitle renderer switch preserves MediaCodec decoding",
                        player.state.value.diagnostics.hardwareDecoder?.startsWith("mediacodec") == true)
                }
                assertTrue((player.state.value.videoFeatureCapabilities[VideoFeature.NATIVE_SUBTITLES].availability == VideoFeatureCapabilities.Availability.AVAILABLE))
                assertTrue(player.state.value.interceptsTextSubtitles)
                assertNull(player.state.value.error)
            } finally { player.close() }
        }
    }
    @Test fun inbandDolbyVisionWithoutContainerTagsPreservesColors() {
        val name = "dolby-vision-inband.hevc"
        assumeTrue("Run Build/Android/prepare_test_media.py with the optional Dolby Vision chart", name in instrumentation.context.assets.list("").orEmpty())
        val player = MPVPlayer(instrumentation.targetContext, PlayerConfiguration(audio = AudioConfiguration(AudioConfiguration.AudioSession.HOST_MANAGED), autoPlay = false))
        ActivityScenario.launch(PlaybackTestActivity::class.java).use { activity ->
            activity.onActivity { it.video.player = player }
            try {
                player.load(fixture(name))
                await("in-band Dolby Vision decode", 30000) { (player.state.value.hasVideoFrame && player.state.value.diagnostics.hardwareDecoder != null) || player.state.value.error != null }
                assertNull(player.state.value.error)
                assertEquals("no", player.state.value.diagnostics.hardwareDecoder)
                assertEquals(DynamicRange.DOLBY_VISION, player.state.value.hdr.source.dynamicRange)
                assertDolbyPrimaryColors(activity, name)
            } finally { activity.onActivity { it.video.player = null }; player.close() }
        }
    }
    private fun assertDolbyPrimaryColors(activity: ActivityScenario<PlaybackTestActivity>, name: String) {
        val bitmap = Bitmap.createBitmap(160, 90, Bitmap.Config.ARGB_8888)
        val latch = CountDownLatch(1)
        var result = -1
        activity.onActivity {
            val view = it.video
            val width = minOf(view.width, view.height * 16 / 9)
            val height = width * 9 / 16
            val x = (view.width - width) / 2; val y = (view.height - height) / 2
            PixelCopy.request(view, Rect(x, y, x + width, y + height), bitmap, { status -> result = status; latch.countDown() }, Handler(Looper.getMainLooper()))
        }
        assertTrue(latch.await(5, TimeUnit.SECONDS)); assertEquals(PixelCopy.SUCCESS, result)
        for ((channel, xs) in listOf(12..17, 33..38, 55..60).withIndex()) {
            val rgb = DoubleArray(3)
            for (y in 36..41) for (x in xs) {
                val pixel = bitmap.getPixel(x, y)
                for (c in 0..2) rgb[c] += ((pixel shr (16 - c * 8)) and 255) / (255.0 * 36)
            }
            assertTrue("$name primary $channel too dark: ${rgb.toList()}", rgb[channel] > .2)
            for (other in 0..2) if (other != channel) assertTrue("$name incorrect hue: ${rgb.toList()}", rgb[channel] > rgb[other] * 2)
        }
        File(instrumentation.targetContext.getExternalFilesDir(null), "$name.png").outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
        bitmap.recycle()
    }
    @Test fun generatedDolbyVisionProfilesDecodeWithMetadata() = session { player, activity ->
        // Generated Profile 5 is useful for metadata/output decisions, but its
        // synthetic base layer is not an IPT-PQ-c2 color reference.
        for (name in listOf("dolby-vision-p5.mp4", "dolby-vision-p81.mp4", "dolby-vision-p84.mp4",
            "dolby-vision-p81-declared-extended.ts", "dolby-vision-p81-extended.ts")) {
            player.load(fixture(name), autoPlay = false, startTime = .5)
            await("$name decoded with Dolby Vision metadata", 30000) {
                (player.state.value.hasVideoFrame && player.state.value.hdr.source.dynamicRange == DynamicRange.DOLBY_VISION) ||
                    player.state.value.error != null
            }
            assertNull("$name: ${player.state.value.error}", player.state.value.error)
            assertEquals("gpu-next", player.state.value.diagnostics.videoOutput)
            assertFrame(activity, name)
            player.stop()
            await("stop $name") { player.state.value.state == PlaybackState.STOPPED }
        }
    }
    @Test fun dolbyVisionReferenceChartRendersCorrectPrimaryColors() {
        val name = "dolby-vision-p5-chart.mp4"
        assumeTrue("Add dolby-vision-p5-chart.mp4 or set MPVUI_DOLBY_VISION_CHART", name in instrumentation.context.assets.list("").orEmpty())
        val player = MPVPlayer(instrumentation.targetContext, PlayerConfiguration(audio = AudioConfiguration(AudioConfiguration.AudioSession.HOST_MANAGED), autoPlay = false, startTime = 25.0))
        ActivityScenario.launch(PlaybackTestActivity::class.java).use { activity ->
            activity.onActivity { it.video.player = player }
            try {
                player.load(fixture(name))
                await("$name decode: ${player.state.value}", 30000) { (player.state.value.position >= 24.9 && player.state.value.hasVideoFrame && player.state.value.diagnostics.hardwareDecoder != null) || player.state.value.error != null }
                assertNull(player.state.value.error)
                assertTrue("Dolby RPU must reach the GPU without Surface RGB conversion",
                    player.state.value.diagnostics.hardwareDecoder in setOf("no", "mediacodec"))
                assertEquals(DynamicRange.DOLBY_VISION, player.state.value.hdr.source.dynamicRange)
                assertDolbyPrimaryColors(activity, name)
            } finally { activity.onActivity { it.video.player = null }; player.close() }
        }
    }
}
