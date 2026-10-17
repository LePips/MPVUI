package mpvuiexample.module

import androidx.compose.animation.core.animateDpAsState
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.Slider
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.LayoutDirection

/** Native vectors cover the player symbols absent from Skip's SF Symbol mapping. */
@Composable
fun PlayerChromeIcon(name: String, modifier: Modifier) {
    val vector = when (name) {
        "play.fill" -> Icons.Outlined.PlayArrow
        "pause.fill" -> Icons.Outlined.Pause
        "gobackward.10" -> Icons.Outlined.Replay10
        "goforward.10" -> Icons.Outlined.Forward10
        "folder" -> Icons.Outlined.FolderOpen
        "chevron.down" -> Icons.Outlined.KeyboardArrowDown
        "captions.bubble" -> Icons.Outlined.ClosedCaption
        "pip.enter" -> Icons.Outlined.PictureInPictureAlt
        "music.note" -> Icons.Outlined.MusicNote
        else -> Icons.Outlined.Info
    }
    Icon(vector, contentDescription = null, tint = Color.White, modifier = modifier.fillMaxSize())
}

/** Relative pointer scrubbing with the native Slider's keyboard and accessibility actions. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PlayerChromeTimeline(value: Double, upperBound: Double, enabled: Boolean,
                         onChange: (Double) -> Unit, onEditing: (Boolean) -> Unit,
                         modifier: Modifier) {
    var dragging by remember { mutableStateOf(false) }
    val latestValue by rememberUpdatedState(value)
    val latestChange by rememberUpdatedState(onChange)
    val latestEditing by rememberUpdatedState(onEditing)
    val layoutDirection = LocalLayoutDirection.current
    val height by animateDpAsState(if (dragging) 20.dp else 12.dp)
    DisposableEffect(Unit) {
        onDispose { if (dragging) latestEditing(false) }
    }
    Slider(
        value = value.toFloat().coerceIn(0f, upperBound.toFloat()),
        valueRange = 0f..upperBound.toFloat(),
        enabled = enabled,
        onValueChange = {
            if (!dragging) { dragging = true; onEditing(true) }
            onChange(it.toDouble())
        },
        onValueChangeFinished = { dragging = false; onEditing(false) },
        modifier = modifier.fillMaxWidth().height(44.dp)
            .pointerInput(enabled, upperBound, layoutDirection) {
                if (!enabled) return@pointerInput
                awaitEachGesture {
                    // Consume pointer input before Slider's absolute tap/drag handlers.
                    // Semantics and key events still use its native value callbacks.
                    val down = awaitFirstDown(pass = PointerEventPass.Initial)
                    down.consume()
                    val startValue = latestValue.coerceIn(0.0, upperBound)
                    val width = size.width.coerceAtLeast(1)
                    val direction = if (layoutDirection == LayoutDirection.Rtl) -1 else 1
                    dragging = true
                    latestEditing(true)
                    try {
                        while (true) {
                            val change = awaitPointerEvent(PointerEventPass.Initial).changes
                                .firstOrNull { it.id == down.id } ?: break
                            if (change.isConsumed) break
                            change.consume()
                            val offset = (change.position.x - down.position.x) / width * upperBound * direction
                            latestChange((startValue + offset).coerceIn(0.0, upperBound))
                            if (!change.pressed) break
                        }
                    } finally {
                        if (dragging) {
                            dragging = false
                            latestEditing(false)
                        }
                    }
                }
            }
            .semantics { contentDescription = "Playback position" },
        thumb = { Spacer(Modifier.size(0.dp)) },
        track = { state ->
            Box(Modifier.fillMaxWidth().height(height).clip(RoundedCornerShape(50))
                .background(Color.White.copy(alpha = if (enabled) 0.2f else 0.08f))) {
                Box(Modifier.fillMaxHeight()
                    .fillMaxWidth((state.value / upperBound.toFloat()).coerceIn(0f, 1f))
                    .background(Color.White.copy(alpha = if (enabled) 1f else 0.4f)))
            }
        }
    )
}
