import Foundation
import Citadel
import NIOCore
import NIOSSH

/// One interactive PTY SSH session to a project's tmux. Mirrors Android's
/// SshConnection (connect/PTY/shell/resize/disconnect).
///
/// ARCHITECTURE (the load-bearing bit):
/// Citadel's `withPTY { inbound, outbound in ... }` exposes the stdin writer
/// (`outbound`, which carries `.changeSize`) ONLY inside the closure. But bridge
/// `onInput`/`onResize` arrive from outside. So we funnel BOTH through a single
/// `AsyncStream<PtyEvent>`; one consumer Task inside the closure switches
/// data→`write` / resize→`changeSize`. This (a) fixes resize (POC's was a no-op →
/// PTY stuck 80×24, tmux can't fill the screen) and (b) keeps all PTY writes on one
/// task = the single-writer discipline the SPEC demands.
///
/// SPEC §5: ed25519 only (Citadel signs it natively, no legacy ssh-rsa/SHA-1 issue).
final class SSHSession {
    enum PtyEvent {
        case data(Data)
        case resize(cols: Int, rows: Int)
    }

    /// Called (on an arbitrary task) with PTY output bytes. Caller hops to main.
    var onOutput: ((Data) -> Void)?
    /// Called once when the PTY loop ends (back-to-list, server hangup, error).
    var onClosed: (() -> Void)?

    private let eventStream: AsyncStream<PtyEvent>
    private let eventCont: AsyncStream<PtyEvent>.Continuation
    private var client: SSHClient?
    // Multi-hop (SPEC §5): when the host has a `via`, the jump client tunnels the target's
    // PTY channel and MUST be retained + closed alongside it (see SshConnect lifecycle note).
    private var jumpClient: SSHClient?
    private var runTask: Task<Void, Never>?
    private var label = "unbound"

    init() {
        var c: AsyncStream<PtyEvent>.Continuation!
        eventStream = AsyncStream<PtyEvent> { c = $0 }
        eventCont = c
    }

    /// Connect (ed25519) + open a PTY running the tmux attach command for `session`.
    /// `via` (SPEC §5) = the resolved jump host config when `h` is an internal host reached
    /// through a bastion; nil = direct. `onConnected` fires once the PTY closure is live;
    /// `onFailure` on connect error.
    func connect(host h: HostConfig, via: HostConfig? = nil, session: String, cols: Int, rows: Int,
                 onConnected: @escaping () -> Void,
                 onFailure: @escaping (String) -> Void) {
        let startup = Self.tmuxAttachCommand(session)
        label = "\(h.name)/\(session)\(via.map { " via=\($0.name)" } ?? "")"
        AgentLog.info("terminal", "connect start host=\(h.name) session=\(session) via=\(via?.name ?? "-")")
        runTask = Task {
            // `live` flips once the PTY is up. A throw BEFORE that = a real connect failure
            // (→ onFailure). A throw AFTER (Citadel's withPTY throws "Already closed" when the
            // remote drops, e.g. tmux kill-session) is a mid-session DROP, not a connect
            // failure — onClosed handles it; onFailure must stay silent or the user sees a
            // misleading "连接失败" on top of the correct "连接已断开".
            var live = false
            do {
                // Direct or ProxyJump (SshConnect picks; jump client tunnels the target PTY).
                let conn = try await SshConnect.connect(target: h, via: via)
                self.client = conn.target
                self.jumpClient = conn.jump
                let client = conn.target
                live = true
                AgentLog.info("terminal", "PTY opening host=\(h.name) session=\(session)")
                onConnected()
                try await self.runPTY(client: client, startup: startup, hostName: h.name, session: session, cols: cols, rows: rows)
            } catch {
                if !live {
                    AgentLog.error("terminal", "connect failed host=\(h.name) session=\(session): \(String(describing: error).prefix(180))")
                    onFailure("\(error)")
                } else {
                    AgentLog.warn("terminal", "PTY ended host=\(h.name) session=\(session): \(String(describing: error).prefix(180))")
                }
            }
            // The PTY loop ended (back-to-list close, server drop, or connect failure). The
            // tunnel is dead either way → close the jump client here so a mid-session drop
            // (where the VC's onClosed nils `ssh` without calling close()) can't leak it.
            // Idempotent with close()'s own teardown (Citadel close is safe to call twice).
            let jc = self.jumpClient
            self.jumpClient = nil
            try? await jc?.close()
            AgentLog.debug("terminal", "session closed host=\(h.name) session=\(session)")
            self.onClosed?()
        }
    }

    /// Enqueue keystrokes (bridge onInput). Fire-and-forget; ordered by the stream.
    func send(_ data: Data) { eventCont.yield(.data(data)) }

    /// Enqueue a window resize (bridge onResize / post-connect syncSize).
    func resize(cols: Int, rows: Int) { eventCont.yield(.resize(cols: cols, rows: rows)) }

    /// Tear down: finish the stream (→ writer Task ends) and close the client
    /// (→ inbound terminates → the reader loop exits → withPTY returns).
    func close() {
        AgentLog.debug("terminal", "close requested \(label)")
        eventCont.finish()
        let client = self.client
        let jump = self.jumpClient
        self.client = nil
        self.jumpClient = nil
        // Close target THEN jump (target's channel rides the jump tunnel; see SshConnect).
        Task { try? await client?.close(); try? await jump?.close() }
    }

    /// 一次性 exec 抓取:在**已有** PTY 连接上开一条侧 exec channel 跑 `command`,读全部 stdout 返回。
    /// 给 LLM 纠错抓 tmux 终端上下文用(`tmux capture-pane`)。复用连接,不新建 SSH(Citadel 同连接支持
    /// 多 channel,与 PTY 主通道独立)。未连接/失败 → nil(纠错侧据此省略终端上下文段,不报错)。
    func execCapture(_ command: String) async -> String? {
        guard let client = self.client else { return nil }
        do {
            var buf = try await client.executeCommand(command)
            return buf.readString(length: buf.readableBytes)
        } catch {
            AgentLog.warn("terminal", "execCapture failed: \(String(describing: error).prefix(120))")
            return nil
        }
    }

    private func runPTY(client: SSHClient, startup: String, hostName: String, session: String, cols: Int, rows: Int) async throws {
        let req = SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: true,
            term: "xterm-256color",
            terminalCharacterWidth: cols,
            terminalRowHeight: rows,
            terminalPixelWidth: 0,
            terminalPixelHeight: 0,
            terminalModes: SSHTerminalModes([:])
        )
        let openedAt = Date()
        try await client.withPTY(req) { [weak self] inbound, outbound in
            guard let self else { return }
            // Single consumer of the event stream → single PTY writer.
            let writer = Task {
                var outboundEvents = 0
                var outboundBytes = 0
                let writerStarted = Date()
                defer {
                    AgentLog.debug(
                        "terminal",
                        "PTY writer ended host=\(hostName) session=\(session) duration=\(Self.seconds(since: writerStarted)) events=\(outboundEvents) bytes=\(outboundBytes)"
                    )
                }
                // First input = the tmux startup line (login shell has narrow PATH;
                // our own probe showed `tmux=none` over non-interactive exec, so we
                // export PATH + locale then exec tmux). See tmuxAttachCommand.
                do {
                    try await outbound.write(ByteBuffer(string: startup))
                    outboundBytes += startup.utf8.count
                } catch {
                    AgentLog.warn("terminal", "PTY startup write failed host=\(hostName) session=\(session): \(String(describing: error).prefix(160))")
                    return
                }
                for await ev in self.eventStream {
                    switch ev {
                    case .data(let d):
                        do {
                            try await outbound.write(ByteBuffer(bytes: Array(d)))
                            outboundEvents += 1
                            outboundBytes += d.count
                        } catch {
                            AgentLog.warn("terminal", "PTY write failed host=\(hostName) session=\(session) bytes=\(d.count) sent=\(outboundBytes): \(String(describing: error).prefix(160))")
                            return
                        }
                    case .resize(let cols, let rows):
                        do {
                            try await outbound.changeSize(cols: cols, rows: rows,
                                                          pixelWidth: 0, pixelHeight: 0)
                        } catch {
                            AgentLog.warn("terminal", "PTY resize failed host=\(hostName) session=\(session) size=\(cols)x\(rows): \(String(describing: error).prefix(160))")
                        }
                    }
                }
            }
            // Pump PTY output → onOutput. Loop keeps closure (and channel) alive.
            var inboundChunks = 0
            var inboundBytes = 0
            var lastOutputAt: Date?
            do {
                for try await chunk in inbound {
                    switch chunk {
                    case .stdout(let buf), .stderr(let buf):
                        var b = buf
                        if let bytes = b.readBytes(length: b.readableBytes) {
                            inboundChunks += 1
                            inboundBytes += bytes.count
                            lastOutputAt = Date()
                            self.onOutput?(Data(bytes))
                        }
                    }
                }
                AgentLog.info(
                    "terminal",
                    "PTY inbound ended host=\(hostName) session=\(session) duration=\(Self.seconds(since: openedAt)) chunks=\(inboundChunks) bytes=\(inboundBytes) idle=\(Self.idle(lastOutputAt, openedAt: openedAt))"
                )
            } catch {
                AgentLog.warn(
                    "terminal",
                    "PTY inbound error host=\(hostName) session=\(session) duration=\(Self.seconds(since: openedAt)) chunks=\(inboundChunks) bytes=\(inboundBytes) idle=\(Self.idle(lastOutputAt, openedAt: openedAt)): \(String(describing: error).prefix(160))"
                )
                writer.cancel()
                throw error
            }
            writer.cancel()
        }
    }

    private static func seconds(since date: Date) -> String {
        String(format: "%.1fs", Date().timeIntervalSince(date))
    }

    private static func idle(_ lastOutputAt: Date?, openedAt: Date) -> String {
        guard let lastOutputAt else { return "no-output/\(seconds(since: openedAt))" }
        return seconds(since: lastOutputAt)
    }

    /// attach-or-create the project's tmux session under UTF-8, with a non-interactive PATH wide
    /// enough to find tmux. Mirrors Android MainActivity.tmuxAttachCommand **including** the
    /// half-page paging fallback conf (SPEC §6):iOS native 在 TerminalHostView 拦 Shift+↑/↓,
    /// 统一转 S-Up/S-Down 让 tmux copy-mode 滚;Claude Code 的 PageUp/PageDown 路径不稳定。
    /// scrollback 升到 50000,copy-mode highlight 调淡以减轻 SwiftTerm 重绘白块感。
    /// conf 用 base64 投递,避开 `;`/`"`/`#{}` 被外层 shell 解释。
    /// `session` MUST already be validated `[A-Za-z0-9_.-]` (ProjectConfig.isSessionNameSafe).
    /// LLM 纠错抓终端上下文:capture-pane 当前 session 活动 pane 可见 + 近 40 行回溯(纯文本,-p)。
    /// PATH 前缀同 tmuxAttachCommand(非交互 exec PATH 太窄找不到 tmux);失败 2>/dev/null → execCapture 得空串。
    /// `session` 须已校验 `[A-Za-z0-9_.-]`(ProjectConfig.isSessionNameSafe)。
    static func tmuxCaptureCommand(_ session: String) -> String {
        "export PATH=\"$PATH:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin\"; "
            + "tmux capture-pane -p -S -40 -t '\(session)' 2>/dev/null"
    }

    static func tmuxAttachCommand(_ session: String) -> String {
        let conf = [
            "source-file -q ~/.tmux.conf",                                  // -f 跳过默认加载 → 先带回用户配置
            "set -g history-limit 50000",
            "set -g mode-style 'fg=default,bg=default'",
            "bind -n S-Up \"copy-mode ; send-keys -X halfpage-up\"",
            "bind -n S-Down 'if -F \"#{pane_in_mode}\" \"send-keys -X halfpage-down\"'",
        ].joined(separator: "\n") + "\n"
        let b64 = Data(conf.utf8).base64EncodedString()
        let c = "/tmp/.xreal-tmux.conf"
        return "export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8; " +
            "export PATH=\"$PATH:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin\"; " +
            "echo \(b64) | base64 -d > \(c); " +
            "tmux source-file \(c) 2>/dev/null; " +           // 已运行 server:bindings 立即对现有 session 生效
            "exec tmux -u -f \(c) new -A -s '\(session)'\n"   // cold-start:server 出生即带 conf(50000 + bindings)
    }
}

enum TmuxModeProbe {
    private static let timeoutMs = 1_600

    static func paneInMode(host h: HostConfig, via: HostConfig?, session: String) async -> Bool? {
        guard ProjectConfig(session: session, name: session, type: .ssh, hotwords: []).isSessionNameSafe else {
            return nil
        }
        return await withTimeout(ms: timeoutMs) {
            await queryPaneInMode(host: h, via: via, session: session)
        }
    }

    private static func queryPaneInMode(host h: HostConfig, via: HostConfig?, session: String) async -> Bool? {
        do {
            let conn = try await SshConnect.connect(target: h, via: via)
            do {
                var buf = try await conn.target.executeCommand("tmux display-message -p -t '\(session)' '#{pane_in_mode}' 2>/dev/null")
                let text = buf.readString(length: buf.readableBytes)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                await conn.closeAll()
                AgentLog.debug("terminal", "tmux mode probe host=\(h.name) session=\(session) pane_in_mode=\(text ?? "-")")
                if text == "1" { return true }
                if text == "0" { return false }
                return nil
            } catch {
                await conn.closeAll()
                throw error
            }
        } catch {
            AgentLog.warn("terminal", "tmux mode probe failed host=\(h.name) session=\(session): \(String(describing: error).prefix(140))")
            return nil
        }
    }

    private actor ResumeOnce<T> {
        private var done = false
        func resume(_ cont: CheckedContinuation<T?, Never>, _ value: T?) {
            if done { return }
            done = true
            cont.resume(returning: value)
        }
    }

    private static func withTimeout<T: Sendable>(ms: Int, _ op: @escaping @Sendable () async -> T?) async -> T? {
        let gate = ResumeOnce<T>()
        return await withCheckedContinuation { (cont: CheckedContinuation<T?, Never>) in
            Task { await gate.resume(cont, await op()) }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
                await gate.resume(cont, nil)
            }
        }
    }
}
