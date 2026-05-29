package io.github.kevinfitzroy.xrealclient

import android.Manifest
import android.app.Activity
import android.content.pm.PackageManager
import android.os.Bundle
import android.text.InputType
import android.util.Base64
import android.util.Log
import android.view.KeyEvent
import android.view.WindowManager
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputConnection
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
                    pendingHostListJson?.let { pushHostList(it) }
                    refreshManifests()   // 首屏:静态 seed 先显示,manifest 拉到后替换
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
                android.util.Log.i(TAG, "ASR = VolcEngineAsr(resource=${asr.resourceId})")
            }
        }

        if (hosts.isNotEmpty()) {
            // 核心流程:真实 host/project 静态枚举(onPageFinished 推)。Enter→findProject 靠它开真终端。
            pendingHostListJson = StatusPoller.staticListJson(hosts)

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
            val updated = runCatching { fetcher.fetch(hosts) }.getOrNull() ?: return@execute
            runOnUiThread {
                if (gen != fetchGen) return@runOnUiThread
                liveProjects = updated.associate { it.name to it.projects }
                pushHostList(StatusPoller.staticListJson(updated))
            }
        }
    }

    override fun onStart() {
        super.onStart()
        poller?.start()
        if (view == View.LIST) refreshManifests()   // 回前台 + 在列表态:刷一次
    }

    override fun onStop() {
        poller?.stop()
        super.onStop()
    }

    /**
     * JS 列表 Enter 进入 project:查到真实 host 配置 → 后台连 SSH(attach 该 project 的 tmux
     * session)→ 热切 channel;查不到(mock 数据)→ 回退干净 LocalEcho 演示。
     */
    private fun onOpenProject(host: String, session: String, name: String, type: String) {
        Log.i(TAG, "openProject host=$host session=$session name=$name type=$type")
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
        writeToTerm("连接 ${h.ssh.user}@${h.ssh.host}:${h.ssh.port} … (${p.sessionName})\r\n")
        thread(name = "ssh-connect", isDaemon = true) {
            try {
                val ssh = SshConnection(
                    host = h.ssh.host, port = h.ssh.port, user = h.ssh.user,
                    privateKeyPath = materializeKey(h).absolutePath,
                    startupCommand = tmuxAttachCommand(p.sessionName),
                    knownHostsFile = java.io.File(filesDir, "known_hosts"),
                )
                ssh.connect(80, 24)   // 初始尺寸;showTerminal 的 fit 会触发 onResize 校正
                runOnUiThread {
                    if (seq == openSeq && view == View.TERMINAL) switchTo(ssh)
                    else runCatching { ssh.close() }   // 用户已走开 → 关掉,别泄漏连接
                }
            } catch (e: Exception) {
                Log.w(TAG, "ssh connect 失败: ${e.message}")
                runOnUiThread {
                    if (seq == openSeq) {
                        switchTo(LocalEchoChannel())
                        writeToTerm("\r\nSSH 连接失败: ${e.message}\r\n")
                    }
                }
            }
        }
    }

    private fun backToList() {
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
     * attach-or-create 该 project 的 tmux session。
     * - LANG/LC_ALL=UTF-8 + `tmux -u`:强制 UTF-8 客户端,否则 tmux 把多字节(中文/powerline)降级成 `_`。
     * - PATH 前缀:非交互 exec 的 PATH 太窄找不到 tmux(同 HostClient)。
     */
    private fun tmuxAttachCommand(session: String): String =
        "export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8; export PATH=\"\$PATH:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin\"; exec tmux -u new -A -s '$session'"

    private fun materializeKey(h: HostConfig): java.io.File =
        java.io.File(filesDir, "term_${h.name}.pem").apply {
            writeText(h.ssh.privateKeyPem); setReadable(false, false); setReadable(true, true)
        }

    /** 热切活动 channel:更新 bridge/voiceDaemon 引用、起新 reader、关旧 channel(解阻塞旧 reader)。 */
    private fun switchTo(newChannel: PtyChannel) {
        val old = activeChannel
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
        runCatching { activeChannel.outputStream().write(b); activeChannel.outputStream().flush() }
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
        if (event.keyCode == VoiceDaemon.KEY_F13 || event.keyCode == VoiceDaemon.KEY_F14) {
            routeVoiceKey(event.action, event.keyCode); return true
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
                if (gen == readerGen) Log.w(TAG, "pty-reader[$gen] stopped: ${e.message}")
            }
        }
    }

    override fun onDestroy() {
        readerGen++   // 让所有 reader 失效
        fetchExec.shutdownNow()
        manifestFetcher?.close()
        dbgInput?.stop()
        poller?.shutdown()
        if (::voiceDaemon.isInitialized) voiceDaemon.shutdown()
        runCatching { activeChannel.close() }
        if (::webView.isInitialized) webView.destroy()
        super.onDestroy()
    }

    companion object {
        private const val TAG = "MainActivity"
        private const val REQ_MIC = 0x101
    }
}
