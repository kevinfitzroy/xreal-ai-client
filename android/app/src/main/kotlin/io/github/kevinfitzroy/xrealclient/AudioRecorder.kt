package io.github.kevinfitzroy.xrealclient

import android.annotation.SuppressLint
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.util.Log
import java.io.ByteArrayOutputStream

/**
 * 16kHz mono PCM_16BIT 录音。start() 后启录音线程持续 read,stop() 返回完整 WAV byte 数组。
 *
 * WAV 包装:加 44 byte RIFF header,让豆包 ASR 直接接受 audio/wav。
 *
 * 需要 RECORD_AUDIO 权限 —— 调用方先确认。
 */
class AudioRecorder(
    val sampleRate: Int = 16000,
    val channels: Int = AudioFormat.CHANNEL_IN_MONO,
    val encoding: Int = AudioFormat.ENCODING_PCM_16BIT,
) {

    private val minBufferSize = AudioRecord.getMinBufferSize(sampleRate, channels, encoding)
    private val bufferSize = (minBufferSize * 2).coerceAtLeast(4096)

    private var record: AudioRecord? = null
    private var recordingThread: Thread? = null
    private val pcm = ByteArrayOutputStream()

    @Volatile private var recording = false

    @SuppressLint("MissingPermission")  // 调用方保证已拿到 RECORD_AUDIO
    fun start() {
        if (recording) return
        pcm.reset()
        record = AudioRecord(
            MediaRecorder.AudioSource.VOICE_RECOGNITION,
            sampleRate, channels, encoding, bufferSize,
        ).also { rec ->
            if (rec.state != AudioRecord.STATE_INITIALIZED) {
                Log.w(TAG, "AudioRecord init failed (state=${rec.state})")
                return
            }
            rec.startRecording()
        }
        recording = true
        recordingThread = Thread({
            val buf = ByteArray(bufferSize)
            try {
                while (recording) {
                    val n = record?.read(buf, 0, buf.size) ?: -1
                    if (n > 0) synchronized(pcm) { pcm.write(buf, 0, n) }
                    else if (n < 0) { Log.w(TAG, "AudioRecord.read=$n"); break }
                }
            } catch (e: Exception) {
                Log.w(TAG, "recording loop: ${e.message}")
            }
        }, "audio-recorder").also { it.start() }
    }

    /** @return WAV bytes(44 byte header + PCM body),失败返回空 array */
    fun stop(): ByteArray {
        if (!recording) return ByteArray(0)
        recording = false
        runCatching {
            record?.stop()
            record?.release()
        }
        recordingThread?.join(500)
        record = null
        recordingThread = null
        val pcmBytes = synchronized(pcm) { pcm.toByteArray() }
        return wrapWav(pcmBytes, sampleRate, channelCount = 1, bitsPerSample = 16)
    }

    /** 取消录音不返回数据(用于 ESC) */
    fun cancel() {
        recording = false
        runCatching {
            record?.stop()
            record?.release()
        }
        recordingThread?.interrupt()
        record = null
        recordingThread = null
        pcm.reset()
    }

    companion object {
        private const val TAG = "AudioRecorder"

        /** 包 PCM 成 WAV(44 byte header)。豆包 ASR 接受 audio/wav。 */
        fun wrapWav(
            pcm: ByteArray, sampleRate: Int, channelCount: Int, bitsPerSample: Int,
        ): ByteArray {
            val byteRate = sampleRate * channelCount * bitsPerSample / 8
            val blockAlign = channelCount * bitsPerSample / 8
            val dataSize = pcm.size
            val totalSize = 36 + dataSize
            val out = ByteArrayOutputStream(44 + dataSize)
            fun le16(v: Int) { out.write(v and 0xff); out.write((v shr 8) and 0xff) }
            fun le32(v: Int) {
                out.write(v and 0xff); out.write((v shr 8) and 0xff)
                out.write((v shr 16) and 0xff); out.write((v shr 24) and 0xff)
            }
            out.write("RIFF".toByteArray())
            le32(totalSize)
            out.write("WAVE".toByteArray())
            out.write("fmt ".toByteArray())
            le32(16)             // fmt chunk size
            le16(1)              // PCM
            le16(channelCount)
            le32(sampleRate)
            le32(byteRate)
            le16(blockAlign)
            le16(bitsPerSample)
            out.write("data".toByteArray())
            le32(dataSize)
            out.write(pcm)
            return out.toByteArray()
        }
    }
}
