package io.github.kevinfitzroy.xrealclient

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

/** vmess:// 解析 + xray 配置生成的纯逻辑单测(无 Android/网络依赖)。 */
class XrayConfigTest {

    // 脱敏假 vmess(RFC5737 文档 IP 203.0.113.x + 全零 UUID + example.com),**绝不**用真实凭证。
    // 动态 base64 编码假 JSON(覆盖典型形态:443 / tcp / tls / sni / aid=0),不硬编码 base64 串。
    private fun fakeVmess(json: String): String =
        "vmess://" + java.util.Base64.getEncoder().encodeToString(json.toByteArray())
    private val sampleVmess = fakeVmess(
        """{"v":"2","ps":"example","add":"203.0.113.10","port":"443",""" +
            """"id":"00000000-0000-0000-0000-000000000000","aid":"0","scy":"auto",""" +
            """"net":"tcp","type":"none","host":"","path":"","tls":"tls",""" +
            """"sni":"example.com","alpn":"","fp":"","insecure":"0"}""",
    )

    @Test fun parsesTypicalVmess() {
        val link = XrayConfig.parseVmess(sampleVmess)
        assertEquals("203.0.113.10", link.address)
        assertEquals(443, link.port)
        assertEquals("00000000-0000-0000-0000-000000000000", link.id)
        assertEquals(0, link.alterId)
        assertEquals("auto", link.security)
        assertEquals("tcp", link.network)
        assertTrue(link.tls)
        assertEquals("example.com", link.sni)
        assertFalse(link.allowInsecure)
    }

    @Test fun buildsValidXrayConfigWithLocalSocks() {
        val link = XrayConfig.parseVmess(sampleVmess)
        val cfg = JSONObject(XrayConfig.buildXrayConfig(link, 10808))

        val inbound = cfg.getJSONArray("inbounds").getJSONObject(0)
        assertEquals("socks", inbound.getString("protocol"))
        assertEquals("127.0.0.1", inbound.getString("listen"))   // 仅本地,不暴露
        assertEquals(10808, inbound.getInt("port"))

        val outbound = cfg.getJSONArray("outbounds").getJSONObject(0)
        assertEquals("vmess", outbound.getString("protocol"))
        val vnext = outbound.getJSONObject("settings").getJSONArray("vnext").getJSONObject(0)
        assertEquals("203.0.113.10", vnext.getString("address"))
        assertEquals(443, vnext.getInt("port"))
        val user = vnext.getJSONArray("users").getJSONObject(0)
        assertEquals("00000000-0000-0000-0000-000000000000", user.getString("id"))

        val stream = outbound.getJSONObject("streamSettings")
        assertEquals("tcp", stream.getString("network"))
        assertEquals("tls", stream.getString("security"))
        assertEquals("example.com", stream.getJSONObject("tlsSettings").getString("serverName"))
    }

    @Test fun sniFallsBackToAddressWhenEmpty() {
        // 构造一个无 sni 的 vmess(base64 of minimal JSON)
        val json = """{"add":"1.2.3.4","port":"443","id":"u","tls":"tls","net":"tcp"}"""
        val url = "vmess://" + java.util.Base64.getEncoder().encodeToString(json.toByteArray())
        val link = XrayConfig.parseVmess(url)
        val cfg = JSONObject(XrayConfig.buildXrayConfig(link, 1080))
        val tls = cfg.getJSONArray("outbounds").getJSONObject(0)
            .getJSONObject("streamSettings").getJSONObject("tlsSettings")
        assertEquals("1.2.3.4", tls.getString("serverName"))   // sni 空 → 回退 address
    }

    @Test fun noTlsOmitsSecurity() {
        val json = """{"add":"1.2.3.4","port":"80","id":"u","net":"tcp"}"""
        val url = "vmess://" + java.util.Base64.getEncoder().encodeToString(json.toByteArray())
        val link = XrayConfig.parseVmess(url)
        assertFalse(link.tls)
        val stream = JSONObject(XrayConfig.buildXrayConfig(link, 1080))
            .getJSONArray("outbounds").getJSONObject(0).getJSONObject("streamSettings")
        assertFalse(stream.has("security"))
    }

    @Test fun rejectsNonVmessUrl() {
        assertThrows(IllegalArgumentException::class.java) { XrayConfig.parseVmess("vless://whatever") }
    }

    @Test fun rejectsGarbageBase64() {
        assertThrows(IllegalArgumentException::class.java) { XrayConfig.parseVmess("vmess://!!!not-base64!!!") }
    }
}
