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
                onConnected()
                try await self.runPTY(client: client, startup: startup, cols: cols, rows: rows)
            } catch {
                if !live { onFailure("\(error)") }   // only a pre-go-live error is a connect failure
            }
            // The PTY loop ended (back-to-list close, server drop, or connect failure). The
            // tunnel is dead either way → close the jump client here so a mid-session drop
            // (where the VC's onClosed nils `ssh` without calling close()) can't leak it.
            // Idempotent with close()'s own teardown (Citadel close is safe to call twice).
            let jc = self.jumpClient
            self.jumpClient = nil
            try? await jc?.close()
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
        eventCont.finish()
        let client = self.client
        let jump = self.jumpClient
        self.client = nil
        self.jumpClient = nil
        // Close target THEN jump (target's channel rides the jump tunnel; see SshConnect).
        Task { try? await client?.close(); try? await jump?.close() }
    }

    private func runPTY(client: SSHClient, startup: String, cols: Int, rows: Int) async throws {
        let req = SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: true,
            term: "xterm-256color",
            terminalCharacterWidth: cols,
            terminalRowHeight: rows,
            terminalPixelWidth: 0,
            terminalPixelHeight: 0,
            terminalModes: SSHTerminalModes([:])
        )
        try await client.withPTY(req) { [weak self] inbound, outbound in
            guard let self else { return }
            // Single consumer of the event stream → single PTY writer.
            let writer = Task {
                // First input = the tmux startup line (login shell has narrow PATH;
                // our own probe showed `tmux=none` over non-interactive exec, so we
                // export PATH + locale then exec tmux). See tmuxAttachCommand.
                try? await outbound.write(ByteBuffer(string: startup))
                for await ev in self.eventStream {
                    switch ev {
                    case .data(let d):
                        try? await outbound.write(ByteBuffer(bytes: Array(d)))
                    case .resize(let cols, let rows):
                        try? await outbound.changeSize(cols: cols, rows: rows,
                                                       pixelWidth: 0, pixelHeight: 0)
                    }
                }
            }
            // Pump PTY output → onOutput. Loop keeps closure (and channel) alive.
            for try await chunk in inbound {
                switch chunk {
                case .stdout(let buf), .stderr(let buf):
                    var b = buf
                    if let bytes = b.readBytes(length: b.readableBytes) {
                        self.onOutput?(Data(bytes))
                    }
                }
            }
            writer.cancel()
        }
    }

    /// attach-or-create the project's tmux session under UTF-8, with a non-interactive PATH wide
    /// enough to find tmux. Mirrors Android MainActivity.tmuxAttachCommand **including** the
    /// half-page paging fallback conf (SPEC §6):iOS native 主路径在 TerminalHostView 拦 Shift+↑/↓
    /// 发 PageUp/PageDown 给 Claude/TUI 自己滚动,避免进入 tmux copy-mode;这里保留 tmux 绑定作兜底。
    /// scrollback 升到 50000。
    /// conf 用 base64 投递,避开 `;`/`"`/`#{}` 被外层 shell 解释。
    /// `session` MUST already be validated `[A-Za-z0-9_.-]` (ProjectConfig.isSessionNameSafe).
    static func tmuxAttachCommand(_ session: String) -> String {
        let conf = [
            "source-file -q ~/.tmux.conf",                                  // -f 跳过默认加载 → 先带回用户配置
            "set -g history-limit 50000",
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
