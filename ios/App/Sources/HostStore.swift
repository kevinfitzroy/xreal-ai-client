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
}
