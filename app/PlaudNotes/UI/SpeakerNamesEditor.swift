import SwiftUI

/// 為逐字稿中的說話者（speaker_0…）設定真實名稱。每位附上第一段發言，方便辨認是誰。
struct SpeakerNamesEditor: View {
    @Environment(\.dismiss) private var dismiss
    let transcript: Transcript
    let onSave: ([String: String]) -> Void

    @State private var names: [String: String] = [:]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("名稱只存在這台裝置。沒填的說話者會以原始代號顯示，筆記不會自行推測是誰。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(transcript.speakers, id: \.self) { sp in
                    Section {
                        TextField("名稱（例如：王經理）", text: binding(sp))
                        if let first = Self.sample(of: sp, in: transcript) {
                            Text(first).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                        }
                    } header: {
                        Text("\(sp)．\(Self.count(of: sp, in: transcript)) 段")
                    }
                }
            }
            .navigationTitle("說話者名稱")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("儲存") {
                        onSave(Self.cleaned(names))
                        dismiss()
                    }
                }
            }
            .onAppear { names = transcript.speakerNames ?? [:] }
        }
    }

    private func binding(_ sp: String) -> Binding<String> {
        Binding(get: { names[sp] ?? "" }, set: { names[sp] = $0 })
    }

    /// 去掉空白名稱
    static func cleaned(_ names: [String: String]) -> [String: String] {
        names.compactMapValues { v in
            let s = v.trimmingCharacters(in: .whitespacesAndNewlines)
            return s.isEmpty ? nil : s
        }
    }

    static func count(of sp: String, in t: Transcript) -> Int {
        t.segments.filter { $0.speaker == sp }.count
    }

    /// 該說話者第一段較長（至少 20 字）的發言，找不到就用第一段
    static func sample(of sp: String, in t: Transcript) -> String? {
        let segs = t.segments.filter { $0.speaker == sp }
        let s = segs.first(where: { $0.text.count >= 20 }) ?? segs.first
        return s.map { "[\(TranscriptExporter.timestamp($0.start))] \($0.text.trimmingCharacters(in: .whitespaces))" }
    }
}
