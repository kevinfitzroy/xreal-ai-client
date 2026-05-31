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
        case unreadable, badJSON, noHosts
        var description: String {
            switch self {
            case .unreadable: return "无法读取导入文件"
            case .badJSON:    return "导入文件不是合法 JSON 或缺少顶层 version/hosts"
            case .noHosts:    return "导入文件没有合法的 host"
            }
        }
    }

    /// Result of an "Open in XrealPOC" import: how many hosts landed + whether ASR creds came too.
    struct ImportResult { let hosts: Int; let asr: Bool }

    /// Import a self-contained `.xrhosts` config bundle (AirDrop → "用 XrealPOC 打开"; SPEC §8 iOS
    /// real-device channel). The bundle is `{version, hosts:[{...,key:<inline PEM>}], asr?}` — the
    /// ONE shape difference from Android staging is the **inline key**. We unpack it into the SAME
    /// private layout `loadHosts()` already consumes: each host's inline PEM is written to
    /// `Documents/<safeName>.pem` (a BARE filename — readKeySafe rejects any `/`), `key` is rewritten
    /// to that bare name and the inline PEM stripped, and the whole BARE array is atomically written
    /// to `Documents/hosts.json` (NOT the wrapper object — loadHosts casts to `[[String:Any]]`).
    /// Ports Android SettingsStore.importStagingIfPresent validation: name sanitized `[^A-Za-z0-9_.-]→_`,
    /// PEM must contain `PRIVATE KEY` and be ≤8KB, atomic tmp→rename, key file mode 0600.
    /// SECURITY: never logs key bytes — counts only.
    @discardableResult
    static func importConfig(from url: URL) throws -> ImportResult {
        guard let data = try? Data(contentsOf: url) else { throw ImportError.unreadable }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              root["version"] != nil,
              let hostsIn = root["hosts"] as? [[String: Any]] else {
            throw ImportError.badJSON
        }

        let docs = documentsDir
        // Clean any half-written artifacts from a prior crashed import (atomic .tmp leftovers).
        (try? FileManager.default.contentsOfDirectory(at: docs, includingPropertiesForKeys: nil))?
            .filter { $0.lastPathComponent.hasSuffix(".tmp") }
            .forEach { try? FileManager.default.removeItem(at: $0) }

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
        guard !staged.isEmpty else { throw ImportError.noHosts }

        let hostsData = try JSONSerialization.data(withJSONObject: staged, options: [])
        try writeAtomic(hostsData, to: docs.appendingPathComponent("hosts.json"))

        // Optional ASR creds (same shape as Android asr.json): validate then atomically persist.
        var asrImported = false
        if let asrObj = root["asr"] as? [String: Any] {
            if let asrData = try? JSONSerialization.data(withJSONObject: asrObj, options: []),
               asrData.count <= 4096 {
                try? writeAtomic(asrData, to: docs.appendingPathComponent("asr.json"))
                asrImported = true
            } else {
                NSLog("[HostStore] import: asr block present but invalid/too-large → skipped")
            }
        }

        NSLog("[HostStore] import OK: \(staged.count) host(s)\(asrImported ? " + ASR creds" : "") → private store")
        return ImportResult(hosts: staged.count, asr: asrImported)
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
