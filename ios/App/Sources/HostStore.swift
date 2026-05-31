import Foundation

/// Reads the Valet-installed `hosts.json` from the app's Documents dir and resolves
/// each host's private key file. Mirrors Android's SettingsStore.parseHosts.
///
/// staging shape (SPEC §8): `[{ name, addr?, host, port?, user, key, basePath?, via?,
/// projects:[{session,name,type}] }]`. `key` is a bare filename pointing at a sibling
/// key file in Documents/ (the iOS dev-injection channel = `simctl get_app_container`
/// copy, the analog of Android's `adb push`).
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
              let json = try? JSONSerialization.jsonObject(with: data),
              let arr = json as? [[String: Any]] else {
            NSLog("[HostStore] no hosts.json (or invalid) → empty (mock)")
            return []
        }
        return arr.compactMap { parseHost($0, docsDir: docs) }
    }

    private static func parseHost(_ o: [String: Any], docsDir: URL) -> HostConfig? {
        guard let name = o["name"] as? String, !name.isEmpty,
              let host = o["host"] as? String, !host.isEmpty,
              let user = o["user"] as? String, !user.isEmpty else {
            NSLog("[HostStore] skip host missing name/host/user")
            return nil
        }
        let keyName = (o["key"] as? String) ?? ""
        guard let pem = readKeySafe(keyName, in: docsDir) else {
            NSLog("[HostStore] skip host '\(name)': bad/missing key '\(keyName)'")
            return nil
        }
        let port = (o["port"] as? Int) ?? 22
        let addr = (o["addr"] as? String) ?? host   // alias only; real host hidden in UI
        let basePath = (o["basePath"] as? String) ?? ""
        let via = (o["via"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let projects = (o["projects"] as? [[String: Any]] ?? []).compactMap(parseProject)
        return HostConfig(
            name: name, addr: addr,
            ssh: SshConfig(host: host, port: port, user: user, privateKeyPem: pem),
            projects: projects, basePath: basePath, via: via
        )
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
        case unreadable, badJSON, noHosts, noContent
        var description: String {
            switch self {
            case .unreadable: return "无法读取导入文件"
            case .badJSON:    return "导入文件不是合法 JSON"
            case .noHosts:    return "导入文件没有合法的 host"
            case .noContent:  return "导入文件缺少 host / hosts / asr 任一字段"
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

    /// Import a self-contained `.xrhosts` config bundle (AirDrop → "用 XrealPOC 打开", or via the
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
            let hostsData = try JSONSerialization.data(withJSONObject: staged, options: [])
            try writeAtomic(hostsData, to: docs.appendingPathComponent("hosts.json"))
            mode = .replace; hostCount = staged.count
        } else if let singleHost {
            // APPEND: stage the one host, merge into existing list dedup-by-name (new wins).
            let staged = stageHosts([singleHost], in: docs)
            guard !staged.isEmpty else { throw ImportError.noHosts }
            let merged = mergeAppend(staged, into: loadBareHosts(in: docs))
            let hostsData = try JSONSerialization.data(withJSONObject: merged, options: [])
            try writeAtomic(hostsData, to: docs.appendingPathComponent("hosts.json"))
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

    /// The current bare-form hosts.json array (post-staging records, `key` = filename). Absent or
    /// malformed → []. Used as the merge base for APPEND.
    private static func loadBareHosts(in docs: URL) -> [[String: Any]] {
        let file = docs.appendingPathComponent("hosts.json")
        guard let data = try? Data(contentsOf: file),
              let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            return []
        }
        return arr
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
