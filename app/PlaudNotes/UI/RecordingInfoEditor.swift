import SwiftUI

/// 修改錄音時間與備註。語音備忘錄分享出來的檔案，自動讀到的時間可能是「分享時間」而非「錄音時間」。
struct RecordingInfoEditor: View {
    @Environment(\.dismiss) private var dismiss
    let item: RecordingItem
    let onSave: (Date, String) -> Void
    let onReset: () -> Void

    @State private var date = Date()
    @State private var remark = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("錄音時間", selection: $date)
                } footer: {
                    Text(item.source == .recorded
                         ? "App 內錄音會自動記錄開始時間。"
                         : item.recordedAtIsDateOnly == true
                         ? "日期取自檔名（Plaud Web 匯出檔以當天行事曆命名），時刻未知；可在此補上實際時間。"
                         : "匯入的檔案會自動讀取檔案內記錄的時間；從語音備忘錄分享出來的檔案，這個時間可能是分享時間，請依實際情況修改。")
                }
                Section {
                    TextField("例如：實際錄音為 9/29 下午，地點台北辦公室", text: $remark, axis: .vertical)
                        .lineLimit(2...6)
                } header: { Text("備註") } footer: {
                    Text("備註會提供給筆記整理當背景資訊（可在範本中用 {{remark}} 放到指定位置）。")
                }
                if item.recordedAtIsManual == true {
                    Section {
                        Button("改回自動偵測的時間", role: .destructive) {
                            onReset()
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle("錄音資訊")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("儲存") {
                        onSave(date, remark.trimmingCharacters(in: .whitespacesAndNewlines))
                        dismiss()
                    }
                }
            }
            .onAppear {
                date = item.noteDate
                remark = item.remark ?? ""
            }
        }
    }
}
