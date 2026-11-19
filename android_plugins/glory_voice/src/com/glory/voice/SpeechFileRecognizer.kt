package com.glory.voice

import android.content.Context
import android.content.Intent
import android.media.AudioFormat
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import org.json.JSONObject
import java.io.File

/** File recognition only: no second microphone capture and no voice upload. */
internal class SpeechFileRecognizer(private val context: Context) {
    private val handler = Handler(Looper.getMainLooper())
    @Volatile private var result = "{\"state\":\"idle\"}"
    private var recognizer: SpeechRecognizer? = null
    private var audio: ParcelFileDescriptor? = null
    private var pcm: File? = null
    private var generation = 0

    fun status(): String = result
    fun cancel() { handler.post { generation++; cleanup(); result = "{\"state\":\"idle\"}" } }
    private fun cleanup() {
        recognizer?.destroy(); recognizer = null
        audio?.close(); audio = null
        pcm?.delete(); pcm = null
    }
    fun start(filename: String, locale: String): String {
        // Earlier Android versions cannot reliably recognize our existing recording.
        if (Build.VERSION.SDK_INT < 33) return "android_13_required"
        result = "{\"state\":\"pending\"}"
        handler.post {
            generation++
            val ticket = generation
            cleanup()
            fun finish(text: String = "", error: String = "") {
                if (ticket != generation) return
                result = JSONObject().put("state", "done").put("text", text).put("error", error).toString()
                cleanup()
            }
            try {
                if (!SpeechRecognizer.isOnDeviceRecognitionAvailable(context)) {
                    finish(error = "on_device_recognizer_unavailable")
                    return@post
                }
                // VoiceClipService writes canonical 16 kHz mono PCM16 WAV (44-byte header).
                val wav = File(filename).readBytes()
                require(wav.size > 44 && String(wav, 0, 4) == "RIFF" && String(wav, 8, 4) == "WAVE")
                pcm = File.createTempFile("glory-speech-", ".pcm", context.cacheDir).also {
                    it.writeBytes(wav.copyOfRange(44, wav.size))
                }
                audio = ParcelFileDescriptor.open(pcm!!, ParcelFileDescriptor.MODE_READ_ONLY)
                recognizer = SpeechRecognizer.createOnDeviceSpeechRecognizer(context)
                recognizer!!.setRecognitionListener(object : RecognitionListener {
                    override fun onReadyForSpeech(params: Bundle?) {}
                    override fun onBeginningOfSpeech() {}
                    override fun onRmsChanged(rmsdB: Float) {}
                    override fun onBufferReceived(buffer: ByteArray?) {}
                    override fun onEndOfSpeech() {}
                    override fun onPartialResults(partialResults: Bundle?) {}
                    override fun onEvent(eventType: Int, params: Bundle?) {}
                    override fun onError(error: Int) { finish(error = "recognizer_error_$error") }
                    override fun onResults(results: Bundle?) {
                        finish(text = results?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull() ?: "")
                    }
                })
                val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH)
                    .putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
                    .putExtra(RecognizerIntent.EXTRA_LANGUAGE, locale)
                    .putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE, audio)
                    .putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE_ENCODING, AudioFormat.ENCODING_PCM_16BIT)
                    .putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE_CHANNEL_COUNT, 1)
                    .putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE_SAMPLING_RATE, 16000)
                recognizer!!.startListening(intent)
                handler.postDelayed({
                    if (ticket == generation && result.contains("pending")) finish(error = "timeout")
                }, 40000)
            } catch (_: Exception) { finish(error = "recognizer_failed") }
        }
        return ""
    }
}
