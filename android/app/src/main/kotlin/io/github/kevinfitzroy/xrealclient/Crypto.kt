package io.github.kevinfitzroy.xrealclient

import org.bouncycastle.jce.provider.BouncyCastleProvider
import java.security.Security

/**
 * 修 sshj-on-Android 的 BouncyCastle 冲突(Stage A.2)。
 *
 * Android 自带一个**精简版** BC(`com.android.org.bouncycastle`)注册为 provider 名 "BC",
 * 会遮蔽我们打包的完整 `bcprov-jdk18on`。结果:sshj 协商 KEX 时找不到 `X25519`
 * (`curve25519-sha256`,现代 OpenSSH 默认),报 `no such algorithm: X25519 for provider BC`。
 *
 * 修法:移除系统 "BC",把完整 [BouncyCastleProvider] 插到最前。必须在任何 SSHClient 创建前调一次。
 */
object Crypto {
    @Volatile private var done = false

    @Synchronized
    fun ensureFullBouncyCastle() {
        if (done) return
        Security.removeProvider("BC")
        Security.insertProviderAt(BouncyCastleProvider(), 1)
        done = true
    }
}
