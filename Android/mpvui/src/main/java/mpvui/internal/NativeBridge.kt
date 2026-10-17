package mpvui.internal

import android.content.Context
import android.view.Surface

/** JNI marshals typed commands and copied records. Swift owns the native session. */
internal object NativeBridge {
    init { System.loadLibrary("mpvui") }
    external fun create(context: Context, settings: ByteArray, output: Int, decoder: Int, lowPower: Boolean, compatibility: Boolean): Long
    external fun send(handle: Long, kind: Int, flags: Int, trackType: Int, role: Int, trackId: Long, value: Double, hasValue: Boolean, strings: Array<String>): LongArray
    external fun waitForEvents(handle: Long): Boolean
    external fun event(handle: Long): CoreEvent?
    external fun snapshot(handle: Long): ByteArray
    external fun stopEvents(handle: Long)
    external fun querySubtitles(handle: Long, type: Int, track: Long, id: Long)
    external fun releaseQuery(handle: Long, id: Long)
    external fun surface(handle: Long, surface: Surface?, display: ByteArray)
    external fun resize(handle: Long, width: Int, height: Int)
    external fun destroy(handle: Long)
    external fun requestFeatures(handle: Long, mask: Int): ByteArray
    external fun retainSessionAddress(handle: Long): Long
}

/** Complete domain delivery; type never contains a native mpv event identifier. */
internal data class CoreEvent(val type: Int, val generation: Long, val query: Long, val record: ByteArray)
