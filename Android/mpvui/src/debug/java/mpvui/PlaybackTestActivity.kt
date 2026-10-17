package mpvui

import android.app.Activity
import android.os.Bundle

/** Instrumentation host is excluded from the published release variant. */
class PlaybackTestActivity : Activity() {
    lateinit var video: MPVPlayerView
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Keep this test surface available on unattended, locked devices.
        setShowWhenLocked(true)
        setTurnScreenOn(true)
        video = MPVPlayerView(this)
        setContentView(video)
    }
}
