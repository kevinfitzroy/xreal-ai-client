import { fileIo as fs } from '@kit.CoreFileKit';
import { AppCtx } from '../util/AppCtx';
import { Log } from '../util/Logger';

/**
 * 把 rawfile 里的共享 Web 资产拷进沙箱 web 目录,供 Web 组件用 `file://` + setPathAllowingUniversalAccess 加载。
 *
 * 为什么不用 `$rawfile('index.html')` 直接当 src(那更简单):
 *   ArkWeb 在 resource:// 协议下,API 12 起默认禁 file/resource 跨源请求 → @font-face 引同目录字体 / fetch addon 易失败。
 *   file:// + setPathAllowingUniversalAccess(整目录放行)= Android `allowFileAccessFromFileURLs` 的等价物,
 *   一次性解决字体 + addon 同源(见 docs/adaptation.md「资产加载」与 DECISIONS.md D3 的两条路对比)。
 *
 * copy-if-absent:字体大(8MB),不每次启动重拷;按文件存在跳过。
 */
const TAG = 'WebAssets';
const ASSETS = ['index.html', 'xterm.js', 'xterm.css', 'addon-fit.js', 'addon-webgl.js',
  'addon-search.js', 'addon-unicode11.js', 'meslo-powerline.otf', 'sarasa-term.ttf'];

export class WebAssets {
  /** 返回沙箱 web 目录绝对路径(已铺好资产)。 */
  static prepare(): string {
    const dir = `${AppCtx.get().filesDir}/web`;
    try { if (!fs.accessSync(dir)) { fs.mkdirSync(dir); } } catch (e) { Log.w(TAG, 'mkdir ' + e); }
    const rm = AppCtx.get().resourceManager;
    for (const name of ASSETS) {
      const dst = `${dir}/${name}`;
      try {
        if (fs.accessSync(dst)) { continue; }   // 已存在,跳过(copy-if-absent)
        const content: Uint8Array = rm.getRawFileContentSync(name);
        const f = fs.openSync(dst, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE);
        fs.writeSync(f.fd, content.buffer.slice(0, content.byteLength));
        fs.closeSync(f);
      } catch (e) { Log.w(TAG, `copy ${name} ${e}`); }
    }
    Log.i(TAG, 'web assets at ' + dir);
    return dir;
  }
}
