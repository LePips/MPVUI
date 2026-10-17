package mpvui

import mpvui.internal.CoreWire
import org.junit.Assert.*
import org.junit.Test

class APIAlignmentTest {
    @Test fun allSessionErrorCategoriesRemainTypedAcrossTheTransport() {
        val error = CoreWire.failure(mapOf("type" to "commandFailed", "context" to "Set property", "code" to -12L, "message" to "Unavailable"))
        assertEquals(PlayerError.CommandFailed("Set property", -12, "Unavailable"), error)
        assertEquals(PlayerError.ClientUnavailable, CoreWire.failure(mapOf("type" to "clientUnavailable")))
        assertNull(CoreWire.failure(null))
    }
    @Test fun subtitlePlacementIsCopiedWithoutParsingAuthoredSettings() {
        val record = CoreWire.encode(listOf(mapOf("startTime" to 1.0, "endTime" to 2.0, "snapshot" to listOf(
            mapOf("text" to "Placed", "placement" to mapOf("horizontalPosition" to .2, "verticalPosition" to .8,
                "horizontalAnchor" to "LEFT", "verticalAnchor" to "BOTTOM", "writingDirection" to "VERTICAL_GROWING_LEFT"))))))
        val cue = CoreWire.timeline(record).single()
        val placement = (cue.snapshot.regions.single().placement as TextSubtitlePlacement.WebVTT).placement
        assertEquals(.2f, placement.horizontalPosition)
        assertEquals(WebVTTPlacement.WritingDirection.VERTICAL_GROWING_LEFT, placement.writingDirection)
        assertTrue(cue.contains(1.0)); assertFalse(cue.contains(2.0))
    }
}
