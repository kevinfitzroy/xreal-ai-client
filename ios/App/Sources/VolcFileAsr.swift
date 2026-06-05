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
