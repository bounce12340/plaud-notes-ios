import SwiftUI

struct GlossaryEditor: View {
    @Environment(GlossaryStore.self) private var store
    @State private var message: String?

    var body: some View {
        @Bindable var store = store
        Form {
            Section {
                TextEditor(text: $store.text)
                    .frame(minHeight: 300)
                    .font(.body.monospaced())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text("一行一個詞（已解析 \(store.entries.count) 個）")
            } footer: {
                Text("""
                範例：
                Etihad
                C2 Pharma
                Syrenjit, Serenjit => Serengit
                「=>」左邊是常見的錯誤寫法（可用逗號分隔多個），右邊是正確寫法，轉錄後會自動更正。
                詞庫會用在：轉錄（ElevenLabs keyterms，另收 20% 轉錄費；含 < > { } [ ] \\、超過 5 個字或 50 字元的詞不送）、轉錄後更正、筆記整理。
                """)
            }
            Section {
                ForEach(GlossaryPresets.all) { preset in
                    Button {
                        let r = GlossaryPresets.merge(preset, into: store.text)
                        store.text = r.text
                        message = r.added == 0 ? "「\(preset.name)」的詞都已在詞庫中" : "已加入 \(r.added) 個詞"
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("加入「\(preset.name)」")
                            Text(preset.summary).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("預設詞庫")
            } footer: {
                Text(message ?? "加入後可自行刪改。產品名、人名等公司專屬名詞請自行補上。")
            }
        }
        .navigationTitle("專有名詞詞庫")
    }
}
