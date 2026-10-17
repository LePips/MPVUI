package mpvui

import mpvui.internal.CoreWire
import org.junit.Assert.*
import org.junit.Test

class PlaybackContractTest {
    @Test fun typedRecordPreservesUnicodeExactIntegersUnknownsAndNestedCollections() {
        val input = mapOf("text" to "日本語 🎬 \"quotes\"\nnext line", "integer" to 9007199254740993L,
            "nested" to listOf(null, false, 37.25, mapOf("empty" to "")))
        assertEquals(input, CoreWire.decode(CoreWire.encode(input)))
    }
    @Test fun recordRejectsTruncationTrailingBytesAndUnknownVersions() {
        val valid = CoreWire.encode(mapOf("value" to listOf("text", true, 42L)))
        for (size in 0 until valid.size) assertThrows(Exception::class.java) { CoreWire.decode(valid.copyOf(size)) }
        assertThrows(Exception::class.java) { CoreWire.decode(valid + byteArrayOf(0)) }
        assertThrows(Exception::class.java) { CoreWire.decode(valid.copyOf().apply { this[4] = 99 }) }
    }
    @Test fun snapshotProjectsCompleteStatesAndSubtitleClearsWithoutMerging() {
        val caption = mapOf("text" to "Hello 🎬", "role" to "SECONDARY", "trackID" to 3L)
        val populated = CoreWire.snapshot(CoreWire.encode(mapOf("state" to "PAUSED", "loadGeneration" to 7L,
            "subtitles" to listOf(caption), "position" to 2.5, "fileSize" to 9007199254740993L)))
        assertEquals(SubtitleRole.SECONDARY, populated.subtitles.regions.single().role)
        assertEquals(9007199254740993L, populated.fileSize)
        val replacement = CoreWire.snapshot(CoreWire.encode(mapOf("state" to "LOADING", "loadGeneration" to 8L, "subtitles" to emptyList<Any>())))
        assertTrue(replacement.subtitles.regions.isEmpty())
        assertNull(replacement.fileSize)
        assertEquals(0.0, replacement.position, 0.0)
    }
}
