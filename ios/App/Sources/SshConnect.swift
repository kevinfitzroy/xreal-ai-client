import Foundation
import Citadel
import Crypto
import Darwin

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
    private static func settings(for h: HostConfig, proxy: ProxyConfig? = nil) throws -> SSHClientSettings {
        let key = try Curve25519.Signing.PrivateKey(sshEd25519: h.ssh.privateKeyPem)
        let dial: (host: String, port: Int)
        if let proxy {
            AgentLog.info("network", "\(h.name): ensure xray proxy=\(proxy.name) localPort=\(proxy.localPort)")
            try XrayProxy.tunnel(hostName: h.name, proxy: proxy, targetHost: "127.0.0.1", targetPort: h.ssh.port)
            dial = ("127.0.0.1", proxy.localPort)
        } else {
            AgentLog.debug("network", "\(h.name): direct SSH port=\(h.ssh.port)")
            dial = (h.ssh.host, h.ssh.port)
        }
        var s = SSHClientSettings(
            host: dial.host,
            port: dial.port,
            authenticationMethod: { .ed25519(username: h.ssh.user, privateKey: key) },
            hostKeyValidator: .acceptAnything()   // TOFU later; local rig only (matches existing code)
        )
        s.connectTimeout = .seconds(12)           // mirrors Android CONNECT_TIMEOUT_MS
        // 注:keepalive / tcpNoDelay 在 Citadel 0.12.1 的 SSHClientSettings 上不存在(只有 connectTimeout),
        // 弱网保活改由 app 层负责 —— NetworkMonitor 感知链路变化 + 主动重连(见 TerminalViewController)。
        return s
    }

    /// Connect to `target`, directly or — when `via` is non-nil — through it as a ProxyJump.
    /// On `via`: connect the jump host first, then `jump.jump(to: targetSettings)` opens the
    /// directTCPIP tunnel + second handshake. Any throw (bad key, jump unreachable, target
    /// auth fail) propagates; partial state (a live jump client when the target handshake
    /// fails) is cleaned up before rethrowing so we never leak a half-open jump connection.
    static func connect(target h: HostConfig, via: HostConfig?) async throws -> Connected {
        do {
            return try await connectOnce(target: h, via: via)
        } catch {
            guard let retry = proxyRestartTarget(target: h, via: via) else { throw error }
            XrayDebugLog.append("ssh failed \(h.name), restart tunnel \(retry.host.name): \(String(describing: error).prefix(160))")
            AgentLog.warn("network", "\(h.name): SSH failed, restart xray tunnel on \(retry.host.name)")
            try XrayProxy.restart(hostName: retry.host.name, proxy: retry.proxy, targetHost: "127.0.0.1", targetPort: retry.host.ssh.port)
            return try await connectOnce(target: h, via: via)
        }
    }

    private static func connectOnce(target h: HostConfig, via: HostConfig?) async throws -> Connected {
        let targetSettings = try settings(for: h, proxy: via == nil ? h.proxy : nil)
        guard let jh = via else {
            AgentLog.debug("network", "\(h.name): SSH handshake direct")
            let c = try await SSHClient.connect(to: targetSettings)
            return Connected(target: c, jump: nil)
        }
        // Multi-hop: jump host first (its own ed25519), then tunnel to the target.
        AgentLog.info("network", "\(h.name): SSH handshake via \(jh.name)")
        let jumpClient = try await SSHClient.connect(to: try settings(for: jh, proxy: jh.proxy))
        do {
            let targetClient = try await jumpClient.jump(to: targetSettings)
            return Connected(target: targetClient, jump: jumpClient)
        } catch {
            try? await jumpClient.close()   // target handshake failed — don't leak the jump
            AgentLog.warn("network", "\(h.name): target handshake through \(jh.name) failed")
            throw error
        }
    }

    private static func proxyRestartTarget(target h: HostConfig, via: HostConfig?) -> (host: HostConfig, proxy: ProxyConfig)? {
        if let via, let proxy = via.proxy { return (via, proxy) }
        if via == nil, let proxy = h.proxy { return (h, proxy) }
        return nil
    }
}

// MARK: - SSH-over-443 runtime (SPEC §5.1)

enum XrayConfig {
    struct VmessLink {
        let address: String
        let port: Int
        let id: String
        let alterId: Int
        let security: String
        let network: String
        let tls: Bool
        let sni: String
        let host: String
        let path: String
        let allowInsecure: Bool
        let ps: String
    }

    /// vless share link 字段(SPEC §5.1)。与 vmess 不同:vless 是**明文 URI**(非 base64 JSON),
    /// 无内置加密,安全全交给传输层 TLS/**Reality**。Reality 必带 publicKey(pbk)+ fingerprint(fp)。
    struct VlessLink {
        let address: String
        let port: Int
        let id: String           // uuid
        let flow: String         // xtls-rprx-vision(Reality 常配)/ 空
        let security: String     // reality / tls / none
        let sni: String          // serverName
        let fingerprint: String  // fp,uTLS 指纹(Reality 必需,缺省 chrome)
        let publicKey: String    // pbk(Reality 必需)
        let shortId: String      // sid(Reality)
        let spiderX: String      // spx(Reality,可选)
        let network: String      // tcp / ws / grpc
        let path: String         // ws/grpc path
        let host: String         // ws Host header
        let ps: String           // #name
    }

    static func parseVmess(_ url: String) throws -> VmessLink {
        guard url.hasPrefix("vmess://") else { throw XrayError.badConfig("不是 vmess:// 链接") }
        let raw = String(url.dropFirst("vmess://".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = decodeBase64(raw),
              let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw XrayError.badConfig("vmess 内容不是合法 JSON")
        }
        func str(_ key: String) -> String { (obj[key] as? String) ?? "" }
        let address = str("add")
        guard !address.isEmpty else { throw XrayError.badConfig("vmess 缺 add") }
        let port = Int(str("port")) ?? (obj["port"] as? Int) ?? 0
        guard (1...65535).contains(port) else { throw XrayError.badConfig("vmess port 非法") }
        let id = str("id")
        guard !id.isEmpty else { throw XrayError.badConfig("vmess 缺 id") }
        return VmessLink(
            address: address,
            port: port,
            id: id,
            alterId: Int(str("aid")) ?? (obj["aid"] as? Int) ?? 0,
            security: str("scy").isEmpty ? "auto" : str("scy"),
            network: str("net").isEmpty ? "tcp" : str("net"),
            tls: str("tls").lowercased() == "tls",
            sni: str("sni"),
            host: str("host"),
            path: str("path"),
            allowInsecure: str("insecure") == "1" || ((obj["insecure"] as? Bool) ?? false),
            ps: str("ps")
        )
    }

    /// 解析 vless 明文 URI:`vless://<uuid>@<host>:<port>?security=reality&pbk=..&sid=..&fp=..&flow=..&type=tcp#name`。
    /// 与 parseVmess(base64 JSON)不同,vless 是标准 URL → 用 URLComponents 拆。Reality 缺 pbk 直接判错(否则连不上)。
    static func parseVless(_ url: String) throws -> VlessLink {
        guard url.hasPrefix("vless://") else { throw XrayError.badConfig("不是 vless:// 链接") }
        guard let comps = URLComponents(string: url) else { throw XrayError.badConfig("vless URL 解析失败") }
        guard let id = comps.user, !id.isEmpty else { throw XrayError.badConfig("vless 缺 uuid") }
        guard let host = comps.host, !host.isEmpty else { throw XrayError.badConfig("vless 缺 host") }
        guard let port = comps.port, (1...65535).contains(port) else { throw XrayError.badConfig("vless port 非法") }
        var q: [String: String] = [:]
        for item in comps.queryItems ?? [] where item.value != nil { q[item.name] = item.value }
        func qv(_ k: String) -> String { q[k] ?? "" }
        let security = qv("security").isEmpty ? "none" : qv("security")
        let network = qv("type").isEmpty ? "tcp" : qv("type")
        let pbk = qv("pbk")
        if security.lowercased() == "reality" && pbk.isEmpty {
            throw XrayError.badConfig("vless reality 缺 publicKey(pbk)")
        }
        return VlessLink(
            address: host,
            port: port,
            id: id,
            flow: qv("flow"),
            security: security,
            sni: qv("sni").isEmpty ? qv("peer") : qv("sni"),
            fingerprint: qv("fp"),
            publicKey: pbk,
            shortId: qv("sid"),
            spiderX: qv("spx"),
            network: network,
            path: qv("path"),
            host: qv("host"),
            ps: comps.fragment ?? ""
        )
    }

    static func build(link: VmessLink, localPort: Int, targetHost: String, targetPort: Int, serverIp: String?) throws -> String {
        let inbound: [String: Any] = [
            "tag": "ssh-in",
            "listen": "127.0.0.1",
            "port": localPort,
            "protocol": "dokodemo-door",
            "settings": [
                "address": targetHost,
                "port": targetPort,
                "network": "tcp",
                "followRedirect": false,
            ],
        ]
        let user: [String: Any] = ["id": link.id, "alterId": link.alterId, "security": link.security]
        let vnext: [String: Any] = [
            "address": serverIp ?? link.address,
            "port": link.port,
            "users": [user],
        ]
        let outbound: [String: Any] = [
            "tag": "proxy",
            "protocol": "vmess",
            "settings": ["vnext": [vnext]],
            "streamSettings": streamSettings(link),
        ]
        let root: [String: Any] = [
            "log": ["loglevel": "warning"],
            "inbounds": [inbound],
            "outbounds": [outbound],
        ]
        let data = try JSONSerialization.data(withJSONObject: root, options: [])
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private static func streamSettings(_ link: VmessLink) -> [String: Any] {
        var ss: [String: Any] = ["network": link.network]
        if link.tls {
            ss["security"] = "tls"
            ss["tlsSettings"] = [
                "serverName": link.sni.isEmpty ? link.address : link.sni,
                "allowInsecure": link.allowInsecure,
            ]
        }
        if link.network.lowercased() == "ws" {
            var ws: [String: Any] = ["path": link.path.isEmpty ? "/" : link.path]
            if !link.host.isEmpty { ws["headers"] = ["Host": link.host] }
            ss["wsSettings"] = ws
        }
        return ss
    }

    static func buildVless(link: VlessLink, localPort: Int, targetHost: String, targetPort: Int, serverIp: String?) throws -> String {
        let inbound: [String: Any] = [
            "tag": "ssh-in",
            "listen": "127.0.0.1",
            "port": localPort,
            "protocol": "dokodemo-door",
            "settings": [
                "address": targetHost,
                "port": targetPort,
                "network": "tcp",
                "followRedirect": false,
            ],
        ]
        var user: [String: Any] = ["id": link.id, "encryption": "none"]
        if !link.flow.isEmpty { user["flow"] = link.flow }   // XTLS flow 只在 outbound user 上
        let vnext: [String: Any] = [
            "address": serverIp ?? link.address,
            "port": link.port,
            "users": [user],
        ]
        let outbound: [String: Any] = [
            "tag": "proxy",
            "protocol": "vless",
            "settings": ["vnext": [vnext]],
            "streamSettings": vlessStreamSettings(link),
        ]
        let root: [String: Any] = [
            "log": ["loglevel": "warning"],
            "inbounds": [inbound],
            "outbounds": [outbound],
        ]
        let data = try JSONSerialization.data(withJSONObject: root, options: [])
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private static func vlessStreamSettings(_ link: VlessLink) -> [String: Any] {
        var ss: [String: Any] = ["network": link.network]
        let sni = link.sni.isEmpty ? link.address : link.sni
        switch link.security.lowercased() {
        case "reality":
            ss["security"] = "reality"
            var r: [String: Any] = [
                "serverName": sni,
                "publicKey": link.publicKey,
                "fingerprint": link.fingerprint.isEmpty ? "chrome" : link.fingerprint,  // uTLS 指纹必填
            ]
            if !link.shortId.isEmpty { r["shortId"] = link.shortId }
            if !link.spiderX.isEmpty { r["spiderX"] = link.spiderX }
            ss["realitySettings"] = r
        case "tls":
            ss["security"] = "tls"
            var t: [String: Any] = ["serverName": sni, "allowInsecure": false]
            if !link.fingerprint.isEmpty { t["fingerprint"] = link.fingerprint }
            ss["tlsSettings"] = t
        default:
            break   // security=none:裸 tcp(少见,合法)
        }
        if link.network.lowercased() == "ws" {
            var ws: [String: Any] = ["path": link.path.isEmpty ? "/" : link.path]
            if !link.host.isEmpty { ws["headers"] = ["Host": link.host] }
            ss["wsSettings"] = ws
        }
        return ss
    }

    /// 统一入口:按 `url` 前缀分派 vmess/vless,解析 → resolve 域名(gomobile xray 内部 DNS 会超时,
    /// 故传入 IP,SNI 仍域名)→ 生成 xray JSON。XrayProxy 只调这个;新增协议只在此加分支。
    static func makeConfig(url: String, localPort: Int, targetHost: String, targetPort: Int,
                           resolve: (String) -> String?) throws -> (config: String, server: String, port: Int, ip: String?) {
        if url.hasPrefix("vless://") {
            let link = try parseVless(url)
            let ip = resolve(link.address)
            let cfg = try buildVless(link: link, localPort: localPort, targetHost: targetHost, targetPort: targetPort, serverIp: ip)
            return (cfg, link.address, link.port, ip)
        }
        if url.hasPrefix("vmess://") {
            let link = try parseVmess(url)
            let ip = resolve(link.address)
            let cfg = try build(link: link, localPort: localPort, targetHost: targetHost, targetPort: targetPort, serverIp: ip)
            return (cfg, link.address, link.port, ip)
        }
        throw XrayError.badConfig("不支持的代理协议(仅 vmess/vless):\(url.prefix(12))")
    }

    private static func decodeBase64(_ s: String) -> Data? {
        let cleaned = s.replacingOccurrences(of: "\n", with: "").replacingOccurrences(of: "\r", with: "")
        let padded = cleaned + String(repeating: "=", count: (4 - cleaned.count % 4) % 4)
        if let data = Data(base64Encoded: padded) { return data }
        let urlSafe = padded.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        return Data(base64Encoded: urlSafe)
    }
}

enum XrayError: Error, CustomStringConvertible {
    case unavailable(String)
    case badConfig(String)
    case startFailed(String)

    var description: String {
        switch self {
        case .unavailable(let s), .badConfig(let s), .startFailed(let s): return s
        }
    }
}

enum XrayProxy {
    private static let lock = NSLock()
    private static var ports: [String: Int] = [:]

    static func tunnel(hostName: String, proxy: ProxyConfig, targetHost: String, targetPort: Int) throws {
        try ensureTunnel(hostName: hostName, proxy: proxy, targetHost: targetHost, targetPort: targetPort, forceRestart: false)
    }

    static func restart(hostName: String, proxy: ProxyConfig, targetHost: String, targetPort: Int) throws {
        try ensureTunnel(hostName: hostName, proxy: proxy, targetHost: targetHost, targetPort: targetPort, forceRestart: true)
    }

    private static func ensureTunnel(
        hostName: String,
        proxy: ProxyConfig,
        targetHost: String,
        targetPort: Int,
        forceRestart: Bool
    ) throws {
        let key = "\(hostName)→\(targetHost):\(targetPort)"
        lock.lock()
        defer { lock.unlock() }
        if let running = ports[key] {
            if running == proxy.localPort && !forceRestart && localPortIsOpen(running) {
                XrayDebugLog.append("reuse \(hostName) localPort=\(proxy.localPort)")
                AgentLog.debug("xray", "\(hostName): reuse tunnel localPort=\(proxy.localPort)")
                return
            }
            ports.removeValue(forKey: key)
            XrayDebugLog.append("\(forceRestart ? "restart" : "stale") \(hostName) oldPort=\(running) newPort=\(proxy.localPort)")
            AgentLog.warn("xray", "\(hostName): \(forceRestart ? "restart" : "stale") tunnel oldPort=\(running) newPort=\(proxy.localPort)")
            try? XrayBridge.load()?.stop(key: key)
            Thread.sleep(forTimeInterval: 0.2)
        } else if let other = ports.first(where: { $0.value == proxy.localPort && $0.key != key }) {
            if localPortIsOpen(other.value) {
                throw XrayError.badConfig("proxy.localPort \(proxy.localPort) 已被 \(other.key) 使用")
            }
            ports.removeValue(forKey: other.key)
            XrayDebugLog.append("remove stale port \(proxy.localPort) owner=\(other.key)")
            AgentLog.warn("xray", "remove stale localPort=\(proxy.localPort) owner=\(other.key)")
            try? XrayBridge.load()?.stop(key: other.key)
            Thread.sleep(forTimeInterval: 0.2)
        }

        guard let bridge = XrayBridge.load() else {
            XrayDebugLog.append("bridge missing \(hostName)")
            AgentLog.error("xray", "\(hostName): bridge missing")
            throw XrayError.unavailable("Xraybridge.framework 未集成,SSH-over-443 不可用")
        }
        let made = try XrayConfig.makeConfig(url: proxy.url, localPort: proxy.localPort, targetHost: targetHost, targetPort: targetPort, resolve: resolveAddress)
        let config = made.config
        XrayDebugLog.append("start \(hostName) proxy=\(proxy.name) localPort=\(proxy.localPort) server=\(made.server):\(made.port) resolved=\(made.ip ?? "-")")
        AgentLog.info("xray", "\(hostName): start proxy=\(proxy.name) localPort=\(proxy.localPort) target=\(targetHost):\(targetPort)")
        try bridge.start(key: key, config: config)

        if let other = ports.first(where: { $0.value == proxy.localPort && $0.key != key }) {
            try? bridge.stop(key: key)
            throw XrayError.badConfig("proxy.localPort \(proxy.localPort) 已被 \(other.key) 使用")
        }
        ports[key] = proxy.localPort
        // xray-core StartInstance can return a beat before the inbound is fully usable.
        // Without this, the very first SSH probe after app launch can get ECONNRESET while
        // the next user-opened terminal succeeds.
        Thread.sleep(forTimeInterval: 0.5)
        XrayDebugLog.append("started \(hostName) localPort=\(proxy.localPort)")
        AgentLog.info("xray", "\(hostName): started localPort=\(proxy.localPort)")
        NSLog("[XrayProxy] start \(key) via \(made.server)\(made.ip.map { "[\($0)]" } ?? ""):\(made.port) → 127.0.0.1:\(proxy.localPort)")
    }

    static func stopAll() {
        guard let bridge = XrayBridge.load() else { return }
        lock.lock()
        let keys = Array(ports.keys)
        ports.removeAll()
        lock.unlock()
        keys.forEach { try? bridge.stop(key: $0) }
        if !keys.isEmpty { XrayDebugLog.append("stopped \(keys.count) tunnel(s)") }
        if !keys.isEmpty { AgentLog.info("xray", "stopped tunnels count=\(keys.count)") }
    }

    private static func resolveAddress(_ host: String) -> String? {
        var hints = addrinfo(ai_flags: AI_ADDRCONFIG, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM, ai_protocol: IPPROTO_TCP, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let result else { return nil }
        defer { freeaddrinfo(result) }
        var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let addr = result.pointee.ai_addr
        let len = result.pointee.ai_addrlen
        guard getnameinfo(addr, len, &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST) == 0 else { return nil }
        return String(cString: buf)
    }

    private static func localPortIsOpen(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        guard inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr) == 1 else { return false }
        return withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }
}

enum XrayDebugLog {
    private static let lock = NSLock()

    static func append(_ line: String) {
        lock.lock()
        defer { lock.unlock() }
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let url = docs.appendingPathComponent("xray-smoke.log")
        let stamp = ISO8601DateFormatter().string(from: Date())
        let data = Data("[\(stamp)] \(line)\n".utf8)
        if FileManager.default.fileExists(atPath: url.path),
           let fh = try? FileHandle(forWritingTo: url) {
            defer { try? fh.close() }
            _ = try? fh.seekToEnd()
            _ = try? fh.write(contentsOf: data)
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }
}

final class XrayBridge {
    private typealias StartFn = @convention(c) (NSString, NSString, UnsafeMutablePointer<NSError?>?) -> Bool
    private typealias StopFn = @convention(c) (NSString, UnsafeMutablePointer<NSError?>?) -> Bool

    private let handle: UnsafeMutableRawPointer
    private let startFn: StartFn
    private let stopFn: StopFn

    private static var cached: XrayBridge?
    private static var attempted = false

    static func load() -> XrayBridge? {
        if let cached { return cached }
        if attempted { return nil }
        attempted = true
        let names = ["Xraybridge", "xraybridge"]
        let roots = [Bundle.main.privateFrameworksPath, Bundle.main.bundlePath].compactMap { $0 }
        for root in roots {
            for name in names {
                let path = "\(root)/\(name).framework/\(name)"
                guard FileManager.default.fileExists(atPath: path),
                      let h = dlopen(path, RTLD_NOW | RTLD_LOCAL) else { continue }
                if let bridge = XrayBridge(handle: h) {
                    cached = bridge
                    return bridge
                }
                dlclose(h)
            }
        }
        NSLog("[XrayBridge] xraybridge.framework not found")
        return nil
    }

    private init?(handle: UnsafeMutableRawPointer) {
        guard let startSym = dlsym(handle, "XraybridgeStart"),
              let stopSym = dlsym(handle, "XraybridgeStop") else { return nil }
        self.handle = handle
        self.startFn = unsafeBitCast(startSym, to: StartFn.self)
        self.stopFn = unsafeBitCast(stopSym, to: StopFn.self)
    }

    deinit { dlclose(handle) }

    func start(key: String, config: String) throws {
        var err: NSError?
        if !startFn(key as NSString, config as NSString, &err) {
            throw XrayError.startFailed(err?.localizedDescription ?? "xray 启动失败")
        }
    }

    func stop(key: String) throws {
        var err: NSError?
        if !stopFn(key as NSString, &err) {
            throw XrayError.startFailed(err?.localizedDescription ?? "xray 停止失败")
        }
    }
}
