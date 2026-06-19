import Foundation
import Darwin

/// **崩溃/异常收集**(issue #35)—— 镜像 Android `AppLog`/`AppLogPrev`:崩溃落盘,**下次启动**重喷到
/// `AgentLog`(进 LogPanel),做到"重开后看上次为啥崩"。零依赖、非生产级(非 PLCrashReporter),够事后复盘。
///
/// 两条捕获路径:
/// - `NSSetUncaughtExceptionHandler`:捕 ObjC/`NSException`(name/reason/`callStackSymbols`),**非信号上下文**,可用 Foundation。
/// - signal handlers(SIGABRT/SEGV/BUS/ILL/FPE/TRAP):捕 Swift `fatalError`/precondition 等。**信号上下文必须 async-signal-safe** →
///   只用 `open`/`write`/`backtrace_symbols_fd`(直写 fd,不 malloc),路径/缓冲在 install 时预备好的全局里,handler 里零 Swift 分配。
///
/// 安全性:handler **仅在崩溃时 fire**,不影响正常运行;最坏=崩中崩日志缺失,不比现状差。
enum CrashReporter {

    static var crashFileURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("agent-logs/last-crash.log")
    }

    /// 在 app 启动最早处调用(`didFinishLaunching` 第一行)。
    static func install() {
        surfaceLastCrash()   // 先把上次崩溃重喷 + 清掉,再装新 handler

        let url = crashFileURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // 预备 signal handler 用的全局(handler 不能有捕获,只能读全局;此处一次性分配,进程内长存)
        crashLogPath = strdup(url.path)
        crashSigHeader = strdup("\n=== CRASH (fatal signal) ===\n")
        crashBacktraceBuf = UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(capacity: Int(crashBacktraceCap))

        NSSetUncaughtExceptionHandler(crashExceptionHandler)
        for sig in [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGTRAP] {
            signal(sig, crashSignalHandler)
        }
        AgentLog.info("crash", "reporter installed")
    }

    /// NSException 路径专用:追加写崩溃文件(非信号上下文,可用 Foundation)。
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

    /// 启动时:若有上次崩溃记录 → 重喷到 AgentLog(进 LogPanel,同 Android `AppLogPrev`)→ 清掉。
    private static func surfaceLastCrash() {
        let url = crashFileURL
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        AgentLog.error("crash", "上次会话崩溃记录:\n" + text.trimmingCharacters(in: .whitespacesAndNewlines))
        try? FileManager.default.removeItem(at: url)
    }
}

// MARK: - 顶层 @convention(c) handler(无捕获,只能读全局)

private var crashLogPath: UnsafeMutablePointer<CChar>?
private var crashSigHeader: UnsafeMutablePointer<CChar>?
private var crashBacktraceBuf: UnsafeMutablePointer<UnsafeMutableRawPointer?>?
private let crashBacktraceCap: Int32 = 128

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

/// 信号捕获 —— **async-signal-safe**:只用 open/write/backtrace_symbols_fd,零 Swift 分配。写完恢复默认 handler 并 re-raise。
private func crashSignalHandler(_ sig: Int32) {
    if let path = crashLogPath {
        let fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        if fd >= 0 {
            if let hdr = crashSigHeader { _ = write(fd, hdr, strlen(hdr)) }
            if let buf = crashBacktraceBuf {
                let n = backtrace(buf, crashBacktraceCap)
                backtrace_symbols_fd(buf, n, fd)   // 直写 fd,不 malloc
            }
            close(fd)
        }
    }
    signal(sig, SIG_DFL)   // 恢复默认 → re-raise 让系统照常记录崩溃
    raise(sig)
}
