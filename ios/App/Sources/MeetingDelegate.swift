import Foundation
import Citadel
import NIOCore

/// 把一段**语音输入**逐字稿(产品想法 / 工作思考 / 多人讨论 / 会议…,不预设)委托给某个 AI-agent
/// subproject:SFTP 写到远端 `/tmp/xreal-voice/`,再 `tmux send-keys` 注入一句"读这个文件、结合项目
/// 背景先弄清我想表达什么、再做合适回应"的开放式 prompt。
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
                let dir = "/tmp/xreal-voice"
                let remotePath = "\(dir)/\(remoteFilename(name))"

                let sftp = try await conn.target.openSFTP()
                try? await sftp.createDirectory(atPath: dir)   // 已存在 → 忽略
                let file = try await sftp.openFile(filePath: remotePath, flags: [.write, .create, .truncate])
                try await file.write(ByteBuffer(bytes: Array(transcript.utf8)))
                try await file.close()
                try await sftp.close()

                let prompt = "这是我用语音录的一段话的转写,存到了 \(remotePath),先读它。它可能是一个产品想法、对最近工作的思考、一段多人讨论/头脑风暴,或别的——你结合本项目的背景,先弄清我想表达什么,再做最合适的回应(该整理就整理、该落成方案或任务就落、该一起讨论就讨论)。注意是语音转写,可能有同音错别字,按意图理解;多人对话里用「说话人N」区分不同的人。"
                // tmux 处于 copy-mode 时 send-keys 会打到翻页导航、报 command failed → 先探 pane_in_mode,
                // 在 mode 里就 -X cancel 退出,再注入。全在一条远端命令里顺序完成,无竞态。
                let s = shq(t.session)
                let cmd = "if [ \"$(tmux display-message -p -t \(s) '#{pane_in_mode}' 2>/dev/null)\" = 1 ]; then tmux send-keys -t \(s) -X cancel; fi; tmux send-keys -t \(s) -l \(shq(prompt)); tmux send-keys -t \(s) Enter"
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
        return "voice-\(f.string(from: Date()))-\(safe.isEmpty ? "rec" : safe).md"
    }

    /// 单引号包裹给远端 shell(session 名已校验安全,prompt 无单引号,这里仍做转义兜底)。
    private static func shq(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
