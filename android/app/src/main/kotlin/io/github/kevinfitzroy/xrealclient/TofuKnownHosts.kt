package io.github.kevinfitzroy.xrealclient

import android.util.Log
import net.schmizz.sshj.common.KeyType
import net.schmizz.sshj.transport.verification.OpenSSHKnownHosts
import java.io.File
import java.security.PublicKey

/**
 * Trust-on-first-use known_hosts。
 * 第一次见的 host:自动加 + 持久化,接受连接。
 * 已知 host 的 key 变了:拒绝(默认行为) —— 可能是中间人攻击或重装服务器,user 需要手删 known_hosts 才能再连。
 *
 * 这是 Phase B 自动化路径;Phase 1 真机部署时改成弹 dialog 让 user 显式信任(对照 fingerprint)。
 */
class TofuKnownHosts(file: File) : OpenSSHKnownHosts(ensureFile(file)) {

    override fun hostKeyUnverifiableAction(hostname: String, key: PublicKey): Boolean {
        return try {
            val entry = HostEntry(null, hostname, KeyType.fromKey(key), key)
            entries().add(entry)
            write(entry)
            Log.i(TAG, "TOFU: 加入新 host '$hostname' (${KeyType.fromKey(key)}) ${entry.fingerprint}")
            true
        } catch (e: Exception) {
            Log.w(TAG, "TOFU: 加 known_hosts 失败,拒绝: ${e.message}")
            false
        }
    }

    override fun hostKeyChangedAction(hostname: String, key: PublicKey): Boolean {
        // 故意 fail loud — host key 变了。user 需要手删 filesDir/known_hosts 这一行才能重新接受
        Log.w(TAG, "host key 变了!拒绝连接 host='$hostname' new=${KeyType.fromKey(key)} fp=${java.util.Arrays.hashCode(key.encoded)}")
        return false
    }

    companion object {
        private const val TAG = "TofuKnownHosts"

        /** 文件不存在则建空 — OpenSSHKnownHosts 构造器要求可读 */
        private fun ensureFile(f: File): File {
            if (!f.exists()) f.parentFile?.mkdirs().also { f.writeText("") }
            return f
        }
    }
}
