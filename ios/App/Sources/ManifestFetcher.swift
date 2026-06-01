import Foundation
import Citadel
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

/// One host's resolved fetch outcome (Phase 3: emitted incrementally per host so the
/// list shows live hosts the instant they answer, not after the slowest/dead host).
/// `liveFetched=false` = no basePath, never probed (no reachability claim, never offline).
struct HostFetchResult {
    let host: HostConfig                       // projects refreshed from manifest, or seed on miss
    let status: [String: SessionState]
    let reachable: Bool                        // SSH connect+exec succeeded this round
    let liveFetched: Bool                      // had a basePath → was actually probed
}

enum ManifestFetcher {

    /// Per-host SSH connect+cat budget. Phase 3 (SPEC §9 robustness): a host that hangs
    /// on TCP connect (VPN dropped, blackholed IP) must NOT stall the whole list — we race
    /// the entire per-host unit (connect + both cats) against this deadline and, on timeout,
    /// render that host disconnected while every reachable host already showed up. Mirrors
    /// Android's CONNECT_TIMEOUT_MS (12s there); shorter here for snappier UX. We don't rely
    /// on Citadel/NIO honoring its own connect timeout against a blackhole — this is external.
    static let perHostTimeoutMs = 7_000

    /// Concurrent fetch (Phase 3). Each host is probed in its own child task with its own
    /// timeout + do/catch, so one dead host can't hang or cancel the others; results are
    /// reassembled in the ORIGINAL host order. `onHostResolved` (optional) fires on the main
    /// actor as each host lands → the VC can re-push incrementally (live hosts appear at
    /// ~connect latency, the dead host flips to disconnected only at the timeout). The
    /// aggregate `FetchResult` is still returned for callers that just want the final state.
    static func fetch(
        _ hosts: [HostConfig],
        onHostResolved: (@MainActor (HostFetchResult) -> Void)? = nil
    ) async -> FetchResult {
        // via (SPEC §5) is a host *name*; resolve it against the full list (mirrors Android
        // ManifestFetcher's `byName[it]`). Built once here, passed into each probe so a
        // via-host's manifest cat rides the jump tunnel just like its PTY does.
        let byName = Dictionary(hosts.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        // Probe all hosts concurrently; collect keyed by name to rebuild original order.
        let resolved: [String: HostFetchResult] = await withTaskGroup(of: HostFetchResult.self) { group in
            for h in hosts {
                let jump = h.via.flatMap { byName[$0] }   // nil via, or via→unknown name = direct
                group.addTask { await probe(host: h, via: jump) }
            }
            var acc: [String: HostFetchResult] = [:]
            for await r in group {
                acc[r.host.name] = r
                if let onHostResolved { await onHostResolved(r) }
            }
            return acc
        }

        var out: [HostConfig] = []
        var statusByHost: [String: [String: SessionState]] = [:]
        var reachable: Set<String> = []
        for h in hosts {   // original order, not completion order
            guard let r = resolved[h.name] else { out.append(h); continue }
            out.append(r.host)
            statusByHost[h.name] = r.status
            if r.reachable { reachable.insert(h.name) }
        }
        return FetchResult(hosts: out, statusByHost: statusByHost, reachable: reachable)
    }

    /// Probe ONE host, time-boxed. No basePath → return seed as-is, not live-fetched (never
    /// offline). Otherwise race connect+cat against `perHostTimeoutMs`; timeout or connect
    /// failure → seed projects, unreachable (→ disconnected badges). The whole unit is inside
    /// the timeout so a half-open host (connects, then stalls on cat) can't stall either.
    private static func probe(host h: HostConfig, via: HostConfig?) async -> HostFetchResult {
        if h.basePath.isEmpty {
            return HostFetchResult(host: h, status: [:], reachable: false, liveFetched: false)
        }
        let result: HostFetchResult? = await withTimeout(ms: perHostTimeoutMs) {
            await fetchOne(host: h, via: via)
        }
        guard let result else {
            NSLog("[ManifestFetcher] \(h.name): probe timed out (\(perHostTimeoutMs)ms) → offline, others unaffected")
            // timeout → seed projects, unreachable → disconnected badges
            return HostFetchResult(host: h, status: [:], reachable: false, liveFetched: true)
        }
        return result
    }

    /// One host's connect + both cats on a single SSH connection (SPEC "同一连接").
    /// connect failure → seed + unreachable. Connected but bad/missing manifest → seed +
    /// reachable (renders unknown, not offline).
    private static func fetchOne(host h: HostConfig, via: HostConfig?) async -> HostFetchResult {
        let base = h.basePath.hasSuffix("/") ? String(h.basePath.dropLast()) : h.basePath
        guard let conn = await connect(host: h, via: via) else {
            NSLog("[ManifestFetcher] \(h.name): connect failed → keep seed, host offline")
            return HostFetchResult(host: h, status: [:], reachable: false, liveFetched: true)
        }
        // Close BOTH target + jump (the via-host's cats rode the jump tunnel; SshConnect).
        defer { Task { await conn.closeAll() } }
        let rawManifest = await cat(conn.target, path: "\(base)/.xreal/projects.json")
        let rawStatus = await cat(conn.target, path: "\(base)/.xreal/status.json")
        let status = parseStatus(rawStatus)
        if let rawManifest, let projects = parseManifest(rawManifest, hostName: h.name) {
            var updated = h
            updated.projects = projects
            XrayDebugLog.append("manifest \(h.name): projects=\(projects.count) states=\(status.count)")
            NSLog("[ManifestFetcher] \(h.name): \(projects.count) projects, \(status.count) live states")
            return HostFetchResult(host: updated, status: status, reachable: true, liveFetched: true)
        }
        XrayDebugLog.append("manifest \(h.name): missing/bad states=\(status.count)")
        NSLog("[ManifestFetcher] \(h.name): manifest missing/bad → keep seed (reachable)")
        return HostFetchResult(host: h, status: status, reachable: true, liveFetched: true)
    }

    /// Single-shot continuation gate: the first of {op completes, timer fires} resumes;
    /// the loser's resume is dropped. An actor so the two racing Tasks can't double-resume.
    private actor ResumeOnce<T> {
        private var done = false
        func resume(_ cont: CheckedContinuation<T, Never>, _ value: T) {
            if done { return }
            done = true
            cont.resume(returning: value)
        }
    }

    /// Hard timeout that does NOT await the loser. `op` runs in an UNSTRUCTURED Task, so this
    /// returns the instant the timer fires even if `op` ignores cancellation — a blackholed
    /// TCP connect (192.0.2.x, VPN-down) doesn't honor cooperative cancellation, so a task
    /// group (which awaits all children on teardown) would block here. The orphaned connect
    /// lingers until the OS connect timeout (~75s) then self-cleans; it's bound to nothing.
    /// Returns nil if the timeout wins. This is the load-bearing "dead host can't hang the
    /// list" mechanism (SPEC §9).
    private static func withTimeout<T: Sendable>(
        ms: Int, _ op: @escaping @Sendable () async -> T
    ) async -> T? {
        let gate = ResumeOnce<T?>()
        return await withCheckedContinuation { (cont: CheckedContinuation<T?, Never>) in
            Task { let r = await op(); await gate.resume(cont, r) }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
                await gate.resume(cont, nil)
            }
        }
    }

    /// Open one SSH connection to the host (direct, or via the jump host when `via` is set —
    /// SPEC §5). ed25519 only. nil on any connect error (jump unreachable / target auth fail).
    /// Returns the target+jump pair so the caller closes both.
    private static func connect(host h: HostConfig, via: HostConfig?) async -> SshConnect.Connected? {
        do {
            let through = via.map { " via \($0.name)" } ?? ""
            NSLog("[ManifestFetcher] connecting \(h.name)\(through)…")   // visible while a dead host hangs
            let conn = try await SshConnect.connect(target: h, via: via)
            XrayDebugLog.append("ssh connected \(h.name)\(through)")
            return conn
        } catch {
            XrayDebugLog.append("ssh failed \(h.name): \(String(describing: error).prefix(160))")
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
