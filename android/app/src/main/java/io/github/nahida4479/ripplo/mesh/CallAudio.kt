package io.github.nahida4479.ripplo.mesh

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRecord
import android.media.AudioTrack
import android.media.MediaRecorder
import android.media.audiofx.AcousticEchoCanceler
import android.media.audiofx.NoiseSuppressor
import android.os.Process
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

internal class CallAudio(private val ctx: Context, private val messenger: BinaryMessenger) :
    MethodChannel.MethodCallHandler,
    EventChannel.StreamHandler {
    private var methods: MethodChannel? = null
    private var events: EventChannel? = null

    @Volatile
    private var sink: EventChannel.EventSink? = null

    @Volatile
    private var record: AudioRecord? = null

    @Volatile
    private var track: AudioTrack? = null
    private var aec: AcousticEchoCanceler? = null
    private var ns: NoiseSuppressor? = null
    private var captureThread: Thread? = null
    private var playThread: Thread? = null

    @Volatile
    private var muted = false

    @Volatile
    private var writtenFrames = 0L
    private val queue = LinkedBlockingQueue<ByteArray>()
    private val queuedBytes = AtomicInteger()
    private var savedMode = AudioManager.MODE_NORMAL
    private var savedSpeaker = false
    private var routed = false

    fun attach() {
        val m = MethodChannel(messenger, "ripplo/audio")
        m.setMethodCallHandler(this)
        methods = m
        val e = EventChannel(messenger, "ripplo/audio/pcm")
        e.setStreamHandler(this)
        events = e
    }

    fun detach() {
        stopAll()
        methods?.setMethodCallHandler(null)
        methods = null
        events?.setStreamHandler(null)
        events = null
        sink = null
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        sink = events
    }

    override fun onCancel(arguments: Any?) {
        sink = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "audioStart" -> {
                    start(call.argument<Boolean>("raw") ?: false)
                    result.success(null)
                }
                "audioPlay" -> {
                    val pcm = call.argument<ByteArray>("pcm")
                    if (pcm == null) {
                        result.error("bad_args", "bad_args", null)
                    } else {
                        play(pcm)
                        result.success(null)
                    }
                }
                "audioMute" -> {
                    muted = call.argument<Boolean>("on") ?: false
                    result.success(null)
                }
                "audioFallback" -> {
                    fallback()
                    result.success(null)
                }
                "audioStop" -> {
                    stopAll()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        } catch (e: SecurityException) {
            stopAll()
            result.error("mic_denied", "mic_denied", null)
        } catch (e: Exception) {
            stopAll()
            result.error("audio_failed", e.message ?: "audio_failed", null)
        }
    }

    @Suppress("DEPRECATION")
    private fun start(raw: Boolean) {
        stopAll()
        if (ctx.checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            throw SecurityException("mic_denied")
        }
        val am = ctx.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        savedMode = am.mode
        savedSpeaker = am.isSpeakerphoneOn
        am.mode = AudioManager.MODE_IN_COMMUNICATION
        am.isSpeakerphoneOn = true
        routed = true
        startTrack()
        startCapture(raw)
    }

    private fun fallback() {
        if (record == null && track == null) return
        stopCapture()
        startCapture(true)
    }

    private fun startTrack() {
        val min = AudioTrack.getMinBufferSize(RATE, AudioFormat.CHANNEL_OUT_MONO, AudioFormat.ENCODING_PCM_16BIT)
        val t = AudioTrack.Builder()
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                    .build(),
            )
            .setAudioFormat(
                AudioFormat.Builder()
                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                    .setSampleRate(RATE)
                    .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                    .build(),
            )
            .setBufferSizeInBytes(maxOf(min, RATE))
            .setTransferMode(AudioTrack.MODE_STREAM)
            .build()
        if (t.state != AudioTrack.STATE_INITIALIZED) {
            t.release()
            throw IllegalStateException("audio_failed")
        }
        queue.clear()
        queuedBytes.set(0)
        writtenFrames = 0L
        track = t
        val th = Thread({ playLoop(t) }, "ripplo-audio-out")
        th.isDaemon = true
        playThread = th
        th.start()
    }

    private fun startCapture(raw: Boolean) {
        val min = AudioRecord.getMinBufferSize(RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
        val r = AudioRecord.Builder()
            .setAudioSource(if (raw) MediaRecorder.AudioSource.MIC else MediaRecorder.AudioSource.VOICE_COMMUNICATION)
            .setAudioFormat(
                AudioFormat.Builder()
                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                    .setSampleRate(RATE)
                    .setChannelMask(AudioFormat.CHANNEL_IN_MONO)
                    .build(),
            )
            .setBufferSizeInBytes(maxOf(min, FRAME_BYTES * 4))
            .build()
        if (r.state != AudioRecord.STATE_INITIALIZED) {
            r.release()
            throw IllegalStateException("audio_failed")
        }
        if (!raw) {
            try {
                if (AcousticEchoCanceler.isAvailable()) {
                    aec = AcousticEchoCanceler.create(r.audioSessionId)
                    aec?.setEnabled(true)
                }
                if (NoiseSuppressor.isAvailable()) {
                    ns = NoiseSuppressor.create(r.audioSessionId)
                    ns?.setEnabled(true)
                }
            } catch (e: RuntimeException) {
                releaseEffects()
            }
        }
        try {
            r.startRecording()
        } catch (e: IllegalStateException) {
            releaseEffects()
            r.release()
            throw e
        }
        if (r.recordingState != AudioRecord.RECORDSTATE_RECORDING) {
            releaseEffects()
            r.release()
            throw IllegalStateException("audio_failed")
        }
        record = r
        val th = Thread({ captureLoop(r) }, "ripplo-audio-in")
        th.isDaemon = true
        captureThread = th
        th.start()
    }

    private fun captureLoop(r: AudioRecord) {
        Process.setThreadPriority(Process.THREAD_PRIORITY_URGENT_AUDIO)
        val buf = ByteArray(FRAME_BYTES)
        try {
            while (record === r) {
                var off = 0
                while (off < FRAME_BYTES && record === r) {
                    val n = r.read(buf, off, FRAME_BYTES - off)
                    if (n < 0) return
                    off += n
                }
                if (off < FRAME_BYTES) return
                val frame = if (muted) ByteArray(FRAME_BYTES) else buf.copyOf()
                Call.post {
                    val s = sink
                    if (s != null) s.success(frame)
                }
            }
        } catch (e: IllegalStateException) {
        }
    }

    private fun backlogFrames(t: AudioTrack): Long =
        writtenFrames - (t.playbackHeadPosition.toLong() and 0xFFFFFFFFL)

    private fun playLoop(t: AudioTrack) {
        Process.setThreadPriority(Process.THREAD_PRIORITY_URGENT_AUDIO)
        var started = false
        var primed = 0
        try {
            while (track === t) {
                val c = queue.poll(20, TimeUnit.MILLISECONDS)
                if (c == null) {
                    if (started && backlogFrames(t) <= 0) {
                        t.pause()
                        started = false
                        primed = 0
                    }
                    continue
                }
                queuedBytes.addAndGet(-c.size)
                var off = 0
                while (off < c.size && track === t) {
                    val n = t.write(c, off, c.size - off)
                    if (n <= 0) break
                    off += n
                    writtenFrames += n / 2
                }
                if (!started) {
                    primed += c.size
                    if (primed >= PRIME_BYTES) {
                        t.play()
                        started = true
                    }
                }
            }
        } catch (e: IllegalStateException) {
        } catch (e: InterruptedException) {
        }
    }

    private fun play(pcm: ByteArray) {
        val t = track ?: return
        val backlog = maxOf(0L, backlogFrames(t)) + queuedBytes.get() / 2
        if (backlog > DROP_FRAMES) return
        queuedBytes.addAndGet(pcm.size)
        queue.add(pcm)
    }

    private fun releaseEffects() {
        try {
            aec?.release()
        } catch (ignored: RuntimeException) {
        }
        try {
            ns?.release()
        } catch (ignored: RuntimeException) {
        }
        aec = null
        ns = null
    }

    private fun stopCapture() {
        val r = record
        record = null
        if (r != null) {
            try {
                r.stop()
            } catch (ignored: IllegalStateException) {
            }
        }
        captureThread?.let {
            try {
                it.join(300)
            } catch (ignored: InterruptedException) {
            }
        }
        captureThread = null
        releaseEffects()
        r?.release()
    }

    private fun stopTrack() {
        val t = track
        track = null
        if (t != null) {
            try {
                t.stop()
            } catch (ignored: IllegalStateException) {
            }
        }
        playThread?.let {
            try {
                it.join(300)
            } catch (ignored: InterruptedException) {
            }
        }
        playThread = null
        t?.release()
        queue.clear()
        queuedBytes.set(0)
    }

    @Suppress("DEPRECATION")
    private fun stopAll() {
        stopCapture()
        stopTrack()
        if (routed) {
            routed = false
            try {
                val am = ctx.getSystemService(Context.AUDIO_SERVICE) as AudioManager
                am.isSpeakerphoneOn = savedSpeaker
                am.mode = savedMode
            } catch (ignored: RuntimeException) {
            }
        }
    }

    companion object {
        private const val RATE = 48000
        private const val FRAME_BYTES = 960 * 2
        private const val PRIME_BYTES = RATE / 10 * 2
        private const val DROP_FRAMES = RATE * 400L / 1000
    }
}
