import Foundation
import Citadel

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

    /// 非交互 SSH exec 不读用户 profile,`PATH` 只有 `/usr/bin:/bin:/usr/sbin:/sbin` → macOS 上 tmux
    /// (`/usr/local/bin` 或 `/opt/homebrew/bin`)直接调会 exit 127 command not found(真机经跳板暴露,#20)。
    /// 不硬编码路径,改用**登录 shell 包一层**:`${SHELL:-/bin/sh} -lc '<cmd>'` 会 source profile
    /// (macOS 的 path_helper / Linux 的 /etc/profile),拿到与交互终端一致的 PATH,平台中立。
    private static func loginShell(_ cmd: String) -> String {
        "${SHELL:-/bin/sh} -lc \(shq(cmd))"
    }

    /// 投递逐字稿。成功返回远端文件绝对路径;失败返回 error。
    static func deliver(transcript: String, name: String, to t: Target) async -> Result<String, Error> {
        do {
            let conn = try await SshConnect.connect(target: t.host, via: t.via)
            do {
                let dir = "/tmp/xreal-voice"
                let remotePath = "\(dir)/\(remoteFilename(name))"

                // #20:Citadel jump tunnel 上 SFTP 不工作(经跳板的 host 完全传不进东西)。逐字稿是纯文本,
                // 改走 exec + 引号 heredoc 写远端文件 —— 和下面的 tmux send-keys 同一条 exec channel,跳板上正常。
                try await writeTextFileViaExec(transcript, to: remotePath, dir: dir, on: conn.target)

                let prompt = "这是我用语音录的一段话的转写,存到了 \(remotePath),先读它。它可能是一个产品想法、对最近工作的思考、一段多人讨论/头脑风暴,或别的——你结合本项目的背景,先弄清我想表达什么,再做最合适的回应(该整理就整理、该落成方案或任务就落、该一起讨论就讨论)。注意是语音转写,可能有同音错别字,按意图理解;多人对话里用「说话人N」区分不同的人。"
                // tmux 处于 copy-mode 时 send-keys 会打到翻页导航、报 command failed → 先探 pane_in_mode,
                // 在 mode 里就 -X cancel 退出,再注入。全在一条远端命令里顺序完成,无竞态。
                //
                // #29:文本和 Enter 之间 sleep。Codex/Claude 这类 TUI 有「粘贴检测」——紧跟一批快速涌入字节的
                // 换行被当多行输入的换行、不是提交;只有空闲后到达的独立 Enter 才算提交(虚拟键盘 Enter=CR 0x0D
                // 能提交、send-keys Enter 同样是 CR 却不行,差异就在时序)。sleep 让 Enter 成为离散按键。
                // 对 Claude 无害(本就能提交)。
                let s = shq(t.session)
                let inner = "if [ \"$(tmux display-message -p -t \(s) '#{pane_in_mode}' 2>/dev/null)\" = 1 ]; then tmux send-keys -t \(s) -X cancel; fi; tmux send-keys -t \(s) -l \(shq(prompt)); sleep 0.5; tmux send-keys -t \(s) Enter"
                _ = try await conn.target.executeCommand(loginShell(inner))

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

    /// 用一次 exec + **引号 heredoc** 把文本写到远端文件(替代在跳板上不通的 SFTP,#20)。引号定界符
    /// `<<'EOF'` → 内容原样写入,不做变量/命令展开;定界符撞了转写内容就加后缀避开。heredoc 内容不是
    /// 命令行参数,不受 ARG_MAX 限制,长逐字稿也安全。`mkdir -p` 建目录,`cat >` 截断写入。
    private static func writeTextFileViaExec(
        _ text: String, to remotePath: String, dir: String, on client: SSHClient
    ) async throws {
        var delim = "XREAL_VOICE_EOF"
        while text.contains(delim) { delim += "_x" }
        let body = text.hasSuffix("\n") ? text : text + "\n"   // 定界符须独占一行
        let cmd = "mkdir -p \(shq(dir)); cat > \(shq(remotePath)) <<'\(delim)'\n\(body)\(delim)\n"
        _ = try await client.executeCommand(cmd)
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
