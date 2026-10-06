import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// 分享面板的「Plaud Notes」：把音檔複製到 App Group 收件匣，下次開啟 Plaud Notes 時匯入。
/// 不在這裡轉錄或上傳（Extension 的記憶體與執行時間都很有限）。
final class ShareViewController: UIViewController {
    private let model = ShareModel()

    override func viewDidLoad() {
        super.viewDidLoad()
        let host = UIHostingController(rootView: ShareView(model: model) { [weak self] in self?.finish() })
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)

        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? [])
            .flatMap { $0.attachments ?? [] }
            .filter { $0.hasItemConformingToTypeIdentifier(UTType.audio.identifier) }
        Task { await model.receive(providers) }
    }

    private func finish() {
        extensionContext?.completeRequest(returningItems: nil)
    }
}

@MainActor
@Observable
final class ShareModel {
    enum Phase: Equatable { case working, done(Int), failed(String) }
    private(set) var phase: Phase = .working

    func receive(_ providers: [NSItemProvider]) async {
        guard let dir = SharedInbox.defaultDirectory else {
            phase = .failed("App Group 未設定，無法交給 Plaud Notes。請確認兩個 target 的 App Groups 設定相同。")
            return
        }
        guard !providers.isEmpty else {
            phase = .failed("沒有可匯入的音檔。")
            return
        }
        var count = 0
        var lastError: String?
        for provider in providers {
            do {
                try await Self.copy(provider, into: dir)
                count += 1
            } catch {
                lastError = error.localizedDescription
            }
        }
        phase = count > 0 ? .done(count) : .failed(lastError ?? "無法讀取音檔。")
    }

    /// 系統給的暫存檔只在 handler 內有效，必須在 handler 裡複製完
    private static func copy(_ provider: NSItemProvider, into dir: URL) async throws {
        let name = provider.suggestedName
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            _ = provider.loadFileRepresentation(forTypeIdentifier: UTType.audio.identifier) { url, error in
                guard let url else {
                    c.resume(throwing: error ?? CocoaError(.fileReadUnknown))
                    return
                }
                do {
                    try SharedInbox.add(fileAt: url, originalName: name, in: dir)
                    c.resume()
                } catch {
                    c.resume(throwing: error)
                }
            }
        }
    }
}

private struct ShareView: View {
    let model: ShareModel
    let close: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                switch model.phase {
                case .working:
                    ProgressView("加入 Plaud Notes…")
                case .done(let count):
                    Image(systemName: "checkmark.circle.fill").font(.largeTitle).foregroundStyle(.green)
                    Text("已加入 \(count) 個音檔").font(.headline)
                    Text("打開 Plaud Notes 後會出現在錄音清單，就可以轉錄。")
                        .multilineTextAlignment(.center).foregroundStyle(.secondary)
                case .failed(let message):
                    Image(systemName: "exclamationmark.triangle.fill").font(.largeTitle).foregroundStyle(.orange)
                    Text(message).multilineTextAlignment(.center)
                }
            }
            .padding()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成", action: close).disabled(model.phase == .working)
                }
            }
            .navigationTitle("Plaud Notes")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
