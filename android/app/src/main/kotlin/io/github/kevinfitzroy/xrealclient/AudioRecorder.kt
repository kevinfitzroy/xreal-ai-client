package io.github.kevinfitzroy.xrealclient

import android.annotation.SuppressLint
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.util.Log
import java.io.ByteArrayOutputStream

/**
 * 16kHz mono PCM_16BIT 录音,**流式**输出:录音线程把读到的 PCM 攒成 ~200ms 定长块,实时回吐给
 * [start] 的 onChunk(裸 PCM,无 WAV 头 —— 豆包流式接口 audio-only 包要的就是裸 PCM)。
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
    private var chunker: PcmChunker? = null
    @Volatile private var recording = false

    @SuppressLint("MissingPermission")  // 调用方保证已拿到 RECORD_AUDIO
    fun start(onChunk: (ByteArray) -> Unit) {
        if (recording) return
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
        val ch = PcmChunker(CHUNK_BYTES, onChunk).also { chunker = it }
        recordingThread = Thread({
            val buf = ByteArray(bufferSize)
            try {
                while (recording) {
                    val n = record?.read(buf, 0, buf.size) ?: -1
                    if (n > 0) ch.add(buf, n)
                    else if (n < 0) { Log.w(TAG, "AudioRecord.read=$n"); break }
                }
            } catch (e: Exception) {
                Log.w(TAG, "recording loop: ${e.message}")
            }
        }, "audio-recorder").also { it.start() }
    }

    /** 停止采集:join 录音线程后冲出尾块(线程已死,无并发),释放。 */
    fun stop() {
        if (!recording) return
        recording = false
        runCatching {
            record?.stop()
            record?.release()
        }
        recordingThread?.join(500)
        chunker?.flush()
        chunker = null
        record = null
        recordingThread = null
    }

    /** 取消:丢弃尾块,不回吐(用于 ESC / 重按)。 */
    fun cancel() {
        recording = false
        runCatching {
            record?.stop()
            record?.release()
        }
        recordingThread?.interrupt()
        chunker = null
        record = null
        recordingThread = null
    }

    companion object {
        private const val TAG = "AudioRecorder"
        /** 200ms @ 16kHz·16bit·mono = 6400 bytes(豆包推荐单包 200ms 性能最优)。 */
        private const val CHUNK_BYTES = 6400
    }
}

/**
 * 把任意大小的 PCM read 攒成固定 [size] 的块回吐给 [sink];尾部不足一块的留到 [flush]。
 * 纯逻辑、无 Android 依赖 —— 见 PcmChunkerTest。
 */
internal class PcmChunker(private val size: Int, private val sink: (ByteArray) -> Unit) {
    private val buf = ByteArrayOutputStream()

    fun add(data: ByteArray, len: Int) {
        buf.write(data, 0, len)
        if (buf.size() < size) return
        val all = buf.toByteArray()
        buf.reset()
        var off = 0
        while (all.size - off >= size) {
            sink(all.copyOfRange(off, off + size))
            off += size
        }
        if (off < all.size) buf.write(all, off, all.size - off)
    }

    /** 冲出尾部不足一块的残留(录音正常结束时调一次)。 */
    fun flush() {
        val rest = buf.toByteArray()
        buf.reset()
        if (rest.isNotEmpty()) sink(rest)
    }
}
