# iOS 客户端 — 已知问题(issue 存档)

> 可直接复制到 GitHub Issues 当正文。每条 issue 自带:现象 / 影响 / 根因分析 / 试过且失败的 / 死路 / 下一步 / 代码位置。

---

## #1 硬件键盘下中文 IME 拦截字母键,无法 raw ASCII 直通(SwiftTerm 终端)

**状态**:未解决(已记录,不 block 核心)。优先级 P2。

### 现象
iOS 客户端终端改用原生 **SwiftTerm** 后,当**硬件键盘当前输入源是中文**时,在终端里敲字母键(`l`/`s`…)会触发**中文拼音 IME 组字**(出候选条 / marked text),而不是把 raw ASCII 直接送进 PTY。需要先在 IME 候选里确认才落字符。

### 影响
- 命令输入(`ls`/`cd`…)体验受损:要么先切英文输入源,要么在 IME 候选里确认。
- **不 block 核心功能**:8BitDo 的 F1(语音)/F2(返回)/方向键/语音注入、以及**英文输入源下的全键盘打字**全部已通。这是 raw-ASCII 直通的**精细化**问题,不是架构问题。

### 根因分析
- IME 由 **iOS 系统级"硬件键盘输入源"**驱动(用户在系统里选的语言),**不是**终端字段能直接覆盖的。
- SwiftTerm 的 `TerminalView` 是完整 `UITextInput`(实现 marked text / `setMarkedText`)→ 系统会对它做组字。
- 字段层的 hint(`keyboardType`、`textInputMode`)**无法**可靠覆盖系统输入源 → 见下"试过且失败"。
- `pressesBegan` 拿得到 raw key(`key.characters="l"`),但 IME 的 `insertText`/`setMarkedText` 路径与 `pressesBegan` **并行**,consume press 挡不住组字。

### 试过且失败
1. **swizzle `keyboardType` getter → `.asciiCapable`**(SwiftTerm 原返回 `.default`)。无效:对硬件键盘 CJK IME 不起作用。代码仍在(无害的标准 hint)。
2. **override `textInputMode` → 取系统已装的英文输入模式**。无效。⚠️ 未插桩验证:若用户**没装**英文硬件输入模式,`activeInputModes.first{en}` 返回 nil → 静默回退 `super`(中文)。**下一步必须先插桩**确认是"override 返回了中文"还是"iOS 忽略了 override"——两者修法完全不同。

### 死路(别再走)
- **改 `setMarkedText`**:marked text 是**累积**的(逐键给完整拼音串)。逐次提交 → 重复打字;忽略 → 丢输入。无解。

### 下一步(按性价比)
1. **⭐ 判别测试(零代码,先做)**:按 🌐 Globe 键 / Ctrl-Space 把硬件键盘输入源切到英文(ABC),再敲 `ls`。
   - **干净出字符** → 这就是**系统输入源是中文**,不是 bug。→ 产品取舍:**终端约定用英文输入源**(零代码,文档一句话即可)。
   - **仍组字** → 才是字段/SwiftTerm 层的 bug,值得继续挖。
2. 若值得挖:给 `textInputMode` override 插桩,打 `UITextInputMode.activeInputModes.map{$0.primaryLanguage}` + 是否被调用,定位是"返回中文"还是"被忽略"。
3. 兜底:接受为**已知限制**,文档写明"终端期望英文输入源";或等 SwiftTerm 上游提供禁 IME 开关。

### 代码位置
- `ios/App/Sources/TerminalHostView.swift` — `textInputMode` override、`keyboardType` swizzle(`TerminalKeyInterceptor.installOnce`)。
- SwiftTerm `Sources/SwiftTerm/iOS/iOSTerminalView.swift` — `UITextInput`/`setMarkedText`/`_markedTextRange`(组字);`pressesBegan`/`keyboardType` 是 `public`(非 `open`,故只能 swizzle);`insertText`/`textInputMode` 可 override。

---

## #2 没连硬件键盘时,终端缺自定义虚拟键盘(触屏 fallback)

**状态**:待做(方案明确,clean)。

### 现象
终端改原生 SwiftTerm 后,原来 index.html 里的自绘虚拟键盘只在(已弃用的)WebView 终端态显示 → iOS 原生终端下没有触屏键盘。没连 8BitDo / 蓝牙键盘时无法触屏输入特殊键。

### 方案(clean)
`GCKeyboard.coalesced == nil`(无硬件键盘)时,给 `TerminalHostView` 挂一个**原生 `inputAccessoryView`**(我们自绘的一行 key bar:Esc/Tab/方向/Ctrl/Enter…),按钮 → `ssh.send` 对应字节;有硬件键盘时设回 `nil`(当前已 nil)。与 #1 的 IME 无关,独立做。
