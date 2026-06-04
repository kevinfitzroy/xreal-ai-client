import Foundation

/// App ↔ Share Extension 之间的**共享音频收件箱**(走 App Group 容器)。
///
/// 用途:语音备忘录等分享进来的录音,先由 Share Extension 拷进这里「接收存起来」;主 app 之后
/// `pending()` 列出 → 转码(`AudioTranscoder`)→ 上传豆包。本类**两个 target 都编译**(主 app + 扩展),
/// 所以只依赖 Foundation,绝不引用任何 app-only 符号(AgentLog / SSH / UIKit)。
///
/// App Group `group.io.github.kevinfitzroy.xrealclient` 需在两端的 .entitlements 里都声明。
enum AudioInbox {

    static let appGroupID = "group.io.github.kevinfitzroy.xrealclient"

    /// 共享容器根(App Group 没配好 / 未授权时为 nil —— 调用方需容错)。
    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
    }

    /// 收件箱目录(惰性创建)。
    static var inboxURL: URL? {
        guard let c = containerURL else { return nil }
        let dir = c.appendingPathComponent("AudioInbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 把外部音频文件**拷贝**进收件箱(源 URL 多为临时/安全作用域,必须当场拷走)。
    /// 文件名前缀加时间戳避免碰撞;返回落地后的 URL。
    @discardableResult
    static func ingest(copyingFrom src: URL, suggestedName: String?) throws -> URL {
        guard let dir = inboxURL else {
            throw NSError(domain: "AudioInbox", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "App Group 容器不可用(\(appGroupID))"])
        }
        let base = sanitize(suggestedName ?? src.lastPathComponent)
        let name = "\(stamp())-\(base.isEmpty ? "audio" : base)"
        let dst = dir.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: dst)
        try FileManager.default.copyItem(at: src, to: dst)
        return dst
    }

    /// 收件箱里现存的文件,**新→旧**排序。
    static func pending() -> [URL] {
        guard let dir = inboxURL,
              let urls = try? FileManager.default.contentsOfDirectory(
                  at: dir, includingPropertiesForKeys: [.contentModificationDateKey],
                  options: [.skipsHiddenFiles]) else { return [] }
        return urls.sorted { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return da > db
        }
    }

    static func remove(_ url: URL) { try? FileManager.default.removeItem(at: url) }

    // MARK: - helpers

    private static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: Date())
    }

    /// 只保留 [A-Za-z0-9.-_],其它(含中文/空格)替成 _,避免落盘文件名问题。
    private static func sanitize(_ s: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
        return String(s.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
    }
}
