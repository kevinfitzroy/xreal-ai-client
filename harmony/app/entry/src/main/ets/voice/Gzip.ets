import { zlib } from '@kit.BasicServicesKit';
import { Log } from '../util/Logger';

/**
 * 内存 gzip —— 豆包流式协议要求 payload gzip(VolcFrame)。
 * ⚠️ 坑(调研):zlib 高层 `compress()` 产出的是 **zlib 格式**(含 zlib 头),不是 gzip。
 *    必须用底层 `deflateInit2(..., windowBits=31, ...)`(31 = 15+16 → gzip 格式),纯内存、不落文件。
 */
const TAG = 'Gzip';

export class Gzip {
  static async compress(input: Uint8Array): Promise<Uint8Array> {
    const out = new ArrayBuffer(input.byteLength + 128);   // 预留;小输入足够
    const zip = zlib.createZipSync();
    const strm: zlib.ZStream = {
      nextIn: input.buffer.slice(input.byteOffset, input.byteOffset + input.byteLength),
      availableIn: input.byteLength,
      nextOut: out,
      availableOut: out.byteLength
    };
    try {
      await zip.deflateInit2(strm,
        zlib.CompressLevel.COMPRESS_LEVEL_DEFAULT_COMPRESSION,
        8 /* Z_DEFLATED */, 31 /* gzip */,
        zlib.MemLevel.MEM_LEVEL_DEFAULT,
        zlib.CompressStrategy.COMPRESS_STRATEGY_DEFAULT_STRATEGY);
      await zip.deflate(strm, zlib.CompressFlushMode.FINISH);
      await zip.deflateEnd(strm);
      // 实际输出长度 = 预留 - 剩余
      const produced = out.byteLength - strm.availableOut;
      return new Uint8Array(out.slice(0, produced));
    } catch (e) {
      Log.e(TAG, 'gzip ' + e);
      throw e as Error;
    }
  }

  /** gunzip(解压豆包 gzip 响应)。windowBits=31 = 自动识别 gzip 头。 */
  static async decompress(input: Uint8Array, hint: number = 4096): Promise<Uint8Array> {
    const out = new ArrayBuffer(Math.max(hint, input.byteLength * 4 + 64));
    const zip = zlib.createZipSync();
    const strm: zlib.ZStream = {
      nextIn: input.buffer.slice(input.byteOffset, input.byteOffset + input.byteLength),
      availableIn: input.byteLength,
      nextOut: out,
      availableOut: out.byteLength
    };
    try {
      await zip.inflateInit2(strm, 31 /* gzip */);
      await zip.inflate(strm, zlib.CompressFlushMode.FINISH);
      await zip.inflateEnd(strm);
      const produced = out.byteLength - strm.availableOut;
      return new Uint8Array(out.slice(0, produced));
    } catch (e) {
      Log.e(TAG, 'gunzip ' + e);
      throw e as Error;
    }
  }
}
