package mpvui

import android.graphics.SurfaceTexture
import android.view.Surface
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import mpvui.internal.*
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class NativeBridgeTest {
    private fun create(): Long {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        return NativeBridge.create(context, PlayerConfiguration().coreRecord(context), 0, 2, false, false)
    }
    private fun send(handle: Long, kind: Int, value: Double = 0.0, strings: Array<String> = emptyArray()): LongArray =
        NativeBridge.send(handle, kind, 0, 0, 0, -1, value, false, strings)
    @Test fun sharedSessionPublishesTypedStateAndOwnedErrors() {
        val handle = create()
        try {
            val operation = send(handle, 9, 37.25)
            assertTrue(operation[0] > 0)
            val property = "missing-property-日本語-🎬"
            send(handle, 17, strings = arrayOf(property, "yes"))
            var volume = false; var error = false
            var last: PlaybackSnapshot? = null
            val deadline = System.nanoTime() + 5_000_000_000L
            while (!(volume && error) && System.nanoTime() < deadline) {
                val event = NativeBridge.event(handle)
                if (event?.type == 1) {
                    val state = CoreWire.snapshot(event.record)
                    last = state
                    volume = volume || state.volume == 37.25
                    val failure = state.error as? PlayerError.CommandFailed
                    error = error || (failure != null && failure.code < 0 && failure.context.contains(property))
                }
                if (!(volume && error)) Thread.sleep(10)
            }
            assertTrue("Copied Swift volume state: $last", volume)
            assertTrue("Typed Swift failure retains Unicode context", error)
        } finally { NativeBridge.stopEvents(handle); NativeBridge.destroy(handle) }
    }
    @Test fun replacingSurfacesFencesNativeOwnershipAndCloseWakesDelivery() {
        val handle = create()
        try {
            repeat(20) {
                val texture = SurfaceTexture(false); val surface = Surface(texture)
                try {
                    NativeBridge.surface(handle, surface, DisplayCapabilities().coreRecord())
                    NativeBridge.resize(handle, 320, 180)
                    NativeBridge.surface(handle, null, DisplayCapabilities().coreRecord())
                } finally { surface.release(); texture.release() }
            }
            NativeBridge.stopEvents(handle)
            assertFalse(NativeBridge.waitForEvents(handle))
        } finally { NativeBridge.destroy(handle) }
    }
}
