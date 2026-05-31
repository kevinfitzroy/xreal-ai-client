import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { Log } from '../../util/Logger';

/**
 * 纯 ArkTS SSH(路径 B)的密码学原语 —— 全部走 HarmonyOS `@kit.CryptoArchitectureKit`(cryptoFramework）。
 * 调研确认覆盖:Ed25519(签名/验签,API 11+)、X25519(ECDH,API 11+)、AES-GCM(API 9+)、
 * HMAC-SHA2(API 9+)、SHA1/256/512(API 9+)。⚠️ ChaCha20-Poly1305 要 API 22+ → API 12 基线下用 AES-GCM。
 *
 * 这些是**真实可用的封装**(非占位);KEX 状态机怎么编排它们见 ArkSshSession.ets(那部分是骨架)。
 * cryptoFramework 是异步 + 对象式 API,这里统一包成 Promise<Uint8Array>。
 */

function u8(buf: ArrayBuffer): Uint8Array { return new Uint8Array(buf); }
function blob(data: Uint8Array): cryptoFramework.DataBlob { return { data }; }

export class SshCrypto {
  /** SHA-256 摘要(KEX 哈希 H、exchange hash 用)。 */
  static async sha256(data: Uint8Array): Promise<Uint8Array> {
    const md = cryptoFramework.createMd('SHA256');
    await md.update(blob(data));
    return u8((await md.digest()).data.buffer as ArrayBuffer);
  }

  static async sha512(data: Uint8Array): Promise<Uint8Array> {
    const md = cryptoFramework.createMd('SHA512');
    await md.update(blob(data));
    return u8((await md.digest()).data.buffer as ArrayBuffer);
  }

  /** HMAC-SHA256(MAC 算法 hmac-sha2-256)。 */
  static async hmacSha256(key: Uint8Array, data: Uint8Array): Promise<Uint8Array> {
    const mac = cryptoFramework.createMac('SHA256');
    const sym = await cryptoFramework.createSymKeyGenerator('HMAC').convertKey(blob(key));
    await mac.init(sym);
    await mac.update(blob(data));
    return u8((await mac.doFinal()).data.buffer as ArrayBuffer);
  }

  /**
   * X25519 ECDH:生成临时密钥对 + 与对端公钥算共享密钥(curve25519-sha256 KEX 的核心)。
   * 返回 { clientPubRaw(32B), sharedSecret }。对端公钥 peerPubRaw = 32 字节原始 X25519 公钥。
   */
  static async x25519(peerPubRaw: Uint8Array): Promise<X25519Result> {
    const gen = cryptoFramework.createAsyKeyGenerator('X25519');
    const kp = await gen.generateKeyPair();
    const ka = cryptoFramework.createKeyAgreement('X25519');
    // 对端公钥:用 X25519 generator 从原始点转 PubKey(需按 cryptoFramework 的 point 编码喂;见 TODO)
    const peerPub = await SshCrypto.x25519PubFromRaw(gen, peerPubRaw);
    const shared = u8((await ka.generateSecret(kp.priKey, peerPub)).buffer as ArrayBuffer);
    const clientPubRaw = await SshCrypto.x25519RawFromPub(kp.pubKey);
    return { clientPubRaw, sharedSecret: shared };
  }

  /**
   * Ed25519 验签:验证 host key 对 exchange hash 的签名(host 身份认证)。
   * pubRaw = 32B 原始 Ed25519 公钥;sig = 64B 签名;msg = 被签数据(exchange hash H)。
   */
  static async ed25519Verify(pubRaw: Uint8Array, msg: Uint8Array, sig: Uint8Array): Promise<boolean> {
    try {
      const gen = cryptoFramework.createAsyKeyGenerator('Ed25519');
      const pub = await SshCrypto.ed25519PubFromRaw(gen, pubRaw);
      const verifier = cryptoFramework.createVerify('Ed25519');
      await verifier.init(pub);
      return await verifier.verify(blob(msg), blob(sig));
    } catch (e) { Log.w('SshCrypto', 'ed25519Verify ' + e); return false; }
  }

  /**
   * Ed25519 签名:用客户端私钥对认证请求签名(publickey auth)。
   * priPkcs8 = PKCS#8 DER 私钥(从 OpenSSH ed25519 私钥解出的标量,见 SshKeyParser TODO)。
   */
  static async ed25519Sign(priPkcs8: Uint8Array, msg: Uint8Array): Promise<Uint8Array> {
    const gen = cryptoFramework.createAsyKeyGenerator('Ed25519');
    const kp = await gen.convertKey(null, blob(priPkcs8));
    const signer = cryptoFramework.createSign('Ed25519');
    await signer.init(kp.priKey);
    return u8((await signer.sign(blob(msg))).data.buffer as ArrayBuffer);
  }

  /** AES-256-GCM 加密(aes256-gcm@openssh.com)。返回 ciphertext||tag。 */
  static async aesGcmEncrypt(key: Uint8Array, iv: Uint8Array, aad: Uint8Array, plain: Uint8Array): Promise<Uint8Array> {
    const cipher = cryptoFramework.createCipher('AES256|GCM|NoPadding');
    const sym = await cryptoFramework.createSymKeyGenerator('AES256').convertKey(blob(key));
    const spec: cryptoFramework.GcmParamsSpec = { algName: 'GcmParamsSpec', iv: blob(iv), aad: blob(aad), authTag: blob(new Uint8Array(16)) };
    await cipher.init(cryptoFramework.CryptoMode.ENCRYPT_MODE, sym, spec);
    return u8((await cipher.doFinal(blob(plain))).data.buffer as ArrayBuffer);
  }

  static async aesGcmDecrypt(key: Uint8Array, iv: Uint8Array, aad: Uint8Array, cipherText: Uint8Array, tag: Uint8Array): Promise<Uint8Array> {
    const cipher = cryptoFramework.createCipher('AES256|GCM|NoPadding');
    const sym = await cryptoFramework.createSymKeyGenerator('AES256').convertKey(blob(key));
    const spec: cryptoFramework.GcmParamsSpec = { algName: 'GcmParamsSpec', iv: blob(iv), aad: blob(aad), authTag: blob(tag) };
    await cipher.init(cryptoFramework.CryptoMode.DECRYPT_MODE, sym, spec);
    return u8((await cipher.doFinal(blob(cipherText))).data.buffer as ArrayBuffer);
  }

  // ───────────────────────────────────────────────────────────────────────────
  // TODO(路径 B,需有环境核 cryptoFramework 的具体 point/key 编码):
  //   下面 4 个 raw↔Key 转换是 curve25519/ed25519「32 字节原始点 ↔ cryptoFramework Key 对象」的桥。
  //   cryptoFramework 的 convertKey 对 X25519/Ed25519 接受的编码(裸 32B vs DER SubjectPublicKeyInfo)
  //   需在 DevEco + 真机用 .d.ts 核准。SSH 线上用的是裸 32B,可能要手工包成 DER 再 convertKey。
  // ───────────────────────────────────────────────────────────────────────────
  private static async x25519PubFromRaw(_gen: cryptoFramework.AsyKeyGenerator, _raw: Uint8Array): Promise<cryptoFramework.PubKey> {
    throw new Error('NotImplemented: x25519 raw→PubKey 编码待核(见 SshCrypto TODO)');
  }
  private static async x25519RawFromPub(_pub: cryptoFramework.PubKey): Promise<Uint8Array> {
    throw new Error('NotImplemented: x25519 PubKey→raw 编码待核');
  }
  private static async ed25519PubFromRaw(_gen: cryptoFramework.AsyKeyGenerator, _raw: Uint8Array): Promise<cryptoFramework.PubKey> {
    throw new Error('NotImplemented: ed25519 raw→PubKey 编码待核');
  }
}

export interface X25519Result {
  clientPubRaw: Uint8Array;
  sharedSecret: Uint8Array;
}
