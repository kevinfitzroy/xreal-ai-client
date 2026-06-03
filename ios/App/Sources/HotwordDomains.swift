import Foundation

/// **LLM 纠错大词表的领域分桶**(issue #16)。每个领域一个具名 list,`all` 合并喂给 `Hotwords.glossary`。
///
/// 为什么单独成文件:热词领域会持续扩充(用户按行业加),集中在此一处便于维护 + review。
/// **只服务 LLM 纠错**(不进 ASR —— 豆包 corpus 有 ~200 字预算上限,见 `Hotwords`)。
///
/// 新增一个行业 = 加一个 `static let xxx = [...]` + 挂到 `all`。挑**高频且 ASR 易听错**的英文专名,别灌字典。
///
/// ⚠️ 两端同步:Android `HotwordDomains.kt` 保持同一份内容。
enum HotwordDomains {

    /// Linux / shell / 系统
    static let linux = [
        "git", "GitHub", "GitLab", "SSH", "SCP", "rsync", "grep", "awk", "sed", "cURL", "wget",
        "sudo", "chmod", "chown", "systemctl", "journalctl", "crontab", "screen", "Vim", "Neovim",
        "Emacs", "nano", "Bash", "Zsh", "apt", "yum", "dnf", "pacman", "Homebrew", "brew",
        "htop", "tar", "gzip", "symlink", "mount", "iptables", "kernel", "daemon", "stdout", "stderr",
        "PATH", "alias", "pipe", "PID",
    ]

    /// 软件开发
    static let softwareDev = [
        "push", "pull", "merge", "rebase", "branch", "clone", "fork", "diff", "stash", "checkout",
        "cherry-pick", "repo", "PR", "CI/CD", "pipeline", "Docker", "Kubernetes", "kubectl", "Helm",
        "container", "image", "registry", "deploy", "rollback", "compile", "debug", "lint", "refactor",
        "API", "SDK", "CLI", "JSON", "YAML", "TOML", "SQL", "regex", "framework", "dependency",
        "npm", "yarn", "pnpm", "pip", "Cargo", "Gradle", "Maven", "Webpack", "Vite", "monorepo",
        "React", "Vue", "Svelte", "Node.js", "Python", "Rust", "Golang", "Java", "Kotlin", "Swift",
        "TypeScript", "JavaScript", "backend", "frontend", "Redis", "PostgreSQL", "MySQL", "SQLite",
        "MongoDB", "GraphQL", "REST", "gRPC", "WebSocket", "OAuth", "JWT", "endpoint", "localhost",
        "async", "await", "mutex", "struct", "enum", "closure",
    ]

    /// 互联网 / web
    static let internet = [
        "HTTP", "HTTPS", "TCP", "UDP", "DNS", "URL", "CDN", "VPN", "proxy", "SSL", "TLS", "GFW",
        "latency", "bandwidth", "browser", "cookie", "cache", "payload", "server", "client", "cloud",
        "AWS", "GCP", "Azure", "Cloudflare", "Nginx", "Apache", "webhook", "subdomain", "gateway",
    ]

    /// AI / 大模型
    static let ai = [
        "LLM", "GPT", "ChatGPT", "OpenAI", "Anthropic", "Gemini", "Llama", "Qwen", "Mistral",
        "embedding", "prompt", "fine-tune", "RAG", "inference", "transformer", "attention", "GPU",
        "CUDA", "PyTorch", "TensorFlow", "Hugging Face", "multimodal", "hallucination", "context window",
        "temperature", "MoE", "quantization", "vLLM", "Ollama", "token", "MCP",
    ]

    /// 医疗美容(注射 / 光电能量 / 项目 / 护理 + 品牌;均为 ASR 高频易错专名)
    static let medicalAesthetics = [
        // 注射类
        "玻尿酸", "肉毒素", "瘦脸针", "除皱针", "水光针", "童颜针", "少女针", "嗨体",
        "乔雅登", "瑞蓝", "保妥适", "伊妍仕", "胶原蛋白", "菲洛嘉",
        // 光电 / 能量
        "热玛吉", "超声刀", "热拉提", "光子嫩肤", "皮秒", "超皮秒", "黄金微针", "射频",
        "点阵激光", "调Q激光", "OPT", "脱毛",
        // 手术 / 项目
        "线雕", "埋线", "双眼皮", "开眼角", "隆鼻", "自体脂肪", "脂肪填充", "吸脂", "溶脂", "面部填充",
        // 护理 / 概念
        "果酸", "刷酸", "焕肤", "小气泡", "微针", "半永久", "纹眉", "美白针", "抗衰", "提拉", "紧致",
        // 品牌(英文,夹在中文里 ASR 常错)
        "Botox", "Thermage", "Ultherapy", "HIFU", "Juvederm", "Restylane", "Sculptra", "Fotona",
    ]

    /// 所有领域合并(顺序无关,`Hotwords.forCorrection` 会去重)。新增行业挂到这里。
    static let all: [String] = linux + softwareDev + internet + ai + medicalAesthetics
}
