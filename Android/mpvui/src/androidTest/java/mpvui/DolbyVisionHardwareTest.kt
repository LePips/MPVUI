package mpvui

import android.graphics.Bitmap
import android.graphics.Rect
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.PixelCopy
import android.view.WindowManager
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/** Opt in with a tagged single-layer Dolby sample (at least 51 seconds) via -e performanceMedia PATH. */
@RunWith(AndroidJUnit4::class)
class DolbyVisionHardwareTest {
    private fun await(message: String, predicate: () -> Boolean) {
        val deadline = SystemClock.elapsedRealtime() + 30_000
        while (!predicate() && SystemClock.elapsedRealtime() < deadline) Thread.sleep(20)
        assertTrue(message, predicate())
    }

    private fun pixels(activity: ActivityScenario<PlaybackTestActivity>): Bitmap {
        val bitmap = Bitmap.createBitmap(320, 180, Bitmap.Config.ARGB_8888)
        val latch = CountDownLatch(1)
        var status = -1
        activity.onActivity {
            val view = it.video
            val width = minOf(view.width, view.height * 16 / 9)
            val height = width * 9 / 16
            val left = (view.width - width) / 2
            val top = (view.height - height) / 2
            PixelCopy.request(view, Rect(left, top, left + width, top + height), bitmap,
                { result -> status = result; latch.countDown() }, Handler(Looper.getMainLooper()))
        }
        assertTrue(latch.await(5, TimeUnit.SECONDS))
        assertEquals(PixelCopy.SUCCESS, status)
        return bitmap
    }

    @Test fun hardwareFramesMatchSoftwareAcrossSeeksAndReplacement() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val source = InstrumentationRegistry.getArguments().getString("performanceMedia")
        assumeTrue("Opt-in Dolby Vision sample", !source.isNullOrBlank())
        val context = instrumentation.targetContext
        val times = listOf(1.0, 12.0, 25.0, 50.0, 3.0, 25.0)
        val references = mutableListOf<Bitmap>()
        try {
            for (decoding in listOf(HardwareDecoding.DISABLED, HardwareDecoding.AUTOMATIC)) {
                val player = MPVPlayer(context, PlayerConfiguration(autoPlay = false, volume = 0.0,
                    audio = AudioConfiguration(AudioConfiguration.AudioSession.HOST_MANAGED), hardwareDecoding = decoding))
                ActivityScenario.launch(PlaybackTestActivity::class.java).use { activity ->
                    activity.onActivity {
                        it.window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                        it.video.player = player
                    }
                    try {
                        times.forEachIndexed { index, time ->
                            if (index == 0 || index == times.lastIndex) player.load(source!!, startTime = time)
                            else player.seekTo(time)
                            await("$decoding seek to $time") {
                                val snapshot = player.state.value
                                val tolerance = snapshot.diagnostics.containerFramesPerSecond?.takeIf { it > 0 }?.let { maxOf(.03, 1.1 / it) } ?: .03
                                snapshot.hasVideoFrame && snapshot.state == PlaybackState.PAUSED &&
                                    kotlin.math.abs(snapshot.position - time) < tolerance
                            }
                            Thread.sleep(300) // PixelCopy must observe the submitted frame.
                            val snapshot = player.state.value
                            assertNull(snapshot.error)
                            assertEquals(DynamicRange.DOLBY_VISION, snapshot.hdr.source.dynamicRange)
                            assertEquals("gpu-next", snapshot.diagnostics.videoOutput)
                            if (decoding == HardwareDecoding.AUTOMATIC) {
                                val expected = InstrumentationRegistry.getArguments().getString("expectedDecoder")
                                if (expected != null) assertEquals(expected, snapshot.diagnostics.hardwareDecoder)
                            }
                            val bitmap = pixels(activity)
                            File(context.getExternalFilesDir(null), "dv-${decoding.name.lowercase()}-$index.png").outputStream().use {
                                bitmap.compress(Bitmap.CompressFormat.PNG, 100, it)
                            }
                            if (decoding == HardwareDecoding.DISABLED) references.add(bitmap)
                            else {
                                try {
                                    var absoluteError = 0L
                                    var largeErrors = 0
                                    for (y in 0 until bitmap.height) for (x in 0 until bitmap.width) {
                                        val reference = references[index].getPixel(x, y)
                                        val actual = bitmap.getPixel(x, y)
                                        for (shift in listOf(0, 8, 16)) {
                                            val error = kotlin.math.abs(((actual shr shift) and 255) - ((reference shr shift) and 255))
                                            absoluteError += error
                                            if (error > 12) largeErrors++
                                        }
                                    }
                                    val channels = bitmap.width * bitmap.height * 3
                                    val mean = absoluteError.toDouble() / channels
                                    android.util.Log.i("MPVUIPerformance", "DV frame $index MAE=$mean largeErrors=${largeErrors.toDouble() / channels}")
                                    assertTrue("$time: hardware pixels differ from software (mean=$mean)", mean < 3.0)
                                    assertTrue("$time: widespread pixel differences", largeErrors < channels * .02)
                                } finally { bitmap.recycle() }
                            }
                        }
                        // A Dolby file must not poison the next ordinary media decoder.
                        val name = "baseline.mp4"
                        val baseline = File(context.cacheDir, name)
                        instrumentation.context.assets.open(name).use { input -> baseline.outputStream().use { input.copyTo(it) } }
                        player.load(baseline.absolutePath, autoPlay = true)
                        await("ordinary media after Dolby") {
                            val snapshot = player.state.value
                            snapshot.hasVideoFrame && !snapshot.paused && snapshot.position > .2 &&
                                snapshot.tracks.any { it.id.type == TrackType.VIDEO && it.codec == "h264" }
                        }
                        assertNull(player.state.value.error)
                    } finally {
                        activity.onActivity { it.video.player = null }
                        player.close()
                    }
                }
            }
        } finally { references.forEach(Bitmap::recycle) }
    }
}
