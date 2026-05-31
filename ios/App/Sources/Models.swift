import Foundation

/// Agent Deck data model — Host (level 1) → Project (level 2). Mirrors Android's
/// AgentModels.kt. Config comes from hosts.json (SPEC §8); the project list's
/// source of truth is the per-host manifest (`<basePath>/.xreal/projects.json`).

enum ProjectType: String {
    case ssh, claude, agent, maestro

    init?(raw: String) { self.init(rawValue: raw.lowercased()) }

    /// AI-agent class (Claude/agent/maestro) vs bare ssh shell. Drives the 🎤 voice
    /// marker (out of Phase 1) but kept for parity.
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

/// One host = SSH params + base path + that host's project list.
struct HostConfig {
    let name: String
    let addr: String          // display alias; real IP never shown in UI (SPEC §8)
    let ssh: SshConfig
    var projects: [ProjectConfig]
    /// Maestro work root; manifest at `<basePath>/.xreal/projects.json`. Empty = no live-fetch.
    let basePath: String
    let via: String?          // multi-hop jump host name (Phase 1: parsed, not used)
}

// MARK: - setHosts JSON serialization
// Produces the exact shape index.html's `window.setHosts` expects (mirrors
// StatusPoller.staticListJson on Android): [{name,addr,up,projects:[{session,name,type,status,age,preview}]}].
// Phase 1 has no live status (hooks/status.json is a later phase) so every project
// is emitted without a `state` field → JS falls back to its seed/on-duty logic and
// shows no spurious badge.
enum DeckJSON {
    static func hostsArray(_ hosts: [HostConfig]) -> String {
        let arr: [[String: Any]] = hosts.map { h in
            let projects: [[String: Any]] = h.projects.map { p in
                // shape matches index.html's setHosts/HOSTS (no `state` field in Phase 1 →
                // JS falls back to its seed/on-duty logic, shows no spurious status badge).
                [
                    "session": p.session,
                    "name": p.name,
                    "type": p.type.rawValue,   // ssh|claude|agent|maestro — matches JS ICONS keys
                    "status": "idle",
                    "age": "",
                    "preview": NSNull(),
                ]
            }
            return [
                "name": h.name,
                "addr": h.addr,
                "up": true,
                "projects": projects,
            ]
        }
        let data = try? JSONSerialization.data(withJSONObject: arr, options: [])
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }
}
