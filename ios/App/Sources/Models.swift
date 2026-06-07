import Foundation

/// Agent Station data model — Host (level 1) → Project (level 2). Mirrors Android's
/// AgentModels.kt. Config comes from hosts.json (SPEC §8); the project list's
/// source of truth is the per-host manifest (`<basePath>/.xreal/projects.json`).

enum ProjectType: String {
    case ssh, claude, codex, agent, maestro

    init?(raw: String) { self.init(rawValue: raw.lowercased()) }

    /// AI-agent class (claude/codex/agent/maestro) vs bare ssh shell. Drives the 🎤 voice
    /// marker (§4), tmux residency (§5), delegation eligibility, correction context.
    var isAiAgent: Bool { self != .ssh }
}

/// One remote project = a persistent tmux session + a type.
struct ProjectConfig {
    let session: String
    let name: String
    let type: ProjectType
    let hotwords: [String]

    /// Session names are interpolated into shell commands — only trust safe chars.
    var isSessionNameSafe: Bool {
        !session.isEmpty && session.range(of: "^[A-Za-z0-9_.-]+$", options: .regularExpression) != nil
    }
}

/// SSH access params for a host.
struct SshConfig {
    let host: String
    let port: Int
    let user: String
    /// OpenSSH ed25519 private key text (SPEC §5: always ed25519).
    let privateKeyPem: String
}

/// Host-owned tunnel for SSH-over-443 (SPEC §5.1). `url` is a standard `vmess://` share link.
struct ProxyConfig {
    let name: String
    let localPort: Int
    let url: String
}

/// One host = SSH params + base path + that host's project list.
struct HostConfig {
    let name: String
    let addr: String          // display alias; real IP never shown in UI (SPEC §8)
    let ssh: SshConfig
    var projects: [ProjectConfig]
    /// Maestro work root; manifest at `<basePath>/.xreal/projects.json`. Empty = no live-fetch.
    let basePath: String
    let via: String?          // multi-hop jump host name
    /// SSH-over-443 tunnel. If this host has `via`, tunnel ownership follows the via host.
    let proxy: ProxyConfig?
}

/// One session's live state (written by Claude Code hooks → status.json). `since` =
/// server epoch seconds it entered that state; the client computes age from it.
/// Mirrors Android's SessionState (ManifestFetcher.kt).
struct SessionState {
    let state: String   // working | waiting | needs-permission | disconnected | unknown
    let since: Int      // epoch seconds (0 = absent)
}

// MARK: - setHosts JSON serialization
// Produces the exact shape index.html's `window.setHosts` expects (mirrors Android's
// StatusPoller.staticListJson): [{name,addr,up,projects:[{session,name,type,...,state?,since,loading}]}].
// index.html's statusFor(p) keys off p.loading > p.state > legacy status; ageText(p)
// off p.since. So Phase 2's whole job is emitting state/since/loading per SPEC §3.
enum DeckJSON {
    /// Serialize the deck, merging hooks live state (`statusByHost`) per SPEC §3:
    ///   - `reachable == nil` → not yet probed (initial seed push): omit `state`, set
    ///     `loading` so JS shows a spinner.
    ///   - host has a non-blank basePath but is NOT in `reachable` → all its projects
    ///     `disconnected` (SPEC §3 rule 1).
    ///   - reachable + status.json has the session → use the reported state (rule 2).
    ///   - reachable + no record → `unknown` (no badge; rule 3, no capture-pane fallback).
    /// `probed` (Phase 3) = the set of hosts whose probe has landed this round. `nil` means
    /// "treat every host as still loading" (the initial seed push). A host present in the set
    /// renders its real state; a host absent keeps a spinner — so live hosts show up while a
    /// dead host is still timing out, instead of the whole list flipping at once.
    static func hostsArray(
        _ hosts: [HostConfig],
        loading: Bool = false,
        statusByHost: [String: [String: SessionState]] = [:],
        reachable: Set<String>? = nil,
        probed: Set<String>? = nil
    ) -> String {
        let arr: [[String: Any]] = hosts.map { h in
            let hostStatus = statusByHost[h.name] ?? [:]
            // Per-host loading: the global `loading` (initial seed) OR this host not yet probed.
            let hostLoading = loading || (probed != nil && !probed!.contains(h.name))
            // Only hosts we actually try to live-fetch (non-blank basePath) can go offline;
            // a blank-basePath host is never probed, so never marked disconnected.
            let unreachable = reachable != nil && !h.basePath.isEmpty && !(reachable!.contains(h.name))
            let projects: [[String: Any]] = h.projects.map { p in
                let live: SessionState? = hostStatus[p.session]
                let state: String? = {
                    if reachable == nil { return nil }          // unprobed: JS falls back to seed logic
                    if hostLoading { return nil }               // this host still spinning → no badge yet
                    if unreachable { return "disconnected" }
                    return live?.state ?? "unknown"
                }()
                var o: [String: Any] = [
                    "session": p.session,
                    "name": p.name,
                    "type": p.type.rawValue,   // ssh|claude|agent|maestro — matches JS ICONS keys
                    "status": "idle",
                    "age": "",                 // JS computes its own age from since; this is the legacy field
                    "loading": hostLoading,    // cold first-load / not-yet-probed: spinner until status arrives
                    "preview": NSNull(),
                ]
                // since MUST be a JSON number (epoch seconds); ageText does now/1000 - since,
                // a string would yield NaN and silently drop the age.
                o["since"] = live?.since ?? 0
                if let state { o["state"] = state }   // omit when unprobed → JS uses on-duty/seed logic
                return o
            }
            return [
                "name": h.name,
                "addr": h.addr,
                "proxy": h.proxy?.name ?? "",
                // While a host is still loading, don't pre-flag it down — only a resolved,
                // confirmed-unreachable host shows the red header dot.
                "up": hostLoading || !unreachable,
                "projects": projects,
            ]
        }
        let data = try? JSONSerialization.data(withJSONObject: arr, options: [])
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }
}
