package io.github.kevinfitzroy.xrealclient

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * SSH-over-443 proxy 归属(effectiveProxy)+ localPort 冲突检测的纯逻辑单测(SPEC §5.1,issue #3)。
 * 无 Android/网络依赖。
 */
class ProxyResolveTest {

    private fun ssh() = SshConfig(host = "h", user = "u", privateKeyPem = "x")
    private fun host(name: String, via: String? = null, proxy: ProxyConfig? = null) =
        HostConfig(name = name, addr = name, ssh = ssh(), projects = emptyList(), via = via, proxy = proxy)

    private val px1 = ProxyConfig("edge-443", 39001, "vmess://a")
    private val px2 = ProxyConfig("edge2-443", 39002, "vmess://b")

    @Test fun directHostUsesOwnProxy() {
        val edge = host("edge", proxy = px1)
        assertEquals(px1, edge.effectiveProxy(listOf(edge)))
    }

    @Test fun viaHostUsesJumperProxyNotOwn() {
        // 内网 host 经跳板:生效 proxy = 跳板的 px1;自己声明的 px2 被忽略(拨公网的是跳板)。
        val jump = host("jump", proxy = px1)
        val inner = host("inner", via = "jump", proxy = px2)
        assertEquals(px1, inner.effectiveProxy(listOf(jump, inner)))
    }

    @Test fun viaHostWithMissingJumperResolvesNull() {
        val inner = host("inner", via = "ghost", proxy = px2)
        assertNull(inner.effectiveProxy(listOf(inner)))
    }

    @Test fun noProxyIsDirect() {
        val plain = host("plain")
        assertNull(plain.effectiveProxy(listOf(plain)))
    }

    @Test fun distinctNamesSamePortConflicts() {
        val a = host("a", proxy = ProxyConfig("pa", 39001, "vmess://a"))
        val b = host("b", proxy = ProxyConfig("pb", 39001, "vmess://b"))
        assertNotNull(localPortConflict(listOf(a, b)))   // 两个不同 name 撞同口 → 冲突(fail closed)
    }

    @Test fun sameProxyReusedIsNotConflict() {
        // 两 host 引用同一 proxy(同 name 同 port)→ 不算冲突
        assertNull(localPortConflict(listOf(host("a", proxy = px1), host("b", proxy = px1))))
    }

    @Test fun distinctPortsNoConflict() {
        assertNull(localPortConflict(listOf(host("a", proxy = px1), host("b", proxy = px2))))
    }
}
