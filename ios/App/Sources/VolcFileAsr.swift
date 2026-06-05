import Foundation

/// 豆包**录音文件识别 2.0(大模型极速版)**客户端 —— 把一段 WAV 一次性转成带说话人标号的逐字稿。
///
/// 接口 `POST /api/v3/auc/bigmodel/recognize/flash`,resource `volc.bigasr.auc_turbo`,**一次请求直接返回**
/// (无 submit/query 轮询)。鉴权 header 跟流式 ASR 同一套(`X-Api-App-Key`/`X-Api-Access-Key`),
/// **复用 `Documents/asr.json` 的 appid/token**,仅 resourceId 换成 auc_turbo。
///
/// 体积约束:base64 内联,≤100MB(≈ 16k/mono/16bit 50 分钟);超长会议后续做分段,这里只管单段。
enum VolcFileAsr {

    static let endpoint = URL(string: "https://openspeech.bytedance.com/api/v3/auc/bigmodel/recognize/flash")!
    static let resourceId = "volc.bigasr.auc_turbo"

    enum FileAsrError: Error, CustomStringConvertible {
        case noCreds
        case http(Int)
        case apiStatus(String, String)   // code, message
        case emptyResult
        case badResponse
        var description: String {
            switch self {
            case .noCreds:            return "缺少 ASR 凭证(Documents/asr.json)"
            case .http(let c):        return "HTTP \(c)"
            case .apiStatus(let c, let m): return "豆包返回 \(c): \(m)"
            case .emptyResult:        return "识别结果为空"
            case .badResponse:        return "响应格式无法解析"
            }
        }
    }

    /// 识别 `wavURL`(16k/mono WAV)。`enableSpeaker` 开说话人分离(小范围会议建议开)。
    /// 异步;失败抛 `FileAsrError` 或网络错误。
    static func recognize(wavURL: URL, enableSpeaker: Bool) async throws -> MeetingTranscript {
        guard let creds = AsrCreds.load() else { throw FileAsrError.noCreds }
        let wavData = try Data(contentsOf: wavURL)

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        creds.applyAuth { req.setValue($1, forHTTPHeaderField: $0) }
        req.setValue(resourceId, forHTTPHeaderField: "X-Api-Resource-Id")
        req.setValue(UUID().uuidString, forHTTPHeaderField: "X-Api-Request-Id")
        req.setValue("-1", forHTTPHeaderField: "X-Api-Sequence")

        let body: [String: Any] = [
            "user": ["uid": creds.uid],
            "audio": ["data": wavData.base64EncodedString(), "format": "wav"],
            "request": [
                "model_name": "bigmodel",
                "enable_itn": true,           // 数字规整
                "enable_punc": true,          // 标点
                "enable_ddc": true,           // 语义顺滑
                "enable_speaker_info": enableSpeaker,
                // TODO 热词:flash 端点的热词字段名未核实,会议场景收益有限,先不传(避免错字段 400)。
            ],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        AgentLog.info("meeting", "flash recognize: \(wavData.count)B wav, speaker=\(enableSpeaker)")
        let (data, resp) = try await URLSession.shared.data(for: req)

        guard let http = resp as? HTTPURLResponse else { throw FileAsrError.badResponse }
        // v3 即便 HTTP 200 也用 header 的 X-Api-Status-Code 表逻辑状态(20000000 = 成功)。
        if let statusCode = http.value(forHTTPHeaderField: "X-Api-Status-Code"), statusCode != "20000000" {
            let msg = http.value(forHTTPHeaderField: "X-Api-Message") ?? ""
            AgentLog.error("meeting", "flash api status \(statusCode) \(msg)")
            throw FileAsrError.apiStatus(statusCode, msg)
        }
        guard http.statusCode == 200 else { throw FileAsrError.http(http.statusCode) }

        #if DEBUG
        // 验真实返回体、钉 parser:把 raw 响应(截断)打进日志面板。
        if let raw = String(data: data, encoding: .utf8) {
            AgentLog.info("meeting", "flash raw resp (\(data.count)B): \(raw.prefix(3000))")
        }
        #endif
        return try parse(data)
    }

    /// 多段识别 + 合并:逐段 recognize(带重试),按段序拼接 utterances 与 fullText。某段静音(emptyResult)
    /// 跳过不致命。⚠️ 说话人标签**每段独立**编号(豆包按请求编号),跨段不保证 speaker N 是同一人 —— 委托给
    /// agent 时由它按上下文映射(issue #19 已知限制)。
    static func recognizeSegments(_ urls: [URL], enableSpeaker: Bool) async throws -> MeetingTranscript {
        guard !urls.isEmpty else { throw FileAsrError.emptyResult }
        if urls.count == 1 { return try await recognizeWithRetry(wavURL: urls[0], enableSpeaker: enableSpeaker) }

        var utterances: [MeetingUtterance] = []
        var texts: [String] = []
        var anyOk = false
        for (i, url) in urls.enumerated() {
            AgentLog.info("meeting", "recognize segment \(i + 1)/\(urls.count)")
            do {
                let seg = try await recognizeWithRetry(wavURL: url, enableSpeaker: enableSpeaker)
                utterances.append(contentsOf: seg.utterances)
                if !seg.fullText.isEmpty { texts.append(seg.fullText) }
                anyOk = true
            } catch FileAsrError.emptyResult {
                AgentLog.info("meeting", "segment \(i + 1) empty (silence?), skip")
            }
            // 非空错误(重试后仍失败)→ 抛出,整体失败(用户可整条重试)。
        }
        guard anyOk else { throw FileAsrError.emptyResult }
        return MeetingTranscript(utterances: utterances, fullText: texts.joined(separator: "\n"))
    }

    /// 单段识别 + **网络容错重试**:瞬时错误(超时/HTTP/解析)线性退避重试;逻辑错误(资源未授权/无凭证/
    /// 空结果)不重试直接抛。
    private static func recognizeWithRetry(wavURL: URL, enableSpeaker: Bool, attempts: Int = 3) async throws -> MeetingTranscript {
        var lastError: Error?
        for attempt in 1...attempts {
            do {
                return try await recognize(wavURL: wavURL, enableSpeaker: enableSpeaker)
            } catch let e as FileAsrError {
                switch e {
                case .noCreds, .apiStatus, .emptyResult: throw e   // 确定性错误,重试无意义
                case .http, .badResponse: lastError = e            // 可能瞬时 → 重试
                }
            } catch {
                lastError = error   // 网络/超时 → 重试
            }
            if attempt < attempts {
                AgentLog.warn("meeting", "segment recognize retry \(attempt)/\(attempts): \(wavURL.lastPathComponent)")
                try? await Task.sleep(nanoseconds: UInt64(attempt) * 1_000_000_000)   // 线性退避 1s/2s
            }
        }
        throw lastError ?? FileAsrError.badResponse
    }

    /// 解析返回体。容错:`speaker` 可能在 utterance 顶层或 `additions.speaker`;无 utterances 时退回 `result.text`。
    private static func parse(_ data: Data) throws -> MeetingTranscript {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw FileAsrError.badResponse
        }
        // result 可能直接是对象,也可能在顶层。
        let result = (root["result"] as? [String: Any]) ?? root
        let fullText = (result["text"] as? String) ?? ""

        var utterances: [MeetingUtterance] = []
        if let arr = result["utterances"] as? [[String: Any]] {
            for u in arr {
                let text = (u["text"] as? String) ?? ""
                guard !text.isEmpty else { continue }
                let additions = u["additions"] as? [String: Any]
                let speaker = (u["speaker"] as? String)
                    ?? (additions?["speaker"] as? String)
                    ?? (u["speaker"] as? Int).map(String.init)
                utterances.append(MeetingUtterance(
                    text: text,
                    speaker: speaker?.isEmpty == true ? nil : speaker,
                    startMs: (u["start_time"] as? Int) ?? 0,
                    endMs: (u["end_time"] as? Int) ?? 0))
            }
        }
        guard !utterances.isEmpty || !fullText.isEmpty else { throw FileAsrError.emptyResult }
        AgentLog.info("meeting", "flash parsed: \(utterances.count) utterances, speakers=\(Set(utterances.compactMap(\.speaker)).count)")
        return MeetingTranscript(utterances: utterances, fullText: fullText)
    }
}
