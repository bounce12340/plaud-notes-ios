import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppSettings.self) private var settings
    @Environment(TemplateStore.self) private var templates

    @State private var elevenKey = ""
    @State private var llmKey = ""
    @State private var message: String?
    @State private var testing = false

    var body: some View {
        @Bindable var settings = settings
        NavigationStack {
            Form {
                Section {
                    SecureField("ElevenLabs API key", text: $elevenKey)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                } header: { Text("轉錄服務") }

                Section {
                    Picker("逐字稿中文", selection: $settings.chineseConversion) {
                        ForEach(ChineseConversionSetting.allCases) { Text($0.label).tag($0) }
                    }
                } header: { Text("簡→繁") } footer: {
                    Text("使用 OpenCC 字典在手機上轉換，不需網路。含日文假名或韓文的段落不轉換。「台灣用語」會把「文件」改成「檔案」，會議內容可能誤轉。")
                }

                Section {
                    Picker("供應商", selection: Binding(
                        get: { settings.llm.presetID },
                        set: { id in
                            if let p = LLMPreset.find(id) { settings.selectPreset(p); llmKey = KeychainStore.get(settings.llm.keychainAccount) ?? "" }
                        })) {
                        ForEach(LLMPreset.all) { Text($0.name).tag($0.id) }
                    }
                    TextField("服務網址（Base URL）", text: $settings.llm.baseURL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    TextField("模型名稱", text: $settings.llm.model)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("API key", text: $llmKey)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Stepper("單次送出上限：\(settings.llm.maxInputCharacters / 1000)k 字",
                            value: $settings.llm.maxInputCharacters, in: 4_000...600_000, step: 4_000)
                    Button(testing ? "測試中…" : "測試連線") { Task { await testLLM() } }
                        .disabled(testing)
                } header: { Text("筆記 LLM") } footer: {
                    Text("\(LLMPreset.find(settings.llm.presetID)?.note ?? "")\n逐字稿超過上限時會分段整理再合併。")
                }

                Section("筆記") {
                    Picker("預設範本", selection: $settings.defaultTemplateID) {
                        ForEach(templates.all) { Text($0.name).tag($0.id) }
                    }
                    Picker("預設輸出語言", selection: $settings.noteLanguage) {
                        ForEach(NoteLanguage.allCases) { Text($0.rawValue).tag($0) }
                    }
                    NavigationLink("管理範本") { TemplateListView() }
                    NavigationLink("專有名詞詞庫") { GlossaryEditor() }
                }

                Section {
                    Button("儲存 API key") { saveKeys() }
                    if let message { Text(message).foregroundStyle(.secondary) }
                } footer: {
                    Text("API key 只存在這台裝置的鑰匙圈，不會同步或寫入檔案。")
                }

                Section("開源授權") {
                    NavigationLink("OpenCC（Apache-2.0）") { LicenseView(resource: "OpenCC-LICENSE") }
                }
            }
            .navigationTitle("設定")
            .toolbar { Button("完成") { saveKeys(); dismiss() } }
            .onAppear {
                elevenKey = KeychainStore.get("elevenlabs") ?? ""
                llmKey = KeychainStore.get(settings.llm.keychainAccount) ?? ""
            }
        }
    }

    private func saveKeys() {
        do {
            try KeychainStore.set(elevenKey, for: "elevenlabs")
            try KeychainStore.set(llmKey, for: settings.llm.keychainAccount)
            message = "已儲存"
        } catch {
            message = error.localizedDescription
        }
    }

    private func testLLM() async {
        saveKeys()
        testing = true
        defer { testing = false }
        do {
            let client = try LLMClientFactory.make(config: settings.llm, apiKey: llmKey)
            let reply = try await client.complete([ChatMessage(role: .user, content: "請只回覆 OK")])
            message = "連線成功：\(reply.prefix(40))"
        } catch {
            message = "連線失敗：\(error.localizedDescription)"
        }
    }
}

struct LicenseView: View {
    let resource: String

    var body: some View {
        ScrollView {
            Text(text).font(.footnote.monospaced()).padding()
        }
        .navigationTitle("授權")
    }

    private var text: String {
        let url = Bundle.main.url(forResource: resource, withExtension: "txt", subdirectory: "OpenCC")
            ?? Bundle.main.url(forResource: resource, withExtension: "txt")
        return url.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "找不到授權檔"
    }
}
