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
/// `fetch` output: hosts with projects refreshed from each manifest + per-host
/// live status (session → state, from status.json) + the set of hosts we reached
/// this round (failed-to-reach hosts → their projects render disconnected).
/// Mirrors Android's FetchResult (ManifestFetcher.kt).
struct FetchResult {
    let hosts: [HostConfig]
    let statusByHost: [String: [String: SessionState]]   // hostName → (session → state)
    let reachable: Set<String>                            // hosts whose SSH connect+exec succeeded
}

enum ManifestFetcher {

    /// For each host: open ONE SSH connection (SPEC: "同一连接") and cat both
    /// `<basePath>/.xreal/projects.json` and `.../status.json` over it. A successful
    /// connection marks the host reachable (independent of whether either file parses,
    /// so a live host with a missing/garbage manifest renders `unknown`, not offline).
    /// Manifest parse failure → keep the host's seed projects (never blank). Hosts with
    /// no basePath are returned as-is (no live fetch, no reachability claim).
    static func fetch(_ hosts: [HostConfig]) async -> FetchResult {
        var out: [HostConfig] = []
        var statusByHost: [String: [String: SessionState]] = [:]
        var reachable: Set<String> = []
        for h in hosts {
            if h.basePath.isEmpty { out.append(h); continue }
            let base = h.basePath.hasSuffix("/") ? String(h.basePath.dropLast()) : h.basePath
            guard let conn = await connect(host: h) else {
                out.append(h)   // unreachable → keep seed; absence from `reachable` → disconnected
                NSLog("[ManifestFetcher] \(h.name): connect failed → keep seed, host offline")
                continue
            }
            defer { Task { try? await conn.close() } }
            reachable.insert(h.name)   // connected = reachable, even if files are missing/bad
            // manifest first, then status — both on the same connection.
            let rawManifest = await cat(conn, path: "\(base)/.xreal/projects.json")
            let rawStatus = await cat(conn, path: "\(base)/.xreal/status.json")
            statusByHost[h.name] = parseStatus(rawStatus)
            if let rawManifest, let projects = parseManifest(rawManifest, hostName: h.name) {
                var updated = h
                updated.projects = projects
                out.append(updated)
                NSLog("[ManifestFetcher] \(h.name): \(projects.count) projects, \(statusByHost[h.name]?.count ?? 0) live states")
            } else {
                out.append(h)   // reachable but bad/missing manifest → keep seed (still reachable → unknown badges)
                NSLog("[ManifestFetcher] \(h.name): manifest missing/bad → keep seed (reachable)")
            }
        }
        return FetchResult(hosts: out, statusByHost: statusByHost, reachable: reachable)
    }

    /// Open one SSH client to the host. ed25519 only (SPEC §5). nil on any connect error.
    private static func connect(host h: HostConfig) async -> SSHClient? {
        do {
            let key = try Curve25519.Signing.PrivateKey(sshEd25519: h.ssh.privateKeyPem)
            return try await SSHClient.connect(
                host: h.ssh.host,
                port: h.ssh.port,
                authenticationMethod: .ed25519(username: h.ssh.user, privateKey: key),
                hostKeyValidator: .acceptAnything(),   // TOFU is a later phase; local rig only
                reconnect: .never
            )
        } catch {
            NSLog("[ManifestFetcher] connect(\(h.name)) failed: \(error)")
            return nil
        }
    }

    /// `cat` a file over an existing connection. Each cat is independently guarded:
    /// `cat` of a missing file exits non-zero and Citadel throws → return nil here so a
    /// missing status.json yields an empty map (→ unknown) without touching reachability.
    /// `cat` lives in /bin → no PATH prefix; single-quote the path (paths are trusted config).
    private static func cat(_ client: SSHClient, path: String) async -> String? {
        do {
            var buf = try await client.executeCommand("cat '\(path)' 2>/dev/null")
            return buf.readString(length: buf.readableBytes)
        } catch {
            NSLog("[ManifestFetcher] cat '\(path)' failed (missing/non-zero exit): \(error)")
            return nil
        }
    }

    /// status.json (`{"timestamp":N,"sessions":[{"session","state","since"}, …]}`) →
    /// session → SessionState. Missing/blank/bad → empty map (→ client renders unknown).
    /// Note `sessions` is an ARRAY, not a map (SPEC §3). Mirrors Android parseStatus.
    static func parseStatus(_ text: String?) -> [String: SessionState] {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sessions = obj["sessions"] as? [[String: Any]] else {
            return [:]
        }
        var out: [String: SessionState] = [:]
        for s in sessions {
            guard let session = s["session"] as? String, !session.isEmpty,
                  let state = s["state"] as? String, !state.isEmpty else { continue }
            let since = (s["since"] as? Int) ?? (s["since"] as? NSNumber)?.intValue ?? 0
            out[session] = SessionState(state: state, since: since)
        }
        return out
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
