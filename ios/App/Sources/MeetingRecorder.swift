import Foundation
import AVFoundation

/// app 内录音 —— `AVAudioRecorder` 直接把音频写进**本 app 沙箱**的 m4a 文件(**不进系统语音备忘录**;
/// Voice Memos 是另一个 app)。给 terminal 页「在当前 subproject 里录一段长语音 → 自动转译 → 默认委托
/// 给本 subproject」用,省掉跳到语音备忘录再分享回来这一圈。
///
/// 录 16k mono AAC(语音够用、体积小,长录音也不爆);下游 `MeetingPipeline` 照常转码 16k WAV + 分段识别。
/// 麦克风权限复用 app 已有的 `NSMicrophoneUsageDescription`(语音输入那条已申请)。
final class MeetingRecorder {

    private var recorder: AVAudioRecorder?
    private(set) var isRecording = false
    private(set) var fileURL: URL?

    /// 开始录音(写到 app temp 的 m4a)。返回 false = 启动失败(session / recorder)。权限由调用方先确保。
    @discardableResult
    func start() -> Bool {
        guard !isRecording else { return true }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .default, options: [])
            try session.setActive(true, options: [])
        } catch {
            NSLog("[MeetingRecorder] AVAudioSession setup failed: \(error.localizedDescription)")
            return false
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rec-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
        ]
        do {
            let r = try AVAudioRecorder(url: url, settings: settings)
            guard r.record() else {
                NSLog("[MeetingRecorder] record() returned false")
                try? session.setActive(false, options: [.notifyOthersOnDeactivation])
                return false
            }
            recorder = r; fileURL = url; isRecording = true
            NSLog("[MeetingRecorder] started → \(url.lastPathComponent)")
            return true
        } catch {
            NSLog("[MeetingRecorder] recorder init failed: \(error.localizedDescription)")
            try? session.setActive(false, options: [.notifyOthersOnDeactivation])
            return false
        }
    }

    /// 停止,返回录好的文件 URL(nil = 没在录)。
    @discardableResult
    func stop() -> URL? {
        guard isRecording, let r = recorder else { return nil }
        r.stop()
        isRecording = false; recorder = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        NSLog("[MeetingRecorder] stopped → \(fileURL?.lastPathComponent ?? "-")")
        return fileURL
    }

    /// 取消并删掉录音文件(中途离开终端等)。
    func cancel() {
        guard let r = recorder else { return }
        r.stop(); r.deleteRecording()
        isRecording = false; recorder = nil; fileURL = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }
}
