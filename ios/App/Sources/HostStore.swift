import Foundation

/// Reads the Valet-installed `hosts.json` from the app's Documents dir and resolves
/// each host's private key file. Mirrors Android's SettingsStore.parseHosts.
///
/// staging shape (SPEC §8): legacy top-level host array, or `{hosts}`. SSH-over-443
/// tunnel config is owned by each host's inline `proxy` object, including a unique
/// localPort. Each host's `key` is a bare filename pointing at a sibling key file in
/// Documents/ (the iOS dev-injection channel = AirDrop/Open In import).
///
/// SECURITY (SPEC §8): `key` must be a bare filename (no path traversal); the key file
/// must contain `PRIVATE KEY` and be ≤8KB. Real IP only lives in `host`, never `addr`.
enum HostStore {
    static var documentsDir: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    }

    /// Lightweight current-config summary for the config page (host count + whether ASR creds
    /// exist). Counts *valid* hosts (same parse loadHosts uses) so the page matches the list.
    /// SECURITY: never surfaces key/token bytes — counts/booleans only.
    static func configSummary() -> (hosts: Int, asr: Bool) {
        let asr = FileManager.default.fileExists(atPath:
            documentsDir.appendingPathComponent("asr.json").path)
        return (hosts: loadHosts().count, asr: asr)
    }

    /// Parse `Documents/hosts.json`. Returns [] (→ index.html mock) if absent or invalid.
    static func loadHosts() -> [HostConfig] {
        let docs = documentsDir
        let file = docs.appendingPathComponent("hosts.json")
        guard let data = try? Data(contentsOf: file),
              let root = parseStoredRoot(data) else {
            NSLog("[HostStore] no hosts.json (or invalid) → empty (mock)")
            AgentLog.warn("config", "hosts.json missing or invalid")
            return []
        }
        let hosts = parseHosts(root.hosts, docsDir: docs)
        AgentLog.info("config", "hosts parsed valid=\(hosts.count) records=\(root.hosts.count)")
        return hosts
    }

    private struct StoredRoot {
        let hosts: [[String: Any]]
    }

    private static func parseStoredRoot(_ data: Data) -> StoredRoot? {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return nil }
        if let arr = json as? [[String: Any]] {
            return StoredRoot(hosts: arr)
        }
        guard let obj = json as? [String: Any] else { return nil }
        let hosts = obj["hosts"] as? [[String: Any]] ?? []
        return StoredRoot(hosts: hosts)
    }

    private static func parseHosts(_ records: [[String: Any]], docsDir: URL) -> [HostConfig] {
        var usedProxyPorts: [Int: String] = [:]
        var out: [HostConfig] = []
        for r in records {
            guard let h = parseHost(r, docsDir: docsDir) else { continue }
            if let proxy = h.proxy {
                if let other = usedProxyPorts[proxy.localPort] {
                    NSLog("[HostStore] skip host '\(h.name)': proxy localPort \(proxy.localPort) conflicts with '\(other)'")
                    AgentLog.error("config", "skip host \(h.name): proxy localPort \(proxy.localPort) conflicts with \(other)")
                    continue
                }
                usedProxyPorts[proxy.localPort] = h.name
            }
            out.append(h)
        }
        return out
    }

    private static func parseHost(_ o: [String: Any], docsDir: URL) -> HostConfig? {
        guard let name = o["name"] as? String, !name.isEmpty,
              let host = o["host"] as? String, !host.isEmpty,
              let user = o["user"] as? String, !user.isEmpty else {
            NSLog("[HostStore] skip host missing name/host/user")
            AgentLog.warn("config", "skip host missing name/host/user")
            return nil
        }
        let keyName = (o["key"] as? String) ?? ""
        guard let pem = readKeySafe(keyName, in: docsDir) else {
            NSLog("[HostStore] skip host '\(name)': bad/missing key '\(keyName)'")
            AgentLog.error("config", "skip host \(name): bad or missing key")
            return nil
        }
        let port = (o["port"] as? Int) ?? 22
        let addr = (o["addr"] as? String) ?? host   // alias only; real host hidden in UI
        let basePath = (o["basePath"] as? String) ?? ""
        let via = (o["via"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let proxy: ProxyConfig?
        do {
            proxy = try parseProxy(o["proxy"], hostName: name)
        } catch {
            NSLog("[HostStore] skip host '\(name)': \(error)")
            AgentLog.error("config", "skip host \(name): \(error)")
            return nil
        }
        let projects = (o["projects"] as? [[String: Any]] ?? []).compactMap(parseProject)
        return HostConfig(
            name: name, addr: addr,
            ssh: SshConfig(host: host, port: port, user: user, privateKeyPem: pem),
            projects: projects, basePath: basePath, via: via, proxy: proxy
        )
    }

    private static func parseProxy(_ raw: Any?, hostName: String) throws -> ProxyConfig? {
        guard let raw else { return nil }
        guard let o = raw as? [String: Any] else {
            throw ImportError.badProxy("proxy 必须是对象,不是共享 proxy 名")
        }
        let name = (o["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "\(hostName)-443"
        guard let url = o["url"] as? String, !url.isEmpty else {
            throw ImportError.badProxy("proxy 缺 url")
        }
        let localPort = (o["localPort"] as? Int) ?? (o["listenPort"] as? Int) ?? 0
        guard (1024...65535).contains(localPort) else {
            throw ImportError.badProxy("proxy.localPort 非法或缺失")
        }
        return ProxyConfig(name: name, localPort: localPort, url: url)
    }

    static func parseProject(_ p: [String: Any]) -> ProjectConfig? {
        guard let session = p["session"] as? String,
              let typeRaw = p["type"] as? String,
              let type = ProjectType(raw: typeRaw) else { return nil }
        let hotwords = (p["hotwords"] as? [String]) ?? []
        let cfg = ProjectConfig(
            session: session,
            name: (p["name"] as? String) ?? session,
            type: type, hotwords: hotwords
        )
        return cfg.isSessionNameSafe ? cfg : nil
    }

    /// Read a key file by bare name with path-traversal + sanity checks (SPEC §8).
    private static func readKeySafe(_ keyName: String, in docsDir: URL) -> String? {
        guard !keyName.isEmpty, !keyName.contains("/"), !keyName.contains("..") else {
            NSLog("[HostStore] key must be a bare filename: '\(keyName)'")
            AgentLog.warn("config", "reject key path: not a bare filename")
            return nil
        }
        let url = docsDir.appendingPathComponent(keyName)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int, size > 0, size <= 8192,
              let text = try? String(contentsOf: url, encoding: .utf8),
              text.contains("PRIVATE KEY") else {
            return nil
        }
        return text
    }

    // MARK: - Valet "Open in" import (SPEC §8 real-device channel)

    enum ImportError: Error, CustomStringConvertible {
        case unreadable, badJSON, noHosts, noContent, badProxy(String)
        var description: String {
            switch self {
            case .unreadable: return "无法读取导入文件"
            case .badJSON:    return "导入文件不是合法 JSON"
            case .noHosts:    return "导入文件没有合法的 host"
            case .noContent:  return "导入文件缺少 host / hosts / asr 任一字段"
            case .badProxy(let s): return s
            }
        }
    }

    /// Which content shape the file turned out to be, so the config page can compare the user's
    /// button intent against what actually imported (a 1-host *replace* and a 1-host *append* both
    /// report hosts:1 — counts alone can't tell them apart). Composable: a global file may also
    /// carry asr; `mode` is the host disposition, `asr` is an independent flag.
    enum ImportMode { case append, replace, asrOnly }

    /// Result of an import: the host disposition, how many hosts landed, whether ASR creds came too.
    struct ImportResult { let mode: ImportMode; let hosts: Int; let asr: Bool }

    /// Import a self-contained `.xrhosts` config bundle (AirDrop → "用 Agent Station 打开", or via the
    /// config page's document picker; SPEC §8 iOS real-device channel). Each inline PEM is written
    /// to `Documents/<safeName>.pem` (a BARE filename — readKeySafe rejects any `/`, 0600), `key` is
    /// rewritten to that filename and the inline PEM stripped, and the BARE array is atomically
    /// written to `Documents/hosts.json` (loadHosts casts to `[[String:Any]]`). Ports Android
    /// importStagingIfPresent validation: name sanitized `[^A-Za-z0-9_.-]→_`, PEM contains
    /// `PRIVATE KEY` and ≤8KB, atomic tmp→rename. SECURITY: never logs key/token bytes.
    ///
    /// Three import shapes, discriminated by the TYPE of the top-level field (not mere key
    /// presence — a host *record* carries a `host` STRING, while the single-host wrapper carries
    /// `host` as an OBJECT; we cast to tell them apart):
    ///   - top-level `host` (object)  → APPEND one host: merge into existing hosts.json, dedup by
    ///     `name` (new overwrites same-name). Existing entries' keys are already files — not re-validated.
    ///   - top-level `hosts` (array)  → REPLACE the whole list (the original Phase-5 behavior).
    ///   - top-level `asr` (object) with no host(s) → write asr.json only, leave hosts.json untouched.
    /// The three are composable: a global file may also carry `asr`. Returns what landed (mode +
    /// host count + asr flag) so the caller can phrase feedback and the config page can flag a
    /// button-intent mismatch. SECURITY: never logs key/token bytes — counts/masks only.
    @discardableResult
    static func importConfig(from url: URL) throws -> ImportResult {
        guard let data = try? Data(contentsOf: url) else { throw ImportError.unreadable }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw ImportError.badJSON
        }

        let docs = documentsDir
        // Clean any half-written artifacts from a prior crashed import (atomic .tmp leftovers).
        (try? FileManager.default.contentsOfDirectory(at: docs, includingPropertiesForKeys: nil))?
            .filter { $0.lastPathComponent.hasSuffix(".tmp") }
            .forEach { try? FileManager.default.removeItem(at: $0) }

        let singleHost = root["host"] as? [String: Any]   // OBJECT = single-host wrapper
        let hostsArr   = root["hosts"] as? [[String: Any]]
        let asrObj     = root["asr"] as? [String: Any]
        guard singleHost != nil || hostsArr != nil || asrObj != nil else {
            throw ImportError.noContent
        }

        // Decide host disposition. asr-only files skip hosts.json entirely.
        var mode: ImportMode = .asrOnly
        var hostCount = 0

        if let hostsArr {
            // REPLACE: stage every host, atomically swap the whole hosts.json (Phase-5 behavior).
            let staged = stageHosts(hostsArr, in: docs)
            guard !staged.isEmpty else { throw ImportError.noHosts }
            try validateProxyPorts(staged)
            try writeStoredHosts(staged, to: docs.appendingPathComponent("hosts.json"))
            mode = .replace; hostCount = staged.count
        } else if let singleHost {
            // APPEND: stage the one host, merge into existing list dedup-by-name (new wins).
            let staged = stageHosts([singleHost], in: docs)
            guard !staged.isEmpty else { throw ImportError.noHosts }
            let existing = loadStoredHosts(in: docs)
            let merged = mergeAppend(staged, into: existing.hosts)
            try validateProxyPorts(merged)
            try writeStoredHosts(merged, to: docs.appendingPathComponent("hosts.json"))
            mode = .append; hostCount = staged.count
        }

        // Optional ASR creds (same shape as Android asr.json: {provider,appid,token,resourceId}):
        // validate size then atomically persist. Independent of host disposition.
        var asrImported = false
        if let asrObj {
            if let asrData = try? JSONSerialization.data(withJSONObject: asrObj, options: []),
               asrData.count <= 4096 {
                try? writeAtomic(asrData, to: docs.appendingPathComponent("asr.json"))
                asrImported = true
            } else {
                NSLog("[HostStore] import: asr block present but invalid/too-large → skipped")
            }
        }

        let modeStr = mode == .replace ? "replace" : (mode == .append ? "append" : "asr-only")
        NSLog("[HostStore] import OK [\(modeStr)]: \(hostCount) host(s)\(asrImported ? " + ASR creds" : "") → private store")
        AgentLog.info("config", "import OK mode=\(modeStr) hosts=\(hostCount) asr=\(asrImported)")
        return ImportResult(mode: mode, hosts: hostCount, asr: asrImported)
    }

    /// Stage a batch of inline-key host records into the private layout loadHosts() consumes:
    /// validate name + inline PEM, write `<safeName>.pem` (BARE filename, 0600), rewrite `key` →
    /// that filename and strip the inline PEM. Shared by REPLACE and APPEND so both stay identical.
    private static func stageHosts(_ hostsIn: [[String: Any]], in docs: URL) -> [[String: Any]] {
        var staged: [[String: Any]] = []
        for o in hostsIn {
            guard let name = o["name"] as? String, !name.isEmpty else {
                NSLog("[HostStore] import: skip host missing name"); continue
            }
            guard let pem = o["key"] as? String, pem.contains("PRIVATE KEY"),
                  pem.utf8.count > 0, pem.utf8.count <= 8192 else {
                NSLog("[HostStore] import: skip host '\(name)': inline key missing/invalid/too-large")
                continue
            }
            let safeName = name.replacingOccurrences(
                of: "[^A-Za-z0-9_.-]", with: "_", options: .regularExpression)
            let keyFileName = "\(safeName).pem"
            let keyURL = docs.appendingPathComponent(keyFileName)
            do {
                try writeAtomic(pem, to: keyURL)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyURL.path)
            } catch {
                NSLog("[HostStore] import: failed writing key for '\(name)': \(error)"); continue
            }
            var rec = o
            rec.removeValue(forKey: "key")        // strip inline PEM
            rec["key"] = keyFileName              // → bare filename loadHosts() expects
            staged.append(rec)
        }
        return staged
    }

    /// The current stored hosts.json root. Absent or malformed → empty. Used as the merge base for APPEND.
    private static func loadStoredHosts(in docs: URL) -> StoredRoot {
        let file = docs.appendingPathComponent("hosts.json")
        guard let data = try? Data(contentsOf: file),
              let root = parseStoredRoot(data) else { return StoredRoot(hosts: []) }
        return root
    }

    /// Merge freshly-staged hosts into the existing list, dedup by `name` (a new record overwrites
    /// the same-name old one in place; otherwise appended). Existing entries are not re-validated.
    private static func mergeAppend(_ incoming: [[String: Any]], into existing: [[String: Any]]) -> [[String: Any]] {
        var merged = existing
        for rec in incoming {
            let name = rec["name"] as? String ?? ""
            if let idx = merged.firstIndex(where: { ($0["name"] as? String) == name }) {
                merged[idx] = rec
            } else {
                merged.append(rec)
            }
        }
        return merged
    }

    private static func validateProxyPorts(_ hosts: [[String: Any]]) throws {
        var used: [Int: String] = [:]
        for h in hosts {
            let name = h["name"] as? String ?? "<unknown>"
            guard h["proxy"] != nil else { continue }
            guard let proxy = try parseProxy(h["proxy"], hostName: name) else { continue }
            if let other = used[proxy.localPort] {
                throw ImportError.badProxy("proxy.localPort \(proxy.localPort) 同时被 \(other) 和 \(name) 使用")
            }
            used[proxy.localPort] = name
        }
    }

    private static func writeStoredHosts(_ hosts: [[String: Any]], to target: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: hosts, options: [])
        try writeAtomic(data, to: target)
    }

    /// Atomic write (tmp → rename) so a crash mid-import can't leave a half-written file.
    private static func writeAtomic(_ data: Data, to target: URL) throws {
        let tmp = target.deletingLastPathComponent()
            .appendingPathComponent("\(target.lastPathComponent).tmp")
        try data.write(to: tmp, options: .atomic)
        if FileManager.default.fileExists(atPath: target.path) {
            _ = try? FileManager.default.replaceItemAt(target, withItemAt: tmp)
            // replaceItemAt consumed tmp on success; if it returned nil, fall through to a move.
            if FileManager.default.fileExists(atPath: tmp.path) {
                try? FileManager.default.removeItem(at: target)
                try FileManager.default.moveItem(at: tmp, to: target)
            }
        } else {
            try FileManager.default.moveItem(at: tmp, to: target)
        }
    }

    private static func writeAtomic(_ text: String, to target: URL) throws {
        try writeAtomic(Data(text.utf8), to: target)
    }
}
