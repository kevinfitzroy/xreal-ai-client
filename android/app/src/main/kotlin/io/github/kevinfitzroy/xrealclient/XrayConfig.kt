package io.github.kevinfitzroy.xrealclient

import org.json.JSONArray
import org.json.JSONObject

/**
 * vmess:// 链接解析 + xray-core JSON 配置生成(SSH-over-443 隧道,SPEC.md §5.1)。
 *
 * **纯函数,无 Android/网络依赖** → JVM 单测覆盖(见 XrayConfigTest)。运行时把生成的配置喂给
 * [XrayProxy](内嵌 xray-core),起一个本地 **dokodemo-door** inbound + vmess(+tls) outbound。
 *
 * **为什么是 dokodemo-door 而不是 socks**:若用 socks inbound 让 sshj 去连 `节点公网IP:22`,目标
 * 正是 vmess 出口节点自己 → 触发 xray 的**自指防环(loop protection)**,流量被悄悄退化成直连,
 * 而直连的 :22 正是被 GFW 卡 KEXINIT 的那条。dokodemo-door 把进来的连接 **override 改写成
 * `127.0.0.1:<port>`** 再送进隧道:进隧道的 dest 是 127.0.0.1(不是节点公网 IP)→ 躲过防环;
 * 服务端 xray 默认 freedom 出站把 `127.0.0.1:22` 当**它自己的 localhost** 直达 sshd。服务端零改动。
 * (= `~/claude/vpn/ssh-over-vmess.md` §3 正解的 xray 等价物;sing-box 的 `direct` inbound override 同理。)
 *
 * vmess:// 格式(v2rayN 通用):`vmess://` + base64(JSON),JSON 字段见 [VmessLink]。
 */
object XrayConfig {

    /** vmess 链接解析后的关键字段(只取我们隧道用得到的)。 */
    data class VmessLink(
        val address: String,   // add:服务器地址(IP/域名)
        val port: Int,         // port:服务器端口(通常 443)
        val id: String,        // id:用户 UUID
        val alterId: Int,      // aid:alterId(VMess AEAD 用 0)
        val security: String,  // scy:加密(auto/aes-128-gcm/chacha20-poly1305/none)
        val network: String,   // net:传输(tcp/ws/...)
        val tls: Boolean,      // tls:是否 TLS
        val sni: String,       // sni:TLS SNI(空则用 address)
        val host: String,      // host:ws Host header(net=ws 用)
        val path: String,      // path:ws 路径(net=ws 用)
        val allowInsecure: Boolean,  // insecure:是否跳过证书校验
        val ps: String,        // ps:备注名(信息性)
    )

    /** 解析 vmess:// 链接。非法格式抛 [IllegalArgumentException]。 */
    fun parseVmess(url: String): VmessLink {
        require(url.startsWith("vmess://")) { "不是 vmess:// 链接" }
        val b64 = url.removePrefix("vmess://").trim()
        // v2rayN 用标准 base64(可能带/不带 padding);兜底也试 URL-safe。
        val json = runCatching { decodeB64(b64) }
            .getOrElse { throw IllegalArgumentException("vmess base64 解码失败: ${it.message}") }
        val o = runCatching { JSONObject(json) }
            .getOrElse { throw IllegalArgumentException("vmess 内容不是合法 JSON") }

        val address = o.optString("add").ifBlank { throw IllegalArgumentException("vmess 缺 add") }
        val port = o.optString("port").toIntOrNull() ?: o.optInt("port", 0)
        require(port in 1..65535) { "vmess port 非法: ${o.opt("port")}" }
        val id = o.optString("id").ifBlank { throw IllegalArgumentException("vmess 缺 id") }
        return VmessLink(
            address = address,
            port = port,
            id = id,
            alterId = o.optString("aid").toIntOrNull() ?: o.optInt("aid", 0),
            security = o.optString("scy").ifBlank { "auto" },
            network = o.optString("net").ifBlank { "tcp" },
            tls = o.optString("tls").equals("tls", ignoreCase = true),
            sni = o.optString("sni"),
            host = o.optString("host"),
            path = o.optString("path"),
            allowInsecure = o.optString("insecure") == "1" || o.optBoolean("insecure", false),
            ps = o.optString("ps"),
        )
    }

    /**
     * 生成完整 xray-core JSON 配置:一个本地 **dokodemo-door** inbound(`127.0.0.1:[localPort]`,把所有
     * 进来的连接 override 改写到 [targetHost]:[targetPort])+ 一个 vmess outbound。
     *
     * 用法:app 让 sshj **直连** `127.0.0.1:[localPort]`(不走 SocketFactory),dokodemo-door 接住、把
     * dest 改写成 [targetHost]:[targetPort] 送进 vmess/tls:443 隧道,服务端 freedom 出站直达该 dest。
     * 典型:[targetHost]=`127.0.0.1`、[targetPort]=22 → 连服务端自己的 sshd(躲自指防环,见类注释)。
     */
    /**
     * @param serverIp 非空 → 用它作为 vmess 拨号地址(替代 [VmessLink.address]),**SNI 仍用域名**。
     *   用途:gomobile xray-core 在 Android 上**内部 DNS 解析常超时**(读不到系统 resolver)→ 由调用方
     *   ([XrayProxy])用 Android 系统 resolver 先把域名解析成 IP 传进来,xray 直接拨 IP、不触发内部 DNS。
     *   TLS SNI/证书仍按域名校验(标准做法,等同 CDN)。
     */
    fun buildXrayConfig(
        link: VmessLink, localPort: Int,
        targetHost: String = "127.0.0.1", targetPort: Int = 22, serverIp: String? = null,
    ): String {
        val inbound = JSONObject()
            .put("tag", "ssh-in")
            .put("listen", "127.0.0.1")
            .put("port", localPort)
            .put("protocol", "dokodemo-door")
            .put(
                "settings",
                JSONObject()
                    .put("address", targetHost)   // override:所有连接的目标改写成这里(= 服务端 localhost)
                    .put("port", targetPort)
                    .put("network", "tcp")
                    .put("followRedirect", false),
            )

        val user = JSONObject()
            .put("id", link.id)
            .put("alterId", link.alterId)
            .put("security", link.security)
        val vnext = JSONObject()
            .put("address", serverIp ?: link.address)   // 拨号用 IP(避 xray 内部 DNS);SNI 仍域名,见 streamSettings
            .put("port", link.port)
            .put("users", JSONArray().put(user))
        val outbound = JSONObject()
            .put("tag", "proxy")
            .put("protocol", "vmess")
            .put("settings", JSONObject().put("vnext", JSONArray().put(vnext)))
            .put("streamSettings", streamSettings(link))

        return JSONObject()
            .put("log", JSONObject().put("loglevel", "warning"))
            .put("inbounds", JSONArray().put(inbound))
            .put("outbounds", JSONArray().put(outbound))
            .toString()
    }

    private fun streamSettings(link: VmessLink): JSONObject {
        val ss = JSONObject().put("network", link.network)
        if (link.tls) {
            ss.put("security", "tls")
            ss.put(
                "tlsSettings",
                JSONObject()
                    .put("serverName", link.sni.ifBlank { link.address })
                    .put("allowInsecure", link.allowInsecure),
            )
        }
        // net=ws:带 path/host header。net=tcp(本场景默认)无需额外设置。
        if (link.network.equals("ws", ignoreCase = true)) {
            val ws = JSONObject().put("path", link.path.ifBlank { "/" })
            if (link.host.isNotBlank()) ws.put("headers", JSONObject().put("Host", link.host))
            ss.put("wsSettings", ws)
        }
        return ss
    }

    /**
     * base64 解码。用 `java.util.Base64`(API 26+,且 JVM 单测里是真实现 —— `android.util.Base64`
     * 在单测里是返回默认值的 stub,故不用它)。容错:补 padding;标准字母表失败再试 URL-safe。
     */
    private fun decodeB64(s: String): String {
        val cleaned = s.replace("\n", "").replace("\r", "").trim()
        val padded = cleaned + "=".repeat((4 - cleaned.length % 4) % 4)
        runCatching {
            return String(java.util.Base64.getDecoder().decode(padded), Charsets.UTF_8)
        }
        return String(java.util.Base64.getUrlDecoder().decode(padded), Charsets.UTF_8)
    }
}
