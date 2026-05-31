import Foundation

/// 流式 ASR 抽象 —— Android `Asr`/`AsrStream`/`AsrCallback` 的 port。
/// 一次"按住说话"对应一个 `AsrStream` 会话。回调可能在任意线程(WS 队列 / 定时器),
/// UI marshal 由调用方负责。
protocol Asr {
    /// 开会话。`lang` "zh"/"en"(部分实现忽略);`hotwords` 提升识别准确率(可空)。
    func open(lang: String, hotwords: [String], callback: AsrCallback) -> AsrStream
}

protocol AsrStream {
    /// 实时音频块(裸 PCM16LE 16k mono)。
    func send(_ pcmChunk: Data)
    /// 录音结束:发最后一包(负包),触发最终结果。
    func finish()
    /// 取消:关连接,之后不再回调。
    func cancel()
}

/// 回调可能在任意线程。`onPartial` 携带全量文本(可直接替换显示)。
protocol AsrCallback: AnyObject {
    func onPartial(_ text: String)
    func onFinal(_ text: String)
    func onError(_ reason: String)
}

/// ASR 凭证(`Documents/asr.json`,形如 `{provider,appid,token,resourceId}`)。
struct AsrCreds {
    let appid: String
    let token: String
    let resourceId: String

    static let defaultResourceId = "volc.seedasr.sauc.duration"

    /// 从私有存储读 asr.json;缺失/无效 → nil(VoiceController 回退 MockAsr)。
    static func load() -> AsrCreds? {
        let url = HostStore.documentsDir.appendingPathComponent("asr.json")
        guard let data = try? Data(contentsOf: url),
              let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        let appid = (o["appid"] as? String) ?? ""
        let token = (o["token"] as? String) ?? ""
        guard !appid.isEmpty, !token.isEmpty else { return nil }
        let resource = (o["resourceId"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? defaultResourceId
        return AsrCreds(appid: appid, token: token, resourceId: resource)
    }
}

/// emulator / 无凭证:假装流式 —— 300ms 出 partial,finish 后 300ms 出 final。忽略真实音频。
/// Android `MockAsr` 的 port。
final class MockAsr: Asr {
    func open(lang: String, hotwords: [String], callback: AsrCallback) -> AsrStream {
        let s = MockStream(lang: lang, cb: callback)
        s.start()
        return s
    }
    private final class MockStream: AsrStream {
        // strong: the stream owns the callback for its lifetime (the GenCallback wrapper has no
        // other holder — weak here would deallocate it immediately → callbacks silently no-op).
        private let cb: AsrCallback
        private let text: String
        private var cancelled = false
        init(lang: String, cb: AsrCallback) { self.cb = cb; self.text = lang == "en" ? "pwd" : "ls -la" }
        func send(_ pcmChunk: Data) {}
        func finish() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self, !self.cancelled else { return }
                self.cb.onFinal(self.text)
            }
        }
        func cancel() { cancelled = true }
        // partial after a short delay
        func start() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self, !self.cancelled else { return }
                self.cb.onPartial(self.text)
            }
        }
    }
}

/// 火山引擎(豆包)大模型流式语音识别 —— 双向流式 WS client,**真流式**:按下即连 WS,音频边录
/// 边推,中间结果实时回 `onPartial`,松手发负包拿最终结果。Android `VolcEngineAsr.kt` 的 port。
///
/// 接口 `wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async`;鉴权走 HTTP header(无签名)。
/// 失败语义:任何错误回 `onError`;服务端先关或超时但已有中间结果,则当 final 用。不 reconnect。
final class VolcAsr: Asr {
    private let appid: String
    private let token: String
    private let resourceId: String

    init(appid: String, token: String, resourceId: String = AsrCreds.defaultResourceId) {
        self.appid = appid
        self.token = token
        self.resourceId = resourceId
    }

    func open(lang: String, hotwords: [String], callback: AsrCallback) -> AsrStream {
        let s = VolcStream(appid: appid, token: token, resourceId: resourceId,
                           hotwords: hotwords, cb: callback)
        s.start()
        return s
    }

    /// 单会话。所有可变状态在串行 `queue` 上访问(URLSessionWebSocketTask 回调来自其内部队列,
    /// 这里统一 hop 到 `queue` 串行化 → 等价 Android 的 `synchronized(lock)`)。
    private final class VolcStream: NSObject, AsrStream, URLSessionWebSocketDelegate {
        private let appid: String, token: String, resourceId: String
        private let hotwords: [String]
        // strong: the stream owns its callback for the session (the GenCallback wrapper has no other
        // holder — weak would deallocate it before any result lands). The stream itself is owned by
        // VoiceController.stream and released on resetIdle/shutdown, so no retain cycle.
        private let cb: AsrCallback

        private let queue = DispatchQueue(label: "volc.asr.stream")
        private var cancelled = false
        private var done = false
        private var connected = false
        private var finishRequested = false
        private var pending: [Data] = []     // onOpen 前缓冲的音频块
        private var best = ""
        private var session: URLSession?     // keeps a STRONG ref to us (delegate) until invalidated
        private var task: URLSessionWebSocketTask!
        private var watchdog: DispatchWorkItem?

        init(appid: String, token: String, resourceId: String, hotwords: [String], cb: AsrCallback) {
            self.appid = appid; self.token = token; self.resourceId = resourceId
            self.hotwords = hotwords; self.cb = cb
            super.init()
        }

        func start() {
            var req = URLRequest(url: VolcStream.endpoint)
            req.setValue(appid, forHTTPHeaderField: "X-Api-App-Key")
            req.setValue(token, forHTTPHeaderField: "X-Api-Access-Key")
            req.setValue(resourceId, forHTTPHeaderField: "X-Api-Resource-Id")
            req.setValue(UUID().uuidString, forHTTPHeaderField: "X-Api-Connect-Id")
            req.setValue(UUID().uuidString, forHTTPHeaderField: "X-Api-Request-Id")
            let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
            self.session = session
            task = session.webSocketTask(with: req)
            task.resume()
            receiveLoop()
        }

        // MARK: URLSessionWebSocketDelegate — onOpen
        func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                        didOpenWithProtocol protocol: String?) {
            queue.async { [weak self] in
                guard let self else { return }
                if self.cancelled { self.task.cancel(with: .normalClosure, reason: nil); return }
                NSLog("[VolcAsr] WS open")
                self.rawSend(VolcFrame.buildFullClientRequest(self.requestJson()))
                while !self.pending.isEmpty {
                    self.rawSend(VolcFrame.buildAudio(self.pending.removeFirst(), last: false))
                }
                self.connected = true
                if self.finishRequested {
                    self.rawSend(VolcFrame.buildAudio(Data(), last: true))
                }
            }
        }

        func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
            // 服务端先关而没发 last 包:已有中间结果当 final。
            queue.async { [weak self] in
                guard let self, !self.cancelled else { return }
                NSLog("[VolcAsr] WS closed code=\(closeCode.rawValue) (finishRequested=\(self.finishRequested))")
                self.resolveFinal()
            }
        }

        private func receiveLoop() {
            task.receive { [weak self] result in
                guard let self else { return }
                switch result {
                case .success(let message):
                    self.queue.async { self.handle(message) }
                    self.receiveLoop()
                case .failure(let error):
                    self.queue.async {
                        guard !self.cancelled else { return }
                        NSLog("[VolcAsr] WS failure (finishRequested=\(self.finishRequested)): \(error.localizedDescription)")
                        self.resolveError(error.localizedDescription)
                    }
                }
            }
        }

        private func handle(_ message: URLSessionWebSocketTask.Message) {
            guard !cancelled else { return }
            guard case let .data(data) = message else { return }   // 服务端只发二进制
            switch VolcFrame.parse(data) {
            case let .server(_, isLast, payloadJson):
                let t = extractText(payloadJson)
                if !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    best = t
                    cb.onPartial(t)
                }
                // 按住期间(finishRequested=false)服务端的 isLast = VAD 判停/分句,继续流;
                // 只在松手发了负包后才真正收尾。
                if isLast {
                    NSLog("[VolcAsr] server isLast (finishRequested=\(finishRequested))")
                    if finishRequested { resolveFinal() }
                }
            case let .error(code, msg):
                NSLog("[VolcAsr] server error code=\(code) msg=\(msg)")
                resolveError("code=\(code)")
            case let .unknown(type):
                NSLog("[VolcAsr] unknown msg type=\(type)")
            }
        }

        // MARK: AsrStream
        func send(_ pcmChunk: Data) {
            queue.async { [weak self] in
                guard let self, !self.cancelled else { return }
                if self.connected { self.rawSend(VolcFrame.buildAudio(pcmChunk, last: false)) }
                else { self.pending.append(pcmChunk) }
            }
        }

        func finish() {
            queue.async { [weak self] in
                guard let self, !self.cancelled else { return }
                self.finishRequested = true
                if self.connected { self.rawSend(VolcFrame.buildAudio(Data(), last: true)) }
                // 未连上:onOpen 排空 pending 后会补发负包。
                // 松手后才启看门狗:录音期间不超时(可长按)。
                let wd = DispatchWorkItem { [weak self] in
                    self?.queue.async { guard let self, !self.cancelled else { return }; self.resolveFinal() }
                }
                self.watchdog = wd
                self.queue.asyncAfter(deadline: .now() + VolcStream.finalTimeout, execute: wd)
            }
        }

        func cancel() {
            queue.async { [weak self] in
                guard let self else { return }
                self.cancelled = true
                self.watchdog?.cancel()
                self.teardownTransport()
            }
        }

        /// 收尾:把 best 当最终结果交出去(可能为空 → VoiceController 回 IDLE)。只生效一次。
        private func resolveFinal() {
            guard !done else { return }
            done = true
            watchdog?.cancel()
            cb.onFinal(best.trimmingCharacters(in: .whitespacesAndNewlines))
            teardownTransport()
        }

        private func resolveError(_ reason: String) {
            guard !done else { return }
            done = true
            watchdog?.cancel()
            cb.onError(reason)
            teardownTransport()
        }

        /// 关 WS + invalidate session。URLSession 强引用 delegate(self)直到 invalidate —— 不做
        /// 每次按住说话泄漏一个 VolcStream。invalidate 后 receive/delegate 回调不再来。
        private func teardownTransport() {
            task?.cancel(with: .normalClosure, reason: nil)
            session?.finishTasksAndInvalidate()
            session = nil
        }

        private func rawSend(_ data: Data) {
            task.send(.data(data)) { err in
                if let err { NSLog("[VolcAsr] send error: \(err.localizedDescription)") }
            }
        }

        /// 命令场景:关 itn / 标点 / 顺滑;result_type=full(partial 全量,直接替换)。
        private func requestJson() -> Data {
            var request: [String: Any] = [
                "model_name": "bigmodel",
                "enable_itn": false,
                "enable_punc": false,
                "enable_ddc": false,
                "result_type": "full",
            ]
            // 热词:corpus.context 是「字符串里嵌 JSON」(豆包文档的怪点),空则整个 corpus 不发。
            let words = Hotwords.cap(hotwords)
            if !words.isEmpty {
                NSLog("[VolcAsr] hotwords sent: \(words.count)/\(hotwords.count) (cap=200chars)")  // 只打数量
                let inner: [String: Any] = ["hotwords": words.map { ["word": $0] }]
                if let ctxData = try? JSONSerialization.data(withJSONObject: inner, options: []),
                   let ctx = String(data: ctxData, encoding: .utf8) {
                    request["corpus"] = ["context": ctx]
                }
            }
            let root: [String: Any] = [
                "user": ["uid": "xreal-client"],
                "audio": ["format": "pcm", "codec": "raw", "rate": 16000, "bits": 16, "channel": 1],
                "request": request,
            ]
            return (try? JSONSerialization.data(withJSONObject: root, options: [])) ?? Data("{}".utf8)
        }

        private func extractText(_ json: String) -> String {
            guard let data = json.data(using: .utf8),
                  let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let result = o["result"] as? [String: Any] else { return "" }
            return (result["text"] as? String) ?? ""
        }

        static let endpoint = URL(string: "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async")!
        static let finalTimeout: TimeInterval = 8.0
    }
}
