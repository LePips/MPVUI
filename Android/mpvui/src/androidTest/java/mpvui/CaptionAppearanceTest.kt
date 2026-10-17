package mpvui

import android.Manifest
import android.graphics.Bitmap
import android.graphics.Canvas
import android.provider.Settings
import android.widget.FrameLayout
import androidx.test.core.app.ActivityScenario
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Test

class CaptionAppearanceTest {
    @Test fun captionsFollowLiveSystemColorAndSizePreferences() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val resolver = instrumentation.targetContext.contentResolver
        val keys = listOf("accessibility_captioning_enabled", "accessibility_captioning_preset",
            "accessibility_captioning_foreground_color", "accessibility_captioning_font_scale")
        val original = keys.associateWith { Settings.Secure.getString(resolver, it) }
        instrumentation.uiAutomation.adoptShellPermissionIdentity(Manifest.permission.WRITE_SECURE_SETTINGS)
        try {
            Settings.Secure.putString(resolver, keys[0], "0")
            Settings.Secure.putString(resolver, keys[3], "1.0")
            ActivityScenario.launch(PlaybackTestActivity::class.java).use { scenario ->
                lateinit var caption: CaptionView
                scenario.onActivity { activity ->
                    caption = CaptionView(activity).apply { setCaption("Caption appearance", 1f) }
                    activity.setContentView(FrameLayout(activity).apply {
                        addView(caption, FrameLayout.LayoutParams(FrameLayout.LayoutParams.WRAP_CONTENT, FrameLayout.LayoutParams.WRAP_CONTENT))
                    })
                }
                fun rendering(): Pair<Int, Int> {
                    var height = 0
                    var yellowPixels = 0
                    scenario.onActivity {
                        height = caption.height
                        if (caption.width > 0 && height > 0) {
                            val bitmap = Bitmap.createBitmap(caption.width, height, Bitmap.Config.ARGB_8888)
                            caption.draw(Canvas(bitmap))
                            for (y in 0 until bitmap.height) for (x in 0 until bitmap.width) {
                                val pixel = bitmap.getPixel(x, y)
                                if ((pixel shr 16 and 255) > 200 && (pixel shr 8 and 255) > 200 && (pixel and 255) < 80) yellowPixels++
                            }
                            bitmap.recycle()
                        }
                    }
                    return height to yellowPixels
                }
                fun await(message: String, predicate: () -> Boolean) {
                    val deadline = System.nanoTime() + 5_000_000_000
                    while (!predicate() && System.nanoTime() < deadline) Thread.sleep(50)
                    assertTrue(message, predicate())
                }
                await("caption laid out") { rendering().first > 0 }
                val initialHeight = rendering().first
                assertEquals(0, rendering().second)
                Settings.Secure.putString(resolver, keys[1], "-1")
                Settings.Secure.putString(resolver, keys[2], (-256).toString())
                Settings.Secure.putString(resolver, keys[3], "1.6")
                Settings.Secure.putString(resolver, keys[0], "1")
                await("live caption color and scale update") {
                    val (height, pixels) = rendering()
                    height > initialHeight * 1.3 && pixels > 30
                }
            }
        } finally {
            original.forEach { (key, value) -> Settings.Secure.putString(resolver, key, value) }
            instrumentation.uiAutomation.dropShellPermissionIdentity()
        }
    }
}
