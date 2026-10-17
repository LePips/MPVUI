package io.github.mpvui.example

import android.content.Intent
import android.os.Bundle
import android.view.accessibility.AccessibilityNodeInfo
import android.graphics.Rect
import android.view.View
import android.view.ViewGroup
import androidx.test.runner.lifecycle.ActivityLifecycleMonitorRegistry
import androidx.test.runner.lifecycle.Stage
import mpvui.MPVPlayerView
import mpvui.MPVPlayer
import mpvui.PlaybackSnapshot
import mpvui.TrackType
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.uiautomator.By
import androidx.test.uiautomator.BySelector
import androidx.test.uiautomator.Configurator
import androidx.test.uiautomator.UiDevice
import androidx.test.uiautomator.UiObject2
import org.junit.Assert.*
import org.junit.After
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.net.ServerSocket
import java.util.concurrent.atomic.AtomicBoolean
import java.util.regex.Pattern
import kotlin.concurrent.thread

/** Exercises the real Swift/Compose screen and verifies native caption views above the video surface. */
@RunWith(AndroidJUnit4::class)
class PlaybackParityTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val device = UiDevice.getInstance(instrumentation)
    private fun await(message: String, timeout: Long = 20000, condition: () -> Boolean) {
        val deadline = System.nanoTime() + timeout * 1_000_000
        while (System.nanoTime() < deadline) {
            instrumentation.uiAutomation.clearCache()
            if (condition()) return
            Thread.sleep(100)
        }
        val dump = File(instrumentation.targetContext.cacheDir, "parity-failure.xml")
        device.dumpWindowHierarchy(dump)
        android.util.Log.e("MPVUIParity", dump.readText())
        android.util.Log.e("MPVUIParity", "Player: ${playerState()}")
        val surface = playerSurface()
        android.util.Log.e("MPVUIParity", "Surface: $surface, valid=${surface?.holder?.surface?.isValid}")
        fail(message)
    }
    private fun find(selector: BySelector): UiObject2 {
        await("Missing control: $selector") { device.hasObject(selector) }
        return device.findObject(selector)
    }
    private fun tap(label: String) {
        await("Missing control: $label") { device.hasObject(By.desc(label)) || device.hasObject(By.text(label)) }
        clickStable(if (device.hasObject(By.desc(label))) By.desc(label) else By.text(label))
    }
    private fun clickStable(selector: BySelector) {
        var previous: Rect? = null
        var stableSince = System.nanoTime()
        await("control settles: $selector") {
            val bounds = device.findObject(selector)?.visibleBounds
            if (bounds != previous) { previous = bounds; stableSince = System.nanoTime() }
            bounds != null && !bounds.isEmpty && System.nanoTime() - stableSince > 350_000_000
        }
        device.findObject(selector).click()
    }
    private fun launch() {
        Configurator.getInstance().waitForIdleTimeout = 0
        device.wakeUp()
        device.setOrientationNatural()
        await("portrait before launching player") { device.displayHeight > device.displayWidth }
        val context = instrumentation.targetContext
        context.startActivity(context.packageManager.getLaunchIntentForPackage(context.packageName)!!.apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)
        })
        find(By.desc("Choose media"))
        await("initial bundled media ready") { playerState()?.hasVideoFrame == true }
        tap("Pause")
    }
    private fun open(url: String) {
        tap("Choose media")
        tap("Open URL…")
        find(By.clazz("android.widget.EditText")).text = url
        tap("Open")
        find(By.desc("Pause"))
        // A seekable timeline means the selected file, rather than the previous media, is ready.
        await("selected media is seekable") { findSlider()?.isEnabled == true }
        tap("Pause")
        find(By.desc("Play"))
    }
    private fun findSlider(node: AccessibilityNodeInfo? = instrumentation.uiAutomation.rootInActiveWindow): AccessibilityNodeInfo? {
        if (node == null) return null
        if (node.rangeInfo != null) return node
        for (index in 0 until node.childCount) findSlider(node.getChild(index))?.let { return it }
        return null
    }
    private fun seek(seconds: Float) {
        await("timeline ready after menu dismissal") { findSlider() != null }
        val args = Bundle().apply { putFloat(AccessibilityNodeInfo.ACTION_ARGUMENT_PROGRESS_VALUE, seconds) }
        assertTrue("TalkBack can seek", findSlider()!!.performAction(AccessibilityNodeInfo.AccessibilityAction.ACTION_SET_PROGRESS.id, args))
    }
    private fun accessibilityNode(label: String, root: AccessibilityNodeInfo? = instrumentation.uiAutomation.rootInActiveWindow): AccessibilityNodeInfo? {
        if (root == null) return null
        if (root.contentDescription?.toString() == label) return root
        for (index in 0 until root.childCount) accessibilityNode(label, root.getChild(index))?.let { return it }
        return null
    }
    private fun toggleControls(label: String) {
        // Its full-screen bounds contain transport buttons; invoke the accessible
        // action instead of tapping the play button at the rectangle's center.
        assertTrue(accessibilityNode(label)!!.performAction(AccessibilityNodeInfo.ACTION_CLICK))
        await("controls toggle") { device.hasObject(By.desc(if (label.startsWith("Hide")) "Show playback controls" else "Hide playback controls")) }
    }
    private fun subtitle(role: String, label: String) {
        tap("Tracks")
        tap(role)
        clickStable(By.textContains(label))
        await("subtitle menu dismisses") { findSlider() != null }
        await("subtitle selection reaches player: $role $label") {
            val selected = playerState()?.subtitleTracks?.firstOrNull { it.subtitleRole?.name?.equals(if (role.startsWith("Primary")) "PRIMARY" else "SECONDARY") == true }
            if (label == "Off") selected == null else selected?.title?.contains(label) == true
        }
    }
    private fun playerState(): PlaybackSnapshot? = player()?.state?.value
    private fun player(): MPVPlayer? = playerSurface()?.player
    private fun playerSurface(): MPVPlayerView? {
        var result: MPVPlayerView? = null
        instrumentation.runOnMainSync {
            fun visit(view: View) {
                if (view is MPVPlayerView) result = view
                if (view is ViewGroup) for (index in 0 until view.childCount) visit(view.getChildAt(index))
            }
            ActivityLifecycleMonitorRegistry.getInstance().getActivitiesInStage(Stage.RESUMED).forEach { visit(it.window.decorView) }
        }
        return result
    }
    private fun captionBounds(text: String): Rect? {
        var result: Rect? = null
        instrumentation.runOnMainSync {
            fun visit(view: View) {
                if (view.javaClass.name == "mpvui.CaptionView" && view.contentDescription?.contains(text) == true) {
                    val rect = Rect()
                    if (view.isShown && view.getGlobalVisibleRect(rect)) result = rect
                }
                if (view is ViewGroup) for (index in 0 until view.childCount) visit(view.getChildAt(index))
            }
            ActivityLifecycleMonitorRegistry.getInstance().getActivitiesInStage(Stage.RESUMED).forEach { visit(it.window.decorView) }
        }
        return result
    }
    private fun caption(text: String): Rect {
        await("Visible intercepted caption: $text") { captionBounds(text) != null }
        return captionBounds(text)!!
    }
    private fun reveal(label: String) {
        repeat(12) {
            // Let disclosure expansion and scroll composition finish before
            // deciding the requested row is still outside the viewport.
            Thread.sleep(350)
            instrumentation.uiAutomation.clearCache()
            val match = device.findObject(By.text(Pattern.compile(Pattern.quote(label), Pattern.CASE_INSENSITIVE)))
            if (match != null && match.visibleBounds.bottom < device.displayHeight * .85) return
            device.swipe(device.displayWidth / 2, device.displayHeight * 4 / 5,
                device.displayWidth / 2, device.displayHeight / 3, 25)
        }
        await("Info does not expose $label", timeout = 1) { false }
    }

    @Test fun interceptedCaptionsInfoAndControlsSurviveRotationPipAndReplacement() {
        MediaServer().use { server ->
            launch()
            open(server.url("multitrack.mkv"))
            subtitle("Primary subtitles", "Overlapping cues")
            subtitle("Secondary subtitles", "English dialogue")
            seek(1.5f)
            val primary = caption("first cue")
            val secondary = caption("EN track cue 1")
            assertTrue("secondary captions appear above primary", secondary.centerY() < primary.centerY())
            assertTrue("captions stay inside letterboxed video", primary.bottom < device.displayHeight * .8)
            toggleControls("Hide playback controls")
            caption("first cue")
            await("hidden controls leave accessibility") { !device.hasObject(By.desc("Tracks")) }
            toggleControls("Show playback controls")
            device.setOrientationLeft()
            await("landscape layout") { device.displayWidth > device.displayHeight }
            caption("first cue")
            tap("Picture in picture")
            var pipReadySince = System.nanoTime()
            await("PiP window finishes entering") {
                val pipWindow = instrumentation.uiAutomation.windows.any { it.isInPictureInPictureMode }
                if (!pipWindow) pipReadySince = System.nanoTime()
                pipWindow && System.nanoTime() - pipReadySince > 1_000_000_000
            }
            val context = instrumentation.targetContext
            context.startActivity(context.packageManager.getLaunchIntentForPackage(context.packageName)!!)
            find(By.desc("Tracks"))
            caption("first cue")
            device.setOrientationNatural()
            await("portrait layout") { device.displayHeight > device.displayWidth }
            tap("Info")
            for (label in listOf("Rate", "Volume", "Muted", "Container", "Frame Rate", "Rotation", "Chapters",
                "Buffering", "Source Transfer", "Quality settings", "Dolby Vision", "Audio and Spatial Audio", "Timing and frame delivery", "Decoder and render work")) {
                reveal(label)
            }
            tap("Done")
            seek(5.5f)
            caption("overlap")
            subtitle("Primary subtitles", "Off")
            await("primary Off clears overlay") { captionBounds("overlap") == null }
            open(server.url("baseline.mp4"))
            await("replacement clears secondary overlay") { captionBounds("EN track cue 2") == null }
            tap("Play")
            find(By.desc("Pause"))
            tap("Forward 10 seconds")
            tap("Back 10 seconds")
            device.takeScreenshot(File(instrumentation.targetContext.cacheDir, "parity-player.png"))
        }
    }

    @Test fun audioArtworkKeepsPlaybackControlsAndCanReturnToVideo() {
        MediaServer().use { server ->
            launch()
            val activePlayer = player()!!
            open(server.url("audio-pcm-stereo.mka"))
            await("audio playback releases the video surface") { player() == null }
            await("controls announce audio playback") { accessibilityNode("Hide playback controls")?.stateDescription == "Audio playback" }
            assertTrue(activePlayer.state.value.audioTracks.isNotEmpty())
            assertFalse(activePlayer.state.value.tracks.any { it.id.type == TrackType.VIDEO })
            seek(1.0f)
            await("audio seek completes without a surface") { kotlin.math.abs(activePlayer.state.value.position - 1.0) < 0.3 }
            val pausedPosition = activePlayer.state.value.position
            tap("Play")
            await("audio advances without a surface") { activePlayer.state.value.position > pausedPosition + 0.3 }
            tap("Pause")
            await("audio pauses without a surface") { activePlayer.state.value.paused }
            toggleControls("Hide playback controls")
            assertEquals("Audio playback", accessibilityNode("Show playback controls")?.stateDescription)
            device.takeScreenshot(File(instrumentation.targetContext.cacheDir, "parity-audio-only.png"))
            toggleControls("Show playback controls")
            open(server.url("baseline.mp4"))
            await("video surface returns on the same player") { player() === activePlayer && activePlayer.state.value.hasVideoFrame }
            await("video clears the audio playback announcement") { accessibilityNode("Hide playback controls")?.stateDescription != "Audio playback" }
        }
    }

    @Test fun inspectorDisclosuresExposeLiveDiagnostics() {
        MediaServer().use { server ->
            launch()
            open(server.url("multitrack.mkv"))
            val activePlayer = player()!!
            assertTrue("closed inspector does not collect render passes", activePlayer.state.value.diagnostics.renderPasses.isEmpty())
            tap("Info")
            if (activePlayer.state.value.diagnostics.videoOutput == "gpu-next") {
                await("opening the paused inspector requests one diagnostic sample") {
                    activePlayer.state.value.diagnostics.renderPasses.isNotEmpty()
                }
            }
            fun expand(label: String, firstRow: String) {
                reveal(label)
                tap(label)
                await("$label expands") { device.hasObject(By.text(firstRow)) }
            }
            expand("Quality settings", "Requested Preset")
            assertTrue("rendering preset has an actual value", device.hasObject(By.text("Balanced")))
            expand("Audio and Spatial Audio", "Audio Output")
            assertTrue("audio route has an actual value", device.hasObject(By.text("audiotrack")))
            expand("Timing and frame delivery", "Decoder Drops")
            reveal("Container Rate")
            assertTrue("frame rate has an actual value", device.hasObject(By.text("15 fps")))
            expand("Decoder and render work", "Selected Decoder")
            reveal("Pixel Format")
            assertTrue("decoder format has an actual value", device.hasObject(By.text("yuv420p")))
            val lastDiagnostics = activePlayer.state.value.diagnostics
            tap("Done")
            await("closing the inspector stops diagnostic sampling") {
                !activePlayer.state.value.isDiagnosticsEnabled
            }
            assertEquals("closing the inspector retains the last diagnostic sample", lastDiagnostics, activePlayer.state.value.diagnostics)
        }
    }

    @After fun restoreRotation() { device.unfreezeRotation() }

    /** Byte-range HTTP fixture avoids granting app-private file access to the target process. */
    private inner class MediaServer : AutoCloseable {
        private val running = AtomicBoolean(true)
        private val server = ServerSocket(0)
        private val media = listOf("baseline.mp4", "multitrack.mkv", "audio-pcm-stereo.mka").associateWith {
            instrumentation.context.assets.open(it).use { input -> input.readBytes() }
        }
        init {
            thread(isDaemon = true, name = "Parity fixture server") {
                while (running.get()) {
                    val client = runCatching { server.accept() }.getOrNull() ?: break
                    thread(isDaemon = true) {
                        client.use { socket -> runCatching {
                            val reader = socket.getInputStream().bufferedReader()
                            val request = reader.readLine() ?: return@runCatching
                            val name = request.split(' ').getOrNull(1)?.removePrefix("/")
                            val bytes = media[name] ?: return@runCatching
                            var start = 0
                            var partial = false
                            while (true) {
                                val line = reader.readLine()?.takeIf { it.isNotEmpty() } ?: break
                                if (line.startsWith("Range:", ignoreCase = true)) {
                                    start = line.substringAfter("bytes=").substringBefore('-').toIntOrNull() ?: 0
                                    partial = true
                                }
                            }
                            start = start.coerceIn(0, bytes.size)
                            val headers = "HTTP/1.1 ${if (partial) "206 Partial Content" else "200 OK"}\r\nContent-Length: ${bytes.size - start}\r\nAccept-Ranges: bytes\r\n" +
                                (if (partial) "Content-Range: bytes $start-${bytes.size - 1}/${bytes.size}\r\n" else "") + "Connection: close\r\n\r\n"
                            socket.getOutputStream().apply {
                                write(headers.toByteArray())
                                if (!request.startsWith("HEAD")) write(bytes, start, bytes.size - start)
                                flush()
                            }
                        } }
                    }
                }
            }
        }
        fun url(name: String) = "http://127.0.0.1:${server.localPort}/$name"
        override fun close() { running.set(false); server.close() }
    }
}
