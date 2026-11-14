package mpvui

import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.Rect
import android.media.MediaCodecList
import android.media.MediaFormat
import android.net.LocalServerSocket
import android.net.LocalSocket
import android.net.LocalSocketAddress
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.system.Os
import android.view.PixelCopy
import android.view.ViewGroup
import android.widget.LinearLayout
import androidx.test.core.app.ActivityScenario
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.ext.junit.runners.AndroidJUnit4
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.withTimeout
import org.junit.Assert.*
import org.junit.Test
import org.junit.Ignore
import org.junit.Assume.assumeTrue
import org.junit.runner.RunWith
import org.junit.runners.model.MultipleFailureException
import org.json.JSONArray
import org.json.JSONObject
import java.io.DataInputStream
import java.io.File
import java.io.IOException
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.ShortBuffer
import java.security.KeyStore
import java.security.MessageDigest
import java.util.Base64
import java.util.concurrent.CountDownLatch
import java.util.concurrent.FutureTask
import java.util.concurrent.TimeUnit
import javax.net.ServerSocketFactory
import javax.net.ssl.KeyManagerFactory
import javax.net.ssl.SSLContext
import kotlin.concurrent.thread
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.sin
import kotlin.math.sqrt

@RunWith(AndroidJUnit4::class)
class PlaybackIntegrationTest {
    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()
    private fun fixture(name: String): String {
        val file = File(instrumentation.targetContext.cacheDir, name)
        file.parentFile?.mkdirs()
        instrumentation.context.assets.open(name).use { input -> file.outputStream().use { input.copyTo(it) } }
        return file.absolutePath
    }
    private fun await(message: String, timeout: Long = 20000, details: (() -> Any?)? = null, predicate: () -> Boolean) {
        val deadline = System.nanoTime() + timeout * 1_000_000
        while (!predicate() && System.nanoTime() < deadline) Thread.sleep(40)
        assertTrue("$message: ${details?.invoke() ?: ""}", predicate())
    }
    private fun session(
        options: Map<String, String> = emptyMap(),
        hardwareDecoding: HardwareDecoding = HardwareDecoding.DISABLED,
        deinterlace: DeinterlacePolicy = DeinterlacePolicy(),
        dolbyVisionPolicy: DolbyVisionPolicy = DolbyVisionPolicy.STRICT,
        block: (MPVPlayer, ActivityScenario<PlaybackTestActivity>) -> Unit,
    ) {
        val player = MPVPlayer(instrumentation.targetContext, PlayerConfiguration(
            hardwareDecoding = hardwareDecoding,
            audio = AudioConfiguration(AudioConfiguration.AudioSession.HOST_MANAGED),
            deinterlace = deinterlace,
            dolbyVisionPolicy = dolbyVisionPolicy,
            additionalOptions = options,
        ))
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
        val video = mapOf(
            "baseline.mp4" to "h264", "video-mp42.asf" to "msmpeg4v2", "video-hevc-8bit.mkv" to "hevc",
            "video-vp9.mkv" to "vp9", "video-av1-10bit.mkv" to "av1", "color-hdr10.mkv" to "hevc",
            "color-hlg.mkv" to "hevc", "video-h264-120fps.mkv" to "h264", "image-webp-animated.webp" to "webp_anim",
            "interlaced-480i-bottom.mkv" to "mpeg2video", "interlaced-576i-top.mkv" to "mpeg2video",
            "interlaced-1080i-top.mkv" to "mpeg2video",
        )
        val audio = mapOf(
            "audio-ac3-stereo.mka" to "ac3", "audio-eac3-stereo.mka" to "eac3", "audio-ac3-5.1.mka" to "ac3",
            "audio-eac3-5.1.mka" to "eac3", "audio-pcm-mono.mka" to "pcm_s16le", "audio-pcm-stereo.mka" to "pcm_s16le",
            "audio-pcm-5.1.mka" to "pcm_s16le", "audio-pcm-7.1.mka" to "pcm_s16le",
        )
        for ((name, codec) in video + audio) {
            val hasVideo = name in video
            val type = if (hasVideo) TrackType.VIDEO else TrackType.AUDIO
            player.load(fixture(name))
            await("$name advances with selected $codec", 30000, details = { player.state.value }) {
                val state = player.state.value
                state.error != null || (state.position > 0.1 && (!hasVideo || state.hasVideoFrame) &&
                    state.tracks.any { it.type == type && it.isSelected && it.codec == codec })
            }
            assertNull("$name: ${player.state.value.error}", player.state.value.error)
            assertTrue(name, player.state.value.duration > 0)
            if (hasVideo) {
                assertTrue(name, player.state.value.dimensions.width > 0)
                assertFrame(activity, name)
            }
            player.stop()
            await("stop $name") { player.state.value.state == PlaybackState.STOPPED }
        }
    }
    @Test fun standaloneAudioSelectsItsCodecAndResumesAfterSeeking() = session { player, _ ->
        val fixtures = mapOf(
            "audio-flac.flac" to "flac", "audio-alac.m4a" to "alac", "audio-mp3.mp3" to "mp3",
            "audio-vorbis.ogg" to "vorbis", "audio-opus.ogg" to "opus", "audio-pcm.wav" to "pcm_s16le",
            "audio-adts.aac" to "aac",
        )
        for ((name, codec) in fixtures) {
            player.load(fixture(name), autoPlay = false)
            await("$name selects its audio track", details = { player.state.value }) {
                val state = player.state.value
                state.paused && state.audioTracks.singleOrNull()?.let { it.isSelected && it.codec == codec } == true
            }
            player.seekTo(1.5)
            await("$name paused seek") { kotlin.math.abs(player.state.value.position - 1.5) < .25 }
            player.play()
            await("$name audio clock advances") { player.state.value.position > 2.0 }
            assertNull(name, player.state.value.error)
            player.stop()
            await("stop $name") { player.state.value.state == PlaybackState.STOPPED }
        }
    }
    @Test fun localVideoDecodersProduceFramesInTheirContainer() =
        expectVideoFixtures(localMediaCases("video").filterNot {
            it.getString("format") in setOf("asf_o", "cdg", "hxvs", "ifv", "kux", "mtv", "ser", "simbiosis_imx", "ty", "usm") ||
                it.getString("file") == "codecs-broadcast-mjpeg.wtv"
        })

    @Test fun wtvMjpegPresentsBothAuthoredPictures() =
        expectAuthoredColors(listOf(localMediaCases("video").single { it.getString("file") == "codecs-broadcast-mjpeg.wtv" }))

    @Test fun ifvCameraReaderPlaysAvcAndPcmFromItsIndexes() {
        val clip = localMediaCases("video").single { it.getString("format") == "ifv" }
        val name = clip.getString("file")
        val options = mapOf("demuxer" to "lavf", "demuxer-lavf-format" to "ifv", "cache" to "no")
        expectVideoFixtures(listOf(clip), verifyColors = true, sessionOptions = options + ("aid" to "no"))
        val samples = capturePcm(name, options + mapOf("ad" to "pcm_s16le,-", "vid" to "no")) { state ->
            assertContainer(name, "ifv", state)
            assertEquals(name, "pcm_s16le", state.audioTracks.single { it.isSelected }.codec)
        }
        assertEquals(name, 60000, samples.limit())
        for (start in listOf(2400, 30000, 52800)) assertMonoTone(name, samples, start, 440)
    }

    @Test fun sofdecReaderPresentsMpeg1AvcAndVp9Pictures() {
        for (clip in localMediaCases("video").filter { it.getString("format") == "usm" }) {
            expectVideoFixtures(listOf(clip), verifyColors = true, sessionOptions = mapOf("aid" to "no", "demuxer-lavf-format" to "usm"))
        }
    }

    @Test fun tivoReadersPresentVideoWithMp2AndAc3Tracks() {
        for (clip in localMediaCases("video").filter { it.getString("format") == "ty" }) {
            expectVideoFixtures(listOf(clip), verifyColors = true, sessionOptions = mapOf("aid" to "no"))
        }
    }

    @Test fun blurayTransportClipsPreserveTheirAuthoredFramesAndPcm() {
        val options = mapOf("vd" to "h264,-", "ad" to "pcm_bluray,-")
        for ((clip, color, tone) in listOf(Triple("00001", 0, 440), Triple("00002", 2, 880))) {
            val name = "bluray/BDMV/STREAM/$clip.m2ts"
            session(options) { player, activity ->
                player.load(fixture(name), autoPlay = false)
                await("$name presents its opening frame", details = { player.state.value }) {
                    player.state.value.hasVideoFrame || player.state.value.error != null
                }
                val state = player.state.value
                assertNull(name, state.error)
                assertContainer(name, "mpegts", state)
                assertEquals(name, "h264", state.videoTracks.single { it.isSelected }.codec)
                assertEquals(name, "pcm_bluray", state.audioTracks.single { it.isSelected }.codec)
                awaitPrimaryColor(activity, name, color)
            }
            val pcm = capturePcm(name, options + ("vid" to "no")) { state ->
                assertContainer(name, "mpegts", state)
                assertEquals(name, "pcm_bluray", state.audioTracks.single { it.isSelected }.codec)
            }
            assertEquals(name, 2.0, pcm.limit() / 48000.0, .1)
            assertMonoTone(name, pcm, 24000, tone)
        }
    }

    @Test fun blurayTransportClipsSelectTheAlternateLpcmAndRenderPgs() {
        val options = mapOf("vd" to "h264,-", "ad" to "pcm_bluray,-", "sid" to "1", "osd-level" to "0", "ao" to "null")
        for ((clip, tone) in listOf("00001" to 660, "00002" to 1100)) {
            val name = "bluray/BDMV/STREAM/$clip.m2ts"
            session(options) { player, activity ->
                player.load(fixture(name), autoPlay = false)
                await("$name opens with two audio tracks and one PGS track", details = { player.state.value }) {
                    player.state.value.let { it.error != null || it.hasVideoFrame && it.audioTracks.size == 2 && it.selectedSubtitle() != null }
                }
                val initial = player.state.value
                assertNull(initial.error)
                assertContainer(name, "mpegts", initial)
                assertEquals("eng", initial.audioTracks.single { it.isSelected }.language)
                assertEquals("hdmv_pgs_subtitle", initial.selectedSubtitle()?.codec)
                val alternate = initial.audioTracks.single { it.language == "spa" }
                player.selectTrack(alternate.id)
                await("$name selects Spanish LPCM") {
                    player.state.value.audioTracks.any { it.id == alternate.id && it.isSelected && it.codec == "pcm_bluray" }
                }

                player.play()
                await("$name shows its first PGS cue", details = { player.state.value.position }) {
                    player.state.value.position in .2..0.9 && brightSubtitlePixels(activity, name) > 4
                }
                await("$name clears its first PGS cue", details = { player.state.value.position }) {
                    player.state.value.position in 1.15..1.9 && brightSubtitlePixels(activity, name) == 0
                }
            }
            val pcm = capturePcm(name, mapOf("ad" to "pcm_bluray,-", "vid" to "no", "aid" to "2")) { state ->
                assertContainer(name, "mpegts", state)
                assertEquals("spa", state.audioTracks.single { it.isSelected }.language)
            }
            assertEquals(name, 2.0, pcm.limit() / 48000.0, .1)
            assertMonoTone(name, pcm, 24000, tone)
        }
    }

    @Test fun imfCompositionOpensAndSeeksAcrossItsMxfTracks() {
        val name = "imf/CPL.xml"
        fixture("imf/ASSETMAP.xml")
        for (color in listOf("red", "blue")) {
            fixture("imf/$color-video.mxf")
            fixture("imf/$color-audio.mxf")
        }
        val options = mapOf("vd" to "jpeg2000,-", "ad" to "pcm_s24le,-")
        session(options) { player, activity ->
            player.load(fixture(name), autoPlay = false)
            await("IMF opens its first MXF resource", details = { player.state.value }) {
                player.state.value.hasVideoFrame || player.state.value.error != null
            }
            val state = player.state.value
            assertNull(name, state.error)
            assertContainer(name, "imf", state)
            assertEquals("jpeg2000", state.videoTracks.single { it.isSelected }.codec)
            assertEquals("pcm_s24le", state.audioTracks.single { it.isSelected }.codec)
            assertEquals(192, state.dimensions.width)
            assertEquals(108, state.dimensions.height)
            awaitPrimaryColor(activity, "IMF first image resource", 0)
            for ((time, channel) in listOf(1.25 to 2, .25 to 0)) {
                player.seekTo(time)
                await("IMF seeks to $time", details = { player.state.value }) {
                    abs(player.state.value.position - time) < .045
                }
                awaitPrimaryColor(activity, "IMF image at $time", channel)
            }
        }
        val pcm = capturePcm(name, options + ("vid" to "no")) { state ->
            assertContainer(name, "imf", state)
            assertEquals("pcm_s24le", state.audioTracks.single { it.isSelected }.codec)
        }
        assertEquals(96000.0, pcm.limit().toDouble(), 96.0)
        assertMonoTone(name, pcm, 12000, 440)
        assertMonoTone(name, pcm, 60000, 880)
    }

    @Test fun longGopAvcSeeksToDistinctFramesInMatroskaMovAndTransportStream() {
        val containers = listOf("mkv" to "mkv", "mp4" to "mov", "ts" to "mpegts")
        for ((extension, format) in containers) {
            val name = "video-h264-long-gop.$extension"
            // The unindexed transport stream needs the full ten-second GOP of preroll.
            val options = mapOf("vd" to "h264,-", "hr-seek" to "yes", "hr-seek-demuxer-offset" to if (extension == "ts") "10" else "0")
            session(options) { player, activity ->
                player.load(fixture(name), autoPlay = false)
                await("$name presents its opening frame", details = { player.state.value }) {
                    player.state.value.hasVideoFrame || player.state.value.error != null
                }
                val state = player.state.value
                assertNull(name, state.error)
                assertContainer(name, format, state)
                assertTrue(name, state.seekable)
                assertEquals(name, "h264", state.videoTracks.single { it.isSelected }.codec)
                var previous = renderedPixels(activity, name)
                for (time in listOf(1.5, 8.25, 4.5)) {
                    player.seekTo(time)
                    await("$name reaches the frame at $time seconds", details = { player.state.value }) {
                        abs(player.state.value.position - time) < .07 && !renderedPixels(activity, name).contentEquals(previous)
                    }
                    assertFrame(activity, name)
                    previous = renderedPixels(activity, name)
                }
            }
        }
    }

    @Test fun paletteAndPackedRgbContainersPreserveTheAuthoredColors() {
        for ((name, format, codec) in listOf(
            Triple("codecs-palette-video.imx", "simbiosis_imx", "simbiosis_imx"),
            Triple("codecs-handheld-picture.mtv", "mtv", "rawvideo"),
        )) {
            session(mapOf("vd" to "$codec,-", "audio" to "no")) { player, activity ->
                player.load(fixture(name), autoPlay = false)
                await("$name presents its opening frame", details = { player.state.value }) {
                    player.state.value.hasVideoFrame || player.state.value.error != null
                }
                val state = player.state.value
                assertNull(name, state.error)
                assertContainer(name, format, state)
                assertEquals(name, codec, state.videoTracks.single { it.isSelected }.codec)
                val clip = localMediaCases("video").single { it.getString("file") == name }
                assertEquals(name, clip.getInt("width"), state.dimensions.width)
                assertEquals(name, clip.getInt("height"), state.dimensions.height)
                awaitPrimaryColor(activity, "$name opening frame", 0)
                player.play()
                awaitPrimaryColor(activity, "$name second color", 2)
            }
        }
    }

    @Test fun vp9MatroskaWithAc3OrOpusPresentsVideoAndDecodesTheAudioTone() {
        for (codec in listOf("ac3", "opus")) {
            val name = "video-vp9-$codec.mkv"
            val options = mapOf("vd" to "vp9,-", "ad" to "$codec,-")
            session(options) { player, activity ->
                player.load(fixture(name), autoPlay = false)
                await("$name opens both tracks", details = { player.state.value }) {
                    player.state.value.hasVideoFrame || player.state.value.error != null
                }
                val first = player.state.value
                assertNull(name, first.error)
                assertContainer(name, "mkv", first)
                assertEquals(name, "vp9", first.videoTracks.single { it.isSelected }.codec)
                assertEquals(name, codec, first.audioTracks.single { it.isSelected }.codec)
                assertFrame(activity, name)
                val pixels = renderedPixels(activity, name)
                player.play()
                await("$name advances and presents a new frame") {
                    player.state.value.position > .3 && !pixels.contentEquals(renderedPixels(activity, name))
                }
            }
            val pcm = capturePcm(name, options + ("vid" to "no")) { state ->
                assertContainer(name, "mkv", state)
                assertEquals(name, codec, state.audioTracks.single { it.isSelected }.codec)
            }
            assertEquals(name, 2.0, pcm.limit() / 48000.0, .12)
            for (start in listOf(4800, 36000, 72000)) assertMonoTone(name, pcm, start, 440)
        }
    }

    @Test fun cameraHxvsProbesAndPlaysBothCodecs() {
        for (clip in localMediaCases("video").filter { it.getString("format") == "hxvs" }) {
            expectVideoFixtures(listOf(clip), verifyColors = true)
        }
    }

    @Test fun kuxProbesAndPlaysFlashVideo() = expectVideoFixtures(
        listOf(localMediaCases("video").single { it.getString("format") == "kux" }),
        verifyColors = true,
    )

    @Test fun astronomySerUsesBothPackedColorFormats() {
        for (clip in localMediaCases("video").filter { it.getString("format") == "ser" }) {
            expectVideoFixtures(listOf(clip), verifyColors = true, sessionOptions = mapOf("demuxer" to "lavf"))
        }
    }

    @Test fun alternateAsfReaderRendersWmv2Frames() = expectVideoFixtures(
        listOf(localMediaCases("video").single { it.getString("format") == "asf_o" }),
        verifyColors = true,
        sessionOptions = mapOf("demuxer" to "lavf", "demuxer-lavf-format" to "asf_o"),
    )

    @Test fun remuxedVideoKeepsItsCodecAndDecodedFrames() =
        expectVideoFixtures(localMediaCases("mappedVideo"), verifyColors = true)

    @Test fun remuxedVideoPreservesBothAuthoredColors() = expectAuthoredColors(localMediaCases("mappedColorVideo"))

    private fun expectVideoFixtures(
        clips: List<JSONObject>,
        verifyColors: Boolean = false,
        sessionOptions: Map<String, String> = emptyMap(),
    ) {
        val failures = mutableListOf<Throwable>()
        for (clip in clips) {
            val name = clip.getString("file")
            val decoder = clip.getString("decoder")
            val input = clip.getJSONObject("mpvOptions")
            val options = input.keys().asSequence().associateWith(input::getString) +
                sessionOptions + ("vd" to "$decoder,-")
            try {
                session(options) { player, activity ->
                    player.load(fixture(name))
                    await("$name decodes with $decoder", timeout = 5000, details = { player.state.value }) {
                        val state = player.state.value
                        state.error != null || (state.hasVideoFrame && state.position > 0.12 && state.container != null)
                    }
                    val state = player.state.value
                    assertNull(name, state.error)
                    assertContainer(name, clip.getString("format"), state)
                    assertEquals(name, clip.getString("codec"), state.videoTracks.single { it.isSelected }.codec)
                    assertEquals(name, clip.getInt("width"), state.dimensions.width)
                    assertEquals(name, clip.getInt("height"), state.dimensions.height)
                    if (verifyColors) {
                        await("$name shows the source's colored bars", timeout = 5000) {
                            renderedPixels(activity, name).any { pixel ->
                                val red = pixel shr 16 and 255
                                val green = pixel shr 8 and 255
                                val blue = pixel and 255
                                maxOf(red, green, blue) - minOf(red, green, blue) > 80
                            }
                        }
                    } else {
                        assertFrame(activity, name)
                    }
                }
            } catch (error: AssertionError) {
                failures.add(error)
            }
        }
        MultipleFailureException.assertEmpty(failures)
    }

    @Test fun vc1AdvancedProfilePresentsBothAuthoredColors() = expectAuthoredColors(localMediaCases("vc1"))

    @Test fun vc1MainProfilePresentsBothAuthoredColors() = expectAuthoredColors(localMediaCases("wmv3"))

    @Test fun legacyVideoDecodersPresentBothAuthoredColors() = expectAuthoredColors(localMediaCases("colorVideo"))

    @Test fun apvProfilesPresentBothAuthoredFrames() = expectAuthoredColors(localMediaCases("apv"))

    @Test fun proresRawProfilesPreserveTheBayerDepthAndGrayscaleLevels() =
        expectAuthoredColors(
            localMediaCases("proresRAWVideo"),
            // The test surface presents the linear Bayer levels through its SDR transfer function.
            grayLevels = 173 to 201,
        )

    @Test fun avcHevcAndVp9PreserveTheDecodedChromaAndBitDepth() = expectAuthoredColors(localMediaCases("chromaVideo"))

    @Test fun referenceVideoDecodersPresentTheExpectedFrames() {
        val failures = mutableListOf<Throwable>()
        for (clip in referenceMediaCases("video")) {
            val file = clip.getString("file")
            val decoder = clip.getString("decoder")
            val options = referenceOptions(clip) + mapOf("vd" to "$decoder,-", "vid" to clip.getInt("track").toString(), "aid" to "no")
            try {
                session(options) { player, activity ->
                    player.load(fixture(file), autoPlay = false)
                    await("$file presents its opening frame", details = { player.state.value }) {
                        player.state.value.hasVideoFrame || player.state.value.error != null
                    }
                    val state = player.state.value
                    assertNull(file, state.error)
                    assertContainer(file, clip.getString("format"), state)
                    assertEquals(file, clip.getString("codec"), state.videoTracks.singleOrNull { it.isSelected }?.codec)
                    assertEquals(file, clip.getInt("width"), state.dimensions.width)
                    assertEquals(file, clip.getInt("height"), state.dimensions.height)

                    val first = renderedPixels(activity, file)
                    var latest = first
                    var changed = false
                    fun visible(pixels: IntArray): Boolean = pixels.any { pixel ->
                        (pixel shr 16 and 255) > 32 || (pixel shr 8 and 255) > 32 || (pixel and 255) > 32
                    }
                    fun differsFromFirst(pixels: IntArray): Boolean = first.indices.any { index ->
                        val before = first[index]
                        val after = pixels[index]
                        abs((before shr 16 and 255) - (after shr 16 and 255)) > 12 ||
                            abs((before shr 8 and 255) - (after shr 8 and 255)) > 12 ||
                            abs((before and 255) - (after and 255)) > 12
                    }
                    val visibleAtStart = visible(first)
                    val steps = clip.getInt("frameSteps")
                    for (step in 1..steps) {
                        val previous = player.state.value.position
                        player.stepForward()
                        await("$file advances to frame $step", timeout = 3500, details = { player.state.value }) {
                            player.state.value.position > previous
                        }
                        latest = renderedPixels(activity, file)
                        changed = differsFromFirst(latest)
                        if (changed && (visibleAtStart || visible(latest))) break
                    }
                    if (steps > 0 && !changed) {
                        // A position update can arrive before the Android surface presents the last step.
                        await("$file presents different frames", timeout = 1500) {
                            latest = renderedPixels(activity, file)
                            differsFromFirst(latest)
                        }
                    }
                    assertTrue("$file presents visible pixels", visibleAtStart || visible(latest))
                }
            } catch (error: AssertionError) {
                failures.add(error)
            }
        }
        MultipleFailureException.assertEmpty(failures)
    }

    @Test fun referenceAudioDecodersPreserveThePcmEnvelope() {
        val failures = mutableListOf<Throwable>()
        for (clip in referenceMediaCases("audio")) {
            val file = clip.getString("file")
            val decoder = clip.getString("decoder")
            val options = mapOf("length" to "2.5") + referenceOptions(clip) +
                mapOf("ad" to "$decoder,-", "aid" to clip.getInt("track").toString(), "vid" to "no")
            try {
                val pcm = capturePcm(file, options) { state ->
                    assertContainer(file, clip.getString("format"), state)
                    assertEquals(file, clip.getString("codec"), state.audioTracks.singleOrNull { it.isSelected }?.codec)
                }
                assertPcmEnvelope(file, pcm, clip)
            } catch (error: AssertionError) {
                failures.add(error)
            }
        }
        MultipleFailureException.assertEmpty(failures)
    }

    private fun assertPcmEnvelope(name: String, pcm: ShortBuffer, clip: JSONObject) {
        val tolerance = clip.optInt("pcmFrameTolerance", 5760).toDouble()
        assertEquals("$name decoded sample count", clip.getInt("pcmFrames").toDouble(), pcm.limit().toDouble(), tolerance)
        val windows = clip.getJSONArray("pcmWindows")
        for (index in 0 until windows.length()) {
            val window = windows.getJSONObject(index)
            val start = window.getInt("startFrame")
            val count = window.getInt("frameCount")
            assertTrue("$name includes the PCM interval at $start", start + count <= pcm.limit())
            var sum = 0.0
            for (frame in start until start + count) {
                val sample = pcm.get(frame) / 32768.0
                sum += sample * sample
            }
            val level = window.getDouble("rms")
            assertEquals("$name PCM level at $start", level, sqrt(sum / count), level * .4 + .005)
        }
    }

    @Test fun anamorphicAvcPresentsEachVariableFrameTimestamp() = session(mapOf("vd" to "h264,-")) { player, activity ->
        val file = "codecs-avc-vfr-anamorphic.mp4"
        player.load(fixture(file), autoPlay = false)
        await("$file presents its first frame", details = { player.state.value }) {
            player.state.value.hasVideoFrame || player.state.value.error != null
        }
        val state = player.state.value
        assertNull(file, state.error)
        assertContainer(file, "mov", state)
        assertEquals("h264", state.videoTracks.single { it.isSelected }.codec)
        assertEquals(192, state.dimensions.width)
        assertEquals(108, state.dimensions.height)
        assertEquals(288, state.dimensions.displayWidth)
        assertEquals(108, state.dimensions.displayHeight)

        val times = listOf(0.0, 0.25, 0.75, 1.0, 1.125, 1.75, 2.0, 2.25, 2.75)
        for ((index, time) in times.withIndex()) {
            if (index > 0) player.stepForward()
            await("$file frame $index at $time seconds", timeout = 5000, details = { player.state.value.position }) {
                abs(player.state.value.position - time) < .002
            }
            awaitPrimaryColor(activity, "$file frame $index", index / 3)
        }
    }

    @Test fun avcHonorsTheMp4RotationMatrix() = session(mapOf("vd" to "h264,-")) { player, activity ->
        val file = "codecs-avc-display-rotation.mp4"
        player.load(fixture(file), autoPlay = false)
        await("$file presents its first frame", details = { player.state.value }) {
            player.state.value.hasVideoFrame || player.state.value.error != null
        }
        val state = player.state.value
        assertNull(file, state.error)
        assertContainer(file, "mov", state)
        assertEquals("h264", state.videoTracks.single { it.isSelected }.codec)
        await("$file rotates blue above red", timeout = 5000) {
            val pixels = renderedPixels(activity, file)
            isPrimaryColor(pixels[22 * 160 + 80], 2) && isPrimaryColor(pixels[67 * 160 + 80], 0)
        }
    }

    @Test fun avcSpsCroppingFollowsTheDecoderAlignmentOption() {
        for (allowUnaligned in listOf(false, true)) {
            val options = mutableMapOf("vd" to "h264,-", "keepaspect" to "no")
            if (allowUnaligned) options["vd-lavc-o"] = "flags=+unaligned"
            session(options) { player, activity ->
                val file = "codecs-avc-explicit-crop.mp4"
                player.load(fixture(file), autoPlay = false)
                await("$file presents its cropped picture", details = { player.state.value }) {
                    player.state.value.let { it.error != null || it.hasVideoFrame }
                }
                val state = player.state.value
                assertNull(state.error)
                assertContainer(file, "mov", state)
                assertEquals("h264", state.videoTracks.single { it.isSelected }.codec)
                assertEquals(if (allowUnaligned) 160 else 176, state.dimensions.width)
                assertEquals(128, state.dimensions.height)
                await("AVC cropped pixels with unaligned output $allowUnaligned") {
                    val pixels = renderedPixels(activity, file)
                    listOf(6, 83).all { row ->
                        val edge = pixels[row * 160 + 6]
                        val matchesEdge = if (allowUnaligned) isPrimaryColor(edge, 0)
                            else maxOf(Color.red(edge), Color.green(edge), Color.blue(edge)) < 24
                        matchesEdge && isPrimaryColor(pixels[row * 160 + 24], 0) &&
                            isPrimaryColor(pixels[row * 160 + 149], 2)
                    }
                }
            }
        }
    }

    @Test fun uhdHevcMain10WithBFramesSeeksInSoftware() =
        session(mapOf("vd" to "hevc,-", "vd-lavc-threads" to "4")) { player, activity ->
            val file = "codecs-hevc-main10-uhd.mp4"
            player.load(fixture(file), autoPlay = false)
            await("$file presents its first UHD picture", timeout = 10000, details = { player.state.value }) {
                player.state.value.let { it.error != null || (it.hasVideoFrame && it.state == PlaybackState.PAUSED) }
            }
            val state = player.state.value
            assertNull(state.error)
            assertContainer(file, "mov", state)
            assertEquals("hevc", state.videoTracks.single { it.isSelected }.codec)
            assertEquals("no", state.diagnostics.hardwareDecoder)
            assertEquals(3840, state.dimensions.width)
            assertEquals(2160, state.dimensions.height)
            assertEquals(10, state.hdr.decoded.bitDepth)
            for ((time, color) in listOf(1.167 to 2, .25 to 0, .667 to 1)) {
                player.seekTo(time)
                await("$file seeks to $time", timeout = 10000, details = { player.state.value }) {
                    abs(player.state.value.position - time) < .1
                }
                awaitPrimaryColor(activity, "$file after seeking to $time", color)
            }
        }

    @Test fun av1FilmGrainChangesPixelsOnTheCpuAndChecksTheGpuPath() {
        val gpuLog = File.createTempFile("av1-film-grain-", ".log", instrumentation.targetContext.cacheDir)
        try {
            verifyAv1FilmGrain(gpuLog)
        } finally {
            gpuLog.delete()
        }
    }

    private fun verifyAv1FilmGrain(gpuLog: File) {
        val name = "codecs-av1-main10-film-grain.mkv"
        val samples = mutableMapOf<String, List<List<Int>>>()
        val modes = mapOf(
            "off" to mapOf("vd-lavc-film-grain" to "cpu", "vd-lavc-o" to "filmgrain=0"),
            "cpu" to mapOf("vd-lavc-film-grain" to "cpu", "vd-lavc-o" to "filmgrain=1"),
            "gpu" to mapOf("vd-lavc-film-grain" to "gpu", "log-file" to gpuLog.absolutePath),
        )
        for ((mode, options) in modes) {
            session(options + ("vd" to "libdav1d,-")) { player, activity ->
                player.setDiagnosticsEnabled(true)
                player.load(fixture(name), autoPlay = false)
                await("$mode AV1 film grain configuration opens", details = { player.state.value }) {
                    player.state.value.let { it.error != null || it.hasVideoFrame && it.hdr.decoded.bitDepth == 10 }
                }
                val state = player.state.value
                assertNull(state.error)
                assertContainer(name, "mkv", state)
                assertEquals("av1", state.videoTracks.single { it.isSelected }.codec)
                assertEquals("gpu-next", state.diagnostics.videoOutput)
                samples[mode] = listOf(.25, 1.25, .5).map { time ->
                    player.seekTo(time)
                    await("$mode AV1 film grain seeks to $time", details = { player.state.value.position }) {
                        player.state.value.let { it.paused && abs(it.position - time) < .07 }
                    }
                    val pixels = renderedPixels(activity, name)
                    (32 until 58).flatMap { y -> (45 until 115).map { x -> Color.red(pixels[y * 160 + x]) } }
                }
            }
        }
        val off = samples.getValue("off")
        for (mode in listOf("cpu", "gpu")) {
            val on = samples.getValue(mode)
            val differences = off.zip(on).map { (base, decoded) -> base.zip(decoded).map { (a, b) -> abs(a - b) }.average() }
            val shaderRejected = mode == "gpu" && Build.HARDWARE in setOf("ranchu", "goldfish") &&
                gpuLog.readText().contains("Failed applying film grain.. disabling!")
            if (shaderRejected) {
                assertTrue("Rejected GPU grain retains the ungrained frames ($differences)", differences.all { it <= .8 })
            } else {
                assertTrue("$mode grain changes the source pixels ($differences)", differences.all { it > .8 })
            }
            assertTrue("$mode retains average luma", off.zip(on).all { (base, decoded) -> abs(base.average() - decoded.average()) < 4 })
        }
    }

    @Test fun mbaffAvcPresentsTheExpectedFrameOrFieldCadence() {
        for (order in listOf("top", "bottom")) {
            for (deinterlace in listOf(false, true)) {
                val policy = DeinterlacePolicy(
                    mode = if (deinterlace) DeinterlacePolicy.Mode.FORCED else DeinterlacePolicy.Mode.DISABLED,
                    algorithm = DeinterlacePolicy.Algorithm.BWDIF,
                )
                session(mapOf("vd" to "h264,-"), deinterlace = policy) { player, activity ->
                    val file = "codecs-avc-mbaff-$order.mp4"
                    player.load(fixture(file), autoPlay = false)
                    await("$file presents its first frame", details = { player.state.value }) {
                        player.state.value.hasVideoFrame || player.state.value.error != null
                    }
                    val state = player.state.value
                    assertNull(file, state.error)
                    assertContainer(file, "mov", state)
                    assertEquals("h264", state.videoTracks.single { it.isSelected }.codec)
                    assertEquals(192, state.dimensions.width)
                    assertEquals(128, state.dimensions.height)
                    val first = renderedPixels(activity, file)
                    val rate = if (deinterlace) 48.0 else 24.0
                    for (index in 1..6) {
                        val time = index / rate
                        player.stepForward()
                        await("$file presents at $time seconds, deinterlacing=$deinterlace", timeout = 5000,
                            details = { player.state.value.position }) {
                            abs(player.state.value.position - time) < .002
                        }
                    }
                    await("$file presents different pixels after stepping", timeout = 5000) {
                        !renderedPixels(activity, file).contentEquals(first)
                    }
                }
            }
        }
    }

    @Test fun mpeg2TelecinePreservesFieldOrderAcrossADominanceChange() {
        val cycle = listOf(35, 98, 165, 229, 58, 122, 186, 247).flatMapIndexed { index, level ->
            List(if (index % 2 == 0) 2 else 3) { level }
        }
        expectMpeg2Fields("codecs-mpeg2-telecine.mkv", 60.0, cycle + cycle)
    }

    @Test fun interlacedMpeg2PreservesAuthoredFieldOrderAndCadence() {
        val cases = listOf(
            "interlaced-480i-bottom.mkv" to 60000.0 / 1001,
            "interlaced-576i-top.mkv" to 50.0,
            "interlaced-1080i-top.mkv" to 60000.0 / 1001,
        )
        val levels = List(3) { listOf(45, 100, 165, 220) }.flatten()
        for ((name, cadence) in cases) expectMpeg2Fields(name, cadence, levels)
    }

    private fun expectMpeg2Fields(file: String, cadence: Double, levels: List<Int>) {
        val policy = DeinterlacePolicy(mode = DeinterlacePolicy.Mode.AUTOMATIC, algorithm = DeinterlacePolicy.Algorithm.BWDIF)
        session(mapOf("vd" to "mpeg2video,-"), deinterlace = policy) { player, activity ->
            player.load(fixture(file), autoPlay = false)
            await("$file presents its first field", details = { player.state.value }) {
                player.state.value.hasVideoFrame || player.state.value.error != null
            }
            val state = player.state.value
            assertNull(file, state.error)
            assertContainer(file, "mkv", state)
            assertEquals("mpeg2video", state.videoTracks.single { it.isSelected }.codec)

            for ((field, level) in levels.withIndex()) {
                val time = field / cadence
                if (field > 0) player.stepForward()
                await("$file field $field at $time seconds", timeout = 5000, details = { player.state.value.position }) {
                    abs(player.state.value.position - time) < .002
                }
                awaitGrayLevel(activity, "$file field $field", level)
            }
        }
    }

    @Test fun cdGraphicsPresentsBothAuthoredColors() = session(mapOf("vd" to "cdgraphics,-")) { player, activity ->
        val file = "codecs-color-cues.cdg"
        player.load(fixture(file), autoPlay = false)
        await("CD Graphics opens the first palette", details = { player.state.value }) {
            player.state.value.hasVideoFrame || player.state.value.error != null
        }
        val state = player.state.value
        assertNull(file, state.error)
        assertContainer(file, "cdg", state)
        assertEquals("cdgraphics", state.videoTracks.single { it.isSelected }.codec)
        assertEquals(300, state.dimensions.width)
        assertEquals(216, state.dimensions.height)
        awaitPrimaryColor(activity, "CD Graphics first half", 0)

        player.play()
        await("CD Graphics advances to the second palette entry") { player.state.value.position >= .5 }
        awaitPrimaryColor(activity, "CD Graphics second half", 2)
    }

    private fun expectAuthoredColors(
        clips: List<JSONObject>,
        grayLevels: Pair<Int, Int>? = null,
        sessionOptions: Map<String, String> = emptyMap(),
    ) = session(sessionOptions) { player, activity ->
        if (clips.any { it.has("mpvPixelFormat") }) player.setDiagnosticsEnabled(true)
        for (clip in clips) {
            val name = clip.getString("file")
            val decoder = clip.getString("decoder")
            val options = clip.getJSONObject("mpvOptions")
            val levels = grayLevels ?: (72 to 180).takeIf { clip.optString("pixelFormat").startsWith("gray") }
            val pixelFormat = clip.optString("mpvPixelFormat")
            player.setProperty("options/vd", "$decoder,-")
            player.setProperty("options/demuxer-lavf-format", options.optString("demuxer-lavf-format"))
            player.setProperty("options/demuxer-lavf-o", options.optString("demuxer-lavf-o"))
            player.load(fixture(name), autoPlay = false)
            await("$name presents its opening frame", details = { player.state.value }) {
                val state = player.state.value
                state.error != null || (state.hasVideoFrame && state.container != null)
            }
            val state = player.state.value
            assertNull(name, state.error)
            assertContainer(name, clip.getString("format"), state)
            assertEquals(name, clip.getString("codec"), state.videoTracks.single { it.isSelected }.codec)
            if (pixelFormat.isNotEmpty()) {
                await("$name reports decoded $pixelFormat", timeout = 5000, details = { player.state.value.diagnostics.pixelFormat }) {
                    player.state.value.diagnostics.pixelFormat == pixelFormat
                }
            }
            assertEquals(name, clip.getInt("width"), state.dimensions.width)
            assertEquals(name, clip.getInt("height"), state.dimensions.height)
            if (levels != null) awaitGrayLevel(activity, "$name opening", levels.first)
            else awaitPrimaryColor(activity, "$name opening", 0)

            player.play()
            if (levels != null) awaitGrayLevel(activity, "$name ending", levels.second)
            else awaitPrimaryColor(activity, "$name ending", 2)
            assertTrue("$name advances to the next color", player.state.value.position > state.position + .25)
            player.stop()
            await("stop $name") { player.state.value.state == PlaybackState.STOPPED }
        }
    }

    @Test fun rawVideoUsesTheConfiguredPlaneLayoutAndFrameRate() {
        val routes = listOf(
            mapOf("demuxer" to "rawvideo", "demuxer-rawvideo-format" to "I420", "demuxer-rawvideo-w" to "96",
                "demuxer-rawvideo-h" to "64", "demuxer-rawvideo-fps" to "8"),
            mapOf("demuxer" to "lavf", "demuxer-lavf-format" to "rawvideo",
                "demuxer-lavf-o" to "video_size=96x64,pixel_format=yuv420p,framerate=8"),
        )
        for (options in routes) {
            expectConfiguredRawVideo("codecs-raw-frames.i420", "rawvideo", options)
        }
    }

    @Test fun nativeRawVideoUsesTheConfiguredPacketSizeAndFrameRate() {
        val clips = listOf(Triple("codecs-raw-frames.mjpg", "mjpeg", "2048"), Triple("codecs-raw-frames.h263p", "h263p", "1024"))
        for ((name, codec, packetSize) in clips) {
            expectConfiguredRawVideo(name, codec, mapOf(
                "demuxer" to "rawvideo", "demuxer-rawvideo-codec" to codec, "demuxer-rawvideo-size" to packetSize,
                "demuxer-rawvideo-w" to "96", "demuxer-rawvideo-h" to "64", "demuxer-rawvideo-fps" to "8",
            ))
        }
    }

    private fun expectConfiguredRawVideo(name: String, codec: String, options: Map<String, String>) {
        val demuxer = options.getValue("demuxer")
        session(options + ("vd" to "$codec,-")) { player, activity ->
            player.load(fixture(name), autoPlay = false)
            await("$demuxer presents the first raw frame", details = { player.state.value }) {
                player.state.value.let { it.error != null || (it.hasVideoFrame && it.diagnostics.containerFramesPerSecond != null) }
            }
            val state = player.state.value
            assertNull("$demuxer $name", state.error)
            assertContainer(name, "rawvideo", state)
            assertEquals(codec, state.videoTracks.single { it.isSelected }.codec)
            assertEquals(96, state.dimensions.width)
            assertEquals(64, state.dimensions.height)
            assertEquals(8.0, state.diagnostics.containerFramesPerSecond!!, .01)
            assertEquals(3.0, state.duration, .01)
            awaitPrimaryColor(activity, "$demuxer raw opening", 0)
            for ((time, color) in listOf(2.125 to 2, 1.125 to 1)) {
                player.seekTo(time)
                awaitPrimaryColor(activity, "$demuxer raw $time", color)
                assertEquals(time, player.state.value.position, .1)
            }
        }
    }

    @Test fun rawDiracFramesUseTheEncodedRate() = session { player, _ ->
        val clips = listOf(Triple("codecs-dirac-24.drc", 24.0, 18), Triple("codecs-dirac-2997.drc", 30_000.0 / 1001, 23))
        for ((name, rate, frameCount) in clips) {
            player.load(fixture(name), autoPlay = false)
            await("$name presents its first frame", details = { player.state.value }) {
                player.state.value.hasVideoFrame || player.state.value.error != null
            }
            assertNull(name, player.state.value.error)
            assertContainer(name, "dirac", player.state.value)
            assertEquals("$name first frame", 0.0, player.state.value.position, 0.002)

            for (frame in 1 until frameCount) {
                val before = player.state.value.position
                player.stepForward()
                await("$name presents Dirac frame $frame", details = { player.state.value.position }) {
                    player.state.value.position > before || player.state.value.error != null
                }
                assertEquals("$name frame $frame timestamp", frame / rate, player.state.value.position, 0.002)
            }
            player.play()
            await("$name reaches EOF after the last frame", details = { player.state.value }) {
                player.state.value.state == PlaybackState.ENDED
            }
            assertEquals("$name duration after reading all access units", frameCount / rate, player.state.value.duration, 1.0 / rate + 0.002)
            player.stop()
            await("stop $name") { player.state.value.state == PlaybackState.STOPPED }
        }
    }

    @Test fun stillImageReadersProduceTheEncodedPattern() = expectAuthoredStillImages("images", "lavf")

    @Test fun mpvImageFileReaderProducesTheEncodedPattern() = expectAuthoredStillImages("mfImages", "mf")

    private fun expectAuthoredStillImages(group: String, demuxer: String) = session(
        mapOf("demuxer" to demuxer, "image-display-duration" to "inf"),
    ) { player, activity ->
        for (image in localMediaCases(group)) {
            val name = image.getString("file")
            val decoder = image.getString("decoder")
            val format = image.getString("format")
            player.setProperty("options/vd", "$decoder,-")
            val options = image.getJSONObject("mpvOptions")
            if (demuxer == "lavf") {
                player.setProperty("options/demuxer-lavf-format", format)
                player.setProperty("options/demuxer-lavf-o", options.optString("demuxer-lavf-o"))
            } else {
                player.setProperty("options/mf-type", options.getString("mf-type"))
            }
            player.load(fixture(name), autoPlay = false)
            await("$name presents its image with $decoder", details = { player.state.value }) {
                player.state.value.hasVideoFrame || player.state.value.error != null
            }
            val state = player.state.value
            assertNull(name, state.error)
            assertContainer(name, format, state)
            assertEquals(name, image.getString("codec"), state.videoTracks.single { it.isSelected }.codec)
            assertEquals(name, image.getInt("width"), state.dimensions.width)
            assertEquals(name, image.getInt("height"), state.dimensions.height)

            val (bright, dark) = if (image.getBoolean("brightOnLeft")) 55 to 105 else 105 to 55
            await("$name presents the authored bright and dark halves", timeout = 5000) {
                val pixels = renderedPixels(activity, name)
                val light = pixels[45 * 160 + bright] shr 8 and 255
                val shade = pixels[45 * 160 + dark] shr 8 and 255
                light - shade > 100 && shade < 60
            }
            player.stop()
            await("stop $name") { player.state.value.state == PlaybackState.STOPPED }
        }
    }

    @Test fun animatedWebpPreservesPartialFramesAndVariableTiming() =
        session(mapOf("vd" to "webp_anim,-", "demuxer-lavf-format" to "webp_anim")) { player, activity ->
            val name = "image-webp-animated.webp"
            player.load(fixture(name), autoPlay = false)
            await("$name starts paused", details = { player.state.value }) {
                player.state.value.let { it.error != null || (it.hasVideoFrame && it.paused && it.duration > 0) }
            }
            val state = player.state.value
            assertNull(name, state.error)
            assertContainer(name, "webp_anim", state)
            assertEquals("webp_anim", state.videoTracks.single { it.isSelected }.codec)
            assertEquals(32, state.dimensions.width)
            assertEquals(24, state.dimensions.height)
            assertEquals("$name includes the last frame duration", 1.5, state.duration, 0.002)

            val frames = listOf(Triple(0.0, 0, 0), Triple(0.25, 0, 2), Triple(0.75, 1, 1))
            for ((time, left, right) in frames) {
                if (time > 0) player.stepForward()
                await("$name presents both halves of the frame at $time seconds", timeout = 5000, details = { player.state.value }) {
                    if (abs(player.state.value.position - time) > 0.002) {
                        false
                    } else {
                        val pixels = renderedPixels(activity, name)
                        isPrimaryColor(pixels[45 * 160 + 60], left) && isPrimaryColor(pixels[45 * 160 + 100], right)
                    }
                }
            }
        }

    @Test fun stillWebpPresentsTheAuthoredRedImage() =
        session(mapOf("vd" to "webp,-", "demuxer" to "lavf", "demuxer-lavf-format" to "webp_pipe")) { player, activity ->
            val name = "image-webp-still.webp"
            player.load(fixture(name), autoPlay = false)
            await("$name presents its image", details = { player.state.value }) {
                player.state.value.let { it.error != null || it.hasVideoFrame }
            }
            val state = player.state.value
            assertNull(name, state.error)
            assertContainer(name, "webp_pipe", state)
            assertEquals(name, "webp", state.videoTracks.single { it.isSelected }.codec)
            assertEquals(32, state.dimensions.width)
            assertEquals(24, state.dimensions.height)
            awaitPrimaryColor(activity, name, 0)
        }

    @Test fun comfortNoiseFollowsTheEncodedLevelChanges() {
        val name = "codecs-comfort-noise.nut"
        val pcm = capturePcm(name, mapOf("ad" to "comfortnoise,-")) { state ->
            assertContainer(name, "nut", state)
            assertEquals(name, "comfortnoise", state.audioTracks.single { it.isSelected }.codec)
        }
        assertEquals(name, 3.04, pcm.limit() / 48000.0, .05)
        for ((start, expected) in listOf(24000 to .015, 48000 to .015, 96000 to .068, 120000 to .069)) {
            val frames = 9600
            val rms = sqrt((start until start + frames).sumOf { frame ->
                val sample = pcm.get(frame) / 32768.0
                sample * sample
            } / frames)
            assertEquals("$name levels at frame $start", expected, rms, expected * .25)
        }
    }

    @Test fun localAudioDecodersProduceTheEncodedTone() = expectAudioFixtures(localMediaCases("audio"))

    @Test fun mpegAudioFloatingPointDecodersPreserveTheTone() {
        val audio = localMediaCases("audio")
        for ((name, decoder) in listOf(
            "codecs-mpeg-layer1.mp1" to "mp1float", "codecs-mp2.mp2" to "mp2float", "codecs-mpeg-audio-in-mp4.mp4" to "mp3on4float",
        )) {
            val clip = audio.single { it.getString("file") == name }
            expectEncodedTone(clip, pipeInput = false, decoder = decoder)
        }
    }

    @Test fun heAacRestoresHighBandAudioInM4aAndAdts() {
        for (clip in localMediaCases("highEfficiencyAAC")) {
            val name = clip.getString("file")
            for (decoder in listOf("aac", "aac_fixed")) {
                val samples = capturePcm(name, mapOf("ad" to "$decoder,-")) { state ->
                    assertContainer(name, clip.getString("format"), state)
                    assertEquals(name, "aac", state.audioTracks.single { it.isSelected }.codec)
                }
                assertTrue("$name via $decoder decoded duration", samples.limit() / 48000.0 in 1.15..1.34)
                assertMonoTone(name, samples, 9600, 440)
                assertTrue("$name via $decoder has a quiet high band before the cue", highBandAmplitude(samples, 9600) < 328)
                assertTrue("$name via $decoder reproduces the authored high band", highBandAmplitude(samples, 43200) > 1147)
            }
        }
    }

    @Test fun vbrMp3TrimsEncoderDelayAndEndPadding() {
        val name = "codecs-mp3-vbr.mp3"
        val samples = capturePcm(name, mapOf("ad" to "mp3,-")) { state ->
            assertContainer(name, "mp3", state)
            assertEquals(name, "mp3", state.audioTracks.single { it.isSelected }.codec)
        }
        assertEquals("MP3 gapless PCM frame count", 60_000, samples.limit())
        assertMonoTone(name, samples, 0, 440)
        assertMonoTone(name, samples, 55_200, 440)
    }

    @Test fun opusTrimsPaddingAndSeeksWithinTheContainerTimestampPrecision() {
        val sources = listOf(Triple("codecs-opus.ogg", "ogg", 1), Triple("codecs-mapping-matroska-opus.mkv", "mkv", 48))
        val options = mapOf("ad" to "opus,-", "vid" to "no", "hr-seek" to "yes")
        for ((name, format, seekTolerance) in sources) {
            for ((start, expectedFrames) in listOf(0 to 60_000, 30_000 to 30_000)) {
                val pcm = capturePcmBytes(name, options, startTime = start / 48_000.0) { state ->
                    assertContainer(name, format, state)
                    assertEquals(name, "opus", state.audioTracks.single { it.isSelected }.codec)
                    assertTrue("$name is seekable", state.seekable)
                }
                val samples = ByteBuffer.wrap(pcm).order(ByteOrder.LITTLE_ENDIAN).asShortBuffer()
                // Matroska uses millisecond timecodes. Ogg may round one sample at an exact seek.
                val tolerance = if (start == 0) 0 else seekTolerance
                assertTrue("$name PCM from sample $start: expected $expectedFrames, got ${samples.limit()}",
                    abs(samples.limit() - expectedFrames) <= tolerance)
                assertMonoTone(name, samples, 0, 440)
                assertMonoTone(name, samples, samples.limit() - 4800, 440)
            }
        }
    }

    @Test fun referenceEac3JocDecodesToSixChannelsOfPcm() {
        val name = "audio-joc-reference.mka"
        assumeTrue("Stage the optional $name sample in the test media directory",
            name in instrumentation.context.assets.list("").orEmpty())
        val pcm = capturePcm(name, mapOf("ad" to "eac3,-", "vid" to "no", "audio-channels" to "5.1(side)")) { state ->
            assertContainer(name, "mkv", state)
            assertEquals("eac3", state.audioTracks.single { it.isSelected }.codec)
            assertTrue("5.1(side)" in state.diagnostics.outputChannels.orEmpty())
        }
        val channels = 6
        assertEquals("Reference JOC interleaved PCM", 0, pcm.limit() % channels)
        assertTrue("PCM duration within one 1536-sample E-AC-3 packet", pcm.limit() / channels in 431_616..433_152)
        val window = 12_000
        for (start in listOf(12_000, 204_000, 396_000)) {
            for (channel in 0 until channels) {
                val meanSquare = (start until start + window).sumOf { frame ->
                    val amplitude = pcm.get(frame * channels + channel) / 32768.0
                    amplitude * amplitude
                } / window
                assertTrue("Channel ${channel + 1} at sample $start", meanSquare > 0.005 * 0.005)
            }
        }
    }

    @Test fun m4aPreservesChaptersArtworkAndSampleExactAacDuration() {
        val name = "codecs-album.m4a"
        val options = mapOf("ad" to "aac,-", "vd" to "mjpeg,-", "audio-display" to "embedded-first")
        session(options + ("ao" to "null")) { player, activity ->
            fun hasBlueCover(): Boolean {
                val pixels = renderedPixels(activity, name)
                val center = pixels[pixels.size / 2 + 80]
                return (center and 0xff) > 180 && (center shr 8 and 0xff) < 70 && (center shr 16 and 0xff) < 70
            }

            player.load(fixture(name), autoPlay = false)
            await("M4A album opens with the cover and first chapter", details = { player.state.value }) {
                val state = player.state.value
                state.error != null || (state.hasVideoFrame && state.currentChapterIndex == 0)
            }
            val state = player.state.value
            assertNull(state.error)
            assertContainer(name, "mov", state)
            assertEquals("Three tone album", state.title)
            assertEquals("Test ensemble", state.metadata.entries.single { it.key.equals("artist", ignoreCase = true) }.value)
            assertEquals("mjpeg", state.videoTracks.single { it.isSelected }.codec)
            assertEquals(listOf("Opening", "Middle", "Ending"), state.chapters.map { it.title })
            assertEquals(listOf(0.0, 1.024, 2.048), state.chapters.map { it.startTime })
            await("M4A displays the blue cover") { hasBlueCover() }
            for ((step, index, time) in listOf(Triple(1, 1, 1.024), Triple(1, 2, 2.048), Triple(-1, 1, 1.024))) {
                if (step > 0) player.nextChapter() else player.previousChapter()
                await("M4A chapter $index is selected", details = { player.state.value }) {
                    val chapter = player.state.value
                    chapter.paused && chapter.currentChapterIndex == index && abs(chapter.position - time) < 0.05
                }
                await("M4A keeps the cover at chapter $index") { hasBlueCover() }
            }
        }

        // Cover art must not require an attached video surface to play the album.
        val samples = capturePcm(name, options) { state ->
            assertContainer(name, "mov", state)
            assertEquals("aac", state.audioTracks.single { it.isSelected }.codec)
        }
        assertEquals("M4A AAC PCM frame count", 147_456, samples.limit())
        assertMonoTone(name, samples, 0, 440)
        assertMonoTone(name, samples, 53_760, 660)
        assertMonoTone(name, samples, 142_656, 880)
    }

    private fun highBandAmplitude(samples: ShortBuffer, start: Int): Double {
        // Many small differences describe the 440 Hz tone. The added high band has much larger differences.
        var total = 0L
        for (i in start + 1 until start + 4799) {
            total += kotlin.math.abs(samples[i - 1].toInt() - 2 * samples[i] + samples[i + 1])
        }
        return total / 4798.0
    }

    @Test fun remuxedAudioKeepsItsCodecAndDecodedTone() = expectAudioFixtures(localMediaCases("mappedAudio"))

    private fun expectAudioFixtures(clips: List<JSONObject>) {
        val failures = mutableListOf<Throwable>()
        for (clip in clips) {
            try {
                expectEncodedTone(clip, pipeInput = clip.getBoolean("pipeInput"))
            } catch (error: AssertionError) {
                failures.add(error)
            }
        }
        MultipleFailureException.assertEmpty(failures)
    }

    @Test fun avcMediaCodecDecoderPresentsAuthoredFramesBeforeAndAfterSeeking() {
        assumeTrue("AVC MediaCodec video requires a physical device", Build.HARDWARE !in setOf("ranchu", "goldfish"))
        val available = MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos.any { codec ->
            !codec.isEncoder && codec.supportedTypes.any { it.equals("video/avc", ignoreCase = true) }
        }
        assumeTrue("The device provides a MediaCodec AVC decoder", available)
        expectVideoThroughSeeks(
            "MediaCodec AVC decoder", fixture("tls-ranges.mp4"), "mov",
            listOf(2.25 to 2, 0.25 to 0), decoder = "h264_mediacodec",
        )
    }

    @Test fun hardwareAvcMediaCodecPresentsAuthoredFramesBeforeAndAfterSeeking() {
        assumeTrue("Hardware AVC requires a physical device", Build.HARDWARE !in setOf("ranchu", "goldfish"))
        val available = MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos.any { codec ->
            !codec.isEncoder && codec.isHardwareAccelerated && codec.supportedTypes.any { it.equals("video/avc", ignoreCase = true) }
        }
        assumeTrue("The device provides a hardware-accelerated MediaCodec AVC decoder", available)
        val names = setOf("mediacodec", "mediacodec-copy")
        session(
            mapOf("vd" to "h264,-", "hwdec-codecs" to "h264"),
            hardwareDecoding = HardwareDecoding.AUTOMATIC,
        ) { player, activity ->
            val file = "tls-ranges.mp4"
            player.load(fixture(file), autoPlay = false)
            await("MediaCodec is active for H.264", details = { player.state.value.diagnostics }) {
                val state = player.state.value
                state.hasVideoFrame && state.diagnostics.hardwareDecoder in names
            }
            assertEquals("h264", player.state.value.videoTracks.single { it.isSelected }.codec)
            assertContainer(file, "mov", player.state.value)
            awaitPrimaryColor(activity, "MediaCodec AVC opening", 0)
            player.seekTo(2.25)
            awaitPrimaryColor(activity, "MediaCodec AVC seek", 2)
            assertEquals(2.25, player.state.value.position, .1)
            assertTrue(player.state.value.diagnostics.hardwareDecoder in names)
        }
    }

    @Test fun mediaCodecHevcPresentsDecodedFrames() =
        expectMediaCodecVideo("codecs-hevc.hevc", "hevc_mediacodec", "video/hevc")

    @Test fun mediaCodecVp8PresentsDecodedFrames() =
        expectMediaCodecVideo("codecs-vp8.webm", "vp8_mediacodec", "video/x-vnd.on2.vp8")

    @Test fun mediaCodecVp9PresentsDecodedFrames() =
        expectMediaCodecVideo("codecs-vp9.webm", "vp9_mediacodec", "video/x-vnd.on2.vp9")

    @Test fun mediaCodecAv1PresentsDecodedFrames() =
        expectMediaCodecVideo("codecs-av1.mkv", "av1_mediacodec", "video/av01")

    @Test fun mediaCodecMpeg2PresentsDecodedFrames() =
        expectMediaCodecVideo("codecs-mpeg2.mpg", "mpeg2_mediacodec", "video/mpeg2")

    @Test fun mediaCodecMpeg4PresentsDecodedFrames() =
        expectMediaCodecVideo("codecs-mpeg4.avi", "mpeg4_mediacodec", "video/mp4v-es")

    @Test fun v4l2Mem2MemDecodersPresentDecodedFrames() {
        val devices = File("/dev").listFiles().orEmpty()
        assumeTrue("V4L2 requires an accessible video device", devices.any {
            it.name.matches(Regex("video[0-9]+")) && it.canRead() && it.canWrite()
        })
        val files = listOf(
            "codecs-h264.h264" to "h264", "codecs-hevc.hevc" to "hevc",
            "codecs-vp8.webm" to "vp8", "codecs-vp9.webm" to "vp9", "codecs-h263.avi" to "h263",
            "codecs-mpeg1.mpg" to "mpeg1", "codecs-mpeg2.mpg" to "mpeg2",
            "codecs-mpeg4.avi" to "mpeg4", "codecs-vc1.vc1" to "vc1",
        )
        val fixtures = localMediaCases("video") + localMediaCases("vc1")
        expectVideoFixtures(files.map { (name, decoder) ->
            fixtures.single { it.getString("file") == name }.put("decoder", "${decoder}_v4l2m2m")
        }, verifyColors = true)
    }

    private fun expectMediaCodecVideo(file: String, decoder: String, mime: String) {
        assumeTrue("$decoder requires a physical device", Build.HARDWARE !in setOf("ranchu", "goldfish"))
        val clip = localMediaCases("video").single { it.getString("file") == file }
        val format = MediaFormat.createVideoFormat(mime, clip.getInt("width"), clip.getInt("height"))
        val available = MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos.any { candidate ->
            !candidate.isEncoder && candidate.supportedTypes.any { it.equals(mime, ignoreCase = true) } &&
                candidate.getCapabilitiesForType(mime).isFormatSupported(format)
        }
        assumeTrue("The device provides a MediaCodec decoder for $mime at the fixture size", available)
        expectVideoFixtures(listOf(clip.put("decoder", decoder)), verifyColors = true)
    }

    @Test fun mediaCodecAacProducesTheEncodedTone() {
        expectMediaCodecTone("codecs-aac-lc.m4a", "aac_mediacodec", "audio/mp4a-latm")
    }

    @Test fun mediaCodecMp3ProducesTheEncodedTone() {
        expectMediaCodecTone("codecs-mp3-fixed.mp3", "mp3_mediacodec", "audio/mpeg")
    }

    @Test fun mediaCodecNarrowbandAmrProducesTheEncodedTone() {
        expectMediaCodecTone("codecs-amr-nb.amr", "amrnb_mediacodec", "audio/3gpp")
    }

    @Test fun mediaCodecWidebandAmrProducesTheEncodedTone() {
        expectMediaCodecTone("codecs-amr-wb.amr", "amrwb_mediacodec", "audio/amr-wb")
    }

    private fun expectMediaCodecTone(file: String, decoder: String, mime: String) {
        val available = MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos.any { codec ->
            !codec.isEncoder && codec.supportedTypes.any { it.equals(mime, ignoreCase = true) }
        }
        assumeTrue("The device provides a MediaCodec decoder for $mime", available)
        val clip = localMediaCases("audio").single { it.getString("file") == file }
        expectEncodedTone(clip, pipeInput = false, decoder = decoder)
    }

    @Test fun surroundFlacPreservesEachChannelAndExactSamples() {
        expectLosslessAudio(localMediaCatalog().getJSONObject("surround"), "flac", "5.1", "s32", Int.SIZE_BYTES)
    }

    @Test fun alacAndWavPreserve24BitStereoAtTheSourceRate() {
        val cases = localMediaCatalog().getJSONArray("audioRates")
        for (index in 0 until cases.length()) {
            val clip = cases.getJSONObject(index)
            expectLosslessAudio(
                clip.getJSONObject("pcm"), clip.getString("codec"), "stereo", "s32", Int.SIZE_BYTES,
                format = clip.getString("format"),
            )
        }
    }

    @Test fun apePreservesEverySampleThroughTheLastCompressedFrame() {
        expectLosslessAudio(localMediaCatalog().getJSONObject("monkeysAudio"), "ape", "mono", "s16", Short.SIZE_BYTES)
    }

    @Test fun cueOpensItsRelativeFlacAndNavigatesAuthoredChapters() {
        fixture("codecs-album.flac")
        val name = "codecs-album.cue"
        val source = fixture(name)
        val options = mapOf("ad" to "flac,-")
        session(options + ("ao" to "null")) { player, _ ->
            player.load(source, autoPlay = false)
            await("CUE album opens at its first track", details = { player.state.value }) {
                val state = player.state.value
                state.error != null || (state.state == PlaybackState.PAUSED && state.currentChapterIndex == 0)
            }
            val state = player.state.value
            assertNull(state.error)
            assertContainer(name, "cue/flac", state)
            assertTrue("$name is seekable", state.seekable)
            assertEquals(listOf("Opening", "Middle", "Ending"), state.chapters.map { it.title })
            assertEquals(listOf(0.0, 1.0, 2.0), state.chapters.map { it.startTime })
            for ((step, index) in listOf(1 to 1, 1 to 2, -1 to 1)) {
                if (step > 0) player.nextChapter() else player.previousChapter()
                await("CUE chapter $index is selected", details = { player.state.value }) {
                    val chapter = player.state.value
                    chapter.state == PlaybackState.PAUSED && chapter.currentChapterIndex == index && abs(chapter.position - index) < 0.05
                }
            }
        }

        val samples = capturePcm(name, options, sourceUrl = source) { state ->
            assertContainer(name, "cue/flac", state)
            assertEquals("flac", state.audioTracks.single { it.isSelected }.codec)
        }
        assertEquals("$name decoded duration", 3.0, samples.limit() / 48000.0, 0.01)
        for ((start, tone) in listOf(12000 to 440, 60000 to 660, 108000 to 880)) {
            assertMonoTone(name, samples, start, tone)
        }
    }

    @Test fun multiFileCueFollowsIndex01WhenChangingSources() {
        fixture("codecs-album-disc-1.flac")
        fixture("codecs-album-disc-2.flac")
        val name = "codecs-album-multi.cue"
        val samples = capturePcm(name, mapOf("ad" to "flac,-"), sourceUrl = fixture(name)) { state ->
            assertContainer(name, "cue/flac", state)
            assertEquals(listOf("First file", "Second file"), state.chapters.map { it.title })
            assertEquals(listOf(0.0, 1.0), state.chapters.map { it.startTime })
        }
        assertEquals("$name decoded duration", 2.0, samples.limit() / 48000.0, 0.025)
        for ((start, tone) in listOf(12000 to 440, 50400 to 880, 88800 to 880)) {
            assertMonoTone(name, samples, start, tone)
        }
    }

    @Test fun localPlaylistsAdvancePastAnUnavailableRelativeEntry() {
        fixture("codecs-http-hls-00.ts")
        fixture("codecs-http-hls-02.ts")
        for (suffix in listOf("m3u", "pls")) {
            val name = "codecs-playlist.$suffix"
            session(mapOf("ao" to "null", "keep-open" to "no")) { player, activity ->
                player.load(fixture(name), autoPlay = false)
                await("$name presents its first entry", details = { player.state.value }) {
                    player.state.value.let { it.error != null || (it.hasVideoFrame && it.container != null) }
                }
                var state = player.state.value
                assertNull(state.error)
                assertContainer(name, "mpegts", state)
                awaitPrimaryColor(activity, "$name opening", 0)

                player.play()
                await("$name reaches the final entry after the missing item", details = { player.state.value }) {
                    player.state.value.let {
                        it.hasVideoFrame && (it.title == "Ending" || it.title.contains("codecs-http-hls-02.ts"))
                    }
                }
                state = player.state.value
                assertNull(state.error)
                assertContainer(name, "mpegts", state)
                awaitPrimaryColor(activity, "$name ending", 2)
                await("$name reaches EOF after the final entry", details = { player.state.value }) {
                    player.state.value.state == PlaybackState.ENDED
                }
                assertNull(player.state.value.error)
            }
        }
    }

    @Test fun recursiveDirectoriesPlayVisibleMediaInNaturalFilenameOrder() {
        val directory = kotlin.io.path.createTempDirectory(instrumentation.targetContext.cacheDir.toPath(), "media-directory-").toFile()
        try {
            File(directory, "Nested").mkdir()
            val paths = listOf("Clip 10.ts" to 2, "Nested/Clip 1.ts" to 1, "Clip 2.ts" to 0, ".Hidden.ts" to 1)
            for ((path, color) in paths) File(fixture("codecs-http-hls-0$color.ts")).copyTo(File(directory, path))
            File(directory, "Clip 1.txt").writeText("Ignored by the video filter")

            val options = mapOf("directory-mode" to "recursive", "directory-filter-types" to "video",
                "ao" to "null", "keep-open" to "no", "speed" to "0.75")
            session(options) { player, activity ->
                player.load(directory.absolutePath)
                for ((basename, color) in listOf("Clip 2.ts" to 0, "Clip 10.ts" to 2, "Clip 1.ts" to 1)) {
                    await("directory plays $basename", details = { player.state.value }) {
                        val state = player.state.value
                        state.error != null || (state.title == basename && state.hasVideoFrame)
                    }
                    val state = player.state.value
                    assertNull(state.error)
                    assertContainer(basename, "mpegts", state)
                    awaitPrimaryColor(activity, basename, color)
                }
                await("the directory ends after the nested clip", details = { player.state.value }) {
                    player.state.value.state == PlaybackState.ENDED
                }
                assertNull(player.state.value.error)
            }
        } finally {
            directory.deleteRecursively()
        }
    }

    @Test fun nativeReferenceAndShortcutPlaylistsOpenRelativeMediaAndPlaintextLoadlistIsGuarded() {
        for (reader in listOf("ini", "url", "txt")) {
            val directory = kotlin.io.path.createTempDirectory(instrumentation.targetContext.cacheDir.toPath(), "text-playlist-").toFile()
            try {
                val opening = "Opening clip.ts"
                val ending = "Ending clip.ts"
                File(fixture("codecs-http-hls-00.ts")).copyTo(File(directory, opening))
                File(fixture("codecs-http-hls-02.ts")).copyTo(File(directory, ending))
                val playlist = File(directory, "Playback.$reader").apply {
                    writeText(when (reader) {
                        "ini" -> "[Reference]\nRef1=$opening\nRef2=$ending\n"
                        "url" -> "[InternetShortcut]\nURL=\"$opening\"\n"
                        else -> "\n$opening\n\n$ending\n"
                    })
                }
                session(mapOf("ao" to "null", "keep-open" to "no", "speed" to "0.75")) { player, activity ->
                    val previous = player.loadGeneration
                    if (reader == "txt") {
                        player.command("loadlist", playlist.absolutePath, "replace")
                        await("the public source guard rejects raw loadlist", details = { player.state.value }) {
                            player.state.value.error is PlayerError.CommandFailed
                        }
                        assertFalse(player.state.value.hasVideoFrame)
                        player.load(File(directory, opening).absolutePath)
                    } else {
                        player.load(playlist.absolutePath)
                    }
                    await("$reader opens its first source", details = { player.state.value }) {
                        val state = player.state.value
                        state.loadGeneration > previous && (state.state == PlaybackState.FAILED ||
                            state.title == opening && state.hasVideoFrame)
                    }
                    assertNull(player.state.value.error)
                    assertContainer(reader, "mpegts", player.state.value)
                    awaitPrimaryColor(activity, "$reader opening", 0)
                    if (reader == "ini") {
                        await("$reader opens its second source", details = { player.state.value }) {
                            val state = player.state.value
                            state.error != null || (state.title == ending && state.hasVideoFrame)
                        }
                        assertNull(player.state.value.error)
                        awaitPrimaryColor(activity, "$reader ending", 2)
                    }
                    await("$reader reaches EOF", details = { player.state.value }) { player.state.value.state == PlaybackState.ENDED }
                }
            } finally {
                directory.deleteRecursively()
            }
        }
    }

    @Test fun matroskaLacingPreservesPcmThroughNativeAndFfmpegReaders() {
        val clips = instrumentation.context.assets.open("matroska-lacing.json").bufferedReader().use { JSONObject(it.readText()) }
        for (mode in listOf("fixed", "xiph", "ebml", "flac-xiph", "flac-ebml")) {
            val decoder = if (mode.startsWith("flac-")) "flac" else "pcm_s16le"
            for ((demuxer, format) in listOf("mkv" to "mkv", "lavf" to "matroska")) {
                expectLosslessAudio(clips.getJSONObject(mode), decoder, "mono", "s16", 2, format = format, demuxer = demuxer)
            }
        }
    }

    @Test fun orderedMatroskaChaptersLinkAnotherSegmentAndReturn() {
        fixture("matroska-ordered-linked.mka")
        val clip = instrumentation.context.assets.open("matroska-ordered.json").bufferedReader().use { JSONObject(it.readText()) }
        expectLosslessAudio(clip, "pcm_s16le", "mono", "s16", 2, format = "mkv_oc/mkv", demuxer = "mkv") { state ->
            assertEquals(listOf("Opening", "Linked", "Return"), state.chapters.map { it.title })
            assertEquals(listOf(0.0, 0.36, 0.72), state.chapters.map { it.startTime })
        }
    }

    @Test fun orderedMatroskaOmitsTheMissingChapterAndRestoresItOnceTheSegmentIsPresent() {
        val catalog = instrumentation.context.assets.open("matroska-ordered.json").bufferedReader().use { JSONObject(it.readText()) }
        val directory = kotlin.io.path.createTempDirectory(instrumentation.targetContext.cacheDir.toPath(), "ordered-").toFile()
        try {
            val original = File(fixture(catalog.getString("file")))
            val main = original.copyTo(File(directory, original.name))

            fun check(clip: JSONObject, titles: List<String>, times: List<Double>) {
                expectLosslessAudio(clip, "pcm_s16le", "mono", "s16", 2,
                    format = "mkv_oc/mkv", demuxer = "mkv", sourceUrl = main.absolutePath) { state ->
                    assertEquals(titles, state.chapters.map { it.title })
                    assertEquals(times, state.chapters.map { it.startTime })
                }
            }

            check(catalog.getJSONObject("withoutLinked"), listOf("Opening", "Return"), listOf(0.0, 0.36))
            val linked = File(fixture("matroska-ordered-linked.mka"))
            linked.copyTo(File(directory, linked.name))
            check(catalog, listOf("Opening", "Linked", "Return"), listOf(0.0, 0.36, 0.72))
        } finally {
            directory.deleteRecursively()
        }
    }

    private fun expectLosslessAudio(
        clip: JSONObject,
        decoder: String,
        layout: String,
        sampleFormat: String,
        bytesPerSample: Int,
        format: String = decoder,
        demuxer: String? = null,
        sourceUrl: String? = null,
        checkTimeline: (PlaybackSnapshot) -> Unit = {},
    ) {
        val name = clip.getString("file")
        val rate = clip.getInt("sampleRate")
        val frames = clip.getInt("frames")
        val channels = clip.getInt("channels")
        val options = mutableMapOf(
            "ad" to "$decoder,-", "audio-channels" to layout, "audio-samplerate" to rate.toString(),
            "audio-format" to sampleFormat, "hr-seek" to "yes",
        )
        if (demuxer != null) options["demuxer"] = demuxer
        for ((start, signature) in listOf(0 to "sha256", clip.getInt("seekStartFrame") to "seekSha256")) {
            val samples = capturePcmBytes(name, options, startTime = start.toDouble() / rate, sourceUrl = sourceUrl) { state ->
                assertContainer(name, format, state)
                assertEquals(decoder, state.audioTracks.single { it.isSelected }.codec)
                assertTrue("$name is seekable", state.seekable)
                checkTimeline(state)
            }
            val frameSize = channels * bytesPerSample
            val expectedBytes = (frames - start) * frameSize
            // mpv truncates the fractional sample offset during an exact seek.
            val oneSampleEarly = start > 0 && samples.size == expectedBytes + frameSize && clip.has("seekEarlySha256")
            assertTrue("$name PCM bytes from frame $start, expected $expectedBytes and found ${samples.size}",
                samples.size == expectedBytes || oneSampleEarly)
            val digest = MessageDigest.getInstance("SHA-256").digest(samples).joinToString("") { "%02x".format(it) }
            val expected = if (oneSampleEarly) "seekEarlySha256" else signature
            assertEquals("$name decoded PCM starting at frame $start", clip.getString(expected), digest)
        }
    }

    @Test fun seekableRawAudioStartsWithTheFirstPacket() {
        val clips = localMediaCases("audio").filter { it.getBoolean("pipeInput") }
        assertEquals(setOf("apm", "g726", "g726le"), clips.map { it.getString("format") }.toSet())
        for (clip in clips) {
            expectEncodedTone(clip, pipeInput = false, requireSeekable = true)
        }
    }

    private fun expectEncodedTone(
        clip: JSONObject,
        pipeInput: Boolean,
        requireSeekable: Boolean = false,
        decoder: String = clip.getString("decoder"),
    ) {
        val name = clip.getString("file")
        val format = clip.getString("format")
        val options = mutableMapOf("ad" to "$decoder,-", "vid" to "no")
        val mpvOptions = clip.getJSONObject("mpvOptions")
        mpvOptions.keys().forEach { options[it] = mpvOptions.getString(it) }
        val samples = capturePcm(name, options, pipeInput) { state ->
            assertContainer(name, format, state)
            assertEquals(name, clip.getString("codec"), state.audioTracks.single { it.isSelected }.codec)
            if (requireSeekable) assertTrue("$name is seekable", state.seekable)
            if (options["vid"] == "no") assertTrue("$name has no selected video", state.videoTracks.none { it.isSelected })
        }
        if (format == "gxf" && clip.getString("codec").startsWith("pcm_")) {
            // The 24-bit fixture has 32 authored 1920-sample packets. The 16-bit
            // muxer output pads its second 32,768-sample packet to a full block.
            val authoredPackets = clip.getString("codec") == "pcm_s24le"
            val expectedSamples = if (authoredPackets) 61440 else 65536
            assertEquals("$name decoded PCM with the full GXF packet layout", expectedSamples, samples.limit())
            for (start in listOf(2400, 30000, 52800)) assertMonoTone(name, samples, start, 440)
            if (!authoredPackets) {
                assertTrue("$name final block contains only padding after the tone", (60000 until samples.limit()).all { samples[it] == 0.toShort() })
            }
            return
        }
        val expectedDuration = if (requireSeekable && format != "apm") 1.275 else 1.25
        val tolerance = if (requireSeekable) 0.005 else 0.15
        assertEquals("$name decoded duration", expectedDuration, samples.limit() / 48000.0, tolerance)
        for (start in listOf(2400, samples.limit() / 2, samples.limit() - 7200)) {
            assertMonoTone(name, samples, start, 440)
        }
    }

    @Test fun borrowedFileDescriptorPcmKeepsBothChannelsAtAnExactSeek() {
        val buffer = ByteBuffer.allocate(60_000 * 4).order(ByteOrder.LITTLE_ENDIAN)
        for (frame in 0 until 60_000) {
            buffer.putShort(((frame * 257) % 65_521 - 32_760).toShort())
            buffer.putShort(((frame * 541) % 65_479 - 32_739).toShort())
        }
        val bytes = buffer.array()
        val input = File.createTempFile("authored-stereo-", ".pcm", instrumentation.targetContext.cacheDir)
        try {
            input.writeBytes(bytes)
            val options = mapOf(
                "ad" to "pcm_s16le,-", "demuxer" to "rawaudio", "demuxer-rawaudio-channels" to "stereo",
                "demuxer-rawaudio-format" to "s16le", "demuxer-rawaudio-rate" to "48000",
                "audio-channels" to "stereo", "cache" to "yes", "hr-seek" to "yes",
            )
            for (firstFrame in listOf(0, 24_000)) {
                ParcelFileDescriptor.open(input, ParcelFileDescriptor.MODE_READ_ONLY).use { descriptor ->
                    val decoded = capturePcmBytes(
                        input.name, options, startTime = firstFrame / 48_000.0, sourceUrl = "fd://${descriptor.fd}",
                    ) { state ->
                        assertContainer(input.name, "rawaudio", state)
                        assertTrue(state.seekable)
                        assertEquals("pcm_s16le", state.audioTracks.single { it.isSelected }.codec)
                    }
                    assertArrayEquals(bytes.copyOfRange(firstFrame * 4, bytes.size), decoded)
                }
            }
        } finally {
            input.delete()
        }
    }

    private fun capturePcm(
        name: String,
        options: Map<String, String>,
        pipeInput: Boolean = false,
        activity: ActivityScenario<PlaybackTestActivity>? = null,
        sourceUrl: String? = null,
        checkState: (PlaybackSnapshot) -> Unit,
    ): ShortBuffer {
        val samples = capturePcmBytes(name, options, pipeInput, activity, sourceUrl = sourceUrl, checkState = checkState)
        return ByteBuffer.wrap(samples).order(ByteOrder.LITTLE_ENDIAN).asShortBuffer()
    }

    private fun capturePcmBytes(
        name: String,
        options: Map<String, String>,
        pipeInput: Boolean = false,
        activity: ActivityScenario<PlaybackTestActivity>? = null,
        startTime: Double? = null,
        sourceUrl: String? = null,
        duringPlayback: ((MPVPlayer) -> Unit)? = null,
        checkState: (PlaybackSnapshot) -> Unit,
    ): ByteArray {
        val context = instrumentation.targetContext
        val pcm = File.createTempFile("decoded-", ".pcm", context.cacheDir)
        try {
            val defaults = mapOf(
                "ao" to "pcm",
                "ao-pcm-file" to pcm.absolutePath,
                "ao-pcm-waveheader" to "no",
                "audio-format" to "s16",
                "audio-samplerate" to "48000",
                "audio-channels" to "mono",
                "gapless-audio" to "no",
            )
            MPVPlayer(context, PlayerConfiguration(
                audio = AudioConfiguration(AudioConfiguration.AudioSession.HOST_MANAGED),
                hardwareDecoding = HardwareDecoding.DISABLED,
                additionalOptions = defaults + options,
            )).use { player ->
                activity?.onActivity { it.video.player = player }
                try {
                    withAudioSource(sourceUrl ?: fixture(name), pipeInput) { source ->
                        // pcm is untimed. Start playback immediately so a short file cannot drain while paused.
                        player.load(source, startTime = startTime)
                        duringPlayback?.invoke(player)
                        await("$name reaches the end", timeout = 5000, details = { player.state.value }) {
                            val state = player.state.value
                            state.error != null || state.state == PlaybackState.ENDED
                        }
                        val state = player.state.value
                        assertNull(name, state.error)
                        checkState(state)
                        player.stop()
                        await("stop $name") { player.state.value.state == PlaybackState.STOPPED }
                    }
                } finally {
                    activity?.onActivity { it.video.player = null }
                }
            }
            return pcm.readBytes()
        } finally {
            pcm.delete()
        }
    }

    @Test fun stereoAudioContainersPreserveBothChannels() {
        val cases = listOf(
            Triple("audio-flac.flac", "flac", "flac"), Triple("audio-alac.m4a", "mov", "alac"),
            Triple("audio-mp3.mp3", "mp3", "mp3"), Triple("audio-vorbis.ogg", "ogg", "vorbis"),
            Triple("audio-opus.ogg", "ogg", "opus"), Triple("audio-pcm.wav", "wav", "pcm_s16le"),
            Triple("audio-adts.aac", "aac", "aac"),
        )
        for ((name, format, decoder) in cases) {
            val pcm = capturePcm(name, mapOf("ad" to "$decoder,-", "audio-channels" to "stereo")) { state ->
                assertContainer(name, format, state)
                assertEquals(name, decoder, state.audioTracks.single { it.isSelected }.codec)
            }
            assertChannelTones(name, pcm, 4.0, listOf(220, 330))
        }
    }

    @Test fun flacPlaylistAdvancesWithoutDroppingOrRepeatingAnyStereoSamples() {
        val name = "audio-flac-gapless.m3u"
        fixture("audio-flac-gapless-01.flac")
        fixture("audio-flac-gapless-02.flac")
        val options = mapOf("ad" to "flac,-", "gapless-audio" to "yes", "audio-channels" to "stereo")
        val samples = capturePcmBytes(name, options) { state ->
            assertContainer(name, "flac", state)
            assertEquals("flac", state.audioTracks.single { it.isSelected }.codec)
            assertTrue("the playlist ended after the second track", state.title.contains("audio-flac-gapless-02"))
        }
        assertEquals(60_000 * 4, samples.size)
        val digest = MessageDigest.getInstance("SHA-256").digest(samples).joinToString("") { "%02x".format(it) }
        assertEquals("2371763cb855fedcefa9b7c7b99e49fe475c8084e80da91b975fade392349899", digest)
    }

    @Test fun matroskaPcmAndDolbyPreserveChannelOrder() {
        for ((layout, channels) in listOf("mono" to 1, "stereo" to 2, "5.1" to 6, "7.1" to 8)) {
            val settings = mapOf("ad" to "pcm_s16le,-", "audio-channels" to layout)
            val name = "audio-pcm-$layout.mka"
            val pcm = capturePcm(name, settings) { state ->
                assertContainer(name, "mkv", state)
                assertEquals(name, "pcm_s16le", state.audioTracks.single { it.isSelected }.codec)
            }
            assertChannelTones(name, pcm, 6.0, List(channels) { 220 + it * 110 })
        }
        for (codec in listOf("ac3", "eac3")) {
            val names = listOf("audio-$codec-stereo.mka", "audio-$codec-5.1.mka") +
                if (codec == "eac3") listOf("audio-eac3-256k-5.1.mka", "audio-eac3-768k-5.1.mka") else emptyList()
            for (name in names) {
                val stereo = name.contains("stereo")
                val layout = if (stereo) "stereo" else "5.1"
                val pcm = capturePcm(name, mapOf("ad" to "$codec,-", "audio-channels" to layout)) { state ->
                    assertContainer(name, "mkv", state)
                    assertEquals(name, codec, state.audioTracks.single { it.isSelected }.codec)
                }
                val duration = if (name == "audio-$codec-5.1.mka") 24.0 else 6.0
                val tones = if (stereo) listOf(220, 330) else listOf(220, 330, 440, null, 660, 770)
                assertChannelTones(name, pcm, duration, tones)
            }
        }
    }

    @Test fun dtsTrackSelectionDecodesTheAuthoredTones() {
        val name = "audio-dts-multitrack.mkv"
        for ((track, frequency) in listOf(1 to 440, 2 to 660)) {
            val pcm = capturePcm(name, mapOf("ad" to "dca,-", "vid" to "no", "aid" to track.toString(), "length" to "2")) { state ->
                assertContainer(name, "mkv", state)
                val selected = state.audioTracks.single { it.isSelected }
                assertEquals(name, "dts", selected.codec)
                assertEquals(name, track, selected.id.mpvId)
            }
            assertEquals(name, 2.0, pcm.limit() / 48000.0, .15)
            for (start in listOf(4800, 36000, 72000)) assertMonoTone(name, pcm, start, frequency)
        }
    }

    @Test fun dtsAudioAndVideoClocksContinueAfterATrackAndSpeedChange() = session(
        mapOf("vd" to "h264,-", "ad" to "dca,-", "ao" to "null", "audio-channels" to "auto",
            "audio-pitch-correction" to "no", "aid" to "1"),
    ) { player, _ ->
        val name = "audio-dts-multitrack.mkv"
        player.setDiagnosticsEnabled(true)
        player.load(fixture(name), autoPlay = false)
        await("DTS starts with both audio tracks", details = { player.state.value }) {
            player.state.value.let { it.hasVideoFrame && it.audioTracks.size == 2 }
        }
        assertContainer(name, "mkv", player.state.value)
        val stereo = player.state.value.audioTracks.single { it.id.mpvId == 2 }
        assertEquals("dts", stereo.codec)
        assertEquals(1, player.state.value.audioTracks.single { it.isSelected }.id.mpvId)
        player.setPlaybackRate(4.0)
        player.play()
        await("DTS 5.1 stays in sync after 30 seconds", timeout = 14000, details = { player.state.value }) {
            val state = player.state.value
            state.position >= 30 && state.diagnostics.audioOutput == "null" &&
                state.diagnostics.outputChannels?.startsWith("5.1") == true &&
                abs(state.diagnostics.audioVideoDriftSeconds ?: Double.POSITIVE_INFINITY) < .25
        }

        player.pause()
        await("DTS pauses for the track switch") { player.state.value.paused }
        val position = player.state.value.position
        player.selectTrack(stereo.id)
        player.setPlaybackRate(3.0)
        player.play()
        await("DTS stereo resumes near the switch with synchronized video", details = { player.state.value }) {
            val state = player.state.value
            state.position in (position + 1)..(position + 5) && state.playbackRate == 3.0 &&
                state.audioTracks.any { it.id == stereo.id && it.isSelected } &&
                state.diagnostics.outputChannels == "stereo" &&
                abs(state.diagnostics.audioVideoDriftSeconds ?: Double.POSITIVE_INFINITY) < .25
        }
        await("DTS stereo continues to EOF", timeout = 20000, details = { player.state.value }) {
            player.state.value.let { it.error != null || it.state == PlaybackState.ENDED }
        }
        assertNull(player.state.value.error)
        assertTrue(player.state.value.position >= 71.5)
    }

    private fun assertChannelTones(name: String, pcm: ShortBuffer, seconds: Double, frequencies: List<Int?>) {
        val channels = frequencies.size
        assertEquals("$name interleaves $channels channels", 0, pcm.limit() % channels)
        assertEquals("$name has the encoded duration", seconds, pcm.limit() / (48000.0 * channels), .15)
        val frames = 4800
        for (start in listOf(12000, ((seconds - .45) * 48000).toInt())) {
            for ((channel, frequency) in frequencies.withIndex()) {
                if (frequency == null) continue
                fun level(hz: Int): Double {
                    var real = 0.0
                    var imaginary = 0.0
                    val radiansPerFrame = 2 * PI * hz / 48000
                    for (frame in 0 until frames) {
                        val sample = pcm.get((start + frame) * channels + channel) / 32768.0
                        real += sample * cos(radiansPerFrame * frame)
                        imaginary += sample * sin(radiansPerFrame * frame)
                    }
                    return sqrt(real * real + imaginary * imaginary) * 2 / frames
                }
                val expected = level(frequency)
                assertTrue("$name channel $channel contains ${frequency}Hz at frame $start", expected > .015)
                assertTrue("$name channel $channel preserves its source position", frequencies.filterNotNull().all {
                    it == frequency || level(it) < expected / 3
                })
            }
        }
    }

    private fun assertMonoTone(name: String, samples: ShortBuffer, start: Int, frequency: Int) {
        var peak = 0
        var belowThreshold = false
        var crossings = 0
        for (index in start until start + 4800) {
            val sample = samples.get(index).toInt()
            peak = maxOf(peak, sample)
            // Ignore small resampling oscillations around zero in quantized inputs.
            if (sample < -256) belowThreshold = true
            if (sample > 256 && belowThreshold) {
                belowThreshold = false
                crossings++
            }
        }
        assertTrue("$name decoded signal at sample $start", peak > 820)
        assertEquals("$name decoded $frequency Hz at sample $start", frequency / 10.0, crossings.toDouble(), 2.0)
    }

    private fun withAudioSource(
        path: String,
        pipeInput: Boolean,
        pipeUrl: (Int) -> String = { "fd://$it" },
        playback: (String) -> Unit,
    ) {
        if (!pipeInput) {
            playback(path)
            return
        }

        val (reader, writer) = ParcelFileDescriptor.createPipe()
        reader.use {
            val transfer = FutureTask {
                ParcelFileDescriptor.AutoCloseOutputStream(writer).use { output ->
                    File(path).inputStream().use { it.copyTo(output) }
                }
            }
            thread(name = "Audio fixture stream") { transfer.run() }
            playback(pipeUrl(reader.fd))
            transfer.get(5, TimeUnit.SECONDS)
        }
    }

    @Test fun ffmpegPipePreservesTheAuthoredAacTone() {
        val name = "codecs-aac-lc.aac"
        withAudioSource(fixture(name), pipeInput = true, pipeUrl = { "ffmpeg://pipe:$it" }) { source ->
            val samples = capturePcm(name, mapOf("ad" to "aac,-", "cache" to "no"), sourceUrl = source) { state ->
                assertContainer(name, "aac", state)
                assertEquals("aac", state.audioTracks.single { it.isSelected }.codec)
                assertFalse("The pipe is nonseekable", state.seekable)
            }
            assertEquals(1.25, samples.limit() / 48000.0, .1)
            for (start in listOf(2400, 29000, 51000)) assertMonoTone(name, samples, start, 440)
        }
    }

    @Test fun localSegmentedPlaybackSeeksAcrossDistinctFrames() = session { player, activity ->
        for (stream in localMediaCases("segmented")) {
            val name = stream.getString("file")
            val parts = stream.getJSONArray("parts")
            for (index in 0 until parts.length()) fixture(parts.getString(index))
            player.load(fixture(name), autoPlay = false)
            await("$name presents the initial frame", details = { player.state.value }) {
                player.state.value.let { it.error != null || it.hasVideoFrame }
            }
            assertNull(name, player.state.value.error)
            assertContainer(name, stream.getString("format"), player.state.value)
            assertEquals(name, "h264", player.state.value.videoTracks.single { it.isSelected }.codec)

            for ((time, channel) in listOf(2.25 to 2, 0.25 to 0, 1.25 to 1)) {
                player.seekTo(time)
                await("$name seeks to $time", details = { player.state.value }) {
                    abs(player.state.value.position - time) < 0.1 && player.state.value.hasVideoFrame
                }
                awaitPrimaryColor(activity, "$name at $time", channel)
            }
            player.stop()
            await("stop $name") { player.state.value.state == PlaybackState.STOPPED }
        }
    }

    @Test fun segmentedVideoPresentsEachAuthoredPicture() {
        for (clip in localMediaCases("segmentedVideo")) {
            val name = clip.getString("file")
            val decoder = clip.getString("decoder")
            withSegmentedSource(clip) { source ->
                session(mapOf("vd" to "$decoder,-", "aid" to "no")) { player, activity ->
                    player.load(source, autoPlay = false)
                    await("$name opens its initial picture", details = { player.state.value }) {
                        player.state.value.let { it.error != null || it.hasVideoFrame }
                    }
                    val state = player.state.value
                    assertNull(name, state.error)
                    assertContainer(name, clip.getString("format"), state)
                    assertEquals(name, clip.getString("codec"), state.videoTracks.single { it.isSelected }.codec)
                    assertEquals(name, 176, state.dimensions.width)
                    assertEquals(name, 144, state.dimensions.height)
                    for ((time, color) in listOf(2.25 to 2, 0.25 to 0, 1.25 to 1)) {
                        player.seekTo(time)
                        await("$name seeks to $time", details = { player.state.value }) {
                            abs(player.state.value.position - time) < 0.1 && player.state.value.hasVideoFrame
                        }
                        awaitPrimaryColor(activity, "$name at $time", color)
                    }
                }
            }
        }
    }

    @Test fun segmentedAudioPresentsEachAuthoredTone() {
        for (clip in localMediaCases("segmentedAudio")) {
            val name = clip.getString("file")
            val decoder = clip.getString("decoder")
            val duration = if ("-packed-" in name) 3.0 else 2.8
            withSegmentedSource(clip) { source ->
                val samples = capturePcm(name, mapOf("ad" to "$decoder,-", "vid" to "no"), sourceUrl = source) { state ->
                    assertContainer(name, clip.getString("format"), state)
                    assertEquals(name, clip.getString("codec"), state.audioTracks.single { it.isSelected }.codec)
                }
                assertEquals("$name decoded duration", duration, samples.limit() / 48000.0, 0.15)
                for ((start, tone) in listOf(12000 to 440, 60000 to 660, 108000 to 880)) {
                    assertMonoTone(name, samples, start, tone)
                }
            }
        }
    }

    private fun withSegmentedSource(clip: JSONObject, check: (String) -> Unit) {
        val name = clip.getString("file")
        val filenames = listOf(name) + streamParts(clip)
        LoopbackMediaServer(filenames.associateWith(::fixtureBytes)).use { server ->
            check(server.url(name))
            for (part in filenames) assertTrue("$name requests $part", server.requested(part))
        }
    }

    @Test fun httpStreamsSeekAcrossPictureAndAudioSegmentBoundaries() = verifyNetworkStreams(secure = false)

    @Test fun httpsStreamsSeekAcrossPictureAndAudioSegmentBoundaries() = verifyNetworkStreams(secure = true)

    @Test fun seekableHlsPreservesVideoAndAudioAcrossTwoDiscontinuityMarkers() = verifyNetworkStreams(
        secure = true,
        streams = listOf(localMediaCatalog().getJSONObject("hlsDiscontinuities")),
        cycles = 3,
        seekPoints = listOf(2.75 to 2, 3.25 to 0, 4.25 to 1, 5.75 to 2, 6.25 to 0, 8.25 to 2, 0.25 to 0),
    )

    @Test fun hlsReportsEarlyEofWhenSeekingPastResetTimestampsAndRecoversOnReload() = session(
        mapOf("vd" to "h264,-", "ad" to "aac,-", "audio" to "auto"),
    ) { player, activity ->
        val catalog = localMediaCatalog()
        val stream = catalog.getJSONObject("hlsTimestampResets")
        val standard = catalog.getJSONObject("hlsDiscontinuities")
        val name = stream.getString("file")
        val filenames = listOf(name, standard.getString("file")) + streamParts(stream) + streamParts(standard)
        LoopbackMediaServer(filenames.associateWith(::fixtureBytes)).use { server ->
            player.load(server.url(name), autoPlay = false)
            await("the reset HLS playlist exposes its declared duration", details = { player.state.value }) {
                player.state.value.let { it.hasVideoFrame && it.state == PlaybackState.PAUSED && it.duration > 8.9 }
            }
            assertContainer(name, "hls", player.state.value)
            assertEquals(9.0, player.state.value.duration, .1)
            player.seekTo(2.75)
            await("HLS seeks before the reset") { abs(player.state.value.position - 2.75) < .1 }
            awaitPrimaryColor(activity, "HLS last picture before reset", 2)

            // The current reader cannot map seeks into a segment whose clock restarted.
            player.seekTo(3.25)
            await("the reset timeline ends at the first discontinuity", details = { player.state.value }) {
                player.state.value.state == PlaybackState.ENDED
            }
            assertTrue(player.state.value.position in 2.75..3.01)
            assertNull(player.state.value.error)

            val previous = player.loadGeneration
            player.load(server.url(standard.getString("file")), autoPlay = false)
            await("HLS recovers with a continuous timeline", details = { player.state.value }) {
                player.state.value.let { it.loadGeneration > previous && it.hasVideoFrame && it.state == PlaybackState.PAUSED }
            }
            player.seekTo(4.25)
            await("HLS seeks after the first boundary") { abs(player.state.value.position - 4.25) < .1 }
            awaitPrimaryColor(activity, "HLS recovery after the first boundary", 1)
        }
    }

    private fun verifyNetworkStreams(
        secure: Boolean,
        streams: List<JSONObject> = localMediaCases("networkStreams"),
        cycles: Int = 1,
        seekPoints: List<Pair<Double, Int>> = listOf(2.25 to 2, 0.25 to 0, 1.25 to 1),
    ) {
        val options = mutableMapOf("vd" to "h264,-", "ad" to "aac,-", "audio" to "auto")
        val socketFactory = if (secure) {
            options["tls-verify"] = "yes"
            options["tls-ca-file"] = fixture("tls-loopback.pem")
            loopbackTLSContext().serverSocketFactory
        } else {
            ServerSocketFactory.getDefault()
        }
        for (stream in streams) {
            val name = stream.getString("file")
            val format = stream.getString("format")
            val filenames = listOf(name) + streamParts(stream)
            LoopbackMediaServer(filenames.associateWith(::fixtureBytes), socketFactory = socketFactory).use { server ->
                val url = server.url(name)
                session(options) { player, activity ->
                    player.load(url, autoPlay = false)
                    await("$name presents its first frame", details = { player.state.value }) {
                        player.state.value.let { it.error != null || it.hasVideoFrame }
                    }
                    val state = player.state.value
                    assertNull(name, state.error)
                    assertContainer(name, format, state)
                    assertEquals(name, "h264", state.videoTracks.single { it.isSelected }.codec)
                    assertTrue("$name is seekable", state.seekable)
                    for ((time, channel) in seekPoints) {
                        player.seekTo(time)
                        await("$name seeks to $time", details = { player.state.value }) {
                            abs(player.state.value.position - time) < 0.1 && player.state.value.hasVideoFrame
                        }
                        awaitPrimaryColor(activity, "$name at $time", channel)
                    }
                }
                val samples = capturePcm(name, options + ("vid" to "no"), sourceUrl = url) { state ->
                    assertContainer(name, format, state)
                    assertEquals(name, "aac", state.audioTracks.single { it.isSelected }.codec)
                }
                val pattern = listOf(440, 660, 880)
                val segmentCount = cycles * pattern.size
                assertEquals("$name decoded duration", segmentCount.toDouble(), samples.limit() / 48000.0, 0.15)
                for (segment in 0 until segmentCount) {
                    assertMonoTone(name, samples, segment * 48000 + 12000, pattern[segment % pattern.size])
                }
                for (filename in filenames) {
                    assertTrue("mpv retrieved $filename over ${if (secure) "HTTPS" else "HTTP"}", server.requested(filename))
                }
            }
        }
    }

    @Test fun liveHlsRecoversWhenItsNextSegmentIsDelayed() = verifyLiveHls(secure = false)

    @Test fun liveHlsRecoversAcrossAnHttpsSegmentStall() = verifyLiveHls(secure = true)

    @Test fun liveDashAdvancesAcrossAnHttpsWindowRollover() = verifyLiveDash("liveDashSliding", secure = true)

    @Test fun liveDashKeepsVideoAndAudioAdvancingThroughTwoHttpsWindowRollovers() {
        val stream = localMediaCatalog().getJSONObject("dashRollovers")
        val manifests = streamParts(stream, "manifests")
        val video = streamParts(stream, "video")
        val audio = streamParts(stream, "audio")
        assertEquals(3, manifests.size)
        assertEquals(7, video.size)
        assertEquals(7, audio.size)
        val name = manifests.first()
        val fragments = video + audio
        val updates = manifests.drop(1).mapIndexed { index, filename ->
            val preceding = 2 * (index + 1)
            LoopbackMediaServer.ResourceVersion(setOf(video[preceding], audio[preceding]), fixtureBytes(filename))
        } + LoopbackMediaServer.ResourceVersion(setOf(video.last(), audio.last()), null)
        val options = mapOf(
            "vd" to "h264,-", "ad" to "aac,-", "cache-pause" to "no",
            "network-timeout" to "4", "demuxer-lavf-o" to "max_reload=8",
        ) + liveStreamingTLSOptions(secure = true)
        val tones = listOf(440, 660, 880, 440, 660, 880)
        LoopbackMediaServer(
            (listOf(name) + fragments).associateWith(::fixtureBytes),
            socketFactory = loopbackTLSContext().serverSocketFactory,
            versions = mapOf(name to updates),
        ).use { server ->
            ActivityScenario.launch(PlaybackTestActivity::class.java).use { activity ->
                val pcm = capturePcmBytes(name, options, activity = activity, sourceUrl = server.url(name), duringPlayback = { player ->
                    for (index in tones.indices) {
                        await("live DASH frame in window ${index / 2 + 1} at ${index}s", details = { player.state.value }) {
                            val state = player.state.value
                            state.error != null || (state.hasVideoFrame && state.position in (index + .15)..(index + .95) &&
                                isPrimaryColor(renderedPixels(activity, name)[45 * 160 + 80], index % 3))
                        }
                        val state = player.state.value
                        assertNull(state.error)
                        assertFalse("Live DASH is nonseekable", state.seekable)
                        assertEquals("h264", state.videoTracks.single { it.isSelected }.codec)
                    }
                }) { state ->
                    assertContainer(name, "dash", state)
                    assertEquals("aac", state.audioTracks.single { it.isSelected }.codec)
                }
                val samples = ByteBuffer.wrap(pcm).order(ByteOrder.LITTLE_ENDIAN).asShortBuffer()
                assertEquals("$name decoded duration", 6.0, samples.limit() / 48000.0, .15)
                for ((index, tone) in tones.withIndex()) assertMonoTone(name, samples, index * 48000 + 12000, tone)
            }
            for (fragment in fragments) assertTrue("mpv retrieved $fragment", server.requested(fragment))
            assertTrue("DASH reloads after the publisher retires the manifest", server.respondedWithError(410))
        }
    }

    private fun verifyLiveHls(secure: Boolean) {
        val stream = localMediaCatalog().getJSONObject("liveStream")
        val name = stream.getString("file")
        val parts = streamParts(stream)
        val options = mapOf(
            "vd" to "h264,-", "ad" to "aac,-", "ao" to "null",
            "demuxer-lavf-o" to "live_start_index=0",
            "cache" to "yes", "cache-pause" to "yes", "cache-pause-wait" to "0.25",
        ) + liveStreamingTLSOptions(secure)
        val factory = if (secure) loopbackTLSContext().serverSocketFactory else ServerSocketFactory.getDefault()
        LoopbackMediaServer((listOf(name) + parts).associateWith(::fixtureBytes), hold = parts.last(), socketFactory = factory).use { server ->
            session(options) { player, activity ->
                try {
                    player.load(server.url(name), autoPlay = false)
                    await("live HLS pauses on the first frame", details = { player.state.value }) {
                        player.state.value.let { it.error != null || (it.hasVideoFrame && it.state == PlaybackState.PAUSED) }
                    }
                    val initial = player.state.value
                    assertNull(initial.error)
                    assertContainer(name, "hls", initial)
                    assertEquals("h264", initial.videoTracks.single { it.isSelected }.codec)
                    assertEquals("aac", initial.audioTracks.single { it.isSelected }.codec)
                    assertEquals(PlaybackState.PAUSED, initial.state)
                    awaitPrimaryColor(activity, "first live segment", 0)

                    server.replace(name, fixtureBytes(stream.getString("update")))
                    player.play()
                    await("live HLS buffers with the final segment withheld", details = { player.state.value }) {
                        server.requested(parts.last()) && player.state.value.buffer.isBuffering
                    }
                    assertTrue("playback stalls before the delayed segment", player.state.value.position < 2.1)
                    assertNull(player.state.value.error)

                    server.releaseHeldResponse()
                    awaitPrimaryColor(activity, "delayed live segment", 2)
                    await("live HLS ends after consuming the delayed segment", details = { player.state.value }) {
                        val state = player.state.value
                        state.state == PlaybackState.ENDED && !state.buffer.isBuffering
                    }
                    assertNull(player.state.value.error)
                } finally {
                    server.releaseHeldResponse()
                }
            }
        }
    }

    @Test fun liveDashReloadsItsManifestAndPresentsTheNewlyListedSegment() = verifyLiveDash("liveDash")

    @Test fun liveDashAdvancesAcrossASlidingSegmentWindow() = verifyLiveDash("liveDashSliding")

    private fun verifyLiveDash(key: String, secure: Boolean = false) {
        val stream = localMediaCatalog().getJSONObject(key)
        val name = stream.getString("file")
        val parts = streamParts(stream)
        val options = mapOf(
            "vd" to "h264,-", "cache-pause" to "no", "network-timeout" to "4", "demuxer-lavf-o" to "max_reload=32",
        ) + liveStreamingTLSOptions(secure)
        val factory = if (secure) loopbackTLSContext().serverSocketFactory else ServerSocketFactory.getDefault()
        LoopbackMediaServer((listOf(name) + parts).associateWith(::fixtureBytes), socketFactory = factory).use { server ->
            session(options) { player, activity ->
                player.load(server.url(name), autoPlay = false)
                await("DASH requests the first advertised segment") { server.requested(parts[1]) }
                assertFalse("The initial DASH manifest does not expose the last segment", server.requested(parts.last()))
                server.replace(name, fixtureBytes(stream.getString("update")))

                await("DASH opens a live video frame", details = { player.state.value }) { player.state.value.hasVideoFrame }
                val state = player.state.value
                assertNull(state.error)
                assertContainer(name, "dash", state)
                assertEquals(176, state.dimensions.width)
                assertEquals("h264", state.videoTracks.single { it.isSelected }.codec)
                assertFalse("Live DASH is nonseekable", state.seekable)
                awaitPrimaryColor(activity, "initial live DASH frame", 0)

                player.play()
                awaitPrimaryColor(activity, "second live DASH segment", 1)
                awaitPrimaryColor(activity, "newly listed live DASH segment", 2)
                assertTrue("DASH requests the new segment", server.requested(parts.last()))
                assertTrue("The new segment follows the previous timeline", player.state.value.position >= 2.0)
                assertNull(player.state.value.error)
            }
        }
    }

    private fun liveStreamingTLSOptions(secure: Boolean): Map<String, String> =
        if (secure) mapOf("tls-verify" to "yes", "tls-ca-file" to fixture("tls-loopback.pem")) else emptyMap()

    @Test fun transportStreamDecodesOverUdpRtpAndSdp() {
        val transport = fixtureBytes("codecs-datagrams.ts")
        val options = transportOptions + ("demuxer-lavf-o" to "protocol_whitelist=[file,udp,rtp]")
        val routes = listOf("udp" to "mpegts", "rtp" to "rtp", "sdp" to "sdp")
        for ((scheme, reader) in routes) {
            LoopbackTransport(transport, usesRtp = scheme != "udp").use { sender ->
                val sdp = if (scheme == "sdp") {
                    File.createTempFile("transport-", ".sdp", instrumentation.targetContext.cacheDir).apply {
                        writeText(sender.sessionDescription)
                    }
                } else null
                try {
                    val source = sdp?.absolutePath ?: "$scheme://127.0.0.1:${sender.port}"
                    assertTransportPlayback(source, reader, options)
                } finally {
                    sdp?.delete()
                }
            }
        }
    }

    @Test fun dvbTunerDecodesTheAuthoredChannel() {
        val arguments = InstrumentationRegistry.getArguments()
        val config = arguments.getString("dvbFixtureChannels")
        val channel = arguments.getString("dvbFixtureChannel")
        val adapter = arguments.getString("dvbFixtureAdapter")?.toInt() ?: 0
        assumeTrue("A DVB tuner and a channel carrying codecs-datagrams.ts are required", config != null && channel != null)
        val devices = File("/dev/dvb/adapter$adapter").listFiles().orEmpty()
        assumeTrue("The test app can access the DVB frontend", devices.any { it.name.startsWith("frontend") && it.canRead() && it.canWrite() })
        val channels = File(requireNotNull(config))
        assertTrue("The DVB fixture channels file is readable", channels.canRead())
        assertTransportPlayback("dvb://$adapter@fixture", "mpegts", transportOptions + mapOf(
            "dvbin-file" to channels.absolutePath,
            "dvbin-prog" to requireNotNull(channel),
            "dvbin-timeout" to "4",
        ))
    }

    @Test fun udpLiteDeliversTheTransportStream() {
        val transport = fixtureBytes("codecs-datagrams.ts")
        LoopbackTransport.withUdpLite(transport) { source ->
            assertTransportPlayback(source, "mpegts", transportOptions + ("network-timeout" to "4"))
        }
    }

    @Test fun dtlsDeliversTheAuthenticatedTransportStream() {
        val arguments = InstrumentationRegistry.getArguments()
        // Build/Tests/run_with_dtls_fixture.py supplies the host loopback port.
        val port = arguments.getString("dtlsFixturePort")?.toIntOrNull()
        assumeTrue("A host-loopback DTLS fixture endpoint is configured", port != null)
        val host = arguments.getString("dtlsFixtureHost") ?: "10.0.2.2"
        require(host in listOf("127.0.0.1", "10.0.2.2") && requireNotNull(port) in 1..65535)
        val options = transportOptions + mapOf(
            "network-timeout" to "4",
            "tls-verify" to "yes",
            "tls-ca-file" to fixture("tls-loopback.pem"),
            "stream-lavf-o" to "verifyhost=127.0.0.1",
        )
        assertTransportPlayback("dtls://$host:$port", "mpegts", options)
    }

    @Test fun transportStreamDecodesOverTcpAndTls() {
        val transport = fixtureBytes("codecs-datagrams.ts")
        val options = transportOptions + mapOf(
            "network-timeout" to "4", "tls-verify" to "yes",
        )
        for (secure in listOf(false, true)) {
            val factory = if (secure) loopbackTLSContext().serverSocketFactory else ServerSocketFactory.getDefault()
            LoopbackMediaServer(rawStream = transport, socketFactory = factory).use { server ->
                assertTransportPlayback(server.url(""), "mpegts", options, verifyTrust = secure)
            }
        }
    }

    @Test fun gopherAndGophersSelectorsDeliverADecodedTransportStream() {
        val name = "codecs-datagrams.ts"
        val transport = fixtureBytes(name)
        val options = transportOptions + mapOf("network-timeout" to "4", "tls-verify" to "yes")
        for (secure in listOf(false, true)) {
            val factory = if (secure) loopbackTLSContext().serverSocketFactory else ServerSocketFactory.getDefault()
            LoopbackMediaServer(rawStream = transport, gopherSelector = name, socketFactory = factory).use { server ->
                assertTransportPlayback(server.url("9/$name"), "mpegts", options, verifyTrust = secure)
                assertTrue("The server received the Gopher file selector", server.requested(name))
            }
        }
    }

    @Test fun rtmpAndRtmpsDeliverTheAuthoredFlv() = expectRtmp(tunneled = false)

    @Test fun rtmptAndRtmptsDeliverTheAuthoredFlv() = expectRtmp(tunneled = true)

    @Test fun rtmpeAndRtmpteNegotiateEncryptedPlayback() {
        for (tunneled in listOf(false, true)) assertRtmp(tunneled, secure = false, encrypted = true)
    }

    private fun expectRtmp(tunneled: Boolean) {
        for (secure in listOf(false, true)) assertRtmp(tunneled, secure, encrypted = false)
    }

    private fun assertRtmp(tunneled: Boolean, secure: Boolean, encrypted: Boolean) {
        val recording = fixtureBytes("codecs-rtmp-replies.bin")
        val options = transportOptions + mapOf(
            "network-timeout" to "4",
            "stream-lavf-o" to "rtmp_live=live",
            "tls-verify" to "yes",
        )
        val factory = if (secure) loopbackTLSContext().serverSocketFactory else ServerSocketFactory.getDefault()
        LoopbackRtmpServer(recording, factory, tunneled = tunneled, encrypted = encrypted).use { server ->
            assertTransportPlayback(server.url, "flv", options, verifyTrust = secure, seekable = true)
        }
    }

    @Test fun windowsMediaHttpSchemesSelectBothAsfTracks() {
        val name = "codecs-windows-media.wmsp"
        val bytes = fixtureBytes(name)
        for (scheme in listOf("mmsh", "mms", "mmshttp")) {
            LoopbackMediaServer(mapOf(name to bytes)).use { server ->
                assertTransportPlayback(server.url(name).replaceFirst("http:", "$scheme:"), "asf", transportOptions, seekable = true)
                val pragmas = server.pragmas(name)
                assertTrue("$scheme requests the ASF header", pragmas.any { "request-context=1" in it })
                assertTrue("$scheme requests playback", "xPlayStrm=1" in pragmas)
                assertTrue("$scheme requests both streams", "stream-switch-count=2" in pragmas)
            }
        }
    }

    @Test fun windowsMediaTcpSelectsBothAsfTracks() {
        LoopbackMmstServer(fixtureBytes("codecs-windows-media.wmsp")).use { server ->
            assertTransportPlayback(server.url, "asf", transportOptions, checkEOF = true)
        }
    }

    @Test fun unixDomainSocketDeliversTheTransportStream() {
        val transport = fixtureBytes("codecs-datagrams.ts")
        val directory = kotlin.io.path.createTempDirectory(instrumentation.targetContext.cacheDir.toPath(), "u-").toFile()
        val socketPath = File(directory, "s").path
        try {
            LocalSocket(LocalSocket.SOCKET_STREAM).use { bound ->
                bound.bind(LocalSocketAddress(socketPath, LocalSocketAddress.Namespace.FILESYSTEM))
                LocalServerSocket(bound.fileDescriptor).use { server ->
                    val transfer = FutureTask {
                        server.accept().use { connection ->
                            try {
                                connection.outputStream.write(transport)
                            } catch (_: IOException) {
                                // The player may close the socket as soon as its assertions finish.
                            }
                        }
                    }
                    thread(name = "Unix transport fixture", isDaemon = true) { transfer.run() }
                    assertTransportPlayback("ffmpeg://unix:$socketPath", "mpegts", transportOptions)
                    transfer.get(5, TimeUnit.SECONDS)
                }
            }
        } finally {
            directory.deleteRecursively()
        }
    }

    @Test fun httpConnectTunnelDeliversTheTransportStream() {
        val authority = "fixture.invalid:80"
        val transport = fixtureBytes("codecs-datagrams.ts")
        LoopbackMediaServer(mapOf(authority to transport)).use { proxy ->
            val source = proxy.url(authority).replaceFirst("http://", "httpproxy://")
            assertTransportPlayback(source, "mpegts", transportOptions)
            assertTrue("The HTTP proxy received the expected CONNECT authority", proxy.requested(authority))
        }
    }

    @Test fun mpegAudioAduDecodersPreserveTheRtpTone() {
        val encoded = fixtureBytes("codecs-reservoir-free.mp3")
        val options = mapOf(
            "vid" to "no", "cache" to "no", "end" to "1.2",
            "demuxer-lavf-o" to "protocol_whitelist=[file,udp,rtp]",
            "demuxer-lavf-probesize" to "4096", "demuxer-lavf-analyzeduration" to "0.2",
        )
        for (decoder in listOf("mp3adu", "mp3adufloat")) {
            LoopbackTransport.mpegAudioAdu(encoded).use { sender ->
                val sdp = File.createTempFile("audio-adu-", ".sdp", instrumentation.targetContext.cacheDir)
                try {
                    sdp.writeText(sender.sessionDescription)
                    val samples = capturePcm(decoder, options + ("ad" to "$decoder,-"), sourceUrl = sdp.absolutePath) { state ->
                        assertContainer(decoder, "sdp", state)
                        assertEquals(decoder, "mp3adu", state.audioTracks.single { it.isSelected }.codec)
                        assertFalse("$decoder RTP stream does not seek", state.seekable)
                    }
                    assertTrue("$decoder decoded duration", samples.limit() / 48000.0 in 1.1..1.3)
                    for (start in listOf(2400, samples.limit() / 2, samples.limit() - 7200)) {
                        assertMonoTone(decoder, samples, start, 440)
                    }
                } finally {
                    sdp.delete()
                }
            }
        }
    }

    @Test fun rtspNegotiatesInterleavedTransportAndDecodesIt() {
        LoopbackRtspServer(fixtureBytes("codecs-datagrams.ts")).use { server ->
            assertTransportPlayback(server.url, "rtsp", transportOptions + ("rtsp-transport" to "tcp"))
        }
    }

    @Test fun rtspsNegotiatesInterleavedTransportOverTrustedTls() {
        val options = transportOptions + mapOf(
            "rtsp-transport" to "tcp", "tls-verify" to "yes", "tls-ca-file" to fixture("tls-loopback.pem"),
        )
        LoopbackRtspServer(fixtureBytes("codecs-datagrams.ts"), loopbackTLSContext().serverSocketFactory).use { server ->
            assertTransportPlayback(server.url, "rtsp", options)
        }
    }

    @Test fun interleavedRtspReconnectsAfterTheServerDropsASession() {
        val transport = fixtureBytes("codecs-datagrams.ts")
        for (secure in listOf(false, true)) {
            val factory = if (secure) loopbackTLSContext().serverSocketFactory else ServerSocketFactory.getDefault()
            val options = transportOptions + mapOf("rtsp-transport" to "tcp", "network-timeout" to "2") +
                liveStreamingTLSOptions(secure)
            LoopbackRtspServer(transport, factory).use { server ->
                session(options) { player, activity ->
                    for (attempt in 1..2) {
                        val previous = player.loadGeneration
                        val plays = server.playRequests
                        player.load(server.url, autoPlay = false)
                        await("RTSP connection $attempt opens a fresh picture",
                            details = { "PLAY requests: ${server.playRequests}, previous: $plays, state: ${player.state.value}" }) {
                            val state = player.state.value
                            state.loadGeneration > previous && (state.error != null ||
                                (state.hasVideoFrame && state.state == PlaybackState.PAUSED && server.playRequests > plays))
                        }
                        val state = player.state.value
                        assertNull(state.error)
                        assertContainer(server.url, "rtsp", state)
                        assertFalse(state.seekable)
                        assertEquals("h264", state.videoTracks.single { it.isSelected }.codec)
                        assertEquals("aac", state.audioTracks.single { it.isSelected }.codec)
                        await("RTSP connection $attempt renders an authored color") {
                            val pixel = renderedPixels(activity, server.url)[45 * 160 + 80]
                            (0..2).any { isPrimaryColor(pixel, it) }
                        }
                        player.play()
                        await("RTSP connection $attempt advances") { player.state.value.position > state.position + .25 }
                        if (attempt == 1) {
                            server.disconnect()
                            await("the dropped RTSP connection ends playback", details = { player.state.value }) {
                                player.state.value.let { it.state == PlaybackState.ENDED || it.state == PlaybackState.FAILED }
                            }
                        }
                    }
                }
            }
        }
    }

    @Test fun elementaryRtpAudioDecodesThroughEachReader() {
        val failures = mutableListOf<Throwable>()
        for (clip in localMediaCases("rtpAudio")) {
            val codec = clip.getString("codec")
            val decoder = clip.getString("decoder")
            val encoded = fixtureBytes(clip.getString("file"))
            val format = RtpAudioFixture(
                clip.getInt("payloadType"), clip.getString("encoding"), clip.getInt("packetBytes"),
                clip.getInt("packetTicks"), clip.getLong("packetMs"),
            )
            val options = mapOf(
                "ad" to "$decoder,-", "vid" to "no", "cache" to "no", "end" to "1.2", "rtsp-transport" to "tcp",
                "demuxer-lavf-o" to "protocol_whitelist=[file,udp,rtp,tcp]",
                "demuxer-lavf-probesize" to "4096", "demuxer-lavf-analyzeduration" to "0.2",
            )
            for (reader in listOf("rtp", "sdp", "rtsp")) {
                val name = "$codec through $reader"
                fun check(source: String) {
                    val samples = capturePcm(name, options, sourceUrl = source) { state ->
                        assertContainer(name, reader, state)
                        assertEquals(name, codec, state.audioTracks.single { it.isSelected }.codec)
                        assertFalse("$name does not seek", state.seekable)
                    }
                    assertEquals("$name decoded duration", 1.2, samples.limit() / 48000.0, 0.12)
                    for (start in listOf(3840, 24000, 45600)) assertMonoTone(name, samples, start, 440)
                }

                try {
                    if (reader == "rtsp") {
                        LoopbackRtspServer(format, encoded).use { check(it.url) }
                    } else {
                        LoopbackTransport(format, encoded).use { sender ->
                            if (reader == "sdp") {
                                val path = File.createTempFile("rtp-audio-", ".sdp", instrumentation.targetContext.cacheDir)
                                try {
                                    path.writeText(sender.sessionDescription)
                                    check(path.absolutePath)
                                } finally {
                                    path.delete()
                                }
                            } else {
                                check("rtp://127.0.0.1:${sender.port}")
                            }
                        }
                    }
                } catch (error: AssertionError) {
                    failures.add(error)
                }
            }
        }
        MultipleFailureException.assertEmpty(failures)
    }

    @Test fun packetizedRtpVideoPresentsBothAuthoredPictures() = expectRtpRecordingFixtures("rtpVideo") { clip, reader, source ->
        expectRtpVideoFrames(clip, reader, source, { isPrimaryColor(it, 0) }, { isPrimaryColor(it, 2) })
    }

    @Test fun referenceRtpTheoraPresentsWhiteAndCyanPictures() =
        expectRtpRecordingFixtures(referenceMediaCases("rtpVideo")) { clip, reader, source, _ ->
            expectRtpVideoFrames(
                clip, reader, source,
                { (it shr 16 and 255) > 200 && (it shr 8 and 255) > 200 && (it and 255) > 200 },
                { (it shr 16 and 255) < 45 && (it shr 8 and 255) > 180 && (it and 255) > 180 },
            )
        }

    private fun expectRtpVideoFrames(
        clip: RtpRecordingFixture,
        reader: String,
        source: String,
        firstColor: (Int) -> Boolean,
        secondColor: (Int) -> Boolean,
    ) {
        val name = "${clip.file} through $reader"
        val log = File.createTempFile("rtp-video-", ".log", instrumentation.targetContext.cacheDir)
        val options = rtpRecordingOptions + mapOf("vd" to "${clip.decoder},-", "log-file" to log.absolutePath)
        try {
            session(options) { player, activity ->
                player.load(source, autoPlay = false)
                await("$name decodes its first picture", details = { player.state.value }) {
                    player.state.value.let { it.hasVideoFrame || it.error != null }
                }
                val state = player.state.value
                assertNull(name, state.error)
                assertContainer(name, reader, state)
                assertEquals(name, clip.codec, state.videoTracks.single { it.isSelected }.codec)
                assertFalse("$name does not seek", state.seekable)
                assertEquals(name, clip.width, state.dimensions.width)
                assertEquals(name, clip.height, state.dimensions.height)
                player.play()
                var pixel = 0
                await("$name opening color", timeout = 5000, details = {
                    "pixel 0x${pixel.toUInt().toString(16)} at ${player.state.value.position}s"
                }) {
                    pixel = renderedPixels(activity, name)[45 * 160 + 80]
                    firstColor(pixel)
                }
                val start = player.state.value.position
                await("$name advances to the second color", timeout = 6000, details = { player.state.value }) {
                    player.state.value.position > start && secondColor(renderedPixels(activity, name)[45 * 160 + 80])
                }
            }
        } catch (error: AssertionError) {
            val diagnostics = log.readLines().filterNot { "[vo/gpu-next/libplacebo]" in it }.takeLast(100).joinToString("\n")
            throw AssertionError("$name\n$diagnostics", error)
        } finally {
            log.delete()
        }
    }

    @Test fun packetizedRtpAudioProducesTheAuthoredTone() =
        expectRtpRecordingFixtures("rtpPacketizedAudio", ::expectPacketizedAudio)

    @Test fun sdpAuthenticatesEncryptedRtpAndDecodesItsTone() =
        expectRtpRecordingFixtures("srtpAudio", ::expectPacketizedAudio)

    @Test fun srtpOpensAuthenticatedMpegTransportDirectly() {
        val row = localMediaCatalog().getJSONObject("srtpTransport")
        val clip = rtpRecordingFixture(row)
        val options = transportOptions + mapOf(
            "stream-lavf-o" to row.getString("inputOptions"),
            "demuxer-lavf-format" to "mpegts",
            "network-timeout" to "4",
        )
        LoopbackTransport(clip, fixtureBytes(clip.file)).use { sender ->
            assertTransportPlayback("srtp://127.0.0.1:${sender.port}", "mpegts", options)
        }
    }

    private fun expectPacketizedAudio(clip: RtpRecordingFixture, reader: String, source: String) {
        val name = "${clip.file} through $reader"
        val options = rtpRecordingOptions + mapOf("ad" to "${clip.decoder},-", "vid" to "no", "end" to "1.2")
        val samples = capturePcm(name, options, sourceUrl = source) { state ->
            assertContainer(name, reader, state)
            assertEquals(name, clip.codec, state.audioTracks.single { it.isSelected }.codec)
            assertFalse("$name does not seek", state.seekable)
        }
        assertEquals("$name decoded duration", 1.2, samples.limit() / 48000.0, .13)
        for (start in listOf(3840, 24000, 45600)) assertMonoTone(name, samples, start, 440)
    }

    @Test fun referenceRtpAudioDecodersPreserveThePcmEnvelope() =
        expectRtpRecordingFixtures(referenceMediaCases("rtpAudio")) { recording, reader, source, clip ->
            val name = "${recording.file} through $reader"
            val options = rtpRecordingOptions + referenceOptions(clip) +
                mapOf("ad" to "${recording.decoder},-", "vid" to "no")
            val samples = capturePcm(name, options, sourceUrl = source) { state ->
                assertContainer(name, reader, state)
                assertEquals(name, recording.codec, state.audioTracks.single { it.isSelected }.codec)
                assertFalse("$name does not seek", state.seekable)
            }
            assertPcmEnvelope(name, samples, clip)
        }

    @Test fun t140RtpSubtitleTextAppearsOverLocalVideo() {
        val cues = listOf("First café cue", "Second broadcast cue")
        val payloadType = 98
        val interval = 400
        val packetsPerCue = 4
        val payloads = cues.flatMap { cue -> List(packetsPerCue) { cue.encodeToByteArray() } }
        val recording = ByteBuffer.allocate(payloads.sumOf { 18 + it.size })
        for ((index, payload) in payloads.withIndex()) {
            recording.putShort((12 + payload.size).toShort())
            recording.putInt(interval * 1000)
            recording.put(0x80.toByte())
            recording.put((payloadType or if (index % packetsPerCue == 0) 0x80 else 0).toByte())
            recording.putShort(index.toShort())
            recording.putInt(index * interval)
            recording.putInt(1297110613)
            recording.put(payload)
        }
        val clip = RtpRecordingFixture(
            "T.140 subtitles", "text", "text", "text", payloadType, listOf("a=rtpmap:$payloadType t140/1000"),
            payloads.size * interval, false, 0, 0,
        )
        val failures = mutableListOf<Throwable>()
        for (reader in clip.readers) {
            val log = File.createTempFile("rtp-subtitle-", ".log", instrumentation.targetContext.cacheDir)
            try {
                withRtpRecording(clip, recording.array(), reader) { source ->
                    val uri = if (reader == "sdp") Uri.fromFile(File(source)) else Uri.parse(source)
                    val options = rtpRecordingOptions + mapOf(
                        "sub-auto" to "no", "sub-stretch-durations" to "yes", "log-file" to log.absolutePath,
                        // This FFmpeg uses 90 kHz for subtitle RTP despite T.140's 1 kHz clock.
                        "sub-speed" to "90",
                    )
                    session(options) { player, _ ->
                        player.setTextSubtitleInterceptionEnabled(true)
                        player.load(fixture("baseline.mp4"), autoPlay = false)
                        await("local video opens before loading T.140") { player.state.value.hasVideoFrame }
                        player.loadExternalSubtitle(uri)
                        await("$reader selects the external plain text track", timeout = 8000, details = { player.state.value }) {
                            player.state.value.selectedSubtitle()?.let { it.isExternal && it.codec == "text" } == true
                        }
                        player.play()
                        var previousPosition = -1.0
                        for (cue in cues) {
                            await("$reader presents $cue", timeout = 6000, details = { player.state.value }) {
                                val state = player.state.value
                                state.position > previousPosition && state.subtitles.regions.any { it.text == cue }
                            }
                            previousPosition = player.state.value.position
                        }
                        player.selectSubtitle(null)
                        await("$reader clears the external text") { player.state.value.subtitles.regions.isEmpty() }
                    }
                }
                assertTrue("$reader was used for T.140", log.readText().contains("Detected file format: $reader (libavformat)"))
            } catch (error: AssertionError) {
                failures.add(AssertionError("T.140 through $reader\n${log.readText().takeLast(6000)}", error))
            } finally {
                log.delete()
            }
        }
        MultipleFailureException.assertEmpty(failures)
    }

    private val rtpRecordingOptions = mapOf(
        "cache" to "no", "rtsp-transport" to "tcp",
        "demuxer-lavf-o" to "protocol_whitelist=[file,udp,rtp,tcp]",
        "demuxer-lavf-probesize" to "32768", "demuxer-lavf-analyzeduration" to "0.8",
    )

    private fun expectRtpRecordingFixtures(catalog: String, check: (RtpRecordingFixture, String, String) -> Unit) =
        expectRtpRecordingFixtures(localMediaCases(catalog)) { clip, reader, source, _ -> check(clip, reader, source) }

    private fun expectRtpRecordingFixtures(
        catalog: List<JSONObject>,
        check: (RtpRecordingFixture, String, String, JSONObject) -> Unit,
    ) {
        val failures = mutableListOf<Throwable>()
        for (row in catalog) {
            val clip = rtpRecordingFixture(row)
            val recording = fixtureBytes(clip.file)
            for (reader in clip.readers) {
                try {
                    withRtpRecording(clip, recording, reader) { source -> check(clip, reader, source, row) }
                } catch (error: AssertionError) {
                    failures.add(AssertionError("${clip.file} through $reader", error))
                }
            }
        }
        MultipleFailureException.assertEmpty(failures)
    }

    private fun rtpRecordingFixture(row: JSONObject): RtpRecordingFixture {
        val attributes = row.getJSONArray("sdpAttributes")
        return RtpRecordingFixture(
            row.getString("file"), row.getString("media"), row.getString("codec"), row.getString("decoder"),
            row.getInt("payloadType"), List(attributes.length()) { attributes.getString(it) },
            row.getInt("loopTicks"), row.getBoolean("direct"), row.optInt("width"), row.optInt("height"),
        )
    }

    private fun withRtpRecording(clip: RtpRecordingFixture, recording: ByteArray, reader: String, check: (String) -> Unit) {
        if (reader == "rtsp") {
            LoopbackRtspServer(clip, recording).use { check(it.url) }
            return
        }
        LoopbackTransport(clip, recording).use { sender ->
            if (reader == "rtp") {
                check("rtp://127.0.0.1:${sender.port}")
            } else {
                val path = File.createTempFile("rtp-recording-", ".sdp", instrumentation.targetContext.cacheDir)
                try {
                    path.writeText(sender.sessionDescription)
                    check(path.absolutePath)
                } finally {
                    path.delete()
                }
            }
        }
    }

    @Test fun sapAnnouncementOpensTheAdvertisedRtpTransport() {
        val log = File.createTempFile("sap-", ".log", instrumentation.targetContext.cacheDir)
        try {
            LoopbackTransport(fixtureBytes("codecs-datagrams.ts"), usesRtp = true).use { sender ->
                sender.withSapAnnouncement { url ->
                    val options = transportOptions + mapOf(
                        "demuxer-lavf-o" to "protocol_whitelist=[udp,rtp]",
                        "demuxer-lavf-probesize" to "524288",
                        "demuxer-lavf-analyzeduration" to "2",
                        "log-file" to log.absolutePath,
                    )
                    assertTransportPlayback(url, "sap", options)
                }
            }
        } catch (failure: AssertionError) {
            throw AssertionError("SAP playback failed\n" + log.readText().takeLast(6000), failure)
        } finally {
            log.delete()
        }
    }

    private val transportOptions = mapOf(
        "vd" to "h264,-", "ad" to "aac,-", "ao" to "null", "cache" to "no",
        "demuxer-lavf-probesize" to "32768", "demuxer-lavf-analyzeduration" to "0.25",
    )

    private fun assertTransportPlayback(
        source: String,
        reader: String,
        options: Map<String, String>,
        verifyTrust: Boolean = false,
        seekable: Boolean = false,
        checkEOF: Boolean = false,
    ) {
        val route = "$source through $reader"
        val log = File.createTempFile("transport-", ".log", instrumentation.targetContext.cacheDir)
        try {
            session(options + ("log-file" to log.absolutePath)) { player, activity ->
                if (verifyTrust) {
                    val previous = player.loadGeneration
                    player.load(source, autoPlay = false)
                    await("$route rejects the untrusted loopback certificate", details = { player.state.value }) {
                        val state = player.state.value
                        state.loadGeneration > previous && state.state == PlaybackState.FAILED
                    }
                    assertTrue(player.state.value.error is PlayerError.LoadFailed)
                    player.setProperty("options/tls-ca-file", fixture("tls-loopback.pem"))
                }
                val previous = player.loadGeneration
                player.load(source, autoPlay = false)
                await("$route presents a frame", details = { player.state.value }) {
                    player.state.value.let { it.loadGeneration > previous && (it.error != null || it.hasVideoFrame) }
                }
                val initial = player.state.value
                assertNull("$route loads", initial.error)
                assertContainer(source, reader, initial)
                assertEquals("$route seekability", seekable, initial.seekable)
                assertEquals("h264", initial.videoTracks.single { it.isSelected }.codec)
                assertEquals("aac", initial.audioTracks.single { it.isSelected }.codec)
                val center = renderedPixels(activity, route)[45 * 160 + 80]
                val rgb = listOf(center shr 16 and 0xff, center shr 8 and 0xff, center and 0xff).sorted()
                assertTrue("$route presents a source color", rgb[1] < 70 && rgb[2] > 180)
                player.play()
                await("$route advances past its first decoded frame", details = { player.state.value }) {
                    player.state.value.position > initial.position + 0.25
                }
                if (checkEOF) {
                    await("$route reaches EOF after the last packet", details = { player.state.value }) {
                        player.state.value.let { it.error != null || it.state == PlaybackState.ENDED }
                    }
                }
                assertNull("$route plays without errors", player.state.value.error)
            }
        } catch (failure: AssertionError) {
            val messages = log.readLines().filter { "[stream" in it || "[ffmpeg" in it }.takeLast(48)
            throw AssertionError("$route failed\n${messages.joinToString("\n")}", failure)
        } finally {
            log.delete()
        }
    }

    @Test fun httpHlsStartsAtTheRequestedBitrateAndSwitchesVideoRendition() {
        val stream = localMediaCatalog().getJSONObject("hlsRenditions")
        val name = stream.getString("file")
        val filenames = streamParts(stream)
        val options = mapOf("vd" to "h264,-", "ad" to "aac,-", "hls-bitrate" to "min")
        LoopbackMediaServer((listOf(name) + filenames).associateWith(::fixtureBytes)).use { server ->
            session(options) { player, activity ->
                player.load(server.url(name), autoPlay = false)
                await("low HLS rendition presents its first frame", details = { player.state.value }) {
                    player.state.value.let { it.error != null || (it.hasVideoFrame && it.dimensions.width > 0) }
                }
                val initial = player.state.value
                assertNull(initial.error)
                assertContainer(name, "hls", initial)
                assertEquals(176, initial.dimensions.width)
                assertEquals(2, initial.videoTracks.size)
                val low = initial.videoTracks.single { it.isSelected }.id
                val high = initial.videoTracks.single { !it.isSelected }.id
                awaitPrimaryColor(activity, "first low rendition frame", 0)

                player.selectTrack(high)
                await("high rendition is selected", details = { player.state.value }) {
                    player.state.value.videoTracks.any { it.id == high && it.isSelected }
                }
                player.seekTo(2.25)
                await("high rendition reaches the final segment", details = { player.state.value }) {
                    player.state.value.let { it.dimensions.width == 352 && abs(it.position - 2.25) < 0.1 }
                }
                awaitPrimaryColor(activity, "high rendition after seek", 2)

                player.selectTrack(low)
                await("low rendition is selected again", details = { player.state.value }) {
                    player.state.value.videoTracks.any { it.id == low && it.isSelected }
                }
                player.seekTo(1.25)
                await("low rendition reaches the middle segment", details = { player.state.value }) {
                    player.state.value.let { it.dimensions.width == 176 && abs(it.position - 1.25) < 0.1 }
                }
                awaitPrimaryColor(activity, "low rendition after seeking back", 1)
                assertEquals("aac", player.state.value.audioTracks.single { it.isSelected }.codec)
                assertNull(player.state.value.error)
            }
            for (playlist in filenames.filter { it.endsWith(".m3u8") }) {
                assertTrue("mpv retrieved $playlist", server.requested(playlist))
            }
            assertTrue("mpv retrieved the final high rendition segment", server.requested(filenames.last()))
        }
    }

    @Test fun httpDashSwitchesRepresentationsWithinTheSameAdaptationSet() = verifyDashVideoSelection("dashRenditions")

    @Test fun httpDashSwitchesVideoAcrossAdaptationSets() = verifyDashVideoSelection("dashAdaptationSets")

    @Test fun httpDashSwitchesAudioAcrossAdaptationSets() {
        val stream = localMediaCatalog().getJSONObject("dashAudioAdaptationSets")
        val name = stream.getString("file")
        val assets = (listOf(name) + streamParts(stream)).associateWith(::fixtureBytes)
        LoopbackMediaServer(assets).use { server ->
            val url = server.url(name)
            session(mapOf("vd" to "h264,-", "ad" to "aac,-", "aid" to "1")) { player, activity ->
                player.load(url, autoPlay = false)
                await("DASH opens both audio adaptation sets", details = { player.state.value }) {
                    player.state.value.let { it.error != null || (it.hasVideoFrame && it.audioTracks.size == 2) }
                }
                val initial = player.state.value
                assertNull(name, initial.error)
                assertContainer(name, "dash", initial)
                val video = initial.videoTracks.single { it.isSelected }.id
                val original = initial.audioTracks.single { it.isSelected }.id
                val alternate = initial.audioTracks.single { !it.isSelected }.id
                for ((audio, color) in listOf(original to 0, alternate to 2, original to 1)) {
                    player.selectTrack(audio)
                    val time = color + 0.25
                    player.seekTo(time)
                    await("DASH selects audio track $audio at $time", details = { player.state.value }) {
                        player.state.value.let { state ->
                            state.error != null || (abs(state.position - time) < 0.1 &&
                                state.audioTracks.any { it.id == audio && it.isSelected })
                        }
                    }
                    val state = player.state.value
                    assertNull(name, state.error)
                    assertEquals(video, state.videoTracks.single { it.isSelected }.id)
                    assertEquals("aac", state.audioTracks.single { it.isSelected }.codec)
                    awaitPrimaryColor(activity, "$name at $time", color)
                }
            }
            for ((id, tones) in listOf(1 to listOf(440, 660, 880), 2 to listOf(990, 990, 990))) {
                val options = mapOf("vid" to "no", "aid" to id.toString(), "ad" to "aac,-")
                val pcm = capturePcm(name, options, sourceUrl = url) { state ->
                    assertContainer(name, "dash", state)
                    assertEquals("aac", state.audioTracks.single { it.isSelected }.codec)
                }
                assertEquals("$name audio track $id duration", 3.0, pcm.limit() / 48000.0, 0.15)
                for ((segment, tone) in tones.withIndex()) {
                    assertMonoTone(name, pcm, 12000 + 48000 * segment, tone)
                }
            }
            assertTrue("DASH fetched the original audio", server.requested("codecs-http-dash-1-02.m4s"))
            assertTrue("DASH fetched the alternate audio", server.requested("codecs-dash-audio-alt-03.m4s"))
        }
    }

    private fun verifyDashVideoSelection(key: String) {
        val stream = localMediaCatalog().getJSONObject(key)
        val name = stream.getString("file")
        val assets = (listOf(name) + streamParts(stream)).associateWith(::fixtureBytes)
        LoopbackMediaServer(assets).use { server ->
            session(mapOf("vid" to "1", "vd" to "h264,-", "ad" to "aac,-")) { player, activity ->
                player.load(server.url(name), autoPlay = false)
                await("DASH opens a two-representation stream", details = { player.state.value }) {
                    val state = player.state.value
                    state.error != null || (state.hasVideoFrame && state.videoTracks.size == 2 && state.audioTracks.any { it.isSelected })
                }
                val initial = player.state.value
                assertNull(initial.error)
                assertContainer(name, "dash", initial)
                assertEquals(176, initial.dimensions.width)
                val low = initial.videoTracks.single { it.isSelected }.id
                val high = initial.videoTracks.single { !it.isSelected }.id
                val audio = initial.audioTracks.single { it.isSelected }.id
                for ((id, width, step) in listOf(Triple(low, 176, 0), Triple(high, 352, 2), Triple(low, 176, 1))) {
                    player.selectTrack(id)
                    await("DASH selects representation $id", details = { player.state.value }) {
                        player.state.value.videoTracks.any { it.id == id && it.isSelected }
                    }
                    val time = step + 0.25
                    player.seekTo(time)
                    await("DASH selects width $width", details = { player.state.value }) {
                        val state = player.state.value
                        state.dimensions.width == width && abs(state.position - time) < 0.1
                    }
                    awaitPrimaryColor(activity, "DASH $width at $time", step)
                    val track = player.state.value.audioTracks.single { it.isSelected }
                    assertEquals(audio, track.id)
                    assertEquals("aac", track.codec)
                    assertNull(player.state.value.error)
                }
            }
            assertTrue("DASH fetched the high representation", server.requested("codecs-dash-renditions-1-03.m4s"))
            assertTrue("DASH fetched the low representation", server.requested("codecs-dash-renditions-0-02.m4s"))
        }
    }

    private fun streamParts(stream: JSONObject, field: String = "parts"): List<String> {
        val parts = stream.getJSONArray(field)
        return List(parts.length()) { parts.getString(it) }
    }

    private fun fixtureBytes(filename: String): ByteArray =
        instrumentation.context.assets.open(filename).use { it.readBytes() }

    @Test fun mpegTransportStreamSwitchesBetweenTwoAuthoredPrograms() {
        val name = "codecs-two-programs.ts"
        val options = mapOf("ad" to "aac,mp2float,-", "vd" to "h264,mpeg2video,-", "hr-seek-demuxer-offset" to "0.65")
        session(options) { player, activity ->
            player.load(fixture(name), autoPlay = false)
            await("both MPEG-TS programs are available", details = { player.state.value }) {
                val state = player.state.value
                state.error != null || (state.hasVideoFrame && state.audioTracks.size == 2 && state.videoTracks.size == 2)
            }
            val initial = player.state.value
            assertNull(name, initial.error)
            assertContainer(name, "mpegts", initial)
            assertTrue("$name is seekable", initial.seekable)
            val avc = initial.videoTracks.single { it.codec == "h264" }
            val mpeg2 = initial.videoTracks.single { it.codec == "mpeg2video" }
            val aac = initial.audioTracks.single { it.codec == "aac" }
            val mp2 = initial.audioTracks.single { it.codec == "mp2" }
            assertTrue("the first program is selected", avc.isSelected && aac.isSelected)
            awaitPrimaryColor(activity, "first MPEG-TS program", 0)

            for ((video, audio, color) in listOf(Triple(mpeg2, mp2, 2), Triple(avc, aac, 0))) {
                val width = if (color == 0) 176 else 352
                val time = if (color == 0) 1.25 else 2.25
                player.selectTrack(video.id)
                player.selectTrack(audio.id)
                await("MPEG-TS selects video and audio from the new program", details = { player.state.value }) {
                    val state = player.state.value
                    state.videoTracks.any { it.id == video.id && it.isSelected } &&
                        state.audioTracks.any { it.id == audio.id && it.isSelected }
                }
                player.seekTo(time)
                await("MPEG-TS seeks to $time in the selected program", details = { player.state.value }) {
                    val state = player.state.value
                    state.dimensions.width == width && abs(state.position - time) < 0.1
                }
                assertNull(name, player.state.value.error)
                awaitPrimaryColor(activity, "$name $width at $time", color)
            }
        }

        for ((id, codec, decoder) in listOf(Triple(1, "aac", "aac"), Triple(2, "mp2", "mp2float"))) {
            val pcm = capturePcm(name, mapOf("vid" to "no", "aid" to id.toString(), "ad" to "$decoder,-")) { state ->
                assertContainer(name, "mpegts", state)
                assertEquals(codec, state.audioTracks.single { it.isSelected }.codec)
            }
            assertEquals("$name program audio duration", 3.0, pcm.limit() / 48000.0, 0.1)
            for (sample in listOf(7200, 60000, 132000)) assertMonoTone(name, pcm, sample, if (id == 1) 440 else 880)
        }
    }

    @Test fun mpegTransportStreamKeepsThePrimaryProgramAcrossPatUpdates() {
        val name = "codecs-changing-programs.ts"
        val options = mapOf(
            "ad" to "aac,-", "vd" to "h264,-", "ao" to "null", "cache" to "no",
            "demuxer-lavf-probesize" to "32768", "demuxer-lavf-analyzeduration" to "0.2",
        )
        session(options) { player, activity ->
            player.load(fixture(name), autoPlay = false)
            await("MPEG-TS opens with only its primary program", details = { player.state.value }) {
                player.state.value.let { it.error != null || it.hasVideoFrame && it.audioTracks.isNotEmpty() }
            }
            val initial = player.state.value
            assertNull(initial.error)
            assertContainer(name, "mpegts", initial)
            val video = initial.videoTracks.single { it.isSelected }
            val audio = initial.audioTracks.single { it.isSelected }
            assertEquals(setOf("h264", "aac"), initial.tracks.mapNotNull { it.codec }.toSet())
            awaitPrimaryColor(activity, "$name opens with red", 0)
            player.play()

            await("MPEG-TS exposes the late program", details = { player.state.value.tracks }) {
                val state = player.state.value
                state.videoTracks.map { it.codec }.toSet() == setOf("h264", "mpeg2video") &&
                    state.audioTracks.size == 2 && state.audioTracks.any { !it.isSelected && it.codec in setOf("mp3", "mp2") }
            }
            awaitPrimaryColor(activity, "$name primary program becomes green", 1)
            awaitPrimaryColor(activity, "$name primary program becomes blue", 2)
            val final = player.state.value
            assertEquals(video.id, final.videoTracks.single { it.isSelected }.id)
            assertEquals(audio.id, final.audioTracks.single { it.isSelected }.id)
            await("MPEG-TS finishes after the late program leaves", details = { player.state.value }) {
                player.state.value.let { it.error != null || it.state == PlaybackState.ENDED }
            }
            assertNull(player.state.value.error)
            assertTrue(player.state.value.position > 8.8)
        }

        val pcm = capturePcm(name, mapOf("vid" to "no", "aid" to "1", "ad" to "aac,-")) { state ->
            assertContainer(name, "mpegts", state)
            assertEquals("aac", state.audioTracks.single { it.isSelected }.codec)
        }
        assertEquals(9.0, pcm.limit() / 48000.0, .15)
        for ((time, tone) in listOf(.25 to 440, 2.75 to 440, 3.25 to 550, 5.75 to 550, 6.25 to 660, 8.75 to 660)) {
            assertMonoTone(name, pcm, (time * 48000).toInt(), tone)
        }
    }

    @Test fun mpegTransportStreamKeepsItsTimelineAcrossPtsWrap() {
        val name = "codecs-pts-wrap.ts"
        val options = mapOf("vd" to "h264,-", "ad" to "aac,-", "hr-seek-demuxer-offset" to "0.65")
        session(options) { player, activity ->
            player.load(fixture(name), autoPlay = false)
            await("wrapped MPEG-TS presents its first frame", details = { player.state.value }) {
                val state = player.state.value
                state.error != null || (state.hasVideoFrame && state.seekable)
            }
            val initial = player.state.value
            assertNull(name, initial.error)
            assertContainer(name, "mpegts", initial)
            assertEquals(3.0, initial.duration, 0.1)
            for ((time, color) in listOf(0.25 to 0, 2.25 to 2, 0.75 to 0)) {
                player.seekTo(time)
                await("MPEG-TS seeks to $time across PTS wrap", details = { player.state.value }) {
                    abs(player.state.value.position - time) < 0.1
                }
                awaitPrimaryColor(activity, "$name at $time", color)
            }
            player.play()
            awaitPrimaryColor(activity, "MPEG-TS color after crossing PTS wrap", 2)
            await("wrapped MPEG-TS reaches EOF", details = { player.state.value }) {
                player.state.value.state == PlaybackState.ENDED
            }
            assertNull(name, player.state.value.error)
        }
        val pcm = capturePcm(name, mapOf("vid" to "no", "ad" to "aac,-")) { state ->
            assertContainer(name, "mpegts", state)
            assertEquals("aac", state.audioTracks.single { it.isSelected }.codec)
        }
        assertEquals("$name decoded audio duration", 3.0, pcm.limit() / 48000.0, 0.1)
        for (sample in listOf(9600, 45600, 50400, 132000)) assertMonoTone(name, pcm, sample, 440)
    }

    @Test fun pairedStreamsDecodeOnEitherSideOfTheSameBoundary() {
        val pairs = localMediaCases("paired")
        session { player, activity ->
            for (pair in pairs) {
                val name = pair.getString("file")
                val videoDecoder = pair.getString("videoDecoder")
                val audioDecoder = pair.getString("audioDecoder")
                player.setProperty("options/vd", "$videoDecoder,-")
                player.setProperty("options/ad", "$audioDecoder,-")
                val previousGeneration = player.state.value.loadGeneration
                player.load(fixture(name), autoPlay = false)
                await("$name presents both selected tracks", details = { player.state.value }) {
                    val state = player.state.value
                    state.loadGeneration > previousGeneration && (state.error != null || state.hasVideoFrame)
                }
                val state = player.state.value
                assertNull(name, state.error)
                assertContainer(name, pair.getString("format"), state)
                assertEquals(name, pair.getString("videoCodec"), state.videoTracks.single { it.isSelected }.codec)
                assertEquals(name, pair.getString("audioCodec"), state.audioTracks.single { it.isSelected }.codec)

                for ((time, channel) in listOf(0.25 to 0, 1.25 to 1, 0.75 to 0, 1.75 to 1)) {
                    player.seekTo(time)
                    await("$name seeks to $time", details = { player.state.value }) {
                        abs(player.state.value.position - time) < 0.1 && player.state.value.hasVideoFrame
                    }
                    awaitPrimaryColor(activity, "$name at $time", channel)
                }
            }
        }
        ActivityScenario.launch(PlaybackTestActivity::class.java).use { activity ->
            for (pair in pairs) {
                checkPairedPcm(pair, pair.getString("videoDecoder"), expectVideo = true, activity = activity)
            }
        }
    }

    @Test fun unavailableVideoDecoderLeavesPairedAviAudioPlayable() {
        val pair = localMediaCases("paired").single { it.getString("format") == "avi" }
        ActivityScenario.launch(PlaybackTestActivity::class.java).use { activity ->
            checkPairedPcm(pair, "vp9", expectVideo = false, activity = activity)
        }
    }

    @Test fun dataReadersRejectNonplayableTracksAndTheSessionRecovers() = session(mapOf("keep-open" to "no")) { player, activity ->
        val transport = fixture("codecs-hls-00.ts")
        val indexedWebm = fixture("codecs-webm-dash-index.webm")
        val raw = File.createTempFile("raw-data-", ".bin", instrumentation.targetContext.cacheDir)
        try {
            raw.writeBytes(ByteArray(256) { it.toByte() })
            player.setProperty("options/demuxer", "lavf")
            for ((format, path, status) in listOf(
                Triple("data", raw.absolutePath, -16),
                Triple("mpegtsraw", transport, -17),
                Triple("webm_dash_manifest", indexedWebm, -16),
            )) {
                player.setProperty("options/demuxer-lavf-format", format)
                val previousGeneration = player.state.value.loadGeneration
                player.load(path)
                await("$format reports a playback error", details = { player.state.value }) {
                    val state = player.state.value
                    state.loadGeneration > previousGeneration && state.error != null && state.state == PlaybackState.FAILED
                }
                val error = player.state.value.error
                assertEquals(format, status, error?.code)
                if (format == "webm_dash_manifest") {
                    assertTrue(format, error is PlayerError.PlaybackFailed)
                } else {
                    assertTrue(format, error is PlayerError.LoadFailed)
                }
                assertFalse("$format produced a video frame", player.state.value.hasVideoFrame)
            }

            player.setProperty("options/demuxer-lavf-format", "")
            for ((path, format) in listOf(transport to "mpegts", indexedWebm to "matroska")) {
                val previousGeneration = player.state.value.loadGeneration
                player.load(path, autoPlay = false)
                await("ordinary $format renders after the rejected inputs", details = { player.state.value }) {
                    player.state.value.let { it.loadGeneration > previousGeneration && (it.hasVideoFrame || it.error != null) }
                }
                assertNull(player.state.value.error)
                assertContainer(path, format, player.state.value)
                awaitPrimaryColor(activity, path, 0)
            }
        } finally {
            raw.delete()
        }
    }

    @Test fun indexedWebmReportsAFrameOnlyWhenAFrameDecodes() = session(mapOf("demuxer" to "lavf")) { player, activity ->
        val source = fixture("codecs-webm-dash-index.webm")
        player.load(fixture("codecs-hls-01.ts"), autoPlay = false)
        await("first item has a decoded frame") { player.state.value.hasVideoFrame }
        awaitPrimaryColor(activity, "first MPEG-TS item", 1)

        player.setProperty("options/demuxer-lavf-format", "webm_dash_manifest")
        player.load(source)
        await("index reader reaches the end of the replacement item", details = { player.state.value }) {
            player.state.value.let { it.container == "webm_dash_manifest" && it.state == PlaybackState.ENDED }
        }
        val metadata = player.state.value
        assertNull(metadata.error)
        assertEquals("vp9", metadata.videoTracks.single { it.isSelected }.codec)
        assertFalse("Indexed track dimensions do not imply a decoded frame", metadata.hasVideoFrame)

        player.setProperty("options/demuxer-lavf-format", "")
        player.load(source, autoPlay = false)
        await("regular WebM reader decodes a frame", details = { player.state.value }) {
            player.state.value.let { it.loadGeneration > metadata.loadGeneration && (it.hasVideoFrame || it.error != null) }
        }
        assertNull(player.state.value.error)
        assertContainer(source, "matroska", player.state.value)
        awaitPrimaryColor(activity, "replacement WebM frame", 0)
    }

    @Test fun truncatedMovCannotReuseAFrameAndTheFullFileRecovers() = session(mapOf("vd" to "h264,-")) { player, activity ->
        val complete = fixture("tls-ranges.mp4")
        val truncated = File.createTempFile("truncated-", ".mp4", instrumentation.targetContext.cacheDir)
        try {
            val header = ByteArray(48)
            DataInputStream(File(complete).inputStream()).use { it.readFully(header) }
            assertEquals("moov", header.decodeToString(startIndex = 36, endIndex = 40))
            truncated.writeBytes(header)

            player.load(fixture("codecs-hls-01.ts"), autoPlay = false)
            await("first item decodes a frame") { player.state.value.hasVideoFrame }
            awaitPrimaryColor(activity, "preceding MPEG-TS", 1)

            val previous = player.state.value.loadGeneration
            player.load(truncated.absolutePath, autoPlay = false)
            await("truncated MOV reports a load error", details = { player.state.value }) {
                val state = player.state.value
                state.loadGeneration > previous && state.state == PlaybackState.FAILED
            }
            val rejected = player.state.value
            assertTrue(rejected.error is PlayerError.LoadFailed)
            assertFalse(rejected.hasVideoFrame)
            assertTrue(rejected.videoTracks.isEmpty())

            player.load(complete, autoPlay = false)
            await("full MOV decodes a new frame", details = { player.state.value }) {
                val state = player.state.value
                state.loadGeneration > rejected.loadGeneration && (state.hasVideoFrame || state.error != null)
            }
            assertNull(player.state.value.error)
            assertContainer(complete, "mov", player.state.value)
            awaitPrimaryColor(activity, "complete MOV opening", 0)
            player.seekTo(2.25)
            await("complete MOV seek reaches the requested time") { abs(player.state.value.position - 2.25) < .12 }
            awaitPrimaryColor(activity, "complete MOV after seek", 2)
        } finally {
            truncated.delete()
        }
    }

    @Test fun truncatedWebmClearsBothTracksAndRecoversThroughEitherReader() {
        val complete = fixture("codecs-paired-vp9-opus.webm")
        val truncated = File.createTempFile("truncated-", ".webm", instrumentation.targetContext.cacheDir)
        try {
            val header = ByteArray(8)
            DataInputStream(File(complete).inputStream()).use { it.readFully(header) }
            assertArrayEquals(byteArrayOf(0x1a, 0x45, 0xdf.toByte(), 0xa3.toByte()), header.copyOf(4))
            truncated.writeBytes(header)

            for ((reader, format) in listOf("mkv" to "mkv", "lavf" to "matroska")) {
                session(mapOf("demuxer" to reader, "vd" to "vp9,-", "ad" to "opus,-")) { player, activity ->
                    player.load(complete, autoPlay = false, startTime = 1.25)
                    await("$reader complete WebM with audio and video", details = { player.state.value }) {
                        val state = player.state.value
                        state.error != null || state.hasVideoFrame && state.audioTracks.any { it.isSelected }
                    }
                    assertNull(player.state.value.error)
                    assertContainer(complete, format, player.state.value)
                    assertEquals("opus", player.state.value.audioTracks.single { it.isSelected }.codec)
                    awaitPrimaryColor(activity, "$reader WebM before truncation", 1)

                    val previous = player.loadGeneration
                    player.load(truncated.absolutePath, autoPlay = false)
                    await("$reader truncated WebM reports a load error", details = { player.state.value }) {
                        val state = player.state.value
                        state.loadGeneration > previous && state.state == PlaybackState.FAILED
                    }
                    val rejected = player.state.value
                    assertTrue(rejected.error is PlayerError.LoadFailed)
                    assertFalse(rejected.hasVideoFrame)
                    assertTrue(rejected.videoTracks.isEmpty())
                    assertTrue(rejected.audioTracks.isEmpty())

                    player.load(complete, autoPlay = false)
                    await("$reader recovery presents both WebM tracks", details = { player.state.value }) {
                        val state = player.state.value
                        state.loadGeneration > rejected.loadGeneration &&
                            (state.error != null || state.hasVideoFrame && state.audioTracks.any { it.isSelected })
                    }
                    val recovered = player.state.value
                    assertNull(recovered.error)
                    assertContainer(complete, format, recovered)
                    assertEquals("vp9", recovered.videoTracks.single { it.isSelected }.codec)
                    assertEquals("opus", recovered.audioTracks.single { it.isSelected }.codec)
                    awaitPrimaryColor(activity, "$reader recovered WebM opening", 0)
                    player.seekTo(1.25)
                    await("$reader complete WebM seeks again") { abs(player.state.value.position - 1.25) < .12 }
                    awaitPrimaryColor(activity, "$reader recovered WebM after seek", 1)
                }
            }
        } finally {
            truncated.delete()
        }
    }

    @Test fun webmTruncatedAfterACompleteClusterReachesEarlyEofAndTheFullFileRecovers() {
        val truncated = "codecs-webm-truncated-cluster.webm"
        for ((reader, format) in listOf("mkv" to "mkv", "lavf" to "matroska")) {
            session(mapOf("demuxer" to reader, "vd" to "vp9,-", "ad" to "opus,-", "ao" to "null")) { player, activity ->
                player.load(fixture(truncated), autoPlay = false, startTime = .7)
                await("$reader presents the first complete cluster", details = { player.state.value }) {
                    val state = player.state.value
                    state.hasVideoFrame && state.audioTracks.any { it.isSelected } && abs(state.position - .7) < .1
                }
                val first = player.state.value
                assertContainer(truncated, format, first)
                assertEquals("vp9", first.videoTracks.single { it.isSelected }.codec)
                assertEquals("opus", first.audioTracks.single { it.isSelected }.codec)
                awaitPrimaryColor(activity, "$reader first cluster", 0)
                player.play()
                await("$reader reaches EOF at the truncated cluster", details = { player.state.value }) {
                    player.state.value.state == PlaybackState.ENDED
                }
                val ended = player.state.value
                assertNull(ended.error)
                assertTrue("$reader EOF at ${ended.position}", ended.position in .9..1.05)

                player.load(fixture("codecs-paired-vp9-opus.webm"), autoPlay = false, startTime = 1.25)
                await("$reader presents the complete second cluster", details = { player.state.value }) {
                    val state = player.state.value
                    state.loadGeneration > ended.loadGeneration && state.hasVideoFrame &&
                        state.state == PlaybackState.PAUSED && abs(state.position - 1.25) < .1
                }
                awaitPrimaryColor(activity, "$reader recovered second cluster", 1)
                assertNull(player.state.value.error)
            }
        }
    }

    @Test fun transparentProResBlendsWithTheBackgroundAndBundledVp8AndVp9StayOpaque() {
        val cases = listOf(
            Triple("codecs-alpha-prores.mov", "mov", "prores"),
            Triple("codecs-alpha-vp8.webm", "mkv", "vp8"),
            Triple("codecs-alpha-vp9.webm", "mkv", "vp9"),
        )
        for ((name, format, codec) in cases) {
            session(mapOf("vd" to "$codec,-", "background" to "color", "background-color" to "#00FF00")) { player, activity ->
                player.load(fixture(name), autoPlay = false)
                await("$name presents a frame", details = { player.state.value }) { player.state.value.hasVideoFrame }
                assertContainer(name, format, player.state.value)
                assertEquals(codec, player.state.value.videoTracks.single { it.isSelected }.codec)
                assertEquals(VideoOutput.GPU, player.state.value.videoFeatureCapabilities.backend)
                for ((time, red) in listOf(.25 to true, 1.25 to false, .25 to true)) {
                    player.seekTo(time)
                    await("$name presents the opacity stripes at $time", details = { player.state.value }) {
                        if (abs(player.state.value.position - time) >= .1) return@await false
                        val pixels = renderedPixels(activity, name, videoAspect = 1.5)
                        val (clear, half, solid) = listOf(26, 80, 133).map { pixels[45 * 160 + it] }
                        fun primary(pixel: Int) = if (red) Color.red(pixel) else Color.blue(pixel)
                        fun other(pixel: Int) = if (red) Color.blue(pixel) else Color.red(pixel)
                        fun foreground(pixel: Int) = primary(pixel) > 215 && Color.green(pixel) < 35 && other(pixel) < 35
                        if (codec == "prores") {
                            Color.green(clear) > 215 && primary(clear) < 35 && other(clear) < 35 &&
                                Color.green(half) in 55..230 && primary(half) in 55..230 && other(half) < 35 && foreground(solid)
                        } else {
                            listOf(clear, half, solid).all(::foreground)
                        }
                    }
                }
                assertNull(player.state.value.error)
            }
        }
    }

    private fun checkPairedPcm(
        pair: JSONObject,
        videoDecoder: String,
        expectVideo: Boolean,
        activity: ActivityScenario<PlaybackTestActivity>,
    ) {
        val name = pair.getString("file")
        val options = mapOf("vd" to "$videoDecoder,-", "ad" to "${pair.getString("audioDecoder")},-")
        val samples = capturePcm(name, options, activity = activity) { state ->
            assertContainer(name, pair.getString("format"), state)
            assertEquals(name, pair.getString("audioCodec"), state.audioTracks.single { it.isSelected }.codec)
            assertEquals(name, expectVideo, state.hasVideoFrame)
        }
        assertEquals("$name decoded duration", 2.0, samples.limit() / 48000.0, 0.15)
        for ((time, frequency) in listOf(0.25 to 440, 0.75 to 440, 1.25 to 660, 1.75 to 660)) {
            assertMonoTone(name, samples, (time * 48000).toInt(), frequency)
        }
    }

    @Test fun mpvImageSequenceDecodesEachDpxFrameInOrder() = session { player, activity ->
        val directory = File(fixture("codecs-still-00.dpx")).parentFile!!
        fixture("codecs-still-01.dpx")
        fixture("codecs-still-02.dpx")
        player.setProperty("options/mf-fps", "1")
        player.load("mf://$directory/codecs-still-%02d.dpx", autoPlay = false)
        await("mpv image sequence presents its first frame", details = { player.state.value }) {
            player.state.value.let { it.error != null || it.hasVideoFrame }
        }
        assertNull(player.state.value.error)
        assertContainer("image sequence", "mf", player.state.value)
        assertEquals("dpx", player.state.value.videoTracks.single { it.isSelected }.codec)
        awaitPrimaryColor(activity, "image 0", 0)

        for (index in 1..2) {
            player.stepForward()
            await("mpv image sequence advances to $index", timeout = 5000, details = { player.state.value }) {
                abs(player.state.value.position - index) < 0.1
            }
            awaitPrimaryColor(activity, "image $index", index)
        }
    }

    private fun awaitPrimaryColor(activity: ActivityScenario<PlaybackTestActivity>, name: String, channel: Int) {
        await("$name presents the expected color", timeout = 5000) {
            isPrimaryColor(renderedPixels(activity, name)[45 * 160 + 80], channel)
        }
    }

    private fun isPrimaryColor(pixel: Int, channel: Int): Boolean {
        val rgb = listOf(pixel shr 16 and 0xff, pixel shr 8 and 0xff, pixel and 0xff)
        return rgb[channel] > 180 && rgb.withIndex().all { it.index == channel || it.value < 70 }
    }

    private fun awaitGrayLevel(activity: ActivityScenario<PlaybackTestActivity>, name: String, level: Int) {
        var rgb = listOf(0, 0, 0)
        await("$name presents gray level $level", timeout = 5000, details = { rgb }) {
            val pixel = renderedPixels(activity, name)[45 * 160 + 80]
            rgb = listOf(pixel shr 16 and 0xff, pixel shr 8 and 0xff, pixel and 0xff)
            rgb.all { abs(it - level) < 12 } && rgb.max() - rgb.min() < 5
        }
    }

    @Test fun timedTextDisplaysAndClearsCuesAfterSeeking() = session { player, _ ->
        val name = "codecs-mov-text.mp4"
        player.setTextSubtitleInterceptionEnabled(true)
        player.load(fixture(name), autoPlay = false)
        await("$name exposes its subtitle track", details = { player.state.value }) {
            player.state.value.hasVideoFrame && player.state.value.subtitleTracks.isNotEmpty()
        }
        val subtitle = player.state.value.subtitleTracks.single()
        assertEquals("mov_text", subtitle.codec)
        assertContainer(name, "mov", player.state.value)
        player.selectSubtitle(subtitle.id)
        assertTimedTextCues(player, "mov_text")

        player.loadExternalSubtitle(Uri.fromFile(File(fixture("codecs-cues.vtt"))))
        await("WebVTT track is selected", details = { player.state.value }) { player.selectedSubtitle()?.codec == "webvtt" }
        assertTimedTextCues(player, "webvtt")
        assertNull(player.state.value.error)
    }

    @Test fun matroskaAsciiSubtitlesPreserveCueTextAndClearTimes() =
        session(mapOf("demuxer" to "lavf", "demuxer-lavf-format" to "matroska", "sid" to "1", "sub-auto" to "no")) { player, _ ->
            val name = "subtitles-ascii.mkv"
            player.setTextSubtitleInterceptionEnabled(true)
            player.load(fixture(name), autoPlay = false)
            await("$name opens with a raw text track", details = { player.state.value }) {
                player.state.value.let { it.error != null || (it.hasVideoFrame && it.selectedSubtitle() != null) }
            }
            assertNull(name, player.state.value.error)
            assertContainer(name, "matroska", player.state.value)
            assertEquals(name, "text", player.state.value.selectedSubtitle()?.codec)
            assertTimedTextCues(player, "text")
        }

    @Test fun nutTextSubtitlesPreserveTheAuthoredText() {
        val name = "subtitles-text.nut"
        val cues = listOf(1.0..2.5 to "First cue", 2.5..4.0 to "Second cue", 4.0..5.5 to "Third cue")
        session(mapOf("sid" to "1", "sub-auto" to "no", "sub-stretch-durations" to "yes")) { player, _ ->
            player.setTextSubtitleInterceptionEnabled(true)
            player.load(fixture(name), autoPlay = false)
            await("$name exposes its selected subtitle track", details = { player.state.value }) {
                player.state.value.let { it.error != null || (it.hasVideoFrame && it.selectedSubtitle() != null) }
            }
            assertNull(name, player.state.value.error)
            assertContainer(name, "nut", player.state.value)
            assertEquals(name, "text", player.state.value.selectedSubtitle()?.codec)
            player.play()
            for ((window, cue) in cues) {
                await("$name displays $cue in $window", timeout = 4000, details = { player.state.value }) {
                    val state = player.state.value
                    state.position in window && state.subtitles.regions.joinToString("\n") { it.text } == cue
                }
            }
            player.selectSubtitle(null)
            await("$name clears text on deselection") { player.state.value.subtitles.regions.isEmpty() }
        }
    }

    @Ignore("Deferred NUT rendering coverage. The reader supplies ASS cue timestamps without durations.")
    @Test fun nutAssSubtitlesCompositeAndClear() =
        session(mapOf("sid" to "1", "sub-auto" to "no", "osd-level" to "0", "sub-stretch-durations" to "yes")) { player, activity ->
            val name = "subtitles-ass.nut"
            player.load(fixture(name))
            await("$name opens with the styled ASS track", details = { player.state.value }) {
                player.state.value.let { it.error != null || (it.hasVideoFrame && it.selectedSubtitle()?.codec == "ass") }
            }
            assertNull(name, player.state.value.error)
            assertContainer(name, "nut", player.state.value)
            await("$name composites its white subtitle glyphs") {
                player.state.value.position in 0.2..4.0 && brightSubtitlePixels(activity, name) > 4
            }
            player.selectSubtitle(null)
            await("$name clears rendered text on deselection") { brightSubtitlePixels(activity, name) == 0 }
        }

    @Test fun externalMpl2SubtitlesFollowTheEncodedTimeline() = session { player, _ ->
        player.setTextSubtitleInterceptionEnabled(true)
        player.load(fixture("baseline.mp4"), autoPlay = false)
        await("baseline opens before adding an external subtitle") { player.state.value.hasVideoFrame }
        player.loadExternalSubtitle(Uri.fromFile(File(fixture("subtitles-cues.mpl2"))))
        await("MPL2 reader exposes the selected external track", details = { player.state.value }) {
            player.selectedSubtitle()?.let { it.codec == "mpl2" && it.isExternal } == true
        }
        assertTimedTextCues(player, "mpl2")
        assertNull(player.state.value.error)
    }

    @Test fun cea608CuesAppearAndClearInMpegTsAndQuickTime() {
        for ((name, format) in listOf("codecs-cea608.ts" to "mpegts", "codecs-cea608.mov" to "mov")) {
            val options = mapOf(
                "vd" to "h264,-", "sid" to "1", "sub-auto" to "no",
                "sub-create-cc-track" to if (format == "mpegts") "yes" else "no",
            )
            session(options) { player, activity ->
                player.setTextSubtitleInterceptionEnabled(true)
                player.load(fixture(name), autoPlay = false)
                await("$name exposes the caption track", details = { player.state.value }) {
                    player.state.value.let { it.error != null || (it.hasVideoFrame && player.selectedSubtitle()?.codec == "eia_608") }
                }
                assertNull(player.state.value.error)
                assertContainer(name, format, player.state.value)
                assertTrue(player.state.value.subtitles.regions.isEmpty())

                val cues = listOf(Triple(1.268, 2.336, "FIRST CAPTION"), Triple(3.270, 4.338, "SECOND CAPTION"))
                for (replay in listOf(false, true)) {
                    val pass = if (replay) "replay after rewind" else "initial playback"
                    if (replay) {
                        player.pause()
                        player.seekTo(0.0)
                        await("$name rewinds with no retained caption", details = { player.state.value }) {
                            val state = player.state.value
                            state.state == PlaybackState.PAUSED && state.position < 0.05 && state.subtitles.regions.isEmpty()
                        }
                    }

                    player.play()
                    for ((start, stop, label) in cues) {
                        await("$name $label appears once during $pass", timeout = 5000, details = { player.state.value }) {
                            val state = player.state.value
                            state.position in (start - 0.1)..(start + 0.4) &&
                                state.subtitles.regions.joinToString("\n") { it.text }.trim() == label
                        }
                        await("$name $label clears at its encoded time during $pass", timeout = 5000, details = { player.state.value }) {
                            val state = player.state.value
                            state.position in (stop - 0.1)..(stop + 0.4) && state.subtitles.regions.isEmpty()
                        }
                    }
                }

                player.pause()
                player.setTextSubtitleInterceptionEnabled(false)
                player.seekTo(0.0)
                await("$name is ready to replay the captions", details = { player.state.value }) {
                    val state = player.state.value
                    state.state == PlaybackState.PAUSED && !state.interceptsTextSubtitles && state.position < 0.05
                }
                assertEquals("$name has no retained glyphs after seeking", 0, brightSubtitlePixels(activity, name))
                player.play()
                for ((index, cue) in cues.withIndex()) {
                    val (start, stop, label) = cue
                    await("$name replays $label in its authored half", timeout = 5000, details = { player.state.value }) {
                        val time = player.state.value.position
                        if (time !in start..(start + 0.6)) {
                            false
                        } else {
                            val (above, below) = renderedPixels(activity, name).withIndex()
                                .filter { (_, pixel) -> isBrightSubtitlePixel(pixel) }
                                .partition { (offset, _) -> offset / 160 < 45 }
                            if (index == 0) below.isNotEmpty() && above.isEmpty()
                            else above.isNotEmpty() && below.isEmpty()
                        }
                    }
                    await("$name clears replayed $label", timeout = 5000, details = { player.state.value }) {
                        player.state.value.position in (stop - 0.1)..(stop + 0.4) && brightSubtitlePixels(activity, name) == 0
                    }
                }
                assertNull(player.state.value.error)
            }
        }
    }

    @Test fun mxfAncillaryCaptionsRetainTheAuthoredCueTimes() {
        val name = "codecs-cea608.mxf"
        val options = mapOf(
            "vd" to "mpeg2video,-", "sid" to "1", "sub-auto" to "no",
            "demuxer-lavf-o" to "eia608_extract=1",
        )
        session(options) { player, _ ->
            player.setTextSubtitleInterceptionEnabled(true)
            player.load(fixture(name), autoPlay = false)
            await("$name exposes the extracted CEA-608 track", details = { player.state.value }) {
                player.state.value.hasVideoFrame && player.selectedSubtitle()?.codec == "eia_608"
            }
            assertContainer(name, "mxf", player.state.value)
            assertTrue(player.state.value.subtitles.regions.isEmpty())
            player.play()
            for ((start, end, text) in listOf(Triple(1.268, 2.336, "FIRST CAPTION"), Triple(3.270, 4.338, "SECOND CAPTION"))) {
                await("$name presents $text at its authored frame", details = { player.state.value }) {
                    val state = player.state.value
                    state.position in (start - 0.1)..(start + 0.35) && state.subtitles.regions.singleOrNull()?.text?.trim() == text
                }
                await("$name clears $text at its authored frame", details = { player.state.value }) {
                    val state = player.state.value
                    state.position in (end - 0.1)..(end + 0.35) && state.subtitles.regions.isEmpty()
                }
            }
            assertNull(player.state.value.error)
        }
    }

    private fun assertTimedTextCues(player: MPVPlayer, codec: String) {
        val plain = listOf(1.25 to "First cue", 2.25 to "", 2.75 to "Second cue")
        val cues = when (codec) {
            "webvtt" -> listOf(1.25 to "WebVTT first cue", 2.25 to "", 2.75 to "WebVTT second cue")
            "mpl2" -> plain + listOf(4.25 to "Third cue", 5.25 to "")
            else -> plain
        }
        for ((time, cue) in cues) {
            player.seekTo(time)
            await("$codec cue at $time", details = { player.state.value }) {
                val state = player.state.value
                abs(state.position - time) < 0.1 && state.subtitles.regions.joinToString("\n") { it.text } == cue
            }
        }
    }

    @Test fun embeddedWebVttFollowsPrimaryAndSecondarySelectionAfterSeeking() = session { player, _ ->
        player.setTextSubtitleInterceptionEnabled(true)
        val readers = listOf(
            Triple("mkv", "mkv", "webvtt-webm"),
            Triple("lavf", "matroska", "webvtt"),
        )
        val inputs = listOf("codecs-webvtt.webm", "codecs-webvtt.mkv")
        val rtlCue = "כתוביות בעברית"
        val placements = mapOf(
            "WebVTT first cue" to WebVTTPlacement(
                horizontalPosition = .25f, verticalPosition = .8f,
                horizontalAnchor = WebVTTPlacement.HorizontalAnchor.LEFT,
                verticalAnchor = WebVTTPlacement.VerticalAnchor.BOTTOM,
                maximumWidth = .4f, textAlignment = WebVTTPlacement.TextAlignment.LEFT,
            ),
            rtlCue to WebVTTPlacement(
                horizontalPosition = .75f, verticalPosition = .2f,
                horizontalAnchor = WebVTTPlacement.HorizontalAnchor.RIGHT,
                verticalAnchor = WebVTTPlacement.VerticalAnchor.TOP,
                maximumWidth = .3f, textAlignment = WebVTTPlacement.TextAlignment.RIGHT,
            ),
        )
        val defaultPlacement = WebVTTPlacement(horizontalPosition = .5f, verticalPosition = .96f)
        for ((name, reader) in inputs.flatMap { file -> readers.map { file to it } }) {
            val (demuxer, format, codec) = reader
            player.setProperty("options/demuxer", demuxer)
            player.load(fixture(name), autoPlay = false)
            await("$demuxer exposes both WebVTT tracks", details = { player.state.value }) {
                player.state.value.let { it.error != null || (it.hasVideoFrame && it.subtitleTracks.size == 2) }
            }
            val state = player.state.value
            assertNull(demuxer, state.error)
            assertContainer(name, format, state)
            val tracks = state.subtitleTracks.sortedBy { it.id.mpvId }
            assertEquals(demuxer, listOf(codec, codec), tracks.map { it.codec })
            val (text, captions) = tracks
            player.selectSubtitle(text.id)
            player.selectSubtitle(captions.id, SubtitleRole.SECONDARY)

            fun checkCues(time: Double?, primary: String, secondary: String) {
                time?.let(player::seekTo)
                await("$demuxer shows primary and secondary cues at $time", details = { player.state.value }) {
                    val snapshot = player.state.value
                    val regions = snapshot.subtitles.regions
                    (time == null || abs(snapshot.position - time) < 0.1) &&
                        regions.filter { it.role == SubtitleRole.PRIMARY }.joinToString("\n") { it.text } == primary &&
                        regions.filter { it.role == SubtitleRole.SECONDARY }.joinToString("\n") { it.text } == secondary &&
                        regions.all { it.placement == TextSubtitlePlacement.WebVTT(placements[it.text] ?: defaultPlacement) }
                }
            }

            checkCues(1.25, "WebVTT first cue", rtlCue)
            checkCues(2.25, "", "")
            checkCues(2.75, "WebVTT second cue", "Captions second cue")
            player.selectSubtitle(null)
            player.selectSubtitle(text.id, SubtitleRole.SECONDARY)
            player.selectSubtitle(captions.id)
            checkCues(1.25, rtlCue, "WebVTT first cue")
            player.selectSubtitle(null, SubtitleRole.SECONDARY)
            checkCues(null, rtlCue, "")
            player.selectSubtitle(null)
            checkCues(null, "", "")
            checkCues(2.75, "", "")
            player.selectSubtitle(text.id)
            player.selectSubtitle(captions.id, SubtitleRole.SECONDARY)
            checkCues(2.75, "WebVTT second cue", "Captions second cue")
            checkCues(3.75, "", "")
            checkCues(1.25, "WebVTT first cue", rtlCue)
            player.stop()
            await("stop $demuxer") { player.state.value.state == PlaybackState.STOPPED }
        }
    }

    @Test fun flvMetadataCaptionsFollowTheAuthoredTimeline() {
        val name = "codecs-flv-captions.flv"
        for (reader in listOf("flv", "live_flv")) {
            session(mapOf("vd" to "flv,-", "demuxer-lavf-format" to reader, "sub-stretch-durations" to "yes")) { player, activity ->
                player.setTextSubtitleInterceptionEnabled(true)
                player.load(fixture(name), autoPlay = false)
                await("$reader exposes the embedded text track", details = { player.state.value }) {
                    player.state.value.hasVideoFrame && player.state.value.subtitleTracks.any { it.codec == "text" }
                }
                assertContainer(name, reader, player.state.value)
                awaitPrimaryColor(activity, reader, 0)
                val text = player.state.value.subtitleTracks.single { it.codec == "text" }
                assertFalse(text.isExternal)
                player.selectSubtitle(text.id)
                assertTrue(player.state.value.subtitles.regions.isEmpty())
                player.play()
                for ((time, expected) in listOf(.4 to "First FLV cue", 1.4 to "Second FLV cue")) {
                    await("$reader presents $expected at ${time}s", timeout = 4000, details = { player.state.value }) {
                        val state = player.state.value
                        state.position in time..(time + .4) && state.subtitles.regions.singleOrNull()?.text == expected
                    }
                }
                player.selectSubtitle(null)
                await("$reader clears the cue on deselection") { player.state.value.subtitles.regions.isEmpty() }
                assertNull(player.state.value.error)
            }
        }
    }

    @Test fun bilingualSrtSidecarsSwitchSubtitleRolesAndClearWhenDeselected() = session(mapOf("sub-auto" to "no")) { player, _ ->
        player.setTextSubtitleInterceptionEnabled(true)
        player.load(fixture("baseline.mp4"), autoPlay = false)
        await("baseline presents its opening frame") { player.state.value.hasVideoFrame }

        player.loadExternalTrack(Uri.fromFile(File(fixture("baseline.en.srt"))), TrackType.SUBTITLE, select = false)
        await("the English sidecar loads") { player.state.value.subtitleTracks.size == 1 }
        val english = player.state.value.subtitleTracks.single().id
        player.loadExternalTrack(Uri.fromFile(File(fixture("baseline.es.srt"))), TrackType.SUBTITLE, select = false)
        await("the Spanish sidecar loads") { player.state.value.subtitleTracks.size == 2 }
        val tracks = player.state.value.subtitleTracks
        val spanish = tracks.single { it.id != english }.id
        assertTrue(tracks.all { it.isExternal && it.codec == "subrip" })

        fun expectCues(time: Double, primary: String, secondary: String) {
            player.seekTo(time)
            await("primary and secondary SRT text at ${time}s", details = { player.state.value.subtitles }) {
                val snapshot = player.state.value
                val regions = snapshot.subtitles.regions
                abs(snapshot.position - time) < .1 &&
                    regions.filter { it.role == SubtitleRole.PRIMARY }.joinToString("\n") { it.text } == primary &&
                    regions.filter { it.role == SubtitleRole.SECONDARY }.joinToString("\n") { it.text } == secondary
            }
        }

        player.selectSubtitle(english)
        player.selectSubtitle(spanish, SubtitleRole.SECONDARY)
        expectCues(1.0, "Welcome to the subtitle demo.", "Bienvenidos a la demostración de subtítulos.")
        expectCues(5.0, "Two languages can appear at the same time.", "Dos idiomas pueden aparecer al mismo tiempo.")
        player.selectSubtitle(null)
        player.selectSubtitle(english, SubtitleRole.SECONDARY)
        player.selectSubtitle(spanish)
        expectCues(9.0, "Elige cada idioma en el menú de pistas.", "Choose each language in the Tracks menu.")
        player.selectSubtitle(null)
        player.selectSubtitle(null, SubtitleRole.SECONDARY)
        expectCues(1.0, "", "")
    }

    @Test fun externalWebVttQueriesPreserveOverlappingRegionsAndTheirPlacement() =
        session(mapOf("sub-auto" to "no")) { player, _ ->
            val sidecar = File.createTempFile("positioned-cues-", ".vtt", instrumentation.targetContext.cacheDir)
            try {
                sidecar.writeText(
                    """
                    WEBVTT

                    00:01.000 --> 00:02.000 position:25%,line-left line:80% size:40%
                    positioned

                    00:01.500 --> 00:02.500
                    default

                    00:03.000 --> 00:04.000
                    last cue

                    """.trimIndent(),
                )
                player.load(fixture("baseline.mp4"), autoPlay = false)
                await("baseline presents its opening frame") { player.state.value.hasVideoFrame }
                player.setTextSubtitleInterceptionEnabled(true)
                player.loadExternalSubtitle(Uri.fromFile(sidecar), role = null)
                await("external WebVTT is exposed") { player.state.value.subtitleTracks.size == 1 }
                val track = player.state.value.subtitleTracks.single()
                assertEquals("webvtt", track.codec)
                assertTrue(track.isExternal)
                assertFalse(track.isSelected)
                val originalPosition = player.state.value.position

                fun query(time: Double): TextSubtitleSnapshot = runBlocking {
                    withTimeout(5000) { player.textSubtitleSnapshot(track.id, at = time) }
                }

                val overlap = query(1.75).regions
                assertEquals(listOf("positioned", "default"), overlap.map { it.text })
                val placement = (overlap.first().placement as TextSubtitlePlacement.WebVTT).placement
                assertEquals(0.25f, placement.horizontalPosition, .001f)
                assertEquals(0.8f, placement.verticalPosition, .001f)
                assertEquals(0.4f, placement.maximumWidth ?: 0f, .001f)
                assertEquals(listOf("default"), query(2.0).regions.map { it.text })
                assertTrue(query(2.5).regions.isEmpty())
                assertEquals(listOf("last cue"), query(3.25).regions.map { it.text })
                assertEquals(originalPosition, player.state.value.position, .001)
                assertNull(player.selectedSubtitle())

                player.selectSubtitle(track.id)
                for ((time, expected) in listOf(1.75 to listOf("positioned", "default"), 2.75 to emptyList())) {
                    player.seekTo(time)
                    await("WebVTT snapshot at ${time}s", details = { player.state.value.subtitles }) {
                        val snapshot = player.state.value
                        abs(snapshot.position - time) < .1 && snapshot.subtitles.regions.map { it.text } == expected
                    }
                }
                assertNull(player.state.value.error)
            } finally {
                sidecar.delete()
            }
        }

    @Test fun localTextSidecarsPreserveCuesAndClearTimes() {
        val catalog = instrumentation.context.assets.open("text-subtitles.json").bufferedReader().use { JSONObject(it.readText()) }
        val sidecars = catalog.getJSONArray("cases")
        val cues = listOf(1.25 to catalog.getString("first"), 3.25 to catalog.getString("second"), 2.25 to "", 4.25 to "")
        val failures = mutableListOf<Throwable>()
        for (index in 0 until sidecars.length()) {
            val sidecar = sidecars.getJSONObject(index)
            val name = sidecar.getString("file")
            val codec = sidecar.getString("codec")
            val video = fixture(sidecar.optString("video", "baseline.mp4"))
            val offset = sidecar.optDouble("timeOffset", 0.0)
            if (codec == "ass") continue
            try {
                session(mapOf("sub-auto" to "no", "sub-files" to fixture(name))) { player, _ ->
                    player.setTextSubtitleInterceptionEnabled(true)
                    player.load(video, autoPlay = false, startTime = cues.first().first + offset)
                    await("$name selects $codec", timeout = 5000, details = { player.state.value }) {
                        player.state.value.hasVideoFrame && player.selectedSubtitle()?.let { it.isExternal && it.codec == codec } == true
                    }
                    for ((index, cue) in cues.withIndex()) {
                        val (cueTime, text) = cue
                        val time = cueTime + offset
                        if (index > 0) player.seekTo(time)
                        await("$name cue at $time s", timeout = 5000, details = { player.state.value.subtitles }) {
                            val state = player.state.value
                            abs(state.position - time) < .1 && state.subtitles.regions.joinToString("\n") { it.text }.trim() == text
                        }
                    }
                }
            } catch (error: AssertionError) {
                failures.add(error)
            }
        }
        MultipleFailureException.assertEmpty(failures)
    }

    @Test fun nativeAssSidecarCompositesBothTimedCues() =
        expectNativeAssCues(File(fixture("text-subtitles-ass.ass")))

    @Test fun nativeAssSidecarFallsBackWhenItsFontIsMissing() {
        val original = File(fixture("text-subtitles-ass.ass")).readText()
        val fallback = File.createTempFile("missing-ass-font-", ".ass", instrumentation.targetContext.cacheDir)
        try {
            val missingFontStyle = original.replace("Style: Default,Arial,", "Style: Default,MPVUI Test Missing Font 3F19,")
            assertNotEquals(original, missingFontStyle)
            fallback.writeText(missingFontStyle)
            expectNativeAssCues(fallback)
        } finally {
            fallback.delete()
        }
    }

    private fun expectNativeAssCues(sidecar: File) = session(mapOf("sid" to "no", "sub-auto" to "no", "osd-level" to "0")) { player, activity ->
        val name = sidecar.name
        player.load(fixture("subtitles.mkv"), autoPlay = false, startTime = 0.5)
        await("video frame without subtitles") { player.state.value.hasVideoFrame && player.selectedSubtitle() == null }
        player.command("sub-add", sidecar.absolutePath, "select")
        await("ASS becomes the selected external track", details = { player.state.value.subtitleTracks }) {
            player.selectedSubtitle()?.let { it.codec == "ass" && it.isExternal } == true
        }
        for ((time, top) in listOf(1.25 to false, 3.25 to true, 2.25 to null, 4.25 to null)) {
            player.seekTo(time)
            await("native ASS frame at $time", timeout = 5000, details = { player.state.value }) {
                if (abs(player.state.value.position - time) > .1) return@await false
                val pixels = renderedPixels(activity, name)
                val above = (0 until 45 * 160).count { isBrightSubtitlePixel(pixels[it]) }
                val below = (45 * 160 until pixels.size).count { isBrightSubtitlePixel(pixels[it]) }
                when (top) {
                    true -> above > 4 && below == 0
                    false -> above == 0 && below > 4
                    null -> above == 0 && below == 0
                }
            }
        }
        assertNull(player.state.value.error)
    }

    @Test fun scenaristSidecarDisplaysAndClearsBothCaptions() = expectCea608Sidecar("codecs-cea608.scenarist")

    @Test fun macCaptionSidecarDisplaysAndClearsBothCaptions() = expectCea608Sidecar("codecs-cea608.mcc")

    @Test fun rawCaptionSidecarDisplaysAndClearsBothCaptions() = expectCea608Sidecar("codecs-cea608.rcwt")

    private fun expectCea608Sidecar(name: String) = session(mapOf("sid" to "no", "sub-auto" to "no")) { player, _ ->
        player.setTextSubtitleInterceptionEnabled(true)
        player.load(fixture("baseline.mp4"), autoPlay = false)
        await("video frame without captions") { player.state.value.hasVideoFrame && player.selectedSubtitle() == null }
        player.command("sub-add", fixture(name), "select")
        await("$name opens the authored caption track", details = { player.state.value.subtitleTracks }) {
            player.selectedSubtitle()?.let { it.isExternal && it.codec == "eia_608" } == true
        }
        player.play()
        for ((time, text) in listOf(1.264 to "FIRST CAPTION", 2.330 to "", 3.264 to "SECOND CAPTION", 4.330 to "")) {
            await("$name cue transitions near $time seconds", timeout = 5000, details = { player.state.value }) {
                val state = player.state.value
                state.position in (time - 0.05)..(time + 0.4) &&
                    state.subtitles.regions.joinToString("\n") { it.text }.trim() == text
            }
        }
        assertNull(player.state.value.error)
    }

    @Test fun rawPgsSidecarRendersAndClearsItsBitmap() = session(mapOf("sid" to "no", "sub-auto" to "no")) { player, activity ->
        val name = "subtitles-external.sup"
        player.load(fixture("subtitles.mkv"), autoPlay = false, startTime = 1.0)
        await("video frame without subtitles") { player.state.value.hasVideoFrame && player.selectedSubtitle() == null }
        player.command("sub-add", fixture(name), "select")
        await("raw PGS becomes the selected external track", details = { player.state.value.subtitleTracks }) {
            player.selectedSubtitle()?.let { it.codec == "hdmv_pgs_subtitle" && it.isExternal } == true
        }
        await("PGS sidecar presents its white bitmap", timeout = 5000) { countWhitePixels(activity, name) > 30 }
        player.seekTo(5.0)
        await("PGS clear at 4 seconds removes the bitmap", timeout = 5000) {
            abs(player.state.value.position - 5.0) < .1 && countWhitePixels(activity, name) == 0
        }
        assertNull(player.state.value.error)
    }

    @Test fun rawDvbSidecarProbesAndCompositesItsDisplaySet() {
        val name = "subtitles-external.dvb"
        val log = File.createTempFile("dvb-", ".log", instrumentation.targetContext.cacheDir)
        try {
            session(mapOf("sid" to "no", "sub-auto" to "no", "log-file" to log.absolutePath)) { player, activity ->
                player.load(fixture("subtitles.mkv"), autoPlay = false)
                await("video frame without subtitles") { player.state.value.hasVideoFrame && player.selectedSubtitle() == null }
                assertEquals(name, 0, countWhitePixels(activity, name))
                player.command("sub-add", fixture(name), "select")
                await("raw DVB becomes the selected external track", details = { player.state.value.subtitleTracks }) {
                    player.selectedSubtitle()?.let { it.codec == "dvb_subtitle" && it.isExternal } == true
                }
                player.play()
                await("raw DVB bitmap is composited", timeout = 5000) { countWhitePixels(activity, name) > 30 }
                player.selectSubtitle(null)
                await("deselecting raw DVB clears the bitmap") { countWhitePixels(activity, name) == 0 }
                assertNull(player.state.value.error)
            }
        } catch (failure: AssertionError) {
            throw AssertionError("Raw DVB sidecar playback failed\n" + log.readText().takeLast(6000), failure)
        } finally {
            log.delete()
        }
    }

    @Test fun vobSubIndexReadsItsCompanionBitmapAndClears() = session(mapOf("sid" to "no", "sub-auto" to "no", "osd-level" to "0")) { player, activity ->
        val name = "subtitles-vobsub.idx"
        fixture("subtitles-vobsub.sub")
        player.load(fixture("subtitles.mkv"), autoPlay = false, startTime = 1.0)
        await("video frame without subtitles") { player.state.value.hasVideoFrame && player.selectedSubtitle() == null }
        player.command("sub-add", fixture(name), "select")
        await("VobSub selects an English external bitmap track", details = { player.state.value.subtitleTracks }) {
            player.selectedSubtitle()?.let { it.isExternal && it.codec == "dvd_subtitle" } == true
        }
        await("VobSub displays the companion bitmap") { brightSubtitlePixels(activity, name) > 4 }
        player.seekTo(5.0)
        await("VobSub clears at the encoded stop time") {
            abs(player.state.value.position - 5.0) < 0.1 && brightSubtitlePixels(activity, name) == 0
        }
        assertNull(player.state.value.error)
    }

    @Test fun xsubRendersAndClearsTheBitmapCue() = session { player, activity ->
        val name = "subtitles-xsub.avi"
        player.load(fixture(name), autoPlay = false, startTime = 1.5)
        await("$name exposes the bitmap track", details = { player.state.value }) {
            player.state.value.hasVideoFrame && player.state.value.subtitleTracks.isNotEmpty()
        }
        assertContainer(name, "avi", player.state.value)
        val subtitle = player.state.value.subtitleTracks.single()
        assertEquals("xsub", subtitle.codec)
        player.selectSubtitle(subtitle.id)

        await("XSUB bitmap is visible", timeout = 5000) { countWhitePixels(activity, name) > 30 }
        player.seekTo(5.0)
        await("XSUB bitmap clears", timeout = 5000) { abs(player.state.value.position - 5.0) < 0.1 && countWhitePixels(activity, name) == 0 }
        assertNull(player.state.value.error)
    }

    private fun countWhitePixels(activity: ActivityScenario<PlaybackTestActivity>, name: String): Int =
        renderedPixels(activity, name).count { pixel ->
            (pixel shr 16 and 0xff) > 180 && (pixel shr 8 and 0xff) > 180 && (pixel and 0xff) > 180
        }

    private fun localMediaCatalog(): JSONObject =
        instrumentation.context.assets.open("codecs.json").bufferedReader().use { JSONObject(it.readText()) }

    private fun localMediaCases(kind: String): List<JSONObject> {
        val cases = localMediaCatalog().getJSONArray(kind)
        return List(cases.length()) { index -> cases.getJSONObject(index) }
    }

    private fun referenceMediaCases(kind: String): List<JSONObject> {
        val assets = instrumentation.context.assets
        assumeTrue("Stage local FATE files with MPVUI_REFERENCE_TEST_MEDIA", assets.list("")?.contains("reference-media.json") == true)
        val entries = assets.open("reference-media.json").bufferedReader().use { JSONArray(it.readText()) }
        val cases = (0 until entries.length()).map { entries.getJSONObject(it) }.filter { it.getString("kind") == kind }
        assumeTrue("Stage local $kind reference fixtures", cases.isNotEmpty())
        return cases
    }

    private fun referenceOptions(clip: JSONObject): Map<String, String> {
        val options = clip.getJSONObject("mpvOptions")
        return options.keys().asSequence().associateWith(options::getString)
    }

    private fun assertContainer(name: String, format: String, state: PlaybackSnapshot) {
        assertTrue("$name expected $format, opened as ${state.container}", state.container?.split(',')?.contains(format) == true)
    }

    private fun assertFrame(activity: ActivityScenario<PlaybackTestActivity>, name: String) {
        // The WebP fixture intentionally contains solid primary frames.
        assertTrue("$name is a blank frame", renderedPixels(activity, name).any { (it and 0x00FFFFFF) > 0x00101010 })
    }

    private fun renderedPixels(
        activity: ActivityScenario<PlaybackTestActivity>, name: String, videoAspect: Double? = null,
    ): IntArray {
        val bitmap = Bitmap.createBitmap(160, 90, Bitmap.Config.ARGB_8888)
        val latch = CountDownLatch(1)
        var result = -1
        try {
            activity.onActivity {
                val view = it.video
                val picture = videoAspect?.let { aspect ->
                    val width = minOf(view.width, (view.height * aspect).toInt())
                    val height = minOf(view.height, (view.width / aspect).toInt())
                    val left = (view.width - width) / 2
                    val top = (view.height - height) / 2
                    Rect(left, top, left + width, top + height)
                }
                PixelCopy.request(view, picture, bitmap, { status -> result = status; latch.countDown() }, Handler(Looper.getMainLooper()))
            }
            assertTrue(latch.await(5, TimeUnit.SECONDS))
            assertEquals("$name has no rendered frame", PixelCopy.SUCCESS, result)
            return IntArray(bitmap.width * bitmap.height).also {
                bitmap.getPixels(it, 0, bitmap.width, 0, 0, bitmap.width, bitmap.height)
            }
        } finally {
            bitmap.recycle()
        }
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
        LoopbackMediaServer(mapOf("baseline.mp4" to bytes)).use { server ->
            player.load(server.url("baseline.mp4"))
            await("HTTP stream playback") { player.state.value.position > .2 || player.state.value.error != null }
            assertNull(player.state.value.error)
            player.stop()
        }
    }

    @Test fun inlineHexAndDataSourcesDecodeAndSeekLikeFiles() = session(mapOf("vd" to "h264,-", "cache" to "no")) { player, activity ->
        val bytes = File(fixture("codecs-part-00.mp4")).readBytes()
        val hex = bytes.joinToString("") { "%02x".format(it) }
        val base64 = Base64.getEncoder().encodeToString(bytes)
        for ((scheme, source) in listOf("hex" to "hex://$hex", "data" to "data://video/mp4;base64,$base64")) {
            expectRedMP4ThroughSeek(player, activity, source, scheme)
            player.stop()
            await("stop $scheme playback") { player.state.value.state == PlaybackState.STOPPED }
        }
    }

    @Test fun memorySubtitlePreservesCueTextAndClearTimes() = session(mapOf("sub-auto" to "no")) { player, activity ->
        player.setTextSubtitleInterceptionEnabled(true)
        expectRedMP4ThroughSeek(player, activity, fixture("codecs-part-00.mp4"), "inline subtitle video")
        val srt = "1\n00:00:00,250 --> 00:00:00,750\nInline cue\n"
        player.command("sub-add", "memory://$srt", "select")
        await("inline subtitle cue appears", details = { player.state.value }) {
            player.selectedSubtitle()?.codec == "subrip" && player.state.value.subtitles.regions.singleOrNull()?.text == "Inline cue"
        }
        player.seekTo(0.833333)
        await("inline subtitle cue clears", details = { player.state.value }) {
            player.state.value.position > .75 && player.state.value.subtitles.regions.isEmpty()
        }
    }

    @Test fun descriptorSourcesSupportSeeksAndRespectOwnership() = session(mapOf("vd" to "h264,-", "cache" to "no")) { player, activity ->
        val file = File(fixture("codecs-part-00.mp4"))
        ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY).use { descriptor ->
            val path = "/proc/self/fd/${descriptor.fd}"
            val target = Os.readlink(path)
            expectRedMP4ThroughSeek(player, activity, "fd://${descriptor.fd}", "borrowed descriptor")
            player.stop()
            await("borrowed descriptor playback stops") { player.state.value.state == PlaybackState.STOPPED }
            assertEquals(target, Os.readlink(path))
        }

        val fd = ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY).detachFd()
        val path = "/proc/self/fd/$fd"
        val target = Os.readlink(path)
        fun isOpen() = runCatching { Os.readlink(path) }.getOrNull() == target
        try {
            expectRedMP4ThroughSeek(player, activity, "fdclose://$fd", "owned descriptor")
            player.stop()
            await("mpv closes the owned descriptor") { !isOpen() }
        } finally {
            if (isOpen()) ParcelFileDescriptor.adoptFd(fd).close()
        }
    }

    @Test fun fileUrlAndInputWrappersRetainExactVideoSeeks() {
        val clip = File(fixture("tls-ranges.mp4"))
        for (scheme in listOf("file", "lavf", "ffmpeg", "cache", "async")) {
            val source = when (scheme) {
                "file" -> Uri.fromFile(clip).toString()
                "lavf", "ffmpeg" -> "$scheme://file:${clip.path}"
                else -> "ffmpeg://$scheme:file:${clip.path}"
            }
            expectVideoThroughSeeks(scheme, source, "mov", listOf(2.25 to 2, 0.25 to 0))
        }
    }

    @Test fun mpvUrlResolvesTheNestedHttpVideo() {
        val name = "tls-ranges.mp4"
        LoopbackMediaServer(mapOf(name to fixtureBytes(name))).use { server ->
            val source = "mpv://${Uri.encode(server.url(name))}"
            expectVideoThroughSeeks("mpv URL", source, "mov", listOf(2.25 to 2, 0.25 to 0))
            assertTrue("The nested HTTP resource was requested", server.requested(name))
        }
    }

    @Test fun ipfsGatewaySchemesRequestTheNamedVideoAndSeekByRange() {
        val clip = fixtureBytes("tls-ranges.mp4")
        val name = "fixture/video.mp4"
        for (scheme in listOf("ipfs", "ipns")) {
            val route = "$scheme/$name"
            LoopbackMediaServer(mapOf(route to clip)).use { server ->
                val options = mapOf("stream-lavf-o" to "gateway=${server.url("")}")
                expectVideoThroughSeeks(scheme, "$scheme://$name", "mov", listOf(2.25 to 2, 0.25 to 0), options = options)
                assertTrue("$scheme requests its gateway path", server.requested(route))
                assertTrue("$scheme issues a nonzero byte range", server.requestedNonzeroRange(route))
            }
        }
    }

    @Test fun ftpInputAuthenticatesAndRestartsAtMediaOffsets() {
        LoopbackFtpServer(fixtureBytes("tls-ranges.mp4")).use { server ->
            expectVideoThroughSeeks("FTP", server.url, "mov", listOf(2.25 to 2, 0.25 to 0))
            assertTrue("The FTP reader used a nonzero restart offset", server.restartedAtNonzeroOffset)
        }
    }

    @Test fun cryptoInputDecryptsAndSeeksToAuthoredFrames() {
        val clip = fixture("tls-ranges.mp4.enc")
        val key = "000102030405060708090a0b0c0d0e0f"
        val iv = "101112131415161718191a1b1c1d1e1f"
        val options = mapOf("stream-lavf-o" to "key=$key,iv=$iv")
        expectVideoThroughSeeks("AES-128 CBC", "ffmpeg://crypto:file:$clip", "mov", listOf(2.25 to 2, 0.25 to 0), options = options)
    }

    @Test fun ffmpegSharedCacheRetainsExactVideoSeeks() {
        val clip = fixture("tls-ranges.mp4")
        val cache = kotlin.io.path.createTempDirectory(instrumentation.targetContext.cacheDir.toPath(), "shared-av-io-").toFile()
        try {
            val options = mapOf("stream-lavf-o" to "cache_dir=${cache.path}")
            expectVideoThroughSeeks("shared cache", "ffmpeg://shared:file:$clip", "mov",
                listOf(2.25 to 2, 0.25 to 0), options = options)
            val entries = cache.listFiles().orEmpty()
            assertTrue("The shared reader wrote a populated cache", entries.any { it.extension == "cache" && it.length() > 0 })
            assertTrue("The shared reader wrote its block map", entries.any { it.extension == "spacemap" && it.length() > 0 })
        } finally {
            cache.deleteRecursively()
        }
    }

    @Test fun growingPcmFileDecodesTheAppendedTone() {
        val target = File.createTempFile("growing-", ".pcm", instrumentation.targetContext.cacheDir)
        val sampleRate = 48000
        fun tone(frequency: Int): ByteArray {
            val samples = ByteBuffer.allocate(sampleRate * Short.SIZE_BYTES).order(ByteOrder.LITTLE_ENDIAN)
            for (frame in 0 until sampleRate) {
                samples.putShort((4096 * sin(2 * PI * frequency * frame / sampleRate)).toInt().toShort())
            }
            return samples.array()
        }
        try {
            target.writeBytes(tone(440))
            val options = mapOf(
                "cache" to "no", "demuxer" to "rawaudio", "demuxer-rawaudio-channels" to "mono",
                "demuxer-rawaudio-rate" to sampleRate.toString(), "demuxer-rawaudio-format" to "s16le",
                "ad" to "pcm_s16le,-",
            )
            val bytes = capturePcmBytes(target.name, options, sourceUrl = "appending://${target.path}", duringPlayback = { player ->
                await("The first PCM tone starts playing", timeout = 1500, details = { player.state.value }) {
                    val state = player.state.value
                    state.container == "rawaudio" && state.diagnostics.audioOutput == "pcm"
                }
                target.appendBytes(tone(880))
            }) { state ->
                assertContainer(target.name, "rawaudio", state)
                assertEquals("pcm_s16le", state.audioTracks.single { it.isSelected }.codec)
            }
            val samples = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN).asShortBuffer()
            assertEquals(96000, samples.limit())
            assertMonoTone(target.name, samples, 19200, 440)
            assertMonoTone(target.name, samples, 67200, 880)
        } finally {
            target.delete()
        }
    }

    @Test fun concatenatedInputsSeekAcrossTheClipBoundary() {
        val directory = kotlin.io.path.createTempDirectory(instrumentation.targetContext.cacheDir.toPath(), "media-concat-").toFile()
        try {
            // One part holds the MOV index. The other holds the indexed media.
            val bytes = fixtureBytes("tls-ranges.mp4")
            val middle = bytes.size / 2
            val segments = listOf(bytes.copyOfRange(0, middle), bytes.copyOfRange(middle, bytes.size)).mapIndexed { index, part ->
                val file = File(directory, "part-$index.bin")
                file.writeBytes(part)
                "file:${file.path}"
            }
            val list = File(directory, "parts.txt")
            list.writeText(segments.joinToString(separator = "\n", postfix = "\n"))
            val steps = listOf(2.25 to 2, 0.25 to 0)
            expectVideoThroughSeeks("concat", "ffmpeg://concat:${segments.joinToString("|")}", "mov", steps)
            expectVideoThroughSeeks("concatf", "ffmpeg://concatf:file:${list.path}", "mov", steps)
        } finally {
            directory.deleteRecursively()
        }

        val clips = listOf("codecs-part-00.mp4", "codecs-part-02.mp4").map(::fixture)
        val edl = clips.joinToString(separator = ";", prefix = "edl://") { "%${it.toByteArray(Charsets.UTF_8).size}%$it,0,1" }
        expectVideoThroughSeeks("edl", edl, "edl/mov", listOf(1.25 to 2, 0.25 to 0))
    }

    private fun expectVideoThroughSeeks(
        label: String, source: String, format: String, seeks: List<Pair<Double, Int>>, decoder: String = "h264",
        options: Map<String, String> = emptyMap(),
    ) = session(mapOf("vd" to "$decoder,-", "cache" to "no") + options) { player, activity ->
        player.load(source, autoPlay = false)
        await("$label opens its video", details = { player.state.value }) {
            val state = player.state.value
            state.error != null || (state.hasVideoFrame && state.container != null)
        }
        val state = player.state.value
        assertNull(label, state.error)
        assertContainer(label, format, state)
        assertTrue("$label can seek", state.seekable)
        assertEquals(label, "h264", state.videoTracks.single { it.isSelected }.codec)
        for ((time, color) in seeks) {
            player.seekTo(time)
            await("$label seeks to $time", details = { player.state.value }) {
                abs(player.state.value.position - time) < 0.05
            }
            awaitPrimaryColor(activity, "$label at $time", color)
        }
    }

    @Test fun boundedInputPreservesPcmWithoutDecodingTrailingBytes() {
        val name = "codecs-aac-lc.aac"
        val clip = fixtureBytes(name)
        val start = 32 * 1024
        val end = start + clip.size
        val envelope = File.createTempFile("media-range-", ".bin", instrumentation.targetContext.cacheDir)
        try {
            envelope.outputStream().use { output ->
                output.write(ByteArray(start))
                repeat(2) { output.write(clip) }
            }
            val options = mapOf("ad" to "aac,-")
            val baseline = capturePcmBytes(name, options) { state ->
                assertContainer(name, "aac", state)
                assertEquals("aac", state.audioTracks.single { it.isSelected }.codec)
            }
            val samples = ByteBuffer.wrap(baseline).order(ByteOrder.LITTLE_ENDIAN).asShortBuffer()
            assertEquals("baseline duration", 1.25, samples.limit() / 48000.0, 0.15)
            for (time in listOf(0.05, 0.55, 1.05)) {
                assertMonoTone(name, samples, (time * 48000).toInt(), 440)
            }

            val sources = listOf(
                "absolute slice" to "slice://$start-$end@${envelope.path}",
                "relative slice" to "slice://$start-+${clip.size}@${envelope.path}",
                "subfile" to "ffmpeg://subfile,,start,$start,end,$end,,:file:${envelope.path}",
            )
            for ((label, source) in sources) {
                val bounded = capturePcmBytes(label, options, sourceUrl = source) { state ->
                    assertContainer(label, "aac", state)
                    assertEquals(label, "aac", state.audioTracks.single { it.isSelected }.codec)
                }
                assertArrayEquals("$label decodes exactly one copy of the source", baseline, bounded)
            }
        } finally {
            envelope.delete()
        }
    }

    private fun expectRedMP4ThroughSeek(
        player: MPVPlayer,
        activity: ActivityScenario<PlaybackTestActivity>,
        source: String,
        label: String,
    ) {
        val previous = player.loadGeneration
        player.load(source, autoPlay = false)
        await("$label presents its opening frame", details = { player.state.value }) {
            val state = player.state.value
            state.loadGeneration > previous && (state.error != null || (state.hasVideoFrame && state.container != null))
        }
        val state = player.state.value
        assertNull(state.error)
        assertContainer(label, "mov", state)
        assertTrue("$label can seek", state.seekable)
        assertEquals("h264", state.videoTracks.single { it.isSelected }.codec)
        player.seekTo(0.5)
        await("$label seeks to 0.5 seconds", details = { player.state.value }) { abs(player.state.value.position - .5) < .05 }
        awaitPrimaryColor(activity, label, 0)
    }

    private fun loopbackTLSContext(): SSLContext {
        val password = "loopback-only".toCharArray()
        val identity = KeyStore.getInstance("PKCS12")
        instrumentation.context.assets.open("tls-loopback.p12").use { identity.load(it, password) }
        val keys = KeyManagerFactory.getInstance(KeyManagerFactory.getDefaultAlgorithm())
        keys.init(identity, password)
        return SSLContext.getInstance("TLS").apply { init(keys.keyManagers, null, null) }
    }

    @Test fun httpsPlaybackVerifiesTrustAndCredentialsAndSeeksWithByteRanges() = session(
        mapOf("vd" to "h264,-", "tls-verify" to "yes", "network-timeout" to "4", "cache" to "no", "ytdl" to "no"),
    ) { player, activity ->
        val name = "tls-ranges.mp4"
        val credentials = "fixture:loopback"
        val authorization = "Basic " + Base64.getEncoder().encodeToString(credentials.toByteArray())
        LoopbackMediaServer(
            mapOf(name to File(fixture(name)).readBytes()),
            socketFactory = loopbackTLSContext().serverSocketFactory,
            authorization = authorization,
        ).use { server ->
            fun expectRejected(url: String, cause: String) {
                val previous = player.loadGeneration
                player.load(url)
                await("HTTPS load fails for $cause", timeout = 10000, details = { player.state.value }) {
                    val state = player.state.value
                    state.loadGeneration > previous && state.state == PlaybackState.FAILED
                }
                assertTrue(player.state.value.error is PlayerError.LoadFailed)
            }

            val source = server.url(name, credentials)
            expectRejected(source, "untrusted certificate")
            assertFalse(server.requested(name))

            player.setProperty("options/tls-ca-file", fixture("tls-loopback.pem"))
            expectRejected(source.replace("@127.0.0.1:", "@localhost:"), "certificate hostname mismatch")
            assertFalse(server.requested(name))
            expectRejected(server.url(name, "fixture:wrong"), "invalid credentials")
            assertTrue(server.respondedWithError(401))
            expectRejected(server.url("tls-missing.mp4", credentials), "missing file")
            assertTrue(server.respondedWithError(404))

            player.load(source, autoPlay = false)
            await("verified HTTPS playback presents a frame", details = { player.state.value }) {
                val state = player.state.value
                state.hasVideoFrame && state.container != null
            }
            val state = player.state.value
            assertNull(state.error)
            assertContainer(name, "mov", state)
            assertTrue(state.seekable)
            assertEquals("h264", state.videoTracks.single { it.isSelected }.codec)
            awaitPrimaryColor(activity, "HTTPS opening", 0)
            player.seekTo(2.25)
            awaitPrimaryColor(activity, "HTTPS seek target", 2)
            assertEquals(2.25, player.state.value.position, .1)
            assertTrue(server.requestedNonzeroRange(name))
            player.stop()
        }
    }

    @Test fun httpsFollowsARedirectAndSeeksInTheFinalResource() = session(
        mapOf("vd" to "h264,-", "tls-verify" to "yes", "tls-ca-file" to fixture("tls-loopback.pem"),
            "cache" to "no", "network-timeout" to "4"),
    ) { player, activity ->
        val name = "tls-ranges.mp4"
        val redirect = "tls-redirect.mp4"
        LoopbackMediaServer(
            mapOf(name to fixtureBytes(name)), socketFactory = loopbackTLSContext().serverSocketFactory,
            redirects = mapOf(redirect to name),
        ).use { server ->
            player.load(server.url(redirect), autoPlay = false)
            await("HTTPS redirect presents the first frame", details = { player.state.value }) {
                player.state.value.let { it.error != null || (it.hasVideoFrame && it.container != null) }
            }
            val state = player.state.value
            assertNull(state.error)
            assertContainer(name, "mov", state)
            assertEquals("h264", state.videoTracks.single { it.isSelected }.codec)
            awaitPrimaryColor(activity, "HTTPS redirect opening", 0)
            player.seekTo(2.25)
            awaitPrimaryColor(activity, "HTTPS redirect seek target", 2)
            assertTrue(server.requested(redirect))
            assertTrue(server.requestedNonzeroRange(name))
        }
    }

    @Test fun httpsRedirectChainsRecoverAfterALoopAndInterruptedResponse() = session(
        mapOf("vd" to "h264,-", "tls-verify" to "yes", "tls-ca-file" to fixture("tls-loopback.pem"),
            "cache" to "no", "network-timeout" to "4", "ytdl" to "no",
            "stream-lavf-o" to "reconnect_delay_max=0,reconnect_max_retries=1"),
    ) { player, activity ->
        val name = "tls-ranges.mp4"
        val destination = "tls-chain-final.mp4"
        val interrupted = "tls-interrupted.mp4"
        val entry = "tls-chain-start.mp4"
        val next = "tls-chain-next.mp4"
        val loop = "tls-loop.mp4"
        val loopNext = "tls-loop-next.mp4"
        val bytes = fixtureBytes(name)
        LoopbackMediaServer(
            mapOf(name to bytes, interrupted to bytes, destination to bytes), socketFactory = loopbackTLSContext().serverSocketFactory,
            redirects = mapOf(entry to next, next to destination, loop to loopNext, loopNext to loop),
            cutoffs = mapOf(interrupted to LoopbackMediaServer.ResponseCutoff(24, resume = false)),
        ).use { server ->
            player.load(server.url(name), autoPlay = false)
            await("the original HTTPS resource presents a frame", details = { player.state.value }) {
                player.state.value.let { it.error != null || (it.hasVideoFrame && it.state == PlaybackState.PAUSED) }
            }
            assertNull(player.state.value.error)
            player.seekTo(2.25)
            awaitPrimaryColor(activity, "original HTTPS seek target", 2)

            for (path in listOf(loop, interrupted)) {
                val previous = player.loadGeneration
                player.load(server.url(path))
                await("HTTPS rejects $path", timeout = 10000, details = { player.state.value }) {
                    player.state.value.let { it.loadGeneration > previous && it.state == PlaybackState.FAILED }
                }
                assertTrue(player.state.value.error is PlayerError.LoadFailed)
                assertFalse("Failed HTTPS loads clear the previous video frame", player.state.value.hasVideoFrame)
                assertTrue(server.requested(path))
            }
            assertTrue(server.requested(loopNext))
            assertTrue("HTTPS attempts to resume the truncated response", server.requestedNonzeroRange(interrupted))
            assertFalse(server.respondedWithError(404))

            val previous = player.loadGeneration
            player.load(server.url(entry), autoPlay = false)
            await("the redirected resource presents a frame", details = { player.state.value }) {
                val current = player.state.value
                current.loadGeneration > previous && (current.error != null ||
                    (current.hasVideoFrame && current.state == PlaybackState.PAUSED))
            }
            val state = player.state.value
            assertNull(state.error)
            assertContainer(name, "mov", state)
            assertTrue(state.seekable)
            assertEquals("h264", state.videoTracks.single { it.isSelected }.codec)
            awaitPrimaryColor(activity, "HTTPS recovery opening", 0)
            player.seekTo(1.25)
            awaitPrimaryColor(activity, "HTTPS recovery seek target", 1)
            player.play()
            await("the redirected resource reaches EOF", details = { player.state.value }) {
                player.state.value.let { it.error != null || it.state == PlaybackState.ENDED }
            }
            assertNull(player.state.value.error)
            assertTrue(server.requested(entry))
            assertTrue(server.requested(next))
            assertTrue(server.requestedNonzeroRange(destination))
        }
    }

    @Test fun httpsResumesAPartialVideoResponseAtTheExactByteAndReachesEof() = session(
        mapOf(
            "vd" to "h264,-", "tls-verify" to "yes", "tls-ca-file" to fixture("tls-loopback.pem"),
            "cache" to "no", "network-timeout" to "4", "ytdl" to "no",
            "stream-lavf-o" to "reconnect=1,reconnect_delay_max=0,reconnect_max_retries=2",
        ),
    ) { player, activity ->
        val name = "tls-ranges.mp4"
        val bytes = fixtureBytes(name)
        val cutoff = (4 shl 20) + 900
        assertTrue(bytes.size > cutoff)
        LoopbackMediaServer(
            mapOf(name to bytes), socketFactory = loopbackTLSContext().serverSocketFactory,
            cutoffs = mapOf(name to LoopbackMediaServer.ResponseCutoff(cutoff, resume = true)),
        ).use { server ->
            player.load(server.url(name), autoPlay = false)
            await("the HTTPS item presents its first frame", details = { player.state.value }) {
                player.state.value.let { it.error != null || it.hasVideoFrame && it.state == PlaybackState.PAUSED }
            }
            val state = player.state.value
            assertNull(state.error)
            assertContainer(name, "mov", state)
            assertEquals("h264", state.videoTracks.single { it.isSelected }.codec)
            awaitPrimaryColor(activity, "resumed HTTPS opening", 0)
            player.play()
            awaitPrimaryColor(activity, "resumed HTTPS second color", 1)
            awaitPrimaryColor(activity, "resumed HTTPS final color", 2)
            assertTrue("HTTPS resumed precisely after the truncated body", server.requestedRange(name, startingAt = cutoff))
            await("the resumed HTTPS item reaches EOF", details = { player.state.value }) {
                player.state.value.let { it.error != null || it.state == PlaybackState.ENDED }
            }
            assertNull(player.state.value.error)
            assertEquals("only one item was loaded", state.loadGeneration, player.state.value.loadGeneration)
        }
    }

    @Test fun webDavAliasesPreserveAuthenticatedSeekablePlayback() = session(
        mapOf(
            "vd" to "h264,-", "tls-verify" to "yes", "tls-ca-file" to fixture("tls-loopback.pem"),
            "cache" to "no", "network-timeout" to "4", "ytdl" to "no",
        ),
    ) { player, activity ->
        val name = "tls-ranges.mp4"
        val credentials = "fixture:loopback"
        val authorization = "Basic " + Base64.getEncoder().encodeToString(credentials.toByteArray())
        val resources = mapOf(name to fixtureBytes(name))
        val tls = loopbackTLSContext()
        for (scheme in listOf("dav", "webdav", "davs", "webdavs")) {
            val factory = if (scheme.endsWith("s")) tls.serverSocketFactory else ServerSocketFactory.getDefault()
            LoopbackMediaServer(resources, socketFactory = factory, authorization = authorization).use { server ->
                val source = scheme + "://" + server.url(name, credentials).substringAfter("://")
                player.load(source, autoPlay = false)
                await("$scheme presents its first frame", details = { player.state.value }) {
                    player.state.value.let { it.error != null || (it.hasVideoFrame && it.container != null) }
                }
                val initial = player.state.value
                assertNull(initial.error)
                assertContainer(scheme, "mov", initial)
                assertTrue("$scheme is seekable", initial.seekable)
                awaitPrimaryColor(activity, "$scheme opening", 0)
                player.seekTo(2.25)
                awaitPrimaryColor(activity, "$scheme seek target", 2)
                assertEquals(2.25, player.state.value.position, .1)
                assertTrue("$scheme requested a nonzero byte range", server.requestedNonzeroRange(name))
                player.stop()
                await("stop $scheme") { player.state.value.state == PlaybackState.STOPPED }
            }
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
        tracks.forEach { track ->
            player.selectSubtitle(null); player.seekTo(1.0)
            await("${track.codec} clear previous subtitle") { brightSubtitlePixels(activity, track.codec.orEmpty()) == 0 }
            player.selectSubtitle(track.id); player.seekTo(1.0)
            await("${track.codec} must composite white subtitle pixels") { brightSubtitlePixels(activity, track.codec.orEmpty()) > 4 }
            assertNull(player.state.value.error)
        }
    }

    @Test fun mp4DvdBitmapCuesRenderAndClear() = assertEmbeddedBitmapCue("subtitles-dvd.mp4", "mov", "dvd_subtitle")

    @Test fun wtvDvbSubtitlesRenderAndClear() = session(mapOf("sid" to "1", "sub-auto" to "no", "osd-level" to "0", "speed" to "2")) { player, activity ->
        val name = "subtitles-dvb.wtv"
        player.load(fixture(name), autoPlay = false)
        await("$name opens with the DVB bitmap track", details = { player.state.value }) {
            player.state.value.let { it.error != null || (it.hasVideoFrame && it.selectedSubtitle()?.codec == "dvb_subtitle") }
        }
        assertNull(name, player.state.value.error)
        assertContainer(name, "wtv", player.state.value)
        player.play()
        await("$name displays the authored bitmap", details = { player.state.value }) {
            player.state.value.position in 0.6..2.5 && brightSubtitlePixels(activity, name) > 4
        }
        await("$name clears the authored bitmap", details = { player.state.value }) {
            player.state.value.position in 4.3..4.9 && brightSubtitlePixels(activity, name) == 0
        }
    }

    @Test fun nutBitmapCuesRenderAndClear() {
        for ((name, codec) in listOf("subtitles-dvd.nut" to "dvd_subtitle", "subtitles-dvb.nut" to "dvb_subtitle")) {
            session(mapOf("sid" to "1", "sub-auto" to "no", "osd-level" to "0", "speed" to "2")) { player, activity ->
                player.load(fixture(name), autoPlay = false)
                await("$name opens with its bitmap subtitle", details = { player.state.value }) {
                    player.state.value.let { it.error != null || (it.hasVideoFrame && it.selectedSubtitle()?.codec == codec) }
                }
                assertNull(name, player.state.value.error)
                assertContainer(name, "nut", player.state.value)
                player.play()
                await("$name shows the authored bitmap", timeout = 4000, details = { player.state.value }) {
                    player.state.value.position in 0.5..2.5 && brightSubtitlePixels(activity, name) > 4
                }
                await("$name clears the authored bitmap", timeout = 5000, details = { player.state.value }) {
                    player.state.value.position in 5.0..8.0 && brightSubtitlePixels(activity, name) == 0
                }
            }
        }
    }

    private fun assertEmbeddedBitmapCue(name: String, format: String, codec: String) =
        session(mapOf("sid" to "1", "sub-auto" to "no", "osd-level" to "0")) { player, activity ->
            player.load(fixture(name), autoPlay = false)
            await("$name opens with the $codec bitmap track", details = { player.state.value }) {
                player.state.value.let { it.error != null || (it.hasVideoFrame && it.selectedSubtitle()?.codec == codec) }
            }
            assertNull(name, player.state.value.error)
            assertContainer(name, format, player.state.value)
            for ((time, visible) in listOf(1.0 to true, 5.0 to false, 1.0 to true)) {
                player.seekTo(time)
                await("$name matches the cue visibility at $time seconds", details = { player.state.value }) {
                    if (abs(player.state.value.position - time) >= .15) return@await false
                    val bright = brightSubtitlePixels(activity, name)
                    if (visible) bright > 4 else bright == 0
                }
            }
        }

    @Test fun dvbAndPgsBitmapCuesRenderAndClearInTransportStreams() {
        session(mapOf("sid" to "1", "sub-auto" to "no", "osd-level" to "0", "speed" to "2")) { player, activity ->
            for ((file, codec) in listOf("subtitles-dvb.ts" to "dvb_subtitle", "subtitles-pgs.m2ts" to "hdmv_pgs_subtitle")) {
                player.load(fixture(file), autoPlay = false)
                await("$file opens with the authored bitmap track", details = { player.state.value }) {
                    val state = player.state.value
                    state.error != null || (state.hasVideoFrame && state.selectedSubtitle()?.codec == codec)
                }
                assertNull(file, player.state.value.error)
                assertContainer(file, "mpegts", player.state.value)
                player.play()
                await("$file displays the authored bitmap", timeout = 6000, details = { player.state.value }) {
                    player.state.value.position in 1.0..<3.0 && brightSubtitlePixels(activity, file) > 4
                }
                await("$file clears the authored bitmap", timeout = 6000, details = { player.state.value }) {
                    player.state.value.position >= 5.0 && brightSubtitlePixels(activity, file) == 0
                }
                player.stop()
                await("stop $file") { player.state.value.state == PlaybackState.STOPPED }
            }
        }
    }

    @Test fun matroskaSubtitleCompressionPreservesVisibleCuesAndClearing() {
        for ((demuxer, format) in listOf("mkv" to "mkv", "lavf" to "matroska")) {
            for (file in listOf("subtitles-none.mkv", "subtitles-zlib.mkv")) {
                val source = fixture(file)
                for ((id, codec, clearAt) in listOf(Triple("1", "ass", 11.0), Triple("2", "hdmv_pgs_subtitle", 5.0))) {
                    val cue = "$file $demuxer $codec"
                    // PGS starts with a sparse packet at zero. Select its track
                    // before loading so this case exercises compression without a subtitle preroll seek.
                    session(mapOf("demuxer" to demuxer, "sid" to id, "osd-level" to "0")) { player, activity ->
                        player.load(source, autoPlay = false)
                        await("$cue opens with the intended subtitle", details = { player.state.value }) {
                            val state = player.state.value
                            state.error != null || (state.hasVideoFrame && state.selectedSubtitle()?.codec == codec)
                        }
                        val state = player.state.value
                        assertNull(cue, state.error)
                        assertContainer(cue, format, state)
                        await("$cue appears on the video surface", timeout = 5000) { brightSubtitlePixels(activity, cue) > 4 }

                        player.seekTo(clearAt)
                        await("$cue clears after its authored end") {
                            abs(player.state.value.position - clearAt) < .15 && brightSubtitlePixels(activity, cue) == 0
                        }
                    }
                }
            }
        }
    }

    private fun brightSubtitlePixels(activity: ActivityScenario<PlaybackTestActivity>, name: String): Int =
        renderedPixels(activity, name).count(::isBrightSubtitlePixel)

    private fun isBrightSubtitlePixel(pixel: Int): Boolean =
        (pixel shr 16 and 255) > 200 && (pixel shr 8 and 255) > 200 && (pixel and 255) > 200

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
    @Test fun bitmapSubtitleColorsPreserveChannelOrder() {
        for ((reader, format) in listOf("mkv" to "mkv", "lavf" to "matroska")) {
            session(mapOf("demuxer" to reader, "sid" to "5", "osd-level" to "0")) { player, activity ->
                val name = "subtitles.mkv"
                player.setTextSubtitleInterceptionEnabled(true)
                player.load(fixture(name), autoPlay = false)
                await("$reader colored bitmap frame", details = { player.state.value }) {
                    player.state.value.let { it.error != null || it.hasVideoFrame && it.subtitleTracks.size == 5 }
                }
                assertNull(player.state.value.error)
                assertContainer(name, format, player.state.value)
                val track = requireNotNull(player.state.value.selectedSubtitle())
                assertEquals("Color channel order", track.title)
                assertEquals("hdmv_pgs_subtitle", track.codec)

                fun matchesPalette(visible: Boolean): Boolean {
                    val pixels = renderedPixels(activity, name)
                    val white = pixels.indices.filter { isBrightSubtitlePixel(pixels[it]) }
                    val red = pixels.indices.filter { isPrimaryColor(pixels[it], 0) }
                    val blue = pixels.indices.filter { isPrimaryColor(pixels[it], 2) }
                    if (!visible) return white.isEmpty() && red.isEmpty() && blue.isEmpty()
                    return white.size > 4 && red.size > 4 && blue.size > 4 &&
                        white.map { it % 160 }.average() < red.map { it % 160 }.average() &&
                        red.map { it % 160 }.average() < blue.map { it % 160 }.average()
                }

                player.play()
                for ((window, visible) in listOf(3.75..3.98 to true, 4.03..4.27 to false)) {
                    await("$reader PGS palette at $window seconds", timeout = 7000, details = { player.state.value.position }) {
                        player.state.value.position in window && matchesPalette(visible)
                    }
                }
                player.pause()
                player.seekTo(.25)
                await("$reader palette returns after seeking back") {
                    abs(player.state.value.position - .25) < .1 && matchesPalette(visible = true)
                }
            }
        }
    }
    @Test fun pgsOverlaysPreserveObjectOrderAndBothLevelsOfTransparency() {
        val name = "subtitles-positioned.mkv"
        for ((reader, format) in listOf("mkv" to "mkv", "lavf" to "matroska")) {
            session(mapOf("demuxer" to reader, "sid" to "2", "osd-level" to "0")) { player, activity ->
                player.load(fixture(name), autoPlay = false)
                await("$reader opens the overlapping PGS fixture") { player.state.value.hasVideoFrame }
                assertContainer(name, format, player.state.value)
                assertEquals("hdmv_pgs_subtitle", player.state.value.selectedSubtitle()?.codec)

                fun matchesOverlay(visible: Boolean): Boolean {
                    val pixels = renderedPixels(activity, name, videoAspect = 360.0 / 640)
                    fun sample(x: Int) = pixels[(540 * 90 / 640) * 160 + x * 160 / 360]
                    val background = sample(80)
                    if (!visible) return listOf(125, 175, 205, 230, 255).all { x ->
                        val pixel = sample(x)
                        abs(Color.red(pixel) - Color.red(background)) <= 2 &&
                            abs(Color.green(pixel) - Color.green(background)) <= 2 &&
                            abs(Color.blue(pixel) - Color.blue(background)) <= 2
                    }
                    val white = sample(125)
                    val alpha = sample(230) shr 16 and 255
                    val solid = sample(255)
                    return isBrightSubtitlePixel(white) && isBrightSubtitlePixel(sample(175)) &&
                        isPrimaryColor(sample(205), 0) && isPrimaryColor(solid, 0) &&
                        alpha > (background shr 16 and 255) + 30 && alpha < (solid shr 16 and 255) - 20
                }

                player.play()
                await("$reader draws both overlapping PGS objects") {
                    player.state.value.position in .3..2.8 && matchesOverlay(visible = true)
                }
                await("$reader PGS clear removes both objects") {
                    player.state.value.position in 3.1..4.8 && matchesOverlay(visible = false)
                }
                player.pause()
                player.seekTo(.2)
                await("$reader restores PGS stacking and transparency after seeking") {
                    abs(player.state.value.position - .2) < .1 && matchesOverlay(visible = true)
                }
                assertNull(player.state.value.error)
            }
        }
    }

    @Test fun embeddedAssRetainsAuthoredColorAndPlacementInOverlappingCues() {
        val name = "subtitles-positioned.mkv"
        for ((reader, format) in listOf("mkv" to "mkv", "lavf" to "matroska")) {
            session(mapOf("demuxer" to reader, "sid" to "1", "osd-level" to "0")) { player, activity ->
                player.load(fixture(name), autoPlay = false)
                await("$reader opens the positioned ASS fixture") { player.state.value.hasVideoFrame }
                assertContainer(name, format, player.state.value)
                assertEquals("ass", player.state.value.selectedSubtitle()?.codec)

                fun matchesColors(upper: Boolean, lower: Boolean): Boolean {
                    val pixels = renderedPixels(activity, name, videoAspect = 360.0 / 640)
                    var green = 0
                    var yellow = 0
                    for ((index, pixel) in pixels.withIndex()) {
                        val red = pixel shr 16 and 255
                        if ((pixel shr 8 and 255) <= 175 || (pixel and 255) >= 90) continue
                        val x = index % 160
                        val y = index / 160
                        if (red < 90) {
                            if (x >= 85 || y !in 7..14) return false
                            green++
                        } else if (red > 175) {
                            if (x <= 72 || y !in 73..80) return false
                            yellow++
                        }
                    }
                    return (if (upper) green > 6 else green == 0) && (if (lower) yellow > 6 else yellow == 0)
                }

                for ((time, upper, lower) in listOf(
                    Triple(.85, true, false), Triple(1.9, true, true), Triple(2.9, false, true),
                    Triple(4.0, false, false), Triple(.85, true, false),
                )) {
                    player.seekTo(time)
                    await("$reader ASS colors and authored placement at $time seconds", details = { player.state.value }) {
                        abs(player.state.value.position - time) < .1 && matchesColors(upper, lower)
                    }
                }
                assertNull(player.state.value.error)
            }
        }
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
        assumeTrue("Add the optional Dolby Vision chart, then rerun just test --platform android --suite integration", name in instrumentation.context.assets.list("").orEmpty())
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

    @Test fun dolbyVisionThroughFragmentedHlsMatchesTheDirectMpvControl() = session(mapOf("vd" to "hevc,-")) { player, activity ->
        val seekTimes = listOf(.75, 3.25, 5.75, 8.25)
        fun colorDifference(first: IntArray, second: IntArray): Double {
            var difference = 0
            for (i in first.indices) {
                difference += abs(Color.red(first[i]) - Color.red(second[i]))
                difference += abs(Color.green(first[i]) - Color.green(second[i]))
                difference += abs(Color.blue(first[i]) - Color.blue(second[i]))
            }
            return difference / (first.size * 3.0)
        }

        for ((profile, id) in listOf("p5" to 5, "p81" to 8)) {
            val name = "dolby-vision-$profile-hls"
            fun open(source: String, format: String) {
                val generation = player.loadGeneration
                player.load(source, autoPlay = false)
                await("$name $format starts with its own Dolby Vision frame", details = { player.state.value }) {
                    player.state.value.let { it.loadGeneration > generation && (it.error != null || it.hasVideoFrame && it.paused) }
                }
                val state = player.state.value
                assertNull(name, state.error)
                assertContainer(name, format, state)
                assertEquals("hevc", state.videoTracks.single { it.isSelected }.codec)
                assertEquals(DynamicRange.DOLBY_VISION, state.hdr.source.dynamicRange)
                assertEquals(id, state.dolbyVision.sourceProfile)
                assertEquals("gpu-next", state.diagnostics.videoOutput)
            }

            fun seek(time: Double) {
                player.seekTo(time)
                await("$name exact paused seek to $time", details = { player.state.value.position }) {
                    player.state.value.let { it.paused && abs(it.position - time) < .075 && it.hasVideoFrame }
                }
            }

            open(fixture("$name.mp4"), "mov")
            val expected = seekTimes.map { time ->
                // The edit list trims two pictures that the HLS muxer restores.
                seek(time - 2 * 1001.0 / 24000)
                renderedPixels(activity, name)
            }
            assertTrue("$name has different pictures across its keyframes", expected.zipWithNext().all { (a, b) -> colorDifference(a, b) > 2 })

            val playlist = "$name.m3u8"
            val files = listOf(playlist, "$name-init.mp4") + (0..3).map { "$name-0$it.m4s" }
            LoopbackMediaServer(files.associateWith(::fixtureBytes)).use { server ->
                open(server.url(playlist), "hls")
                for (index in listOf(0, 2, 1, 3, 0, 3)) {
                    seek(seekTimes[index])
                    await("$name HLS matches its direct picture in fragment $index", details = { player.state.value }) {
                        colorDifference(expected[index], renderedPixels(activity, name)) < 2
                    }
                    assertEquals(DynamicRange.DOLBY_VISION, player.state.value.hdr.source.dynamicRange)
                    assertEquals(id, player.state.value.dolbyVision.sourceProfile)
                }
                player.play()
                await("$name HLS advances through EOF", details = { player.state.value }) {
                    player.state.value.let { it.error != null || it.state == PlaybackState.ENDED }
                }
                assertNull(player.state.value.error)
                assertTrue(player.state.value.position > 9.75)
                for (file in files) assertTrue("$name requests $file", server.requested(file))
            }
        }
    }

    @Test fun hdr10AndHlgToneMappingPreservesLumaOrderAfterSeeks() = session(
        mapOf("vd" to "hevc,-", "target-trc" to "srgb", "target-prim" to "bt.709",
            "target-peak" to "100", "tone-mapping" to "bt.2390"),
    ) { player, activity ->
        for ((name, range) in listOf("color-hdr10-luma.mkv" to DynamicRange.HDR10, "color-hlg-luma.mkv" to DynamicRange.HLG)) {
            val generation = player.loadGeneration
            player.load(fixture(name), autoPlay = false, startTime = .5)
            await("$name presents its tone-mapped picture", details = { player.state.value }) {
                val state = player.state.value
                state.loadGeneration > generation && (state.error != null ||
                    state.hasVideoFrame && state.paused && state.hdr.decoded.bitDepth == 10)
            }
            assertNull(player.state.value.error)
            assertContainer(name, "mkv", player.state.value)
            assertEquals(range, player.state.value.hdr.source.dynamicRange)
            assertEquals("gpu-next", player.state.value.diagnostics.videoOutput)

            for ((time, rising) in listOf(.5 to true, 2.25 to false, .5 to true)) {
                player.seekTo(time)
                await("$name shows the authored luma order at $time seconds", details = { player.state.value }) {
                    val state = player.state.value
                    if (!state.paused || abs(state.position - time) > .1) return@await false
                    val pixels = renderedPixels(activity, name)
                    val bars = listOf(20, 60, 100, 140).map { x ->
                        listOf(35, 45, 55).map { y -> pixels[y * 160 + x] }
                    }
                    val neutral = bars.flatten().all { pixel ->
                        abs(Color.red(pixel) - Color.green(pixel)) <= 8 && abs(Color.green(pixel) - Color.blue(pixel)) <= 8
                    }
                    val levels = bars.map { bar -> bar.map(Color::red).average() }
                    val ordered = if (rising) levels else levels.reversed()
                    neutral && ordered.first() < 20 && ordered.last() > 100 &&
                        ordered.zipWithNext().all { (low, high) -> high - low > 6 }
                }
                assertEquals(range, player.state.value.hdr.source.dynamicRange)
            }
        }
    }

    @Test fun hdr10PlusSceneStatisticsFollowSeekOrderAndClearOnSdrReplacement() {
        val context = instrumentation.targetContext
        val log = File.createTempFile("hdr10plus-", ".log", context.cacheDir)
        try {
            session(mapOf("vd" to "hevc,h264,-", "log-file" to log.absolutePath)) { player, activity ->
                val name = "color-hdr10plus-scenes.mkv"
                player.load(fixture(name), autoPlay = false)
                await("HDR10+ HEVC decodes with dynamic metadata", details = { player.state.value }) {
                    val state = player.state.value
                    state.error != null || state.hasVideoFrame && state.hdr.decoded.hasHDR10PlusMetadata == true
                }
                assertNull(player.state.value.error)
                assertContainer(name, "mkv", player.state.value)
                assertEquals("hevc", player.state.value.videoTracks.single { it.isSelected }.codec)
                val keys = listOf("scene-max-r", "scene-max-g", "scene-max-b", "scene-avg")
                val commandText = keys.joinToString(" ") { "\${=video-params/$it}" }
                val scenes = listOf(.5 to listOf(400, 300, 200, 130), 2.5 to listOf(600, 500, 400, 170),
                    1.5 to listOf(900, 700, 500, 280), .5 to listOf(400, 300, 200, 130))
                for ((index, scene) in scenes.withIndex()) {
                    val (time, expected) = scene
                    player.seekTo(time)
                    await("HDR10+ exact paused seek to $time", details = { player.state.value.position }) {
                        player.state.value.let { it.paused && abs(it.position - time) < .08 }
                    }
                    val label = "MPVUITestHDR10Plus-$index "
                    val values = Regex("${Regex.escape(label)}([0-9.]+) ([0-9.]+) ([0-9.]+) ([0-9.]+)")
                    await("HDR10+ scene at $time has $expected", timeout = 5000) {
                        player.command("expand-properties", "print-text", label + commandText)
                        values.findAll(log.readText()).any { match ->
                            match.groupValues.drop(1).zip(expected).all { (level, target) -> abs(level.toDouble() - target) < 1 }
                        }
                    }
                    assertEquals(DynamicRange.HDR10, player.state.value.hdr.source.dynamicRange)
                    assertFrame(activity, name)
                }

                val generation = player.loadGeneration
                player.load(fixture("baseline.mp4"), autoPlay = false)
                await("SDR replacement clears dynamic HDR state", details = { player.state.value }) {
                    val state = player.state.value
                    state.loadGeneration > generation && state.hasVideoFrame && state.hdr.decoded.dynamicRange == DynamicRange.SDR &&
                        state.hdr.decoded.hasHDR10PlusMetadata != true
                }
                assertNull(player.state.value.error)
                assertEquals("h264", player.state.value.videoTracks.single { it.isSelected }.codec)
            }
        } finally {
            log.delete()
        }
    }

    @Test fun profile7AndUntaggedDolbyVisionDecodeAcrossSeekAndClearForSdr() {
        val profiles = listOf(
            "dolby-vision-p7.mp4" to 7,
            "dolby-vision-p5-untagged.mp4" to 5,
            "dolby-vision-p7-untagged.mp4" to 7,
            "dolby-vision-p81-untagged.mp4" to 8,
            "dolby-vision-p84-untagged.mp4" to 8,
        )
        for (policy in DolbyVisionPolicy.entries) {
            session(dolbyVisionPolicy = policy) { player, activity ->
                for ((name, profile) in profiles) {
                    val range = if (name == "dolby-vision-p7-untagged.mp4") DynamicRange.HDR10 else DynamicRange.DOLBY_VISION
                    val generation = player.state.value.loadGeneration
                    player.load(fixture(name), autoPlay = false, startTime = 0.5)
                    await("$name presents the current item as $range", details = { player.state.value }) {
                        val state = player.state.value
                        state.loadGeneration > generation && (state.error != null || state.hasVideoFrame && state.hdr.source.dynamicRange == range)
                    }
                    assertNull(name, player.state.value.error)
                    assertContainer(name, "mov", player.state.value)
                    assertEquals("hevc", player.state.value.videoTracks.single { it.isSelected }.codec)
                    assertEquals("gpu-next", player.state.value.diagnostics.videoOutput)
                    assertFrame(activity, name)

                    player.seekTo(1.25)
                    await("$name seeks with its source range", details = { player.state.value }) {
                        abs(player.state.value.position - 1.25) < .05 && player.state.value.hasVideoFrame
                    }
                    val dolbyVision = player.state.value.dolbyVision
                    assertEquals(name, policy, dolbyVision.requestedPolicy)
                    if (!name.contains("-untagged") || dolbyVision.sourceProfile != null) {
                        assertEquals(name, profile, dolbyVision.sourceProfile)
                    }
                    assertEquals(name, range, player.state.value.hdr.source.dynamicRange)
                    assertNotEquals(name, DolbyVisionStatus.Conversion.CONVERTED, dolbyVision.conversion)
                    assertFrame(activity, "$name after seek")
                }

                val generation = player.state.value.loadGeneration
                player.load(fixture("interlaced-576i-top.mkv"), autoPlay = false)
                await("SDR replacement presents its own frame", details = { player.state.value }) {
                    val state = player.state.value
                    state.loadGeneration > generation && state.hasVideoFrame && state.hdr.decoded.dynamicRange == DynamicRange.SDR
                }
                assertNull(player.state.value.error)
                assertNull(player.state.value.dolbyVision.sourceProfile)
                assertFalse(player.state.value.hdr.source.dolbyVision)
                assertFrame(activity, "SDR after Dolby Vision")
            }
        }
    }

    @Test fun profile7WithAnHlgBaseRemainsUnconvertedInSoftware() {
        val name = "dolby-vision-p7-invalid-base.mp4"
        for (policy in DolbyVisionPolicy.entries) {
            session(mapOf("vd" to "hevc,h264,-"), dolbyVisionPolicy = policy) { player, activity ->
                player.load(fixture(name), autoPlay = false, startTime = .5)
                await("$policy presents the HLG base", details = { player.state.value }) {
                    val state = player.state.value
                    state.error != null || state.hasVideoFrame && state.hdr.decoded.transferFunction == TransferFunction.HLG
                }
                val base = player.state.value
                assertNull(base.error)
                assertContainer(name, "mov", base)
                assertEquals("hevc", base.videoTracks.single { it.isSelected }.codec)
                assertEquals("gpu-next", base.diagnostics.videoOutput)
                assertEquals(policy, base.dolbyVision.requestedPolicy)
                assertNotEquals(DolbyVisionStatus.Conversion.CONVERTED, base.dolbyVision.conversion)
                assertFrame(activity, "$policy HLG base")
                player.seekTo(1.25)
                await("$policy seeks in the unconverted HLG base", details = { player.state.value }) {
                    val state = player.state.value
                    abs(state.position - 1.25) < .08 && state.hdr.decoded.transferFunction == TransferFunction.HLG
                }
                assertNotEquals(DolbyVisionStatus.Conversion.CONVERTED, player.state.value.dolbyVision.conversion)

                player.load(fixture("codecs-hls-00.ts"), autoPlay = false)
                await("$policy replaces the HLG base with SDR", details = { player.state.value }) {
                    val state = player.state.value
                    state.loadGeneration > base.loadGeneration && (state.error != null ||
                        state.hasVideoFrame && state.hdr.decoded.dynamicRange == DynamicRange.SDR)
                }
                assertNull(player.state.value.error)
                assertNull(player.state.value.dolbyVision.sourceProfile)
                awaitPrimaryColor(activity, "$policy SDR replacement", 0)
            }
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
