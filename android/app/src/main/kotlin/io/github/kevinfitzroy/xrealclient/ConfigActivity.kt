package io.github.kevinfitzroy.xrealclient

import android.app.Activity
import android.content.Intent
import android.graphics.Color
import android.os.Bundle
import android.text.InputType
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import android.widget.Toast

/**
 * 简单配置界面 — 第一次启动 / 用户主动改配置时进。
 * 纯 programmatic UI(不用 XML layout 减依赖)。
 *
 * 跳转:MainActivity 检测 [SettingsStore.loadSsh].isComplete() == false → startActivity(this)
 * 保存后:回到 MainActivity 触发 SSH connect。
 */
class ConfigActivity : Activity() {

    private lateinit var store: SettingsStore
    private lateinit var hostEdit: EditText
    private lateinit var portEdit: EditText
    private lateinit var userEdit: EditText
    private lateinit var keyEdit: EditText
    private lateinit var startupEdit: EditText
    private lateinit var asrProviderEdit: EditText
    private lateinit var asrAppidEdit: EditText
    private lateinit var asrTokenEdit: EditText
    private lateinit var asrResourceEdit: EditText

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        store = SettingsStore(this)

        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(20), dp(28), dp(20), dp(20))
            setBackgroundColor(0xff11131a.toInt())
        }
        val scroll = ScrollView(this).apply { addView(root) }
        setContentView(scroll)

        val ssh = store.loadSsh()
        val asr = store.loadAsr()

        root.addView(header(getString(R.string.config_ssh_section)))
        hostEdit = root.addInput(getString(R.string.config_ssh_host_hint), ssh.host)
        portEdit = root.addInput(
            getString(R.string.config_ssh_port_hint), ssh.port.toString(),
            inputType = InputType.TYPE_CLASS_NUMBER,
        )
        userEdit = root.addInput(getString(R.string.config_ssh_user_hint), ssh.user)
        keyEdit = root.addInput(
            getString(R.string.config_ssh_key_hint), ssh.privateKeyPem,
            multiline = true,
        )
        startupEdit = root.addInput(getString(R.string.config_ssh_startup_hint), ssh.startupCommand)

        root.addView(header(getString(R.string.config_asr_section)))
        asrProviderEdit = root.addInput(getString(R.string.config_asr_provider), asr.provider.name)
        asrAppidEdit = root.addInput(getString(R.string.config_asr_appid), asr.appid)
        asrTokenEdit = root.addInput(getString(R.string.config_asr_token), asr.token)
        asrResourceEdit = root.addInput(getString(R.string.config_asr_resource), asr.resourceId)

        root.addView(Button(this).apply {
            text = getString(R.string.config_save)
            setOnClickListener { save() }
        })
    }

    private fun save() {
        val ssh = SshConfig(
            host = hostEdit.text.toString().trim(),
            port = portEdit.text.toString().toIntOrNull() ?: 22,
            user = userEdit.text.toString().trim(),
            privateKeyPem = keyEdit.text.toString().trim(),
            startupCommand = startupEdit.text.toString().trim().ifBlank { "abduco -A dev bash" },
        )
        if (!ssh.isComplete()) {
            Toast.makeText(this, "SSH host/user/key 必填", Toast.LENGTH_SHORT).show()
            return
        }
        val asr = AsrConfig(
            provider = runCatching {
                AsrProvider.valueOf(asrProviderEdit.text.toString().uppercase())
            }.getOrDefault(AsrProvider.MOCK),
            appid = asrAppidEdit.text.toString().trim(),
            token = asrTokenEdit.text.toString().trim(),
            resourceId = asrResourceEdit.text.toString().trim().ifBlank { AsrConfig.DEFAULT_RESOURCE_ID },
        )
        store.saveSsh(ssh)
        store.saveAsr(asr)
        setResult(RESULT_OK)
        startActivity(Intent(this, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP))
        finish()
    }

    // --- 简单 view helpers ---

    private fun header(text: String) = TextView(this).apply {
        this.text = text
        textSize = 18f
        setTextColor(0xff94e0b2.toInt())
        setPadding(0, dp(20), 0, dp(8))
    }

    private fun LinearLayout.addInput(
        hint: String, initial: String, multiline: Boolean = false, inputType: Int = -1,
    ): EditText {
        val tv = TextView(this@ConfigActivity).apply {
            text = hint
            setTextColor(Color.LTGRAY)
            setPadding(0, dp(8), 0, dp(2))
            textSize = 12f
        }
        val edit = EditText(this@ConfigActivity).apply {
            setText(initial)
            setTextColor(Color.WHITE)
            setBackgroundColor(0xff1c1f2a.toInt())
            setPadding(dp(8), dp(8), dp(8), dp(8))
            if (multiline) {
                this.inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_MULTI_LINE
                minLines = 4
                gravity = Gravity.TOP
            } else if (inputType >= 0) {
                this.inputType = inputType
            }
            layoutParams = ViewGroup.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT,
            )
        }
        addView(tv)
        addView(edit)
        return edit
    }

    private fun dp(v: Int): Int = (v * resources.displayMetrics.density).toInt()

    @Suppress("unused")
    private fun View.hide() { visibility = View.GONE }
}
