import { util } from '@kit.ArkTS';
import { buffer } from '@kit.ArkTS';

/**
 * Base64 / UTF-8 / 二进制小工具。
 * 桥与 index.html 之间走 Base64-over-string(对齐 Android `TerminalBridge` 的 b64 双向桥);
 * 这是平台中立契约的一部分:JS 侧 `btoa`/`atob`,原生侧这里。
 * (HarmonyOS Web 也支持 runJavaScriptExt 直传 ArrayBuffer,可后续提速,见 docs/adaptation.md;
 *  第一版保持与 Android/iOS 一致的 b64 路径,降低跨端心智负担。)
 */
const b64 = new util.Base64Helper();

export class Bytes {
  /** bytes(Uint8Array)→ Base64 字符串 */
  static toB64(data: Uint8Array): string { return b64.encodeToStringSync(data); }

  /** Base64 字符串 → bytes(Uint8Array) */
  static fromB64(s: string): Uint8Array { return b64.decodeSync(s); }

  /** UTF-8 字符串 → bytes */
  static utf8(s: string): Uint8Array { return new Uint8Array(buffer.from(s, 'utf-8').buffer); }

  /** bytes → UTF-8 字符串 */
  static str(data: Uint8Array): string { return buffer.from(data.buffer, data.byteOffset, data.byteLength).toString('utf-8'); }

  /** UTF-8 字符串 → Base64(便捷:语音/控制字节注入用) */
  static strToB64(s: string): string { return b64.encodeToStringSync(Bytes.utf8(s)); }

  /** ArrayBuffer → Uint8Array */
  static u8(buf: ArrayBuffer): Uint8Array { return new Uint8Array(buf); }
}
