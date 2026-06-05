import Foundation
import Citadel
import NIOCore

/// 把一段会议逐字稿**委托**给某个 AI-agent subproject:SFTP 写到远端 `/tmp/xreal-meetings/`,
/// 再 `tmux send-keys` 往该 session 注入一句"读这个文件、结合项目背景整理成纪要"的 prompt。
///
/// 复用现有 SSH 栈(`SshConnect` 带 via 跳板 / proxy 隧道)。**零服务端增量**:只是客户端跑一次性
/// SFTP + tmux send-keys,不装任何常驻件。委托目标只该是 AI-agent 类(选择器已过滤掉 ssh shell)。
enum MeetingDelegate {

    struct Target {
        let host: HostConfig
        let via: HostConfig?
        let session: String
        let projectName: String
    }

    /// 投递逐字稿。成功返回远端文件绝对路径;失败返回 error。
    static func deliver(transcript: String, name: String, to t: Target) async -> Result<String, Error> {
        do {
            let conn = try await SshConnect.connect(target: t.host, via: t.via)
            do {
                let dir = "/tmp/xreal-meetings"
                let remotePath = "\(dir)/\(remoteFilename(name))"

                let sftp = try await conn.target.openSFTP()
                try? await sftp.createDirectory(atPath: dir)   // 已存在 → 忽略
                let file = try await sftp.openFile(filePath: remotePath, flags: [.write, .create, .truncate])
                try await file.write(ByteBuffer(bytes: Array(transcript.utf8)))
                try await file.close()
                try await sftp.close()

                let prompt = "这是一段会议/对话的转写,已存到 \(remotePath)。先读这个文件,再结合本项目的背景,帮我整理成一份会议纪要(提炼要点/决定/待办;说话人按上下文映射成真人)。"
                let cmd = "tmux send-keys -t \(shq(t.session)) -l \(shq(prompt)) && tmux send-keys -t \(shq(t.session)) Enter"
                _ = try await conn.target.executeCommand(cmd)

                await conn.closeAll()
                AgentLog.info("meeting", "delegated → \(t.host.name)/\(t.session) : \(remotePath)")
                return .success(remotePath)
            } catch {
                await conn.closeAll()
                throw error
            }
        } catch {
            AgentLog.error("meeting", "delegate failed \(t.host.name)/\(t.session): \(error)")
            return .failure(error)
        }
    }

    private static func remoteFilename(_ name: String) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"; f.locale = Locale(identifier: "en_US_POSIX")
        let bad = CharacterSet(charactersIn: "/\\:\u{0} ").union(.controlCharacters)
        let safe = String(name.unicodeScalars.map { bad.contains($0) ? "_" : Character($0) })
        return "meeting-\(f.string(from: Date()))-\(safe.isEmpty ? "rec" : safe).md"
    }

    /// 单引号包裹给远端 shell(session 名已校验安全,prompt 无单引号,这里仍做转义兜底)。
    private static func shq(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
