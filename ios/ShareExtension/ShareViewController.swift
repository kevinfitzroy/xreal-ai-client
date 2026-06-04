import UIKit
import UniformTypeIdentifiers

/// 「分享到 Agent Station」入口:接收语音备忘录等分享来的**音频附件**,当场拷进 App Group
/// 共享收件箱(`AudioInbox`),然后立即完成。**只负责「接收存起来」** —— 转码 / 选项目 / 上传
/// 全在主 app 里(此扩展刻意保持轻量:扩展内存配额紧,长音频转码放主 app 才稳)。
///
/// 无 compose UI:进来即存、存完即关,对用户几乎无感。principal class 用 @objc 固定运行时名,
/// 与 Info.plist 的 NSExtensionPrincipalClass 对应。
@objc(ShareViewController)
final class ShareViewController: UIViewController {

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        ingestFirstAudioAttachment()
    }

    private func ingestFirstAudioAttachment() {
        guard let item = extensionContext?.inputItems.first as? NSExtensionItem,
              let provider = item.attachments?.first(where: {
                  $0.hasItemConformingToTypeIdentifier(UTType.audio.identifier)
              }) else {
            finish(ok: false, note: "没有音频附件")
            return
        }

        provider.loadFileRepresentation(forTypeIdentifier: UTType.audio.identifier) { [weak self] url, error in
            guard let url else {
                self?.finish(ok: false, note: error?.localizedDescription ?? "读取分享文件失败")
                return
            }
            // 这个 url 只在本回调期内有效 —— 必须同步拷进共享容器再返回。
            var storedName: String?
            var failure: String?
            do {
                let dst = try AudioInbox.ingest(copyingFrom: url, suggestedName: url.lastPathComponent)
                storedName = dst.lastPathComponent
            } catch {
                failure = "\(error)"
            }
            DispatchQueue.main.async {
                self?.finish(ok: failure == nil, note: failure ?? storedName ?? "")
            }
        }
    }

    private func finish(ok: Bool, note: String) {
        NSLog("[ShareExtension] ingest ok=\(ok) note=\(note)")
        if ok {
            extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
        } else {
            extensionContext?.cancelRequest(withError: NSError(
                domain: "AgentStationShare", code: 1,
                userInfo: [NSLocalizedDescriptionKey: note]))
        }
    }
}
