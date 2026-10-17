package mpvui

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.os.Handler
import android.os.Looper

internal class AudioFocusController(private val context: Context, private val player: MPVPlayer, private val enabled: Boolean) : AutoCloseable {
    private val manager = context.getSystemService(AudioManager::class.java)
    private val main = Handler(Looper.getMainLooper())
    @Volatile private var resume = false
    @Volatile private var held = false
    private val request = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
        .setAudioAttributes(AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA).setContentType(AudioAttributes.CONTENT_TYPE_MOVIE).build())
        .setWillPauseWhenDucked(true)
        .setOnAudioFocusChangeListener({ change ->
            when (change) {
                AudioManager.AUDIOFOCUS_GAIN -> { held = true; if (resume) { resume = false; player.play() } }
                AudioManager.AUDIOFOCUS_LOSS -> { held = false; resume = false; player.pauseForFocus() }
                AudioManager.AUDIOFOCUS_LOSS_TRANSIENT, AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK -> {
                    resume = !player.state.value.paused; held = false; player.pauseForFocus()
                }
            }
        }, main).build()
    private val noisy = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) { if (intent?.action == AudioManager.ACTION_AUDIO_BECOMING_NOISY) player.pause() }
    }
    init {
        if (enabled) {
            context.registerReceiver(noisy, IntentFilter(AudioManager.ACTION_AUDIO_BECOMING_NOISY), Context.RECEIVER_NOT_EXPORTED)
        }
    }
    fun request(): Boolean {
        if (!enabled || held) return true
        held = manager.requestAudioFocus(request) == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
        return held
    }
    fun beforeLoad(autoPlay: Boolean): Boolean { resume = false; return autoPlay && request() }
    fun cancelResume() { resume = false }
    fun abandon() { resume = false; if (enabled) manager.abandonAudioFocusRequest(request); held = false }
    override fun close() { abandon(); if (enabled) context.unregisterReceiver(noisy) }
}
