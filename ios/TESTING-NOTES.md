# iOS 待真机验证清单

> 本会话(语音录入听写链路)堆了几块**只过了模拟器构建、未在真机端到端验**的改动。
> 下次真机过一遍按这个清单走。装机:Xcode 选 **XrealPOC** scheme + iPhone,**⌘R**(App Group 上次已 provision,这次应该直接装上)。

---

## 1. ⭐ 语音「按住说话 → 上滑锁定录音」(本会话重点,优先验)

提交 `29a35c7`。涉及 `VoiceController` / `VoiceOverlayView` / `PcmWavWriter` / `TerminalViewController`。

### 正常流程该是怎样
1. 进一个 **Claude/agent 类 subproject** 终端 → **长按底部语音区**说话 → overlay 出实时识别文字(跟旧版一样)。
2. **别松手,手指上滑**到 overlay 卡片之上 → overlay 变**微红** + 提示「↑ 松手转录音」。
3. **松手(手指停在 overlay 上)** → 进**录音态**:overlay 显示「🔴 录音中 · 计时」+ **取消 / 停止并转写** 两个按钮,免持继续说。
4. 点**停止并转写** → 走分段转写 → **自动委托给当前这个 subproject** → toast「✓ 已交给 X」,该 session 里冒出整理 prompt。
5. 点**取消** → 丢弃,不转写。

### 反向验证(别回归)
- 长按说话 **不上滑**、直接松手 → 应还是**老的语音转文本**(overlay 预览 → Enter 注入),没被破坏。
- 上滑 armed 后**再滑回去**松手 → 应取消升级、回到正常语音转文本。

### ⚠️ 我模拟器测不了、要你重点看的
- **(A) 手势接力**:这根连续手指从「终端 long-press」滑到「overlay 之上」,是按"终端 long-press 全程持有这根手指"实现的。**若上滑到 overlay 上 armed 不触发**(overlay 把触摸抢走了),记下来 → 要调 gestureRecognizer 优先级/`shouldRecognizeSimultaneously`。
- **(B) 录音态按钮能不能点**:录音时 overlay 自身手势被停用、好让「停止/取消」按钮收触摸。验证这俩点得动、不被 overlay 吞。
- **(C) 无缝录音对不对**:`PcmWavWriter` 从按下第一秒 tee。验证转写出来的文本**包含你上滑前说的话**(没丢头),且整段完整。
- **(D) 委托落点**:停止后确认是委托给**当前打开的** subproject(不是别的)。

### 体验可调(验完给手感,我再磨)
- **armed 阈值**:现在是"手指上滑到 overlay 卡片顶部之上"才 armed(`VoiceOverlayView.cardTopY()`)。太高/太低都能改。
- 录音态 overlay 长相、按钮文案、是否加波形/振动反馈。

### 拉日志看内部(我可远程拉)
`AgentLog` 关键字:`locked to recording` / `stop recording → …` / `cancel recording` / `transcoded … N 段` / `delegated → host/session`。

---

## 2. #19 长录音分段(80 分钟那条)

提交 `a4c4d49`。`AudioTranscoder.toWav16kMonoSegments`(每段 ≤10min)+ `VolcFileAsr.recognizeSegments`(逐段重试)。
- 验:一段**很长**的录音(>10min,理想 ~80min)能转写成功,日志出现 `recognize segment k/N`,网络抖一下能重试不整条崩。
- 已知限制:跨段说话人编号不保证同一人;整条重试会重跑所有段;非 VAD 切段。

## 3. 失败条目可删除

提交 `ca431ce`。点 Home「录音转写」里**失败**的条目 → 应弹「重试转写 / 删除 / 取消」,不再一点就重转。验证能删掉。

---

## 装机/排障速记
- ⌘R 装;真机 app 不受信任 → 设置→通用→VPN与设备管理→信任。
- 拉设备日志(我可远程):`xcrun devicectl device copy from --device <UDID> --domain-type appDataContainer --domain-identifier io.github.kevinfitzroy.xrealclient --source Documents/agent-logs/agent.log --destination /tmp/agent.log`
- 这几笔都**只本地提交、未 push**(`git log origin/main..HEAD`)。
