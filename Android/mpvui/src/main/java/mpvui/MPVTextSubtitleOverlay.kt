package mpvui

import android.content.Context
import android.content.ContextWrapper
import android.app.Activity
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Typeface
import android.text.Layout
import android.text.StaticLayout
import android.text.TextPaint
import android.view.View
import android.view.accessibility.CaptioningManager
import androidx.compose.foundation.layout.*
import androidx.compose.runtime.Composable
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.compose.ui.platform.LocalContext
import kotlin.math.ceil
import kotlin.math.max
import kotlin.math.min

/** Intercepted text captions inside the fitted video, with live system caption preferences.
 * Primary cues sit below secondary cues. Styled ASS and bitmap subtitles remain in mpv.
 * This basic overlay uses role-based layout and ignores authored [TextSubtitleRegion.placement].
 * Hosts needing WebVTT positioning or vertical writing can render the typed placement themselves.
 */
@Composable
fun MPVTextSubtitleOverlay(snapshot: TextSubtitleSnapshot, modifier: Modifier = Modifier, aspectRatio: Float = 16f / 9f) {
    val activity = LocalContext.current.activity()
    val inlineWidth = remember { floatArrayOf(0f) }
    BoxWithConstraints(modifier, contentAlignment = Alignment.Center) {
        val aspect = aspectRatio.takeIf { it.isFinite() && it > 0 } ?: 16f / 9f
        val width = min(maxWidth.value, maxHeight.value * aspect)
        val height = width / aspect
        // Match inline wrapping in PiP, where the entire Activity is resized.
        val scale = if (activity?.isInPictureInPictureMode == true && inlineWidth[0] > 0) min(1f, width / inlineWidth[0]) else 1f
        SideEffect { if (activity?.isInPictureInPictureMode != true) inlineWidth[0] = width }
        Box(Modifier.size(width.dp, height.dp).clipToBounds()
            .padding(horizontal = max(24f * scale, width * .08f).dp, vertical = max(24f * scale, height * .08f).dp)) {
            SubtitleRole.entries.forEach { role ->
                Column(Modifier.align(if (role == SubtitleRole.PRIMARY) Alignment.BottomCenter else Alignment.TopCenter),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy((6 * scale).dp)) {
                    snapshot.regions.filter { (it.role ?: SubtitleRole.PRIMARY) == role }.forEach { region ->
                        AndroidView(factory = { CaptionView(it) }, update = { it.setCaption(region.text, scale) })
                    }
                }
            }
        }
    }
}

private tailrec fun Context.activity(): Activity? = when (this) {
    is Activity -> this
    is ContextWrapper -> baseContext.activity()
    else -> null
}

/** Text-only View lets caption size follow CaptioningManager rather than applying font scaling twice. */
internal class CaptionView(context: Context) : View(context) {
    private val manager = context.getSystemService(CaptioningManager::class.java)
    private var captionScale = 1f
    private val density: Float get() = resources.displayMetrics.density * captionScale
    private val textPaint = TextPaint(Paint.ANTI_ALIAS_FLAG)
    private val fill = Paint(Paint.ANTI_ALIAS_FLAG)
    private var caption = ""
    private var layout: StaticLayout? = null
    private var foreground = Color.WHITE
    private var background = Color.TRANSPARENT
    private var window = 0xA6000000.toInt()
    private var edge = CaptioningManager.CaptionStyle.EDGE_TYPE_NONE
    private var edgeColor = Color.BLACK
    private val horizontalPadding: Float get() = 8 * density
    private val verticalPadding: Float get() = 4 * density
    private val listener = object : CaptioningManager.CaptioningChangeListener() {
        override fun onEnabledChanged(enabled: Boolean) = updateStyle()
        override fun onFontScaleChanged(fontScale: Float) = updateStyle()
        override fun onUserStyleChanged(userStyle: CaptioningManager.CaptionStyle) = updateStyle()
    }

    init {
        importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_YES
        isClickable = false
        updateStyle()
    }
    fun setCaption(value: String, scale: Float) {
        if (captionScale != scale) { captionScale = scale; updateStyle() }
        if (caption == value) return
        caption = value
        contentDescription = value
        requestLayout()
        invalidate()
    }
    private fun updateStyle() {
        val style = manager.userStyle.takeIf { manager.isEnabled }
        foreground = style?.takeIf { it.hasForegroundColor() }?.foregroundColor ?: Color.WHITE
        background = style?.takeIf { it.hasBackgroundColor() }?.backgroundColor ?: Color.TRANSPARENT
        // An explicit system caption background replaces the default caption window.
        window = style?.takeIf { it.hasWindowColor() }?.windowColor
            ?: if (style?.hasBackgroundColor() == true) Color.TRANSPARENT else 0xA6000000.toInt()
        edge = style?.takeIf { it.hasEdgeType() }?.edgeType ?: CaptioningManager.CaptionStyle.EDGE_TYPE_NONE
        edgeColor = style?.takeIf { it.hasEdgeColor() }?.edgeColor ?: Color.BLACK
        textPaint.typeface = style?.typeface ?: Typeface.create("sans-serif", Typeface.NORMAL)
        textPaint.textSize = 21 * density * (manager.fontScale.takeIf { it.isFinite() && it > 0 } ?: 1f)
        requestLayout()
        invalidate()
    }
    override fun onAttachedToWindow() {
        super.onAttachedToWindow()
        manager.addCaptioningChangeListener(listener)
        updateStyle()
    }
    override fun onDetachedFromWindow() {
        manager.removeCaptioningChangeListener(listener)
        super.onDetachedFromWindow()
    }
    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        val available = if (MeasureSpec.getMode(widthMeasureSpec) == MeasureSpec.UNSPECIFIED) Int.MAX_VALUE else MeasureSpec.getSize(widthMeasureSpec)
        val desired = ceil(Layout.getDesiredWidth(caption, textPaint) + horizontalPadding * 2).toInt()
        val width = resolveSize(min(desired, available), widthMeasureSpec)
        layout = StaticLayout.Builder.obtain(caption, 0, caption.length, textPaint, max(1, (width - horizontalPadding * 2).toInt()))
            .setAlignment(Layout.Alignment.ALIGN_CENTER).setIncludePad(false).build()
        setMeasuredDimension(width, resolveSize(ceil(layout!!.height + verticalPadding * 2).toInt(), heightMeasureSpec))
    }
    override fun onDraw(canvas: Canvas) {
        val layout = layout ?: return
        fill.color = window
        canvas.drawRoundRect(0f, 0f, width.toFloat(), height.toFloat(), 7 * density, 7 * density, fill)
        canvas.save()
        canvas.translate(horizontalPadding, verticalPadding)
        fill.color = background
        for (line in 0 until layout.lineCount) {
            canvas.drawRect(layout.getLineLeft(line) - 2 * density, layout.getLineTop(line).toFloat() - density,
                layout.getLineRight(line) + 2 * density, layout.getLineBottom(line).toFloat() + density, fill)
        }
        textPaint.color = foreground
        textPaint.style = Paint.Style.FILL
        when (edge) {
            CaptioningManager.CaptionStyle.EDGE_TYPE_OUTLINE -> {
                textPaint.style = Paint.Style.STROKE
                textPaint.strokeWidth = 2 * density
                textPaint.color = edgeColor
                layout.draw(canvas)
                textPaint.style = Paint.Style.FILL
                textPaint.color = foreground
            }
            CaptioningManager.CaptionStyle.EDGE_TYPE_DROP_SHADOW -> textPaint.setShadowLayer(density, 2 * density, 2 * density, edgeColor)
            CaptioningManager.CaptionStyle.EDGE_TYPE_RAISED, CaptioningManager.CaptionStyle.EDGE_TYPE_DEPRESSED -> {
                val raised = edge == CaptioningManager.CaptionStyle.EDGE_TYPE_RAISED
                textPaint.setShadowLayer(density, -density, -density, if (raised) Color.WHITE else edgeColor)
                layout.draw(canvas)
                textPaint.setShadowLayer(density, density, density, if (raised) edgeColor else Color.WHITE)
            }
        }
        layout.draw(canvas)
        textPaint.clearShadowLayer()
        canvas.restore()
    }
}
