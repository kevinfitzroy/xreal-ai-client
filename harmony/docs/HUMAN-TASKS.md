# HarmonyOS 适配 — 需你人工做的事(我做不了)

> 凡涉及**环境 / 华为账号 / 真机 / 二选一决策**的,都在这。按依赖顺序排。
> 我能做的(代码 + 文档)已做完;这些是卡在物理/账号/编译上、必须你来的。

---

## T0 先做决策(5 分钟,不需环境)

读 [`DECISIONS.md`](DECISIONS.md),至少定 **D1(SSH backend A/B)**。其余可用默认值。
定完告诉我,我把选中那条 SSH backend 做完(A:补 NAPI 实现;B:补协议栈)。

---

## T1 装鸿蒙开发环境

- **DevEco Studio**(最新版,含 HarmonyOS SDK / API 12+ / JBR / hvigor / ohpm / hdc)。
- 或纯 CLI:**Command Line Tools for HarmonyOS**(无 IDE 也能 `hvigorw` 构建,但首次仍需 `ohpm install` 补工具产物)。
- 设环境变量 `DEVECO_SDK_HOME` 等。
- 验证:`hdc list targets` 能跑、`hvigorw -v` 有版本。

> ⚠️ 我手写的工程骨架到「DevEco 能识别」为止;`oh_modules/`、`oh-package-lock.json5`、`hvigor/hvigor-config.json5`
> 这些**工具生成物**我造不全 —— 首次用 DevEco 打开 `harmony/app/` 或跑一次 `ohpm install` 让它补齐,**才能构建**。

---

## T2 首次打开 + 编译跑通(空壳)

1. DevEco 打开 `harmony/app/`(注意是 `app/` 子目录,不是 `harmony/`)。
2. 让它 sync(补 oh_modules / lock / hvigor-config）。
3. **先把 `ssh/SshBackend.ets` 的 BACKEND 保持 `'arkts'`**(纯 ArkTS 不依赖 native,先确认 ArkTS 全编译通过)。
4. 构建:`cd harmony/app && ./hvigorw --mode module -p product=default -p module=entry@default assembleHap`
   - 预期:**ArkTS 编译通过**;运行起来能看到 **index.html mock 列表 + 终端 UI 壳**(SSH 未完成 → 开 project 会提示连接失败,正常)。
   - 若有 ArkTS 类型/API 报错:多半是我凭调研写的 API 签名与真 .d.ts 有细微出入(几个官方 references 页是 JS 渲染、我无法逐字核)。按 DevEco 类型提示修正,告诉我哪里不符我同步代码。

> 这一步的目的:**先让壳子(Web/列表/键路由/语音 UI)编译通过 + 上模拟器/真机看到界面**,把「我凭文档写的 ArkTS」与「真实 SDK」对齐,再往下做 SSH。

---

## T3 (若选 D1=A)交叉编译 libssh2 → .so

路径 A 需要 `libssh2`(+ OpenSSL 或 mbedTLS)交叉编译成 HarmonyOS arm64 静态/动态库。详见 [`ssh-options.md`](ssh-options.md) §A。概要:

1. 用 **OpenHarmony-SIG/tpc_c_cplusplus(Lycium)** 交叉编译框架,先编 OpenSSL + zlib,再编 libssh2。
2. 产物放 `app/entry/src/main/cpp/libs/arm64-v8a/`(libssh2.a + libcrypto.a),头文件放 `cpp/include/`。
3. 打开 `app/entry/build-profile.json5` 的 `externalNativeOptions`(已写好,注释着)。
4. `app/entry/oh-package.json5` 声明 `"libsshbridge.so": "file:./src/main/cpp/types/libsshbridge"`。
5. `NativeSshChannel.ets` 取消 `import nativeBridge from 'libsshbridge.so'` 注释 + 删占位。
6. `SshBackend.ets` 的 `BACKEND` 改 `'native'`。

> 我能写的:CMake + NAPI 桥骨架(已写)+ ArkTS wrapper(已写)。我做不了的:跑交叉编译(无环境)+ 验证链接。

---

## T4 签名(华为实名账号)

HarmonyOS 真机装包**必须签名**,且比 Android 更绑云端(华为账号 + AppGallery Connect）。

- **注册并实名**华为开发者账号(个人即可,免费;实名需身份证/人脸,绕不过)。
- **自动签名(推荐调试)**:DevEco `File > Project Structure > Signing Configs > Automatically generate signature`,
  连真机后 IDE 自动申请 debug 证书 + profile 回填 `build-profile.json5`(我已留 `signingConfigs: []` 空占位)。
- **手动签名(上架/CI)**:AGC 申请 .cer + .p7b（debug profile 要登记真机 UDID:`hdc shell bm get --udid`），
  四件套(.p12/.cer/.p7b + 密码)填进 `signingConfigs`。**密码绝不进 git**(`.gitignore` 已忽略 signature/ 与 *.p12/.cer/.p7b)。

---

## T5 代客安装(Valet):push 配置 + SSH key 到真机

对应 Android 的 `/data/local/tmp/xreal_hosts.json` 那套。HarmonyOS 用 `hdc`:

```
hdc file send ./hosts.json /data/local/tmp/xreal_import/hosts.json
hdc file send ./asr.json   /data/local/tmp/xreal_import/asr.json
hdc file send ./tk.pem     /data/local/tmp/xreal_import/tk.pem
# 启动 app → SettingsStore.importStagingIfPresent 拷进私有沙箱
```

> ⚠️ **待你真机实测**:NEXT 沙箱对 `/data/local/tmp` 的 app 读权限各版本收紧不一(我无法验)。
> 若 app 读不到 staging:退路 = `hdc file send` 直接送到 app 沙箱物理路径,或 `hdc shell` 里 cp。实测后告诉我,我调 `SettingsStore` 的 staging 路径。
> hosts.json / asr.json 形状 = **与 Android 完全一致**(SPEC §8),可直接复用 Android 那份。

---

## T6 真机验证(物理设备,我做不了)

与 Android「硬件部分你验」同构。要在 XREAL 眼镜 + HarmonyOS 信号源真机上验:

1. **8BitDo 物理键实际 KeyCode**:`KeyRouter.ets` 里 F1=2090/F2=2091 是 HarmonyOS 标准码,但 8BitDo 在鸿蒙设备实际映射**不保证一致**(像 Beam Pro 走 Generic.kl 那样)。`Index.ets` 的 `onKeyEvent` 里打 `e.keyCode`/`e.keyText` log,看真实值,告诉我我改映射。
2. **麦克风**:`AudioCapturer` 的 `readData` 实际回调粒度(我按 200ms 攒包,真机核)。
3. **AR 眼镜全屏 + WebGL**:`EntryAbility` 的沉浸式 + ArkWeb WebGL 在眼镜上的真实显示/GPU 行为。
4. **软键盘抑制**:`onInterceptKeyboardAttach` 是否真的压住系统键盘。
5. **file:// 字体加载**:`WebAssets` + `setPathAllowingUniversalAccess` 下 Meslo/Sarasa 是否正常渲染(中文/powerline)。

每条验完把现象/log 发我,我据此调代码 —— 与 Android/iOS 的真机迭代节奏一致。

---

## 我已做完、你不用管的

- 全部 ArkTS 业务代码(列表/终端/桥/语音/按键/配置)+ 两条 SSH backend 骨架 + cpp NAPI 骨架。
- 工程骨架配置(权限/资源/入口/构建配置)。
- 共享 Web 资产已复制进 rawfile(`sync-web-assets.sh` 可重新同步)。
- 文档(本套)。
