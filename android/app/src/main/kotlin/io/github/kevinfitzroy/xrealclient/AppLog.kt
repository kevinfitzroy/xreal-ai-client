package io.github.kevinfitzroy.xrealclient

import android.content.Context
import android.util.Log
import java.io.File
import java.io.FileWriter
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * 持久化文件日志 —— 解决「眼镜上闪退、手机没接 adb,崩溃栈和断连前后上下文全丢」的问题。
 *
 * - 落点:`getExternalFilesDir("logs")/app.log`(app 私有外存;minSdk34 = scoped storage,
 *   `adb pull /sdcard/Android/data/<pkg>/files/logs/app.log` 可直接拉,不需 run-as)。
 *   超 [MAX_BYTES] 滚动一份 `app.log.1`。
 * - 每条:时间 + 级别 + tag + **线程名**(分得清是哪条后台线程崩的)+ 文本(+ 异常全栈)。同时进 logcat。
 * - **启动重喷**:[init] 时把上一会话尾部重喷到 logcat(tag `AppLogPrev`)。重开 app 后只需
 *   `adb logcat -s AppLogPrev` 就能看「上次为什么崩」,无需碰 `/sdcard/Android/data` 或 run-as。
 * - **崩溃直写**:全局未捕获异常处理器(见 [XrealApp])在进程将死时调 [fatal] **同步**直写本文件
 *   (不经任何 executor —— 进程都要死了,异步写排不上)。
 *
 * 容量控制:只记生命周期 / 连接·认证·断开 / ASR 错误 / 崩溃。**绝不记逐字节/逐帧数据** —— 同步直
 * 写文件靠这个低频前提才便宜。
 */
object AppLog {
    private const val MAX_BYTES = 512 * 1024
    private const val TAG = "AppLog"
    private const val PREV = "AppLogPrev"

    private val lock = Any()
    private val ts = SimpleDateFormat("MM-dd HH:mm:ss.SSS", Locale.US)
    @Volatile private var logFile: File? = null

    /** 在 Application.onCreate 调用一次。先把上一会话尾部重喷 logcat,再开新会话。 */
    fun init(ctx: Context) {
        val dir = (ctx.getExternalFilesDir("logs") ?: File(ctx.filesDir, "logs")).apply { mkdirs() }
        val f = File(dir, "app.log")
        dumpTailToLogcat(f)
        synchronized(lock) { logFile = f }
        i(TAG, "==== session start (log=${f.absolutePath}) ====")
    }

    fun d(tag: String, msg: String) { Log.d(tag, msg); append("D", tag, msg, null) }
    fun i(tag: String, msg: String) { Log.i(tag, msg); append("I", tag, msg, null) }
    fun w(tag: String, msg: String, tr: Throwable? = null) { Log.w(tag, msg, tr); append("W", tag, msg, tr) }
    fun e(tag: String, msg: String, tr: Throwable? = null) { Log.e(tag, msg, tr); append("E", tag, msg, tr) }

    /** 崩溃路径专用:进程将死,同步直写,不依赖任何 executor。 */
    fun fatal(thread: Thread, e: Throwable) = append("F", "CRASH", "uncaught on thread '${thread.name}'", e)

    private fun append(level: String, tag: String, msg: String, tr: Throwable?) {
        val f = logFile ?: return
        synchronized(lock) {
            try {
                if (f.length() > MAX_BYTES) rotate(f)
                FileWriter(f, true).use { w ->
                    w.append(ts.format(Date())).append(' ').append(level).append('/').append(tag)
                        .append(" [").append(Thread.currentThread().name).append("] ")
                        .append(msg).append('\n')
                    if (tr != null) w.append(Log.getStackTraceString(tr)).append('\n')
                }
            } catch (_: Throwable) { /* 日志自身失败绝不能再抛(尤其崩溃路径) */ }
        }
    }

    private fun rotate(f: File) {
        runCatching {
            val bak = File(f.parentFile, "app.log.1")
            if (bak.exists()) bak.delete()
            f.renameTo(bak)
        }
    }

    /** 把上一会话(上次进程)日志尾部重喷 logcat —— 重开 app 后免 run-as 直接 `adb logcat` 复盘。 */
    private fun dumpTailToLogcat(f: File) {
        if (!f.exists()) return
        runCatching {
            val tail = f.readLines().takeLast(120)
            Log.i(PREV, "──── 上一会话尾部 ${tail.size} 行(完整见 ${f.absolutePath})────")
            tail.forEach { Log.i(PREV, it) }
            Log.i(PREV, "──── 上一会话尾部结束 ────")
        }
    }
}
