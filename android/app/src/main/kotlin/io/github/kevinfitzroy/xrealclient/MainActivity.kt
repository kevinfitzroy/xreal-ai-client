package io.github.kevinfitzroy.xrealclient

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.hardware.display.DisplayManager
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.os.Bundle
import android.text.InputType
import android.util.Base64
import android.util.Log
import android.view.KeyEvent
import android.view.WindowManager
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputConnection
import android.webkit.ConsoleMessage
import android.webkit.RenderProcessGoneDetail
import android.webkit.WebChromeClient
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.Toast
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import kotlin.concurrent.thread

/**
 * 主 Activity — WebView SPA:列表视图(Agent Deck)⇄ 终端视图。
 *
 * 当前(P.1):列表用 mock 数据;进入 project 切到终端,终端走 LocalEchoChannel
 * (真 SSH per-project 连接 + 状态探测后续接)。
 *
 * 导航:
 *   列表 Enter → JS Bridge.openProject → 切终端视图
 *   BACK 键   → 终端视图返回列表;列表视图则退出 app
 *
 * **不变量**:TerminalBridge / VoiceDaemon 实例创建后不重建(channel 等用 @Volatile var 热切)。
 */
class MainActivity : Activity() {

    private lateinit var webView: WebView
    private lateinit var bridge: TerminalBridge
    private lateinit var voiceDaemon: VoiceDaemon

    // 当前活动终端通道:进 project 时热切到真 SshConnection,回列表/无配置时是 LocalEchoChannel
    @Volatile private var activeChannel: PtyChannel = LocalEchoChannel()

    private enum class View { LIST, TERMINAL }
    @Volatile private var view = View.LIST

    // reader 线程代数:切 channel 时 ++,旧 reader(可能阻塞在 read)被 close 解阻塞后凭此静默退出
    @Volatile private var readerGen = 0
    // open 序号:快速 open→back→open 时,在途 SSH 连接凭此判断自己是否已 obsolete(advisor 抓的 race)
    @Volatile private var openSeq = 0

    private var backupVoiceDigit = -1
    private var backupVoiceKey = -1

    private lateinit var hosts: List<HostConfig>
    // 实时状态刷新(P2,搁置,见 FleetFeatures.LIVE_STATUS / ROADMAP):仅开关开 + 有 host 时才建
    private var poller: StatusPoller? = null
    // 调试输入直通:仅 debug build + 有 host 配置时起(电脑经 adb 打字进终端,见 scripts/term-relay.py)
    private var dbgInput: DebugInputServer? = null
    // 真实 host/project 列表(静态枚举):页面加载完成后一次性推给 WebView,让 Enter 能开真终端
    private var pendingHostListJson: String? = null
    // live manifest:最近一次从各 host 拉到的 project 列表(hostName→projects),findProject 的真相来源
    @Volatile private var liveProjects: Map<String, List<ProjectConfig>> = emptyMap()
    private var manifestFetcher: ManifestFetcher? = null
    @Volatile private var fetchGen = 0   // 契约:仅 UI 线程 ++(onPageFinished/backToList/onStart),故无需原子
    private var lastPushedJson: String? = null   // pushHostList 去重:内容不变不重推(避免列表重渲染闪烁)
    private val fetchExec = java.util.concurrent.Executors.newSingleThreadExecutor()   // manifest 拉取串行(HostClient 非并发安全)

    private val displayManager: DisplayManager
        get() = getSystemService(Context.DISPLAY_SERVICE) as DisplayManager

    // 监听 display 增删:眼镜↔Beam Pro 走 USB-C DP-Alt,断连=外接 display 移除。把这个事件打上时间戳,
    // 才能跟「闪退 / SSH 失败」对得上(诊断「眼镜断连」是因还是果)。registerDisplayListener 在 onCreate。
    private val displayListener = object : DisplayManager.DisplayListener {
        override fun onDisplayAdded(id: Int) = AppLog.i(TAG, "display ADDED id=$id ${displayDesc(id)}")
        override fun onDisplayRemoved(id: Int) = AppLog.w(TAG, "display REMOVED id=$id")
        override fun onDisplayChanged(id: Int) = AppLog.i(TAG, "display CHANGED id=$id ${displayDesc(id)}")
    }
    private fun displayDesc(id: Int): String = runCatching {
        val d = displayManager.getDisplay(id) ?: return "(gone)"
        val pt = android.graphics.Point().also { @Suppress("DEPRECATION") d.getRealSize(it) }
        "name='${d.name}' ${pt.x}x${pt.y} state=${d.state}"
    }.getOrElse { "(?)" }

    // 网络/VPN 抖动监听:VPN 不稳(GFW 干扰 / 与 Mac 双登录互踢)flap 时,app 的默认网络在 VPN↔WiFi
    // 间反复切。把这些事件落进 app.log,就能跟 SSH 断流/重连失败对上时间戳 → 自证「VPN 抖 → app 崩」,
    // 不用再去翻系统 logcat 对时间。registerDefaultNetworkCallback 跟踪的就是 app 实际走的那张网。
    private val connectivityManager: ConnectivityManager
        get() = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
    @Volatile private var lastNetCap: String? = null
    private val netCallback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(n: Network) = AppLog.i(TAG, "net AVAILABLE $n")
        override fun onLost(n: Network) = AppLog.w(TAG, "net LOST $n (默认网络断 → 在用的 SSH 会被撕掉)")
        override fun onCapabilitiesChanged(n: Network, c: NetworkCapabilities) {
            val sig = "$n vpn=${c.hasTransport(NetworkCapabilities.TRANSPORT_VPN)}" +
                " wifi=${c.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)}" +
                " internet=${c.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)}" +
                " validated=${c.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)}"
            if (sig != lastNetCap) { lastNetCap = sig; AppLog.i(TAG, "net CAP $sig") }   // 去重:cap 回调很频
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        Crypto.ensureFullBouncyCastle()   // sshj 用 X25519 KEX 前必须先换上完整 BC(Stage A.2)
        window.setFlags(
            WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON,
            WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON,
        )
        // 彻底禁用系统软键盘:窗口声明"不需要与 IME 交互"(仍可聚焦、硬件键正常)。
        // 输入只走 8BitDo 硬件键 + 语音 + 自绘虚拟键盘。比 per-view TYPE_NULL 可靠。
        window.addFlags(WindowManager.LayoutParams.FLAG_ALT_FOCUSABLE_IM)
        WebView.setWebContentsDebuggingEnabled(true)

        bridge = TerminalBridge(
            initial = activeChannel,
            onOpenProject = ::onOpenProject,
            onVoice = { down, lang ->
                val kc = if (lang == "en") VoiceDaemon.KEY_F14 else VoiceDaemon.KEY_F13
                if (down) voiceDaemon.onKeyDown(kc) else voiceDaemon.onKeyUp(kc)
            },
            onVkeyEnter = { if (!voiceDaemon.onEnter()) writeChannelByte(13) },   // 13 = CR
            onVkeyEsc = { if (!voiceDaemon.onEsc()) writeChannelByte(27) },        // 27 = ESC
            hasHwKeyboard = ::hasHardwareKeyboard,
            onGoHome = { if (view == View.TERMINAL) backToList() },
        )

        webView = object : WebView(this@MainActivity) {
            // 抑制软键盘:本产品输入 = 8BitDo 硬件键 + 语音,软键盘会挡住半屏。
            // TYPE_NULL 让系统不弹软键盘,但硬件 KeyEvent 仍照常进 dispatchKeyEvent / WebView。
            override fun onCreateInputConnection(outAttrs: EditorInfo): InputConnection? {
                val ic = super.onCreateInputConnection(outAttrs)
                outAttrs.inputType = InputType.TYPE_NULL
                return ic
            }
        }.apply {
            setBackgroundColor(0xff0d0f16.toInt())
            settings.apply {
                javaScriptEnabled = true
                domStorageEnabled = true
                @Suppress("DEPRECATION")
                allowFileAccessFromFileURLs = true   // 让 file:// 页面能加载 @font-face 字体(sarasa-term.ttf)
            }
            webViewClient = object : WebViewClient() {
                override fun onPageFinished(view: WebView?, url: String?) {
                    // 页面就绪后才推真实 host/project 列表(window.setHosts 此时才存在)
                    AppLog.i(TAG, "WebView onPageFinished url=$url")
                    pendingHostListJson?.let { pushHostList(it) }
                    refreshManifests()   // 首屏:静态 seed 先显示,manifest 拉到后替换
                }
                // WebView 渲染进程被系统杀(OOM / GPU 上下文丢失 —— xterm.js 用 WebGL,眼镜断连或尺寸
                // 剧烈 churn 都可能触发)。默认 return false = **直接崩 app**(极可能就是这次「闪退」)。
                // 改成:落日志 + return true 阻止硬崩 + recreate() 重建 WebView 自恢复(胜过白屏/硬崩)。
                override fun onRenderProcessGone(view: WebView?, detail: RenderProcessGoneDetail?): Boolean {
                    AppLog.e(TAG, "WebView RENDER PROCESS GONE didCrash=${detail?.didCrash()} priority=${detail?.rendererPriorityAtExit()} isCurrent=${view === webView}")
                    runCatching { recreate() }
                    return true
                }
            }
            webChromeClient = object : WebChromeClient() {
                override fun onConsoleMessage(m: ConsoleMessage): Boolean {
                    // JS 侧报错(xterm.js / WebGL / resize)只有这里看得到。只落 WARNING+,避免刷屏。
                    val lvl = m.messageLevel()
                    if (lvl == ConsoleMessage.MessageLevel.WARNING || lvl == ConsoleMessage.MessageLevel.ERROR)
                        AppLog.w(TAG, "JS $lvl: ${m.message()} @${m.sourceId()}:${m.lineNumber()}")
                    return true
                }
            }
            addJavascriptInterface(bridge, TerminalBridge.JS_NAME)
        }
        setContentView(webView)
        webView.loadUrl("file:///android_asset/index.html")

        voiceDaemon = VoiceDaemon(webView = webView, initialChannel = activeChannel)

        if (ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO)
            == PackageManager.PERMISSION_GRANTED
        ) {
            voiceDaemon.recorder = AudioRecorder()
        } else {
            ActivityCompat.requestPermissions(this, arrayOf(Manifest.permission.RECORD_AUDIO), REQ_MIC)
        }

        startReaderFor(activeChannel)

        val settings = SettingsStore(this)
        hosts = settings.loadHosts()   // 先跑:会触发 Valet staging 导入(hosts/keys/asr.json → 私有存储)

        // ASR provider:配了 Volc 凭证(Valet 导入或 ConfigActivity)就接真豆包流式,否则留 MockAsr。
        settings.loadAsr().let { asr ->
            if (asr.isVolcConfigured()) {
                voiceDaemon.asr = VolcEngineAsr(asr.appid, asr.token, asr.resourceId)
                AppLog.i(TAG, "ASR = VolcEngineAsr(resource=${asr.resourceId})")
            }
        }

        if (hosts.isNotEmpty()) {
            // 核心流程:真实 host/project 静态枚举(onPageFinished 推)。Enter→findProject 靠它开真终端。
            // loading=true:首屏徽章先转圈;manifest 拉到后 refreshManifests 推 loading=false 的真状态。
            pendingHostListJson = StatusPoller.staticListJson(hosts, loading = true)

            // live manifest 拉取(P1.1c):任一 host 配了 basePath 才建 fetcher
            if (hosts.any { it.basePath.isNotBlank() }) {
                manifestFetcher = ManifestFetcher(filesDir, java.io.File(filesDir, "known_hosts"))
            }

            // 实时状态刷新(P2,搁置):开关开才建 poller,周期性用真实状态/preview 覆盖静态枚举。
            if (FleetFeatures.LIVE_STATUS) {
                poller = StatusPoller(
                    hosts = hosts,
                    keyDir = filesDir,
                    knownHostsFile = java.io.File(filesDir, "known_hosts"),
                    onUpdate = { json -> pushHostList(json) },
                )
            }

            // 调试输入直通:测试基建(与状态刷新无关),debug build + 有真 host 时监听
            if (BuildConfig.DEBUG) {
                dbgInput = DebugInputServer(sink = { activeChannel }).also { it.start() }
            }
        }

        displayManager.registerDisplayListener(displayListener, null)
        runCatching { connectivityManager.registerDefaultNetworkCallback(netCallback) }
        AppLog.i(TAG, "onCreate done: hosts=${hosts.size} displays=${displayManager.displays.size}")
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        // 眼镜断连可能改 display/uiMode → 视 configChanges 声明,要么走这里、要么直接重建 Activity(看
        // 生命周期日志有没有 onDestroy→onCreate 就知道是哪种)。记下来对得上「断连↔闪退」。
        AppLog.i(TAG, "onConfigurationChanged orient=${newConfig.orientation} uiMode=${newConfig.uiMode} kbd=${newConfig.keyboard} hardKbdHidden=${newConfig.hardKeyboardHidden}")
        pushHwKeyboardState()   // 8BitDo 等硬件键盘插拔 → 动态显隐虚拟键盘
    }

    /** 把"当前有无外接物理键盘"推给 WebView,让它显隐自绘虚拟键盘。8BitDo 连=隐藏 vkey,断=弹出 vkey。 */
    private fun pushHwKeyboardState() {
        val present = hasHardwareKeyboard()
        AppLog.i(TAG, "hwKeyboard present=$present → setHwKeyboard")
        runOnUiThread {
            if (::webView.isInitialized) webView.evaluateJavascript("window.setHwKeyboard && window.setHwKeyboard($present)", null)
        }
    }

    override fun onResume() {
        super.onResume()
        AppLog.i(TAG, "onResume view=$view displays=${displayManager.displays.size}")
    }

    override fun onPause() {
        AppLog.i(TAG, "onPause view=$view")
        super.onPause()
    }

    /** 把整批 hosts JSON 推给 WebView 列表。内容不变则不重推(setHosts 会重渲染 + 重放入场动画 → 闪烁)。 */
    private fun pushHostList(json: String) {
        if (json == lastPushedJson) return
        lastPushedJson = json
        runOnUiThread {
            if (::webView.isInitialized) {
                webView.evaluateJavascript("window.setHosts(${org.json.JSONObject.quote(json)})", null)
            }
        }
    }

    /** 从各 host 拉 manifest(P1.1c)→ 更新 liveProjects + 列表。单线程串行(HostClient 非并发安全),
     *  fetchGen 让被新触发取代的旧任务跳过;拉取失败保留当前列表(pushHostList 去重不会重推)。 */
    private fun refreshManifests() {
        val fetcher = manifestFetcher ?: return
        val gen = ++fetchGen
        fetchExec.execute {
            if (gen != fetchGen) return@execute
            val result = runCatching { fetcher.fetch(hosts) }.getOrNull() ?: return@execute
            runOnUiThread {
                if (gen != fetchGen) return@runOnUiThread
                liveProjects = result.hosts.associate { it.name to it.projects }
                pushHostList(StatusPoller.staticListJson(result.hosts, statusByHost = result.status, reachable = result.reachable))
            }
        }
    }

    override fun onStart() {
        super.onStart()
        AppLog.i(TAG, "onStart view=$view")
        poller?.start()
        if (view == View.LIST) refreshManifests()   // 回前台 + 在列表态:刷一次
    }

    override fun onStop() {
        AppLog.i(TAG, "onStop view=$view")
        poller?.stop()
        super.onStop()
    }

    /**
     * JS 列表 Enter 进入 project:查到真实 host 配置 → 后台连 SSH(attach 该 project 的 tmux
     * session)→ 热切 channel;查不到(mock 数据)→ 回退干净 LocalEcho 演示。
     */
    private fun onOpenProject(host: String, session: String, name: String, type: String) {
        AppLog.i(TAG, "openProject host=$host session=$session name=$name type=$type seq=${openSeq + 1}")
        val seq = ++openSeq
        view = View.TERMINAL
        runOnUiThread {
            webView.evaluateJavascript(
                "window.showTerminal(${org.json.JSONObject.quote(name)}, ${org.json.JSONObject.quote(type)})", null,
            )
        }

        val match = findProject(host, session)
        if (match == null) {
            applyProjectHotwords(null)     // mock / 无配置:语音热词回退 BASE
            switchTo(LocalEchoChannel())   // 本地 echo,demo 不卡
            return
        }
        val (h, p) = match
        applyProjectHotwords(p)            // 进 project:BASE + 该 project 的热词
        writeToTerm("连接 ${h.name} … (${p.sessionName})\r\n")   // 用别名,不打真 IP(防截图泄漏)
        thread(name = "ssh-connect", isDaemon = true) {
            AppLog.i(TAG, "ssh-connect start host=${h.name} session=${p.sessionName} via=${h.via ?: "-"} seq=$seq")
            try {
                // SSH-over-443:生效 proxy = 实际拨公网那一跳(SPEC §5.1)。直连 host 用自己的、经 via 用跳板的。
                val eff = h.effectiveProxy(hosts)
                // 多跳:via 指向的跳板 host(如 OPS via TK)→ 经它 ProxyJump,端到端认证到本 host;proxy 归跳板。
                val jump = h.via?.let { viaName ->
                    hosts.firstOrNull { it.name == viaName }?.let { jh ->
                        JumpSpec(jh.ssh.host, jh.ssh.port, jh.ssh.user, materializeKey(jh).absolutePath, java.io.File(filesDir, "known_hosts"), eff)
                    } ?: run { AppLog.w(TAG, "via host '$viaName' 未配置 → 退回直连"); null }
                }
                val ssh = SshConnection(
                    host = h.ssh.host, port = h.ssh.port, user = h.ssh.user,
                    privateKeyPath = materializeKey(h).absolutePath,
                    startupCommand = tmuxAttachCommand(p.sessionName),
                    knownHostsFile = java.io.File(filesDir, "known_hosts"),
                    jump = jump,
                    proxy = if (h.via == null) eff else null,   // 终端连接也必须走隧道(SPEC §5.1 行为契约 1)
                )
                ssh.connect(80, 24)   // 初始尺寸;showTerminal 的 fit 会触发 onResize 校正
                AppLog.i(TAG, "ssh connected host=${h.name} session=${p.sessionName} (seq=$seq obsolete=${seq != openSeq})")
                runOnUiThread {
                    if (seq == openSeq && view == View.TERMINAL) switchTo(ssh)
                    else runCatching { ssh.close() }   // 用户已走开 → 关掉,别泄漏连接
                }
            } catch (e: Exception) {
                // 异常类名才分得清病因:SocketTimeout/NoRouteToHost=VPN 死,UserAuth=认证,TransportException=host key…
                AppLog.w(TAG, "ssh connect 失败 host=${h.name}: ${e.javaClass.simpleName}: ${e.message}", e)
                runOnUiThread {
                    if (seq == openSeq) {
                        switchTo(LocalEchoChannel())
                        writeToTerm("\r\nSSH 连接失败: ${e.javaClass.simpleName}: ${e.message}\r\n")
                    }
                }
            }
        }
    }

    private fun backToList() {
        AppLog.i(TAG, "backToList (from view=$view)")
        openSeq++   // 让在途的 SSH 连接知道自己已 obsolete(回来后别再错切)
        view = View.LIST
        applyProjectHotwords(null)     // 回列表:语音热词回退 BASE
        runOnUiThread { webView.evaluateJavascript("window.showList()", null) }
        switchTo(LocalEchoChannel())   // 断开当前 project 的 SSH(switchTo 关掉旧 channel)
        refreshManifests()   // 回列表即拉一次:刚让 Maestro 建的新项目此刻出现(主刷新时机)
    }

    /** 设当前 project 的语音上下文:热词(BASE 继承 + per-project)+ 是否加 🎤 marker(仅 AI-agent 类)。 */
    private fun applyProjectHotwords(p: ProjectConfig?) {
        voiceDaemon.hotwords = if (p == null) Hotwords.BASE else Hotwords.merge(p.hotwords)
        voiceDaemon.voiceMarkerEnabled = p?.type?.isAiAgent() ?: false
        Log.d(TAG, "voice ctx: hotwords=${voiceDaemon.hotwords.size} marker=${voiceDaemon.voiceMarkerEnabled} (project=${p?.sessionName ?: "none"})")
    }

    /** 按 session 查(name 可能重复)。真相来源:最近一次 manifest 拉到的 liveProjects,无则 seed。 */
    private fun findProject(host: String, session: String): Pair<HostConfig, ProjectConfig>? {
        val h = hosts.firstOrNull { it.name == host } ?: return null
        val p = (liveProjects[host] ?: h.projects).firstOrNull { it.sessionName == session } ?: return null
        return h to p
    }

    /**
     * attach-or-create 该 project 的 tmux session,并注入半页翻页绑定 + 大 scrollback。
     * - LANG/LC_ALL=UTF-8 + `tmux -u`:强制 UTF-8 客户端,否则 tmux 把多字节(中文/powerline)降级成 `_`。
     * - PATH 前缀:非交互 exec 的 PATH 太窄找不到 tmux(同 HostClient)。
     * - **翻页**:Shift+↑/↓ → tmux root 表(-n,Claude Code 收不到 → 不冲突)进 copy-mode 半页滚。
     *   xterm.js 默认把 Shift+Arrow 编码成 `ESC[1;2A/B` 经 SSH 送达 tmux。
     * - **scrollback**:history-limit 50000(默认 2000)。经多 agent 实测修正(见 commit):`set -g` 不能
     *   回溯升级已有 window → 必须用 `-f conf` 在 server 启动那刻加载(新 session 出生即 50000);
     *   `source-file` 让 bindings 对已运行 server 立即生效。现有运行中的老 window 需重建才升 scrollback。
     * - conf 用 base64 投递,彻底避开 `;`/`"`/`#{}` 被外层 shell 解释。
     */
    private fun tmuxAttachCommand(session: String): String {
        val conf = buildString {
            append("source-file -q ~/.tmux.conf\n")   // cold-start 时 -f 会跳过默认加载 → 先把用户配置带回来
            append("set -g history-limit 50000\n")
            append("bind -n S-Up \"copy-mode ; send-keys -X halfpage-up\"\n")
            append("bind -n S-Down 'if -F \"#{pane_in_mode}\" \"send-keys -X halfpage-down\"'\n")
        }
        val b64 = Base64.encodeToString(conf.toByteArray(Charsets.UTF_8), Base64.NO_WRAP)
        val c = "/tmp/.xreal-tmux.conf"
        return "export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8; " +
            "export PATH=\"\$PATH:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin\"; " +
            "echo $b64 | base64 -d > $c; " +
            "tmux source-file $c 2>/dev/null; " +           // 已运行 server:bindings 立即对现有 session 生效
            "exec tmux -u -f $c new -A -s '$session'"        // cold-start:server 出生即带 conf(50000 + bindings)
    }

    private fun materializeKey(h: HostConfig): java.io.File =
        java.io.File(filesDir, "term_${h.name}.pem").apply {
            writeText(h.ssh.privateKeyPem); setReadable(false, false); setReadable(true, true)
        }

    /** 热切活动 channel:更新 bridge/voiceDaemon 引用、起新 reader、关旧 channel(解阻塞旧 reader)。 */
    private fun switchTo(newChannel: PtyChannel) {
        val old = activeChannel
        AppLog.d(TAG, "switchTo ${old.javaClass.simpleName} -> ${newChannel.javaClass.simpleName}")
        activeChannel = newChannel
        bridge.channel = newChannel
        voiceDaemon.channel = newChannel
        startReaderFor(newChannel)
        if (old !== newChannel) runCatching { old.close() }
        // 关键:把当前 xterm 尺寸重推给新通道。showTerminal 的 fit→onResize 早在 SSH 连上前就
        // 触发过(那时打到的是 LocalEcho),不重推 SSH PTY 会停在初始 80x24 → tmux 内容画不满。
        runOnUiThread { if (::webView.isInitialized) webView.evaluateJavascript("window.syncSize && window.syncSize()", null) }
    }

    private fun writeToTerm(s: String) {
        val b64 = Base64.encodeToString(s.toByteArray(Charsets.UTF_8), Base64.NO_WRAP)
        runOnUiThread { if (::webView.isInitialized) webView.evaluateJavascript("window.writeToTerm('$b64')", null) }
    }

    private fun writeChannelByte(b: Int) {
        runCatching { activeChannel.write(byteArrayOf(b.toByte())) }   // 原子 write+flush(串行化,见 PtyChannel)
    }

    /** 是否接了外置物理键盘(8BitDo 在键盘模式会算 QWERTY)→ 决定虚拟键盘显隐 */
    private fun hasHardwareKeyboard(): Boolean {
        val cfg = resources.configuration
        return cfg.keyboard == android.content.res.Configuration.KEYBOARD_QWERTY &&
            cfg.hardKeyboardHidden == android.content.res.Configuration.HARDKEYBOARDHIDDEN_NO
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        if (requestCode == REQ_MIC) {
            if (grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED) voiceDaemon.recorder = AudioRecorder()
            else Toast.makeText(this, R.string.mic_permission_denied, Toast.LENGTH_LONG).show()
        }
    }

    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        if (!::voiceDaemon.isInitialized) return super.dispatchKeyEvent(event)

        // BACK:终端视图 → 返回列表(消费);列表视图 → 默认(退出)
        if (event.keyCode == KeyEvent.KEYCODE_BACK && event.action == KeyEvent.ACTION_UP) {
            if (view == View.TERMINAL) { backToList(); return true }
            return super.dispatchKeyEvent(event)
        }

        // 列表视图:方向键/Enter 交给 WebView 的列表导航,语音键不介入
        if (view == View.LIST) return super.dispatchKeyEvent(event)

        // --- 以下为终端视图 ---
        Log.i(TAG, "dispatchKey code=${event.keyCode} action=${event.action} ctrl=${event.isCtrlPressed} alt=${event.isAltPressed}")

        // 备路径 Ctrl+Alt+1/2 → F13/F14(松手时修饰键先释放,所以记住数字键的 UP 来收尾)
        if (event.action == KeyEvent.ACTION_DOWN && event.repeatCount == 0 && event.isCtrlPressed && event.isAltPressed) {
            val mapped = when (event.keyCode) {
                KeyEvent.KEYCODE_1 -> VoiceDaemon.KEY_F13
                KeyEvent.KEYCODE_2 -> VoiceDaemon.KEY_F14
                else -> null
            }
            if (mapped != null) { backupVoiceDigit = event.keyCode; backupVoiceKey = mapped; voiceDaemon.onKeyDown(mapped); return true }
        }
        if (event.action == KeyEvent.ACTION_UP && event.keyCode == backupVoiceDigit) {
            voiceDaemon.onKeyUp(backupVoiceKey); backupVoiceDigit = -1; return true
        }
        // Beam Pro 实测(Stage A.1):8BitDo 经 Android Generic.kl,F13–F24(scancode 183+)全被注释 →
        // 映射不出 keycode,系统在送达前丢弃,到不了 app。改用已映射的 F1/F2 作主路径。
        // F13/F14/F15 分支保留:其它设备 / 未来 .kl 若认 F13+ 仍可用,无害。
        if (event.keyCode == KeyEvent.KEYCODE_F1) {        // F1 = 语音(hold-to-talk)
            when (event.action) {
                // 按住时 ACTION_DOWN 会自动重复 → 只在首次按下开 ASR,否则每帧重启会话
                KeyEvent.ACTION_DOWN -> if (event.repeatCount == 0) voiceDaemon.onKeyDown(VoiceDaemon.KEY_F13)
                KeyEvent.ACTION_UP -> voiceDaemon.onKeyUp(VoiceDaemon.KEY_F13)
            }
            return true
        }
        if (event.keyCode == KeyEvent.KEYCODE_F2) {        // F2 = 返回列表
            if (event.action == KeyEvent.ACTION_UP) backToList()
            return true
        }
        if (event.keyCode == VoiceDaemon.KEY_F13 || event.keyCode == VoiceDaemon.KEY_F14) {
            routeVoiceKey(event.action, event.keyCode); return true
        }
        // F15 → 返回列表(吞掉 down+up,别漏进 xterm;backToList 在 up 触发一次)
        if (event.keyCode == KEYCODE_F15) {
            if (event.action == KeyEvent.ACTION_UP) backToList()
            return true
        }
        if (event.action == KeyEvent.ACTION_DOWN) {
            when (event.keyCode) {
                KeyEvent.KEYCODE_ENTER -> if (voiceDaemon.onEnter()) return true
                KeyEvent.KEYCODE_ESCAPE -> if (voiceDaemon.onEsc()) return true
            }
        }
        return super.dispatchKeyEvent(event)
    }

    private fun routeVoiceKey(action: Int, keyCode: Int) {
        when (action) {
            KeyEvent.ACTION_DOWN -> voiceDaemon.onKeyDown(keyCode)
            KeyEvent.ACTION_UP -> voiceDaemon.onKeyUp(keyCode)
        }
    }

    /** 为某个 channel 起 reader 线程(各自 generation);切换时旧 reader 因 gen 失配 + 旧 channel 被关而退出。 */
    private fun startReaderFor(ch: PtyChannel) {
        val gen = ++readerGen
        thread(start = true, name = "pty-reader-$gen", isDaemon = true) {
            val buf = ByteArray(4096)
            try {
                val ins = ch.inputStream()
                while (gen == readerGen) {
                    val n = ins.read(buf)
                    if (n <= 0) break
                    val b64 = Base64.encodeToString(buf, 0, n, Base64.NO_WRAP)
                    runOnUiThread { webView.evaluateJavascript("window.writeToTerm('$b64')", null) }
                }
            } catch (e: Exception) {
                if (gen == readerGen) AppLog.w(TAG, "pty-reader[$gen] stopped: ${e.javaClass.simpleName}: ${e.message}")
            }
        }
    }

    override fun onDestroy() {
        AppLog.i(TAG, "onDestroy view=$view isFinishing=$isFinishing isChangingConfigurations=$isChangingConfigurations")
        runCatching { displayManager.unregisterDisplayListener(displayListener) }
        runCatching { connectivityManager.unregisterNetworkCallback(netCallback) }
        readerGen++   // 让所有 reader 失效
        fetchExec.shutdownNow()
        manifestFetcher?.close()
        dbgInput?.stop()
        poller?.shutdown()
        runCatching { XrayProxy.stopAll() }   // SSH-over-443:关掉内嵌 xray 实例(无则 no-op)
        if (::voiceDaemon.isInitialized) voiceDaemon.shutdown()
        runCatching { activeChannel.close() }
        if (::webView.isInitialized) webView.destroy()
        super.onDestroy()
    }

    companion object {
        private const val TAG = "MainActivity"
        private const val REQ_MIC = 0x101
        // F15(API 34 起 KEYCODE_F15=328,裸 int):终端→返回列表的专用功能键。
        // 用它代替语义不定的 BACK —— 8BitDo 的 "BACK" 标签发什么键码由固件决定,F15 是确定的。
        private const val KEYCODE_F15 = 328
    }
}
