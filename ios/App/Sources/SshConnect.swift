import Foundation
import Citadel
import Crypto

/// Multi-hop (ProxyJump) connect helper. The iOS equivalent of Android's `SshJump.kt`
/// (`JumpSpec` + `open(spec, target, port)` → LocalPortForwarder).
///
/// PORT NOTE — why this is ~30 lines and Android's is ~75: sshj has **no** native
/// ProxyJump, so Android bind a local `ServerSocket` and ran a `LocalPortForwarder`
/// thread, then SSH'd a second client to `127.0.0.1:localPort`. Citadel/SwiftNIO SSH
/// has the primitive built in: `SSHClient.jump(to:)` (Citadel/Client.swift) opens a
/// `directTCPIP` channel to `target:port` *through the jump client* and runs a full
/// second SSH handshake over it via `SSHClient.connect(on: channel, settings:)`. The
/// returned client is **end-to-end authenticated to the target** (the jump host only
/// relays the encrypted stream; it never holds target creds) — exactly the Android
/// guarantee, no manual socket plumbing. So there's no ServerSocket / port-forward
/// thread to port; the directTCPIP channel *is* the tunnel.
///
/// host key validation mirrors Android: jump connect = TOFU-class (here acceptAnything,
/// local rig only, same as the rest of the codebase); target rides the already-encrypted
/// jump tunnel so its host key is likewise acceptAnything.
///
/// LIFECYCLE (load-bearing): the jump client MUST be retained and closed alongside the
/// target — its session.channel carries the directTCPIP channel the target lives on.
/// Drop it and the tunnel dies, taking the target with it. So `connect` returns BOTH
/// clients; every caller closes target then jump (mirrors Android `sshJump?.close()`).
/// The jumped client's `connectionSettings.reconnect` defaults to `.never` (verified in
/// SSHConnectionPoolSettings) → a dropped tunnel will NOT auto-reconnect *directly* to
/// the internal host (which would bypass the jump and fail).
enum SshConnect {

    /// A connected target client plus the jump client that tunnels it (nil when direct).
    /// `closeAll()` tears both down in the right order.
    struct Connected {
        let target: SSHClient
        let jump: SSHClient?
        func closeAll() async {
            try? await target.close()
            try? await jump?.close()   // close jump AFTER target (target rides jump's channel)
        }
    }

    /// ed25519 auth method + acceptAnything validator for a host (SPEC §5). Throws on a
    /// malformed key (caller treats as a connect failure).
    private static func settings(for h: HostConfig) throws -> SSHClientSettings {
        let key = try Curve25519.Signing.PrivateKey(sshEd25519: h.ssh.privateKeyPem)
        var s = SSHClientSettings(
            host: h.ssh.host,
            port: h.ssh.port,
            authenticationMethod: { .ed25519(username: h.ssh.user, privateKey: key) },
            hostKeyValidator: .acceptAnything()   // TOFU later; local rig only (matches existing code)
        )
        s.connectTimeout = .seconds(12)           // mirrors Android CONNECT_TIMEOUT_MS
        return s
    }

    /// Connect to `target`, directly or — when `via` is non-nil — through it as a ProxyJump.
    /// On `via`: connect the jump host first, then `jump.jump(to: targetSettings)` opens the
    /// directTCPIP tunnel + second handshake. Any throw (bad key, jump unreachable, target
    /// auth fail) propagates; partial state (a live jump client when the target handshake
    /// fails) is cleaned up before rethrowing so we never leak a half-open jump connection.
    static func connect(target h: HostConfig, via: HostConfig?) async throws -> Connected {
        let targetSettings = try settings(for: h)
        guard let jh = via else {
            let c = try await SSHClient.connect(to: targetSettings)
            return Connected(target: c, jump: nil)
        }
        // Multi-hop: jump host first (its own ed25519), then tunnel to the target.
        let jumpClient = try await SSHClient.connect(to: try settings(for: jh))
        do {
            let targetClient = try await jumpClient.jump(to: targetSettings)
            return Connected(target: targetClient, jump: jumpClient)
        } catch {
            try? await jumpClient.close()   // target handshake failed — don't leak the jump
            throw error
        }
    }
}
