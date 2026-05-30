package io.github.kevinfitzroy.xrealclient

import android.app.Application

/**
 * Application 子类 —— 只为两件事存在:
 *   1. 尽早 [AppLog.init](进程一起来就开文件日志,并把上一会话尾部重喷 logcat);
 *   2. 装**全局未捕获异常处理器** —— 后台线程(ssh-io / pty-reader / ssh-connect / ASR WS reader)
 *      任一抛未捕获异常,默认行为是直接杀进程(=用户看到的「闪退」)却不留痕迹。这里在进程将死前
 *      把崩溃线程 + 全栈同步写进文件,再链回系统默认处理器(照常弹崩溃 / 杀进程,不改变既有行为)。
 *
 * 在 AndroidManifest 的 <application android:name=".XrealApp"> 注册。
 */
class XrealApp : Application() {
    override fun onCreate() {
        super.onCreate()
        AppLog.init(this)
        val prev = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { t, e ->
            runCatching { AppLog.fatal(t, e) }
            prev?.uncaughtException(t, e)   // 链回系统默认:不吞崩溃,只是先留底
        }
        AppLog.i("XrealApp", "process onCreate, global uncaught handler installed")
    }
}
