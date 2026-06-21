import Foundation

/// **崩溃/异常收集**(issue #35)—— 捕 ObjC/`NSException`,落盘,**下次启动**重喷到 `AgentLog`(进 LogPanel),
/// 做到"重开后看上次为啥崩"(镜像 Android `AppLog`/`AppLogPrev`)。
///
/// ⚠️ **只捕 NSException(ObjC 异常),不捕 Swift trap**(fatalError / 越界 / 强解包 nil 等走信号 SIGTRAP/SIGILL)。
/// 历史:曾用 signal handler 捕信号,但在**无调试器**的独立启动时,某个信号被 handler 截到 → 重抛杀进程 →
/// 崩溃循环 → **白屏**(调试器在场时信号被 lldb 截走,故"插线正常、拔线白屏")。signal 方案已撤。
/// Swift-trap 捕获需 **PLCrashReporter** 这类成熟方案(独立线程 + 备用栈 + 真正 async-signal-safe),留作后续。
/// NSException 捕获对 UIKit/KVO/未识别选择器等 ObjC 崩溃仍有效,且**绝对安全、不碰信号、不影响启动**。
enum CrashReporter {

    static var crashFileURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("agent-logs/last-crash.log")
    }

    /// 在 app 启动早期调用。
    static func install() {
        surfaceLastCrash()   // 先把上次崩溃重喷 + 清掉
        let url = crashFileURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        NSSetUncaughtExceptionHandler(crashExceptionHandler)
        AgentLog.info("crash", "reporter installed (NSException only)")
    }

    /// 追加写崩溃文件(NSException handler 非信号上下文,可用 Foundation)。
    static func appendToCrashFile(_ text: String) {
        let url = crashFileURL
        guard let data = text.data(using: .utf8) else { return }
        if let fh = try? FileHandle(forWritingTo: url) {
            defer { try? fh.close() }
            _ = try? fh.seekToEnd()
            try? fh.write(contentsOf: data)
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// 启动时:有上次崩溃记录 → 重喷到 AgentLog(进 LogPanel,同 Android `AppLogPrev`)→ 清掉。
    private static func surfaceLastCrash() {
        let url = crashFileURL
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        AgentLog.error("crash", "上次会话崩溃记录:\n" + text.trimmingCharacters(in: .whitespacesAndNewlines))
        try? FileManager.default.removeItem(at: url)
    }
}

/// ObjC/NSException 捕获 —— 非信号上下文,可安全用 Foundation。
private func crashExceptionHandler(_ exception: NSException) {
    let stack = exception.callStackSymbols.joined(separator: "\n")
    let text = """

    === CRASH (NSException) ===
    name: \(exception.name.rawValue)
    reason: \(exception.reason ?? "")
    \(stack)

    """
    CrashReporter.appendToCrashFile(text)
}
