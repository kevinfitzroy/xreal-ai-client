# 代客安装 (Valet Setup) — 给「代客 agent」的引导

> **这份文件是写给 AI agent 看的,不是写给人看的。**
>
> 用法:用户在自己的**笔记本/台式机**上开一个 Claude Code(或同等 agent),把这份文件丢给它,说一句
> "照这个把我的 xreal-ai-client 装好"。你(那个 agent)就是**代客 (Valet)**,负责经 `adb` 替用户完成 app 初始化。
>
> 为什么要 agent 来做:这个 app 跑在 AR 眼镜 + 6 键手柄上,**故意不做设置 UI**,SSH 参数 / 私钥这种东西在眼镜上手输是地狱。所以把活儿交给一个有真键盘 + `adb` 的 agent。详见项目 README「代客安装」。

---

## 你的任务(一句话)

在 Mac 上生成一把**专用** SSH key,把它和 host 连接配置经 `adb` 推到手机 app 的 staging,触发 app 导入到私有存储;再到目标 host 上部署 **Maestro**(host 端 orchestrator)让它接管项目管理。

## 前置检查

```bash
adb devices          # 必须看到一台 device(不是 unauthorized/offline)。没有 → 让用户开 USB 调试并授权
adb shell pm path io.github.kevinfitzroy.xrealclient   # 确认 app 已安装。没有 → 让用户先装 APK
```

> **运行位置**:本指南假设你在 `xreal-ai-client` 的一个 checkout 里运行(第 4 步要 `scp` 仓库内的
> `docs/orchestrator-CLAUDE.md`)。不在 → 先 `git clone` 这个仓库并 `cd` 进去,或把 repo 路径记下,
> 第 4 步用绝对路径。

## 第 1 步 — 问用户拿 host 信息

你需要这几项(对话式地问,别让用户写文件):
- **host 地址**(IP 或域名)、**端口**(默认 22)、**登录用户名**
- **base path**:这台 host 上放所有项目的根目录(如 `/home/evan/work`)。Maestro和所有项目都在它下面。
- 一个**短名字**给这台 host(列表显示用,如 `beam-server`)

## 第 2 步 — 生成专用 key(绝不用用户主 key)

```bash
HOST_NAME=beam-server                       # 用户给的短名字
KEY=~/.ssh/xreal_${HOST_NAME}
ssh-keygen -t ed25519 -f "$KEY" -N "" -C "xreal-valet-${HOST_NAME}"
```

- **必须是专用、一次性的 key**。不要复用、不要上传用户已有的私钥。
- 这把 key 的用途单一:app ←→ 这台 host。泄露了用户可以单独吊销它,不波及别的。

## 第 3 步 — 把公钥装到 host

```bash
ssh-copy-id -i "$KEY.pub" <user>@<host>     # 或手动 append 到 host 的 ~/.ssh/authorized_keys
ssh -i "$KEY" <user>@<host> 'echo ok && tmux -V && claude --version'   # 验证能登 + host 上有 tmux/claude
```

如果 host 上没装 `tmux` 或 `claude`,先引导用户在 host 上装好(Maestro需要它们)。

## 第 4 步 — 部署 Maestro 到 host

把 `docs/orchestrator-CLAUDE.md` 放成 host 的 `<base>/CLAUDE.md`,并把助手脚本 `docs/xreal-project.sh` 放到 `<base>/.xreal/`,起常驻 maestro session:

```bash
BASE=/home/evan/work                        # 用户给的 base path
scp -i "$KEY" docs/orchestrator-CLAUDE.md <user>@<host>:"$BASE/CLAUDE.md"
ssh -i "$KEY" <user>@<host> "mkdir -p '$BASE/.xreal'"
scp -i "$KEY" docs/xreal-project.sh <user>@<host>:"$BASE/.xreal/xreal-project.sh"
ssh -i "$KEY" <user>@<host> "
  chmod +x '$BASE/.xreal/xreal-project.sh'
  printf '%s\n' '{ \"version\": 1, \"projects\": [] }' > '$BASE/.xreal/projects.json'   # 合法空清单
  cd '$BASE' && tmux -u new -d -s maestro 'claude'                                       # 常驻 Maestro
"
```

## 第 5 步 — 拼 import bundle 并推到 app staging

staging 目录 = `/data/local/tmp/xreal_import/`。里面放 `hosts.json` + 私钥文件(**`key` 字段必须是纯文件名**,app 会拒绝带 `/` 或 `..` 的路径)。

```bash
STAGING=/data/local/tmp/xreal_import
KEY_FILE=$(basename "$KEY")                  # 如 xreal_beam-server

# hosts.json:连接信息 + base path + 一个 seed 项目(Maestro自己),这样用户进 app 就能找到Maestro
cat > /tmp/xreal_hosts.json <<JSON
[
  {
    "name": "${HOST_NAME}",
    "addr": "<user>@<host>",
    "host": "<host>",
    "port": 22,
    "user": "<user>",
    "basePath": "${BASE}",
    "key": "${KEY_FILE}",
    "projects": [
      { "session": "maestro", "name": "Maestro", "type": "maestro" }
    ]
  }
]
JSON

# ⚠️ 严格顺序:push 必须全部完成,再 force-stop + start。用 && 串起来,别并行。
adb shell "mkdir -p $STAGING" \
  && adb push "$KEY" "$STAGING/$KEY_FILE" \
  && adb push /tmp/xreal_hosts.json "$STAGING/hosts.json" \
  && adb shell am force-stop io.github.kevinfitzroy.xrealclient \
  && adb shell input keyevent KEYCODE_WAKEUP \
  && adb shell am start -n io.github.kevinfitzroy.xrealclient/.MainActivity
```

app 启动时会:把 key 拷进私有存储(`filesDir/keys/<host>.pem`,600)、写私有 `hosts.json`。

## 第 6 步 — 验证,然后**你来清 staging**(关键)

```bash
adb logcat -d -s SettingsStore:I | tail -3      # 应看到 "Valet 导入完成:1 host → 私有存储…"
```

⚠️ **app 自己删不掉 staging** —— 它是 untrusted_app SELinux 域,能读但无权删 `/data/local/tmp`。所以**确认导入成功后,你(Valet,跑在 adb shell 域,有权限)必须手动清掉**那把世界可读的 key:

```bash
adb shell rm -rf /data/local/tmp/xreal_import
adb shell ls /data/local/tmp/xreal_import 2>&1  # 应为 "No such file or directory"
```

然后让用户看手机:app 列表里应出现这台 host + 「Maestro」。进Maestro终端说一句"帮我建个做 X 的项目",Maestro就会建目录 + 起 session + 更新 manifest。

## 收尾 & 安全提醒

- 删掉 Mac 上的临时文件:`rm -f /tmp/xreal_hosts.json`。专用私钥 `$KEY` 留着(app 用的就是它)。
- 一台 host 一把专用 key。要加第二台 host?重跑第 1–6 步,换 `HOST_NAME`。
- 这把 key 只配了这台 host 的访问,丢了单独吊销即可。**全程没碰用户的主 key。**
