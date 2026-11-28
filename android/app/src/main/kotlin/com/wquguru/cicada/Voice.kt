package com.wquguru.cicada

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import android.os.Bundle
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import cicada.LingClient
import cicada.Log
import java.util.Locale
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

class Voice(private val context: Context) {
    enum class Result { Spoken, NoVoice, Failed }

    private var tts: TextToSpeech? = null
    private var ready = CountDownLatch(1)
    private var ok = false
    @Volatile var speaking = false; private set

    fun warm() { engine() }

    @Synchronized private fun engine(): TextToSpeech? {
        tts?.let { return if (ready.await(3, TimeUnit.SECONDS) && ok) it else null }
        ready = CountDownLatch(1)
        val t = TextToSpeech(context.applicationContext) { status ->
            ok = status == TextToSpeech.SUCCESS
            Log.d("voice: engine ${if (ok) "ready" else "failed $status"}")
            ready.countDown()
        }
        t.setAudioAttributes(AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_ASSISTANT)
            .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build())
        tts = t
        return if (ready.await(3, TimeUnit.SECONDS) && ok) t else null
    }

    fun has(lang: String): Boolean {
        val t = engine() ?: return false
        val r = t.isLanguageAvailable(Locale.forLanguageTag(lang))
        return r >= TextToSpeech.LANG_AVAILABLE
    }

    fun speak(text: String, lang: String, onStart: () -> Unit, onEnd: () -> Unit): Result {
        val t = engine() ?: return Result.Failed
        val locale = Locale.forLanguageTag(lang)
        val avail = t.isLanguageAvailable(locale)
        if (avail < TextToSpeech.LANG_AVAILABLE) { Log.d("voice: no voice for $lang ($avail)"); return Result.NoVoice }
        t.language = locale
        t.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
            override fun onStart(id: String) { speaking = true; Log.d("voice: start $lang"); onStart() }
            override fun onDone(id: String) { speaking = false; Log.d("voice: done"); onEnd() }
            @Deprecated("Deprecated in Java") override fun onError(id: String) { speaking = false; Log.d("voice: error"); onEnd() }
            override fun onError(id: String, code: Int) { speaking = false; Log.d("voice: error $code"); onEnd() }
            override fun onStop(id: String, interrupted: Boolean) { speaking = false; onEnd() }
        })
        val r = t.speak(text, TextToSpeech.QUEUE_FLUSH, Bundle(), "said-${System.nanoTime()}")
        return if (r == TextToSpeech.SUCCESS) Result.Spoken else Result.Failed
    }

    private class Stopped : RuntimeException()
    @Volatile private var track: AudioTrack? = null

    fun speakCloud(ling: LingClient, text: String, voiceName: String?, language: String?,
                   onStart: () -> Unit, onEnd: () -> Unit, reference: Pair<String, String>? = null): Result {
        val rate = LingClient.TTS_RATE
        val t = try {
            AudioTrack.Builder()
                .setAudioAttributes(AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_ASSISTANT)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build())
                .setAudioFormat(AudioFormat.Builder().setSampleRate(rate).setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                    .setChannelMask(AudioFormat.CHANNEL_OUT_MONO).build())
                .setTransferMode(AudioTrack.MODE_STREAM)
                .setBufferSizeInBytes(maxOf(AudioTrack.getMinBufferSize(rate, AudioFormat.CHANNEL_OUT_MONO, AudioFormat.ENCODING_PCM_16BIT), rate))
                .build()
        } catch (e: Exception) { Log.d("voice: no audio track ${e.javaClass.simpleName}"); return Result.Failed }
        track = t
        speaking = true
        var frames = 0L
        try {
            ling.speech(text, voiceName, language, reference = reference) { pcm ->
                if (track !== t) throw Stopped()
                if (frames == 0L) { t.play(); Log.d("voice: cloud start"); onStart() }
                t.write(pcm, 0, pcm.size)
                frames += pcm.size / 2
            }
            if (frames == 0L) return Result.Failed
            val until = System.currentTimeMillis() + frames * 1000 / rate + 2000
            while (track === t && t.playbackHeadPosition < frames && System.currentTimeMillis() < until) Thread.sleep(40)
            Log.d("voice: cloud done")
            return Result.Spoken
        } catch (_: Stopped) {
            return Result.Spoken
        } catch (e: Exception) {
            Log.d("voice: cloud failed ${e.message ?: e.javaClass.simpleName}")
            return if (frames > 0) Result.Spoken else Result.Failed
        } finally {
            if (track === t) track = null
            try { t.stop() } catch (_: Exception) {}
            t.release()
            speaking = false
            onEnd()
        }
    }

    fun stop() {
        tts?.stop()
        track?.let { track = null; try { it.pause(); it.flush() } catch (_: Exception) {} }
    }
}
