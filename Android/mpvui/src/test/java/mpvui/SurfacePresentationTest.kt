package mpvui

import org.junit.Assert.*
import org.junit.Test

class SurfacePresentationTest {
    private val configuration = PlayerConfiguration(desiredHDRHeadroom = 2f)
    private val playing = PlaybackSnapshot(
        state = PlaybackState.PLAYING, paused = false, hasVideoFrame = true,
        diagnostics = PlaybackDiagnostics(videoOutput = "mediacodec_embed", containerFramesPerSecond = 24000.0 / 1001),
    )

    @Test fun frameRatePreservesFractionalCadenceAndPlaybackSpeed() {
        assertEquals((24000.0 / 1001).toFloat(), playing.surfacePresentation(configuration).frameRate, .00001f)
        assertEquals((48000.0 / 1001).toFloat(), playing.copy(playbackRate = 2.0).surfacePresentation(configuration).frameRate, .00001f)
        val integerRate = playing.copy(diagnostics = playing.diagnostics.copy(containerFramesPerSecond = 24.0))
        assertEquals(24f, integerRate.surfacePresentation(configuration).frameRate, 0f)
        assertNotEquals(integerRate.surfacePresentation(configuration).frameRate, playing.surfacePresentation(configuration).frameRate)
    }

    @Test fun pauseKeepsNativeHeadroomAndReleasesRefreshAndWakeRequests() {
        val active = playing.surfacePresentation(configuration)
        assertTrue(active.keepScreenOn)
        assertEquals(2f, active.hdrHeadroom, 0f)
        val paused = playing.copy(state = PlaybackState.PAUSED, paused = true).surfacePresentation(configuration)
        assertEquals(SurfacePresentation(hdrHeadroom = 2f), paused)
        assertEquals(active, playing.copy(state = PlaybackState.SEEKING).surfacePresentation(configuration))
    }

    @Test fun terminalAndReplacementStatesReleasePresentationRequests() {
        for (state in listOf(PlaybackState.IDLE, PlaybackState.LOADING, PlaybackState.STOPPED, PlaybackState.FAILED)) {
            assertEquals("$state clears stale frame state", SurfacePresentation(), playing.copy(state = state).surfacePresentation(configuration))
        }
        assertEquals(SurfacePresentation(), playing.copy(hasVideoFrame = false).surfacePresentation(configuration))
        assertEquals(SurfacePresentation(hdrHeadroom = 2f), playing.copy(state = PlaybackState.ENDED).surfacePresentation(configuration))
    }

    @Test fun gpuFallbackRestoresAutomaticHeadroomDespiteHDRSourceMetadata() {
        val gpu = playing.copy(
            hdr = HDRStatus(source = VideoSignal(transferFunction = TransferFunction.PQ)),
            diagnostics = playing.diagnostics.copy(videoOutput = "gpu-next"),
        ).surfacePresentation(configuration)
        assertEquals(0f, gpu.hdrHeadroom, 0f)
        assertTrue(gpu.keepScreenOn)
        assertEquals(playing.surfacePresentation(configuration).frameRate, gpu.frameRate, 0f)
        assertEquals(0f, playing.surfacePresentation(PlayerConfiguration()).hdrHeadroom, 0f)
        assertEquals(0f, playing.surfacePresentation(configuration.copy(hdrPolicy = HDRPolicy.DISABLED)).hdrHeadroom, 0f)
    }

    @Test fun disabledMatchingKeepsWakeAndHeadroomWithoutVotingForAFrameRate() {
        assertEquals(SurfacePresentation(keepScreenOn = true, hdrHeadroom = 2f),
            playing.surfacePresentation(configuration.copy(displayMatching = DisplayMatching.DISABLED)))
    }

    @Test fun unavailableOrInvalidCadenceDoesNotInventARefreshRate() {
        for (fps in listOf(null, 0.0, -24.0, Double.NaN, Double.POSITIVE_INFINITY)) {
            assertEquals(0f, playing.copy(diagnostics = playing.diagnostics.copy(containerFramesPerSecond = fps))
                .surfacePresentation(configuration).frameRate, 0f)
        }
    }

    @Test fun headroomRejectsInvalidRatiosBeforeCreatingAPlayer() {
        for (ratio in listOf(-1f, .5f, 10001f, Float.NaN, Float.POSITIVE_INFINITY)) {
            assertThrows(IllegalArgumentException::class.java) { PlayerConfiguration(desiredHDRHeadroom = ratio) }
        }
        for (ratio in listOf(0f, 1f, 2f, 10000f)) {
            assertEquals(ratio, PlayerConfiguration(desiredHDRHeadroom = ratio).desiredHDRHeadroom, 0f)
        }
    }
}
