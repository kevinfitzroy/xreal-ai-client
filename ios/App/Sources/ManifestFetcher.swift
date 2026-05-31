import Foundation
import Citadel
import Crypto
import NIOCore

/// Pulls each host's project list from `<basePath>/.xreal/projects.json` via a
/// short-lived independent exec channel (`cat`), mirroring Android's
/// HostClient.catFile + ManifestFetcher.parseManifest.
///
/// DUAL-CHANNEL (SPEC, Android's血换的架构): the manifest `cat` uses its own
/// SSHClient (connect → executeCommand → close), entirely separate from the
/// interactive PTY a project opens. We never scrape the manifest over the PTY.
enum ManifestFetcher {

    /// Connect to `host`, `cat` its manifest, parse it. Returns the host with its
    /// `projects` replaced by the manifest list; on any failure returns the host
    /// unchanged (keeps seed list — never blanks it). Hosts with no basePath are
    /// returned as-is (no live fetch).
    static func fetch(_ hosts: [HostConfig]) async -> [HostConfig] {
        var out: [HostConfig] = []
        for h in hosts {
            if h.basePath.isEmpty { out.append(h); continue }
            let base = h.basePath.hasSuffix("/") ? String(h.basePath.dropLast()) : h.basePath
            let path = "\(base)/.xreal/projects.json"
            if let raw = await catFile(host: h, path: path),
               let projects = parseManifest(raw, hostName: h.name) {
                var updated = h
                updated.projects = projects
                out.append(updated)
                NSLog("[ManifestFetcher] \(h.name): \(projects.count) projects from manifest")
            } else {
                out.append(h)   // unreachable / bad manifest → keep seed
                NSLog("[ManifestFetcher] \(h.name): manifest fetch failed → keep seed")
            }
        }
        return out
    }

    /// One-shot `cat` over an independent exec channel. ed25519 only (SPEC §5).
    private static func catFile(host h: HostConfig, path: String) async -> String? {
        do {
            let key = try Curve25519.Signing.PrivateKey(sshEd25519: h.ssh.privateKeyPem)
            let client = try await SSHClient.connect(
                host: h.ssh.host,
                port: h.ssh.port,
                authenticationMethod: .ed25519(username: h.ssh.user, privateKey: key),
                hostKeyValidator: .acceptAnything(),   // TOFU is a later phase; local rig only
                reconnect: .never
            )
            defer { Task { try? await client.close() } }
            // `cat` lives in /bin → no PATH prefix needed (unlike the tmux PTY path).
            // single-quote the path; manifest paths come from trusted host config.
            var buf = try await client.executeCommand("cat '\(path)' 2>/dev/null")
            return buf.readString(length: buf.readableBytes)
        } catch {
            NSLog("[ManifestFetcher] catFile(\(h.name)) failed: \(error)")
            return nil
        }
    }

    /// manifest JSON → projects. version != 1 / parse failure → nil (caller keeps seed).
    /// Mirrors Android ManifestFetcher.parseManifest: skips illegal/unsafe project entries.
    static func parseManifest(_ text: String, hostName: String) -> [ProjectConfig]? {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            NSLog("[ManifestFetcher] \(hostName): manifest parse failed")
            return nil
        }
        let ver = (obj["version"] as? Int) ?? 0
        guard ver == 1 else {
            NSLog("[ManifestFetcher] \(hostName): manifest version=\(ver) unsupported")
            return nil
        }
        let arr = (obj["projects"] as? [[String: Any]]) ?? []
        return arr.compactMap { p in
            let cfg = HostStore.parseProject(p)
            if cfg == nil {
                NSLog("[ManifestFetcher] \(hostName): skip illegal project \(p["session"] ?? "?")")
            }
            return cfg
        }
    }
}
