import Foundation

enum AgentLogLevel: Int, CaseIterable {
    case debug = 0
    case info = 1
    case warn = 2
    case error = 3

    var title: String {
        switch self {
        case .debug: return "DEBUG"
        case .info: return "INFO"
        case .warn: return "WARN"
        case .error: return "ERROR"
        }
    }
}

struct AgentLogEntry {
    let id = UUID()
    let date: Date
    let level: AgentLogLevel
    let category: String
    let message: String
}

extension Notification.Name {
    static let agentLogDidChange = Notification.Name("agentLogDidChange")
}

final class AgentLog {
    static let shared = AgentLog()

    private let lock = NSLock()
    private var items: [AgentLogEntry] = []
    private let maxEntries = 600
    private let maxFileBytes: UInt64 = 512 * 1024
    private let maxRotatedFiles = 3
    private let iso = ISO8601DateFormatter()

    private var logDir: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("agent-logs", isDirectory: true)
    }

    private var logFile: URL {
        logDir.appendingPathComponent("agent.log")
    }

    private init() {
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        items = loadPersistedEntries()
    }

    static func debug(_ category: String, _ message: String) { shared.append(.debug, category, message) }
    static func info(_ category: String, _ message: String) { shared.append(.info, category, message) }
    static func warn(_ category: String, _ message: String) { shared.append(.warn, category, message) }
    static func error(_ category: String, _ message: String) { shared.append(.error, category, message) }

    func log(_ level: AgentLogLevel, _ category: String, _ message: String) {
        append(level, category, message)
    }

    func snapshot() -> [AgentLogEntry] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }

    func clear() {
        lock.lock()
        items.removeAll()
        clearFiles()
        lock.unlock()
        NotificationCenter.default.post(name: .agentLogDidChange, object: self)
    }

    private func append(_ level: AgentLogLevel, _ category: String, _ message: String) {
        let entry = AgentLogEntry(date: Date(), level: level, category: category, message: message)
        let line = encode(entry)
        lock.lock()
        items.append(entry)
        if items.count > maxEntries {
            items.removeFirst(items.count - maxEntries)
        }
        appendLineToFile(line)
        lock.unlock()
        NSLog("[\(level.title)] [\(category)] \(message)")
        NotificationCenter.default.post(name: .agentLogDidChange, object: self)
    }

    private func encode(_ entry: AgentLogEntry) -> Data {
        let obj: [String: Any] = [
            "ts": iso.string(from: entry.date),
            "level": entry.level.title,
            "category": entry.category,
            "message": entry.message,
        ]
        let data = (try? JSONSerialization.data(withJSONObject: obj, options: [])) ?? Data()
        return data + Data("\n".utf8)
    }

    private func appendLineToFile(_ line: Data) {
        do {
            try FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
            try rotateIfNeeded(incomingBytes: UInt64(line.count))
            if FileManager.default.fileExists(atPath: logFile.path),
               let fh = try? FileHandle(forWritingTo: logFile) {
                defer { try? fh.close() }
                _ = try? fh.seekToEnd()
                _ = try? fh.write(contentsOf: line)
            } else {
                try line.write(to: logFile, options: .atomic)
            }
        } catch {
            NSLog("[ERROR] [log] persist failed: \(error)")
        }
    }

    private func rotateIfNeeded(incomingBytes: UInt64) throws {
        let size = ((try? FileManager.default.attributesOfItem(atPath: logFile.path)[.size]) as? NSNumber)?.uint64Value ?? 0
        guard size + incomingBytes > maxFileBytes else { return }
        for i in stride(from: maxRotatedFiles, through: 1, by: -1) {
            let src = rotatedURL(i)
            let dst = rotatedURL(i + 1)
            if i == maxRotatedFiles, FileManager.default.fileExists(atPath: src.path) {
                try? FileManager.default.removeItem(at: src)
            } else if FileManager.default.fileExists(atPath: src.path) {
                try? FileManager.default.removeItem(at: dst)
                try FileManager.default.moveItem(at: src, to: dst)
            }
        }
        if FileManager.default.fileExists(atPath: logFile.path) {
            try? FileManager.default.removeItem(at: rotatedURL(1))
            try FileManager.default.moveItem(at: logFile, to: rotatedURL(1))
        }
    }

    private func rotatedURL(_ index: Int) -> URL {
        logDir.appendingPathComponent("agent.log.\(index)")
    }

    private func clearFiles() {
        try? FileManager.default.removeItem(at: logFile)
        for i in 1...maxRotatedFiles {
            try? FileManager.default.removeItem(at: rotatedURL(i))
        }
    }

    private func loadPersistedEntries() -> [AgentLogEntry] {
        let urls = (1...maxRotatedFiles).reversed().map(rotatedURL) + [logFile]
        var out: [AgentLogEntry] = []
        for url in urls where FileManager.default.fileExists(atPath: url.path) {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") {
                if let entry = decodeLine(String(line)) { out.append(entry) }
            }
        }
        if out.count > maxEntries {
            out.removeFirst(out.count - maxEntries)
        }
        return out
    }

    private func decodeLine(_ line: String) -> AgentLogEntry? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ts = obj["ts"] as? String,
              let date = iso.date(from: ts),
              let levelRaw = obj["level"] as? String,
              let category = obj["category"] as? String,
              let message = obj["message"] as? String else {
            return nil
        }
        let level: AgentLogLevel
        switch levelRaw {
        case AgentLogLevel.debug.title: level = .debug
        case AgentLogLevel.info.title: level = .info
        case AgentLogLevel.warn.title: level = .warn
        case AgentLogLevel.error.title: level = .error
        default: level = .debug
        }
        return AgentLogEntry(date: date, level: level, category: category, message: message)
    }
}
