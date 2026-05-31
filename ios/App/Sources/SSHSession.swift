import Foundation
import Citadel
import Crypto
import NIOCore
import NIOSSH

/// M2 (stretch): a real SSH connection to a local throwaway sshd on 127.0.0.1,
/// using Citadel 0.12 (SwiftNIO SSH). Requests a PTY + interactive shell and pipes
/// PTY output to `onOutput`. Input is fed through an AsyncStream so the closure-scoped
/// `withPTY` stays alive for the lifetime of the session.
///
/// SECURITY: hardcoded to 127.0.0.1 + a throwaway key the POC harness drops into the
/// app's Documents dir. NEVER touches real hosts.
final class SSHSession {
    var onOutput: ((Data) -> Void)?

    private let inputContinuation: AsyncStream<Data>.Continuation
    private let inputStream: AsyncStream<Data>

    private init() {
        var cont: AsyncStream<Data>.Continuation!
        self.inputStream = AsyncStream<Data> { cont = $0 }
        self.inputContinuation = cont
    }

    static func connect(onConnected: @escaping (SSHSession) -> Void,
                        onFailure: @escaping (String) -> Void) {
        let fm = FileManager.default
        guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first else {
            onFailure("no documents dir"); return
        }
        let keyURL = docs.appendingPathComponent("poc_key")
        guard let keyText = try? String(contentsOf: keyURL, encoding: .utf8) else {
            onFailure("no throwaway key at Documents/poc_key (M2 not provisioned)")
            return
        }
        let user = (try? String(contentsOf: docs.appendingPathComponent("poc_user"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? NSUserName()
        // Port is configurable so the POC can target a throwaway sshd on a high port
        // (avoids touching the user's real ~/.ssh/authorized_keys on port 22).
        let port = (try? String(contentsOf: docs.appendingPathComponent("poc_port"), encoding: .utf8))
            .flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 22

        Task {
            do {
                let privateKey = try Insecure.RSA.PrivateKey(sshRsa: keyText)
                let client = try await SSHClient.connect(
                    host: "127.0.0.1",
                    port: port,
                    authenticationMethod: .rsa(username: user, privateKey: privateKey),
                    hostKeyValidator: .acceptAnything(),   // POC only
                    reconnect: .never
                )
                let session = SSHSession()
                onConnected(session)
                try await session.runPTY(client: client)
            } catch {
                onFailure("connect failed: \(error)")
            }
        }
    }

    func send(_ data: Data) {
        inputContinuation.yield(data)
    }

    func resize(cols: Int, rows: Int) {
        // PTY window-change not wired in POC (Citadel 0.12 exposes it on the channel;
        // out of scope for the echo/shell proof).
        _ = (cols, rows)
    }

    @available(iOS 13.0, macOS 15.0, *)
    private func runPTY(client: SSHClient) async throws {
        let req = SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: true,
            term: "xterm-256color",
            terminalCharacterWidth: 80,
            terminalRowHeight: 24,
            terminalPixelWidth: 0,
            terminalPixelHeight: 0,
            terminalModes: SSHTerminalModes([:])
        )
        try await client.withPTY(req) { [weak self] inbound, outbound in
            guard let self else { return }
            // Pump stdin from the AsyncStream into the PTY.
            let writer = Task {
                for await chunk in self.inputStream {
                    try? await outbound.write(ByteBuffer(bytes: Array(chunk)))
                }
            }
            // Read PTY output -> onOutput. Loop keeps the closure (and channel) alive.
            for try await output in inbound {
                switch output {
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
}
