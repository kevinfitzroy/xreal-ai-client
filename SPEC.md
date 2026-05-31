# SPEC.md — XREAL AI Client 客户端契约(平台中立)

> **Contract version: 1**
>
> 这是 XREAL AI Client **所有客户端实现的单一真相源**。当前有两个目标客户端:
> **Android**(已上真机,Kotlin)与 **iOS**(规划中,Swift)。两端都实现**这一层**;
> 平台代码坐在契约之下。
>
> **防内耗铁律**:任何跨端行为(列表怎么来、状态怎么算、语音怎么注入、按键什么语义、
> 配置怎么进来)**只在这份文档里定义一次**。改契约 = 改这份 + 两端对齐(见 §12)。
> 平台专属实现细节(Kotlin/Swift、WebView/WKWebView、Service/background-mode)**不写进契约正文**,
> 只在 §11 平台矩阵里登记落点。
>
> 服务端(Maestro)是这份契约的**生产侧**,其实现指南见 [`docs/orchestrator-CLAUDE.md`](docs/orchestrator-CLAUDE.md);
> 二者必须一致,改服务端契约(§2/§3)时两边同步。

---

## 0. 谁该读这份

- **实现某个客户端的 agent**(Android 或 iOS):这是你必须满足的行为契约。先读这份,再读你那端的平台代码。
- **改服务端 Maestro / 脚本的 agent**:§2 manifest、§3 status、§4 voice 是你和客户端的接口,改形状前看这份。
- **做产品/架构决策的人**:§1 是边界,§9 是底线。

不在这份里的东西:**怎么用某语言实现**(看各端仓库/目录)、**为什么这么设计**(看 [`docs/`](docs/) 背景/架构/决策文档)。

---

## 1. 系统角色与边界(一句话架构)

客户端 = **Agent Deck**:一个 **host(一级)→ project(二级)** 的列表,每个 project = 一个工作目录 + 一个持久 tmux/abduco session。用户戴 **AR 眼镜**,用**物理小键盘(~6 键)+ 中英语音**操作,没有舒适鼠标/键盘。

```
客户端(Android / iOS)
├─ 列表:从各 host 的 manifest 拉(§2),显示运行状态(§3)
├─ 终端:xterm.js in WebView,渲染远端 PTY
├─ SSH:直连云端(§5),内网 host 经多跳跳板(§5 via)
├─ 语音:录音 → 豆包 ASR(§7)→ 直写 SSH(§4)
└─ 物理键:按语义路由(§6)
        │ Raw SSH(port 22),内网经 ProxyJump
        ▼
各 host:tmux + Claude Code + Maestro 编排
        └─ .xreal/ 下写 manifest(§2)+ status.json(§3)
```

**边界(不可 deviate,见 [`CLAUDE.md`](CLAUDE.md) §5):**
- **服务端零增量**,唯一例外 = 每 host `.xreal/` 的状态 hooks(§3)。不引入 ttyd/nginx/Voice Gateway。
- **单 app 闭环**:SSH + 终端 + 语音全在一个进程/一个 app 内。
- **客户端只读 manifest/status,只写 SSH 输入**;它不是真相源,各 host 的 Maestro 才是。

---

## 2. Manifest 契约(host→project 列表的真相源)

每个 host 上由 Maestro 维护的项目清单。**客户端只读,Maestro 只写。形状错了客户端就读不到项目。**

- **位置**:`<basePath>/.xreal/projects.json`(`basePath` 由客户端的 host 配置给,见 §8)。
- **首次不存在**:Maestro 负责创建合法空清单 `{ "version": 1, "projects": [] }`。
- **原子写**:Maestro 必须 `tmp → mv` 覆盖,避免客户端读到半截 JSON。

**schema:**
```jsonc
{
  "version": 1,
  "projects": [
    {
      "session": "blog-rewrite",      // tmux session 名,唯一,只允许 [A-Za-z0-9_.-](客户端会拼进 shell 命令)
      "name": "博客重写",              // 显示名(可中文)
      "type": "claude",               // maestro | claude | agent | ssh
      "dir": "/home/evan/work/blog",  // 工作目录绝对路径(给 Maestro 自己备忘;客户端不直接用)
      "group": "work",                // 可选:分组标签
      "startup": "claude --resume",   // 可选:重启备忘(客户端不执行)
      "hotwords": ["kubectl", "Grafana"]  // 可选:project 级语音热词(§7)
    }
  ]
}
```

**type 枚举(客户端据此分类 + 决定语音前缀 §4):**
| type | 含义 | 是 AI-agent? |
|---|---|---|
| `maestro` | host 的 orchestrator,每 host 一个 | 是 |
| `claude` | Claude Code 会话 | 是 |
| `agent` | 其它 AI agent | 是 |
| `ssh` | 裸 shell(日志/REPL 等配角终端) | **否** |

**maestro 置顶规则**:`type":"maestro"` 的项,客户端**pin 到该 host 列表首位**,给专属图标/色。Maestro 把自己列在首位,`session/name/type` 固定 `"maestro"/"Maestro"/"maestro"`。

---

## 3. 状态契约(运行状态显示)

客户端列表给每个 project 显示运行状态徽章 + 时长。状态由 **Claude Code hooks 事件驱动上报(不抓屏)**。

- **位置**:`<basePath>/.xreal/status.json`,客户端**一次性读**(列表加载时,**非轮询**——实时刷新是搁置的 P2)。
- **来源**:hooks 在 project 的 `.claude/settings.json` 配好,事件触发写本文件:
  | hook 事件 | → 状态 |
  |---|---|
  | `UserPromptSubmit` | `working` |
  | `Stop` / `SessionStart` | `waiting` |
  | `SessionEnd` | `disconnected` |
  | `Notification`(matcher `permission_prompt`) | `needs-permission` |

**schema(聚合文件;`sessions` 是数组,不是 map):**
```jsonc
{
  "timestamp": 1748600000,          // 本次聚合的 epoch 秒(信息性,客户端不依赖)
  "sessions": [
    { "session": "blog-rewrite", "state": "working", "since": 1748600000, "updated": 1748600050 },
    { "session": "maestro",      "state": "waiting", "since": 1748599000, "updated": 1748600050 }
  ]
}
```
- `since` = 进入当前 state 的 epoch 秒(state 不变则保留,客户端据此算时长);`updated` = 最近一次 hook 触发(信息性)。
- 服务端实现:每 session 一个 `<base>/.xreal/status/<session>.json`,`agent-status.sh` 触发时重新聚合成上面的 `status.json`(`docs/xreal-project.sh`)。客户端只读 `session`/`state`/`since`。

**状态枚举(客户端 [`SPEC §11` 平台矩阵] 共同实现):**
| state | 来源 | 客户端显示 |
|---|---|---|
| `working` | hooks | 绿色 + 转圈,`Nm working` |
| `waiting` | hooks | 琥珀脉冲,`Nm waiting` |
| `needs-permission` | hooks(权限弹窗) | **视觉同 waiting**,文案「需确认」(= waiting 的细分,不算独立颜色) |
| `disconnected` | hooks 或客户端(host 不可达) | 红色,`offline` |
| `unknown` | **客户端兜底**(无 hooks 上报) | **不显示徽章** |

> 「4 态简化模型」= working/waiting/disconnected/unknown;`needs-permission` 是 waiting 的细分上报值,客户端可独立提示(现为「需确认」)但归在 waiting 视觉族。**刻意不再增加更多状态,也不做 capture-pane 兜底**(实在不清楚就 unknown)。

**客户端合并规则(实现要求):**
1. host **不可达**(manifest 拉取失败)→ 该 host 所有 project 显示 `disconnected`。
2. host 可达 + status.json 有该 session → 用上报状态。
3. host 可达 + 无该 session 记录 → `unknown`(无徽章)。**不做 capture-pane 兜底。**

**展示规则(实现要求):**
- 时长 = `now - since`;`<0` 或 `>1440` 分钟则隐藏时长(钟偏/陈旧)。文案如 `3m working`、`12m waiting`。
- **增量渲染防闪烁**:状态刷新走 **DOM patch**(按 **`host + " " + session` 复合键**定位,**不能只用 session**——不同 host 会有同名 `maestro` session,只用 session 会串台),不整列表重绘。结构变了(project 增删)才重渲染。

---

## 4. 语音注入契约(🎤 约定)

ASR 出文本后,客户端**直写 SSH outputStream**,字符走 SSH 到远端 shell,shell echo 回送,xterm.js 渲染。**语音路径不需要知道终端 UI 存在。**

- **AI-agent 类会话**(`maestro`/`claude`/`agent`)注入时**加 `🎤 ` 前缀**(U+1F3A4 + 空格),让对端 agent 知道这是语音转写、可能有同音/断词错误,按意图理解。
- **`ssh` 类**(裸 shell)**不加前缀**,直接注入。
- **写入必须后台单线程**(平台无关的硬约束):主线程写会永久损坏 SSH 库的输出缓冲(见 [`CLAUDE.md`](CLAUDE.md) memory `input-path-constraints`)。

对端 agent 侧怎么对待 `🎤 ` 见 [`docs/orchestrator-CLAUDE.md`](docs/orchestrator-CLAUDE.md) §6.2(Maestro 把这段 seed 进每个 AI 子项目的 `CLAUDE.md`)。

---

## 5. 会话 / SSH 契约

- **session 驻留**:
  - `claude`/`agent`/`maestro` 类 → 用 **tmux**(状态/预览需要 `capture-pane` 能力)。
  - `ssh` 类 → abduco 或 tmux 均可。
  - 启动命令可配置(`SshConfig.startupCommand`,默认 `abduco -A dev bash`;agent 类由列表逻辑换成 tmux attach)。
- **tmux 约定**(客户端拼 attach 命令时):
  - UTF-8:client 用 `tmux -u`。
  - session 名只信任 `[A-Za-z0-9_.-]`(要拼进 `tmux capture-pane -t '<session>'` 等 shell 命令)。
  - attach 用 `new -A -s <session>`(存在则 attach,不存在则建)。
- **多跳(ProxyJump)**:host 配置带 `via`(= 另一 host 的 `name`)→ SSH 经该跳板本地端口转发到达。典型:OPS(AWS 内网,只 VPN 可达)`via: "TK-ALIYUN"`,由挂 OpenVPN 的 TK 转发。手机本身**不挂 VPN**。
- **known_hosts**:**TOFU**(首次信任并记录,之后校验)。

### 5.1 SSH-over-443 隧道(可选,per-host opt-in)

**动机**:SSH 走 :22 连海外 host 常被 GFW 限速/阻断(DPI 在 KEX 阶段定点丢包),但同机 :443 的 xray(vmess+TLS)服务正常。客户端**可选**地内嵌 xray-core,起一个**仅本地**的 **dokodemo-door** inbound(`127.0.0.1:<随机口>`),把进来的 SSH 连接**目标 override 改写成服务端的 `127.0.0.1:22`** 再送进 vmess/tls:443 隧道 → SSH-over-443。客户端让 SSH **直连这个本地口**(不走 SOCKS)。

- **⭐ 为什么是 dokodemo-door override,不是 SOCKS**(关键,踩过坑):若用 SOCKS inbound 让 SSH 去连 `节点公网IP:22`,目标正是 vmess 出口节点**自己**的地址 → 触发 xray/代理客户端的**自指防环(loop protection):拒绝把"连自己"的流量塞进通往自己的隧道 → 悄悄退化成直连** → 直连的 :22 正是被 GFW 卡的那条。dokodemo-door 把 dest override 成 `127.0.0.1:22`(不是节点公网 IP)→ 躲过防环;服务端 xray 默认 freedom 出站把 `127.0.0.1:22` 当**它自己的 localhost** 直达 sshd。(参考 `~/claude/vpn/ssh-over-vmess.md` §2-§3;sing-box 的 `direct` inbound override 同理。)
- **零服务端增量**:复用用户已有的 :443 xray 服务 + 服务端默认 freedom 出站(§CLAUDE.md 边界的既有例外不扩大,**不需任何服务端配置改动**)。
- **不挂系统 VPN / 不用 tun**:只起一个 dokodemo-door inbound,**仅代理 app 自己的 SSH 连接**,不碰系统其它流量,无需 VpnService 权限。
- **可选 + 优雅降级**:host 不带 `proxy` → 直连(现有行为完全不变)。客户端若没内嵌 xray-core(未 build wrapper)→ 带 `proxy` 的 host 视为"代理不可用",连接失败并提示,**不影响其它直连 host**(§9)。
- **`proxies` 表**:命名代理,host 按名 `"proxy":"<name>"` 引用(多 host 可共享一个 proxy,不重复粘 URL)。
- **⚠️ 当前只支持 `vmess://`**(标准 v2rayN 分享链接,base64 JSON)。`vless://` / `ss://` / `trojan://` 等**暂不支持**——客户端解析器只认 `vmess://` 前缀,其它前缀直接报错(该 host 连接失败,不影响直连 host)。底层 xray-core 本身支持全协议,扩展只需在客户端加 URL parser + 生成对应 outbound 配置(见各端实现),**协议范围是客户端解析层的限制,不是隧道架构的限制**。
- **⭐ proxy 归属"拨公网的那一跳"**(与 `via` 的交互规则,平台无关):
  - **直连 host**(无 `via`)带 `proxy` → 该 host 自己经隧道(dokodemo override 到服务端 `127.0.0.1:port`)拨号。
  - **多跳 host**(有 `via`)→ proxy 跟着 `via` 指向的**跳板** host 走(拨公网的是跳板);到达跳板后的内层转发已在隧道内,**不再**叠加 proxy。即:一个 host 的 `proxy` 字段在它**作为跳板被别人 `via`** 时生效于那条外层拨号;host 自己有 `via` 时,其 `proxy` 字段被忽略(由跳板的 proxy 决定)。
  - 第一版实现聚焦**直连 host 带 proxy**;proxy×via 复合按上述规则但可后置。
- **⭐ UI 契约:host 头必须显示生效的 proxy 标识**(跨端,两端都要做)。用户在 AR 眼镜下要能**一眼确认这台 host 是走隧道还是直连**,否则代理生没生效完全不可见。规则:
  - host 解析出生效 proxy(直连=自己的 `proxy`;多跳=按上面归属规则取**跳板**的 proxy)→ host 头显示一个 **🔒 + proxy 名** 的徽章(如 `🔒 tk-443`);无 proxy → 不显示(直连 host 视觉无变化)。
  - 标识取的是"实际拨公网那一跳的 proxy 名",所以经 `via` 的内网 host 也会显示其跳板的 proxy 名(因为它的流量确实经那条隧道出去)。
  - 这是**显示契约**(显示什么、何时显示),具体渲染(徽章位置/配色)是平台实现(§11)。
- **公钥算法 = 一律 `ed25519`(硬约定)**:Valet 给客户端签发的 key **必须是 `ed25519`**。背景:iOS 的 Citadel 0.12 用 **RSA** key 时签名走 legacy `ssh-rsa`(SHA-1),现代 OpenSSH 默认 `PubkeyAcceptedAlgorithms` 不收 → 认证失败;ed25519 无此问题,所有现代 host 都收。**现状(2026-05-31 核实):真实 host 已全部 ed25519** —— `xreal_TK-ALIYUN`/`xreal_OPS`/dev-rig `xreal_phase0` 都是 ED25519,**无需迁移**。POC 当时撞 ssh-rsa 只因用了 RSA throwaway。**坚持 ed25519、不要用 RSA key**,这条就不是问题。(Android/sshj 对 RSA 是否协商 rsa-sha2 未核实,但既然统一 ed25519 就无关。)
- **翻页语义**:见 §6(它是输入语义的一部分)。

---

## 6. 输入语义契约(物理键 + 翻页)

客户端**统一这些语义**;**物理按键映射 per-device**(下表),但语义跨端一致。

| 语义 | 行为 |
|---|---|
| **语音** | **hold-to-talk**:按住=录音,松开=结束并注入(§4)。**不是 toggle**。 |
| **返回列表** | 从终端回到 host/project 列表 |
| **翻页 上 / 下** | 进 tmux copy-mode **半页**滚动(避免与 Claude Code 自身翻页冲突) |
| **确认/回车** | 标准 Enter(语音 overlay 确认也走它) |

**物理映射(per-device,登记在此,新设备追加):**
| 设备 | 语音 | 返回 | 翻页上/下 | 备路径 |
|---|---|---|---|---|
| Beam Pro X4100 + 8BitDo Micro | **F1**(keycode 131) | **F2**(132) | **Shift+↑ / Shift+↓** | Ctrl+Alt+1/2 |
| iOS(规划) | GameController framework 映射,待 POC 定 | 同 | 同 | — |

> 为什么 Beam Pro 用 F1/F2 而非原设计 F13/F14:Beam Pro 的 `Generic.kl` 注释掉了 F13–F24,keycode 到不了 app(Stage A.1 实测)。详见 [`CLAUDE.md`](CLAUDE.md) §5。

### 6.1 屏幕方向 + 虚拟键盘(UI 契约,**per-platform 不同**)

| 平台 | 屏幕方向 | 虚拟键盘行数 |
|---|---|---|
| Android(Beam Pro) | **锁横屏**(AR 眼镜固定横向) | 单行(终端态显示) |
| iOS(iPhone) | **横竖兼容**(随设备旋转,终端 `fitAddon` 重排) | **横屏 1 行 / 竖屏 2 行**(CSS media query 响应) |

- **硬件键盘接入 → 虚拟键盘消失**(两端一致语义):检测到外接/蓝牙键盘(8BitDo)connect → 客户端调 `window.setHwKeyboard(true)` 隐藏虚拟键盘;disconnect → 恢复。Android 走 `onConfigurationChanged`/`Configuration.keyboard`;iOS 走 `GCKeyboardDidConnect`/`GCKeyboardDidDisconnect`(GameController)。**`index.html` 的隐藏逻辑(`setHwKeyboard`)是共享的**,各端只负责**检测并调用**。
- 虚拟键盘的响应式行数 = `index.html` 的 CSS media query(**共享资产**);Android 锁横屏 → 永远命中 1 行分支,该改动对 Android **无可见影响**。

---

## 7. ASR 契约(语音识别)

- **引擎**:豆包(VolcEngine)**流式** ASR。`resourceId` 默认 `volc.seedasr.sauc.duration`(流式 2.0 小时版)。
- **凭证**:`{ provider:"VOLC", appid, token, resourceId }`,经代客安装(§8)进私有存储,**无设置 UI**。
- **热词** = **内置通用词**(Claude Code 控制命令:compact/context/agent/resume/model… 所有 project 继承)+ **该 project 的 manifest `hotwords`**(§2),合并后喂 ASR。
- **克制**:有 token 预算上限,超了截断,**通用词优先**;每 project 几个~十几个真正高频易错的专名即可。

---

## 8. Host 配置 / 代客安装(Valet)契约

**无设置 UI 是刻意设计**——用户戴眼镜没法舒服填表。配置经**带外通道**推进设备私有存储,app 启动时导入。

**hosts.json schema(导入用 staging 形态):**

两种顶层形态,客户端都接受(向后兼容):
- **顶层数组**(legacy / 无代理):直接是 host 列表,等价于下面 `hosts` 字段。
- **顶层对象** `{ "proxies": [...], "hosts": [...] }`:带可选 `proxies` 表(SSH-over-443,§5.1)+ host 列表。

```jsonc
{
  "proxies": [                    // 可选:命名代理表(SSH-over-443 隧道,§5.1)。无则省略整个字段
    {
      "name": "tk-443",           // proxy 唯一名(host 用 "proxy" 字段按名引用)
      "url": "vmess://..."        // 标准 vmess:// 分享链接(base64 JSON;v2rayN 格式)。客户端内嵌 xray 解析
    }
  ],
  "hosts": [
    {
      "name": "TK-ALIYUN",          // host 唯一名(也用于私钥落地文件名)
      "addr": "tk-aliyun",          // 可选:显示别名。缺省 = host。⚠️ 真实 IP 绝不进 addr(UI 会显示 addr)
      "host": "47.x.x.x",           // 真实连接地址(IP/域名)。UI 不显示这个字段
      "port": 22,                   // 可选,默认 22
      "user": "xreal",
      "key": "tk.pem",              // staging:指向同目录私钥纯文件名(导入后变私有 keys/<name>.pem,权限 600)
      "basePath": "/home/xreal/work",// manifest/status 在 <basePath>/.xreal/ 下(§2/§3)。空 = 不 live-fetch
      "via": "TK-ALIYUN",           // 可选:多跳跳板 host 名(§5)
      "proxy": "tk-443",            // 可选:经哪个 proxy 拨号(§5.1)。无则直连(默认,现有行为不变)
      "projects": [                 // seed 列表(真相由 manifest 覆盖)
        { "session": "maestro", "name": "Maestro", "type": "maestro" }
      ]
    }
  ]
}
```

**安全契约(平台无关,强制):**
- **真实 IP 只进 `host`,绝不进 `addr`/UI**。`addr` 是给人看的别名。
- 私钥落**私有存储**,权限收紧(仅 app 自身可读)。`key` 必须是纯文件名(防路径遍历),私钥须含 `PRIVATE KEY`、合理大小(≤8KB)。
- 导入**原子写**(tmp→rename),防半成品。

**注入通道(平台相关 —— 这是两端少数真正不同的地方之一):**
| 平台 | staging 落点 | 机制 |
|---|---|---|
| Android | `/data/local/tmp/xreal_import/{hosts.json, asr.json, <keys>}` | `adb push` → app 启动 import 到私有存储 → best-effort 清 staging(权威清理由 Valet `adb shell rm`) |
| iOS | **开发期(模拟器)**:`xcrun simctl get_app_container booted <bundle> data` 定位容器 → copy 进 `Documents/`(仅模拟器)。**真机(本版)= 分享单「Open in」**:Valet 产出**单个自含 `.xrhosts`**(JSON,与 Android staging 唯一差异 = **内联 key**),AirDrop →「用 XrealPOC 打开」→ `importConfig` 解析、每个 host 内联 PEM 写私有 `Documents/<name>.pem`(0600)、`key`→纯文件名、原子写私有 `hosts.json` → 列表刷新。**三类导入,按文件顶层内容自动判别**:**①`host` 对象**→追加(并入,按 name 去重);**②`hosts` 数组**→替换整表;**③`asr` 对象**(`{provider,appid,token,resourceId}`,无 hosts)→只写 `asr.json`。可组合。注册自定义扩展 `.xrhosts` + 自有 UTI `io.github.kevinfitzroy.xrealclient.hosts`(`LSHandlerRank=Owner`,**不抢 `public.json`**)。**用户不手输 host/key**,只 AirDrop 一个 Valet 生成的文件。私有存储**结果形状不变**。**⚠️ app 内「齿轮→Host 配置页文档选择器」手动导入 = P2**(曾实现于 `8765af1`、后撤回;与「无设置 UI / AI agent 代劳」哲学略拧,AirDrop 已够) |

> iOS 没有 `adb push 到任意 app 私有目录`这种能力(沙盒)。代客安装在 iOS 上**换实现 = 分享单「Open in」**,但**契约形状(hosts.json/asr.json schema + 安全规则)不变**。**真机注入 = 分享单「Open in」+ 自含 `.xrhosts`,2026-05-31 真机实测通过**(AirDrop →「用 XrealPOC 打开」出现 → 导入 → SSH 连 Mac LAN host → 真终端;UTI 匹配生效)。曾是 iOS 客户端首要待解项,**已解**。导入逻辑三类判别(append/replace/asr-only)亦经模拟器 `-importConfigPath` lever 验。**app 内 Host 配置页文档选择器(第二入口)搁置 P2**(曾实现又撤回)。平台实现变更,**不 bump Contract version**。

---

## 9. 优雅降级契约(底线)

任何组件挂了,用户能**退回 Termius / Termux 继续工作**。这个 app **不是必需品**。客户端实现不得做出"挂了就完全没法工作"的强耦合。

---

## 10. 平台中立性自检(写新功能前过一遍)

加任何跨端功能时,先问:
1. 这个行为属于**契约**(列表/状态/语音/按键语义/配置形状)还是**平台实现**(怎么渲染/怎么连 SSH/怎么录音)?
2. 若是契约 → 先改本文件 + 两端对齐(§12);**不要**只在一端实现完再让另一端"抄"。
3. 若是平台实现 → 各端自由发挥,但**对外行为必须满足本契约**。

---

## 11. 平台实现矩阵(契约 → 各端落点)

> **iOS 列状态标记**:✅ = 模拟器 POC(2026-05-31,`ios/`)已实测验过;否则为规划/待真机。POC 验掉的核心风险:**WKWebView 原样跑 index.html + Base64 桥 + 字体 + WebGL + 真 PTY SSH 全通**。

| 契约项 | Android(已上真机) | iOS |
|---|---|---|
| 终端 UI | WebView + xterm.js + WebGL + unicode11 | **WKWebView + 同一套 `index.html`(POC ✅ 原样跑通,零改动)**;Bridge shim→`messageHandlers` |
| 字体(Meslo/Sarasa/emoji,file://) | WebView `allowFileAccessFromFileURLs` | **`loadFileURL(allowingReadAccessTo:)` 授权整目录,无跨域(POC ✅)** |
| WebGL | xterm webgl addon | **WKWebView 提供,addon 正常无 DOM 回退(POC ✅)** |
| SSH | sshj 0.39 + BouncyCastle | **Citadel 0.12(SwiftNIO SSH,async/await;POC ✅ 真 PTY 跑通)** ⚠️ RSA 走 legacy `ssh-rsa`,见 §5 |
| 多跳 ProxyJump | sshj LocalPortForwarder | **Citadel `SSHClient.jump(to:)` → directTCPIP channel(POC ✅,两跳模拟器跑通)**;无本地 socket 转发,跳板 client 上开 directTCPIP 隧道 + 第二次握手端到端认证到目标 |
| SSH-over-443 代理(§5.1) | 自建 `xraybridge.aar`(gomobile 封官方 xtls/xray-core,见 `xray-bridge/`)起本地 **dokodemo-door**(override→服务端 `127.0.0.1:22`)+ sshj **直连**该本地口 | 规划:`xray-core`(或 sing-box `direct` inbound)Apple gomobile/cgo 起本地 dokodemo-door override + Citadel 直连本地口(待 POC) |
| proxy 标识徽章(§5.1 UI 契约) | host 列表 JSON 加 `proxy` 字段(`StatusPoller.hostProxyLabel` 按归属规则解析)→ `index.html` 的 `.host .hproxy` 渲染 🔒+名 | 规划:host 头同位置渲染同款徽章(SwiftUI) |
| 语音常驻 | Foreground Service | **background audio mode**(iOS 受限,需重设计;无前台 Service 等价物) |
| 物理键路由 | `Activity.dispatchKeyEvent` | `GameController` framework + `pressesBegan`(UIKey) |
| 麦克风 | `AudioRecord` → Opus | `AVAudioEngine` |
| ASR HTTP | OkHttp(豆包流式) | `URLSession` |
| 配置注入(§8) | `adb push` → 私有存储 | 模拟器 `simctl` 容器 copy(开发期);**真机 = 分享单「Open in」+ 自含 `.xrhosts`**(✅ 2026-05-31,§8) |
| 持久化日志 | `getExternalFilesDir` + `adb pull` | app container + Xcode/`pymobiledevice3` 取 |
| AI 开发期截屏 | `adb exec-out screencap` | 模拟器 `xcrun simctl io booted screenshot`;真机 `pymobiledevice3 developer dvt screenshot` |
| AI 开发期装机 | `adb install`(零账号) | 模拟器 `simctl install`(零签名);真机 `xcrun devicectl device install`(**需签名 .app**) |
| 工程脚手架 | Gradle | **xcodegen(`project.yml`,资产用 `type: folder` folder reference)(POC ✅)** |

**iOS 开发便捷度注记**:模拟器(`simctl`)对 AI 友好度 ≈ 甚至优于 adb(装/起/截屏零签名);**真机**则被**代码签名门**卡住(每次装机需 Xcode + Apple 账号,免费证书 7 天)。所以 iOS 开发**模拟器优先**验非硬件逻辑,硬件路径(8BitDo/麦克风/DP-to-眼镜)上真机由用户验——与 Android 的"硬件部分用户验"同构。

---

## 12. 契约变更流程(防内耗的关键)

改任何跨端行为:
1. **先改本文件**(SPEC.md),break 兼容时 bump 顶部 `Contract version`。
2. 若动了 §2 manifest / §3 status / §4 voice **服务端侧契约** → 同步 [`docs/orchestrator-CLAUDE.md`](docs/orchestrator-CLAUDE.md) + [`docs/xreal-project.sh`](docs/xreal-project.sh)。
3. **两端各自对齐实现**;不要让一端领先太多导致另一端反向适配。
4. 平台专属细节进 §11 矩阵,不进契约正文。

> 单一真相源原则:同一个契约事实(如 status.json 形状)**只在本文件权威定义一次**,其它文档**引用**它而不重新声明,避免漂移。
