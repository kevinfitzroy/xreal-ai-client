/**
 * SSH 线格式编解码(RFC 4251 §5)—— 纯 ArkTS SSH(路径 B)用。
 * 类型:byte / boolean / uint32 / uint64 / string(uint32 长度前缀 + 字节)/ mpint / name-list。
 * 这层是纯函数、无平台依赖,最容易先写对、可单测。
 */

export class SshWriter {
  private parts: Uint8Array[] = [];
  private len = 0;

  byte(b: number): SshWriter { return this.push(new Uint8Array([b & 0xff])); }
  bool(v: boolean): SshWriter { return this.byte(v ? 1 : 0); }

  uint32(n: number): SshWriter {
    const a = new Uint8Array(4);
    a[0] = (n >>> 24) & 0xff; a[1] = (n >>> 16) & 0xff; a[2] = (n >>> 8) & 0xff; a[3] = n & 0xff;
    return this.push(a);
  }

  /** string = uint32 长度 + 原始字节 */
  bytes(data: Uint8Array): SshWriter { this.uint32(data.length); return this.push(data); }
  str(s: string): SshWriter { return this.bytes(utf8(s)); }
  nameList(names: string[]): SshWriter { return this.str(names.join(',')); }

  /** mpint:大端有符号大整数,最高位为 1 时前补 0x00(我们只用正数) */
  mpint(data: Uint8Array): SshWriter {
    let i = 0; while (i < data.length && data[i] === 0) { i++; }   // 去前导 0
    const trimmed = data.subarray(i);
    if (trimmed.length === 0) { return this.uint32(0); }
    if (trimmed[0] & 0x80) {
      const padded = new Uint8Array(trimmed.length + 1); padded.set(trimmed, 1);
      return this.bytes(padded);
    }
    return this.bytes(trimmed);
  }

  raw(data: Uint8Array): SshWriter { return this.push(data); }

  private push(a: Uint8Array): SshWriter { this.parts.push(a); this.len += a.length; return this; }

  build(): Uint8Array {
    const out = new Uint8Array(this.len); let o = 0;
    for (const p of this.parts) { out.set(p, o); o += p.length; }
    return out;
  }
}

export class SshReader {
  private off = 0;
  constructor(private buf: Uint8Array) {}

  remaining(): number { return this.buf.length - this.off; }
  byte(): number { return this.buf[this.off++]; }
  bool(): boolean { return this.byte() !== 0; }

  uint32(): number {
    const b = this.buf, o = this.off; this.off += 4;
    return ((b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3]) >>> 0;
  }

  bytes(): Uint8Array { const n = this.uint32(); const s = this.buf.subarray(this.off, this.off + n); this.off += n; return s; }
  str(): string { return utf8Decode(this.bytes()); }
  nameList(): string[] { const s = this.str(); return s.length ? s.split(',') : []; }
  mpint(): Uint8Array { return this.bytes(); }
  rest(): Uint8Array { return this.buf.subarray(this.off); }
  skip(n: number): void { this.off += n; }
}

export function utf8(s: string): Uint8Array {
  const out: number[] = [];
  for (let i = 0; i < s.length; i++) {
    let c = s.charCodeAt(i);
    if (c < 0x80) { out.push(c); }
    else if (c < 0x800) { out.push(0xc0 | (c >> 6), 0x80 | (c & 0x3f)); }
    else if (c >= 0xd800 && c <= 0xdbff) {
      const c2 = s.charCodeAt(++i); c = 0x10000 + ((c & 0x3ff) << 10) + (c2 & 0x3ff);
      out.push(0xf0 | (c >> 18), 0x80 | ((c >> 12) & 0x3f), 0x80 | ((c >> 6) & 0x3f), 0x80 | (c & 0x3f));
    } else { out.push(0xe0 | (c >> 12), 0x80 | ((c >> 6) & 0x3f), 0x80 | (c & 0x3f)); }
  }
  return new Uint8Array(out);
}

function utf8Decode(a: Uint8Array): string {
  let s = ''; let i = 0;
  while (i < a.length) {
    const c = a[i++];
    if (c < 0x80) { s += String.fromCharCode(c); }
    else if (c < 0xe0) { s += String.fromCharCode(((c & 0x1f) << 6) | (a[i++] & 0x3f)); }
    else if (c < 0xf0) { s += String.fromCharCode(((c & 0x0f) << 12) | ((a[i++] & 0x3f) << 6) | (a[i++] & 0x3f)); }
    else { let cp = ((c & 0x07) << 18) | ((a[i++] & 0x3f) << 12) | ((a[i++] & 0x3f) << 6) | (a[i++] & 0x3f);
      cp -= 0x10000; s += String.fromCharCode(0xd800 + (cp >> 10), 0xdc00 + (cp & 0x3ff)); }
  }
  return s;
}
