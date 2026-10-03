import SwiftUI

struct RecordingDetailView: View {
    @Environment(RecordingLibrary.self) private var library
    @Environment(AppSettings.self) private var settings
    @Environment(TemplateStore.self) private var templates
    @Environment(GlossaryStore.self) private var glossary
    let item: RecordingItem

    private enum Tab: String, CaseIterable { case transcript = "逐字稿", notes = "筆記" }

    @State private var tab: Tab = .transcript
    @State private var language = "auto"
    @State private var transcript: Transcript?
    @State private var notes: String?
    @State private var templateID: UUID?
    @State private var noteLanguage: NoteLanguage = .zhTW
    @State private var busy: String?
    @State private var error: String?
    @State private var confirmUpload = false
    @State private var confirmLLM = false
    @State private var editingSpeakers = false
    @State private var editingInfo = false
    @State private var renaming = false
    @State private var newTitle = ""
    @State private var titleSuggestion: String?
    @State private var confirmTitle = false
    /// 串流中的筆記（產生完成後清掉，改顯示存好的 notes）
    @State private var streamingNotes: String?

    /// 清單中最新的資料（手動改日期／備註後會更新）
    private var current: RecordingItem { library.item(id: item.id) ?? item }

    var body: some View {
        List {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .listRowBackground(Color.clear)

            if let busy {
                HStack { ProgressView(); Text(busy) }
            }
            if let error {
                Text(error).foregroundStyle(.red)
            }

            switch tab {
            case .transcript: transcriptSections
            case .notes: notesSections
            }
        }
        .navigationTitle(current.title)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("重新命名", systemImage: "pencil") {
                    newTitle = current.title
                    renaming = true
                }
            }
        }
        .alert("重新命名", isPresented: $renaming) {
            TextField("標題", text: $newTitle)
            Button("取消", role: .cancel) {}
            Button("儲存") { library.rename(id: item.id, title: newTitle) }
        }
        .onAppear(perform: loadSaved)
        .confirmationDialog("音檔會上傳到 ElevenLabs 進行轉錄。", isPresented: $confirmUpload,
                            titleVisibility: .visible) {
            Button("上傳並轉錄") { Task { await transcribe() } }
        }
        .sheet(isPresented: $editingInfo) {
            RecordingInfoEditor(item: current) { date, remark in
                library.updateInfo(id: item.id, recordedAt: date, remark: remark)
            } onReset: {
                library.resetRecordedAt(id: item.id)
            }
        }
        .sheet(isPresented: $editingSpeakers) {
            if let t = transcript {
                SpeakerNamesEditor(transcript: t) { names in
                    var updated = t
                    updated.speakerNames = names
                    transcript = updated
                    library.saveTranscript(updated, for: item)
                }
            }
        }
        .confirmationDialog("逐字稿會傳送到 \(settings.llm.host)（\(settings.llm.model)）整理成筆記，並依筆記建議標題。",
                            isPresented: $confirmLLM, titleVisibility: .visible) {
            Button("傳送並產生筆記") { Task { await generateNotes() } }
        }
        .confirmationDialog("筆記內容會傳送到 \(settings.llm.host)（\(settings.llm.model)）產生標題建議。",
                            isPresented: $confirmTitle, titleVisibility: .visible) {
            Button("傳送並建議標題") {
                Task { if let notes { await suggestTitle(from: TitleSuggester.stripNotesFooter(notes)) } }
            }
        }
    }

    // MARK: - 逐字稿

    @ViewBuilder private var transcriptSections: some View {
        Section("轉錄（ElevenLabs）") {
            Picker("語言", selection: $language) {
                Text("自動偵測").tag("auto")
                Text("中文").tag("zh")
                Text("英文").tag("en")
                Text("日文").tag("ja")
                Text("韓文").tag("ko")
            }
            Button(transcript == nil ? "開始轉錄" : "重新轉錄") { confirmUpload = true }
                .disabled(busy != nil)
            if !glossary.entries.isEmpty {
                Text("會使用詞庫中的 \(glossary.entries.count) 個專有名詞（ElevenLabs 另收 20% 轉錄費）")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        if let transcript {
            Section {
                if !transcript.speakers.isEmpty {
                    Button("說話者名稱（\(transcript.speakers.count) 位）") { editingSpeakers = true }
                }
                if let mode = settings.chineseConversion.mode {
                    Button("重新套用簡→繁（\(mode.rawValue)）") { reconvert(mode) }
                        .disabled(busy != nil)
                }
                let md = TranscriptExporter.markdown(title: current.title, transcript: transcript)
                ShareLink("分享 Markdown", item: md, preview: SharePreview("\(current.title)-逐字稿.md"))
                ShareLink("分享 Word（.docx）",
                          item: DocxFile(fileName: DocxFile.safeFileName("\(current.title)-逐字稿.docx"),
                                         title: current.title, markdown: md),
                          preview: SharePreview("\(current.title)-逐字稿.docx"))
            } footer: {
                Text("引擎：\(transcript.engine)．語言：\(transcript.languageCode ?? "未知")．後處理：\(transcript.postProcessing ?? "無")")
            }
            Section("逐字稿") {
                ForEach(Array(transcript.segments.enumerated()), id: \.offset) { _, s in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(TranscriptExporter.timestamp(s.start)) \(transcript.displayName(s.speaker) ?? "")")
                            .font(.caption).foregroundStyle(.secondary)
                        Text(s.text).textSelection(.enabled)
                    }
                }
            }
        }
    }

    // MARK: - 筆記

    @ViewBuilder private var notesSections: some View {
        Section("產生筆記") {
            Picker("範本", selection: Binding(get: { templateID ?? settings.defaultTemplateID },
                                            set: { templateID = $0 })) {
                ForEach(templates.all) { Text($0.name).tag($0.id) }
            }
            if let t = transcript, let s = TemplateSuggester.suggest(for: t),
               let suggested = NoteTemplate.builtIn(named: s.templateName) {
                let selected = templateID ?? settings.defaultTemplateID
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("建議範本：\(s.templateName)").font(.subheadline)
                        Spacer()
                        if selected == suggested.id {
                            Text("已選用").font(.caption).foregroundStyle(.secondary)
                        } else {
                            Button("套用") { templateID = suggested.id }
                                .buttonStyle(.bordered)
                        }
                    }
                    Text(s.reason + "（依說話比例與用詞推測，可自行更改）")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Picker("輸出語言", selection: $noteLanguage) {
                ForEach(NoteLanguage.allCases) { Text($0.rawValue).tag($0) }
            }
            Button {
                editingInfo = true
            } label: {
                LabeledContent("錄音時間", value: current.noteDateText
                               + (current.recordedAtIsManual == true ? "（手動）" : ""))
            }
            if let remark = current.trimmedRemark {
                LabeledContent("備註", value: remark)
            }
            LabeledContent("模型", value: settings.llm.model.isEmpty ? "未設定" : "\(settings.llm.model)（\(settings.llm.host)）")
            Button(notes == nil ? "產生筆記" : "重新產生") { confirmLLM = true }
                .disabled(transcript == nil || busy != nil)
            if transcript == nil {
                Text("請先完成轉錄。").font(.caption).foregroundStyle(.secondary)
            } else if let t = transcript, t.speakers.contains(where: { t.displayName($0) == $0 }) {
                Text("建議先到「逐字稿」設定說話者名稱，筆記才能寫出正確的負責人。")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        if let streamingNotes {
            Section("筆記（產生中…）") {
                Text(Self.renderMarkdown(streamingNotes))
                    .textSelection(.enabled)
            }
        }
        if let suggestion = titleSuggestion {
            Section {
                Text(suggestion).font(.headline)
                HStack {
                    Button("套用") { applyTitle(suggestion) }
                        .buttonStyle(.borderedProminent)
                    Button("略過") { titleSuggestion = nil }
                        .buttonStyle(.bordered)
                }
            } header: {
                Text("AI 建議標題")
            } footer: {
                Text("目前標題：\(current.title)。套用後，原檔名會記在備註；筆記內的標題要重新產生筆記才會更新。")
            }
        }
        if let notes, streamingNotes == nil {
            Section {
                ShareLink("分享 Markdown", item: notes, preview: SharePreview("\(current.title)-筆記.md"))
                ShareLink("分享 Word（.docx）",
                          item: DocxFile(fileName: DocxFile.safeFileName("\(current.title)-筆記.docx"),
                                         title: current.title, markdown: notes),
                          preview: SharePreview("\(current.title)-筆記.docx"))
                if titleSuggestion == nil {
                    Button("請 AI 建議標題") { confirmTitle = true }
                        .disabled(busy != nil)
                }
            }
            Section("筆記") {
                Text(Self.renderMarkdown(notes))
                    .textSelection(.enabled)
            }
        }
    }

    /// 只解析粗體、連結等行內語法並保留換行；標題符號會原樣顯示（完整排版請分享 .docx 或 .md 檔）。
    private static func renderMarkdown(_ md: String) -> AttributedString {
        (try? AttributedString(markdown: md, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(md)
    }

    // MARK: - 動作

    private func loadSaved() {
        transcript = library.loadTranscript(for: item)
        notes = library.loadNotes(for: item)
        noteLanguage = settings.noteLanguage
    }

    private func transcribe() async {
        guard let key = KeychainStore.get("elevenlabs"), !key.isEmpty else {
            error = ProviderError.missingAPIKey.localizedDescription; return
        }
        busy = "轉錄中…"; error = nil
        defer { busy = nil }
        do {
            let provider = ElevenLabsProvider(apiKey: key)
            var t = try await provider.transcribe(
                fileURL: library.url(for: item),
                options: TranscriptionOptions(languageCode: language == "auto" ? nil : language,
                                              keyterms: glossary.entries.map(\.term)))
            t = Glossary.apply(to: t, entries: glossary.entries)
            // 重新轉錄時保留已設定的說話者名稱
            t.speakerNames = transcript?.speakerNames
            if let mode = settings.chineseConversion.mode {
                busy = "簡→繁轉換中…"
                t = await Self.convert(t, mode: mode)
                // 轉換後再套一次更正：詞庫用繁體寫的錯誤寫法，要等轉成繁體後才比對得到
                t = Glossary.apply(to: t, entries: glossary.entries)
            }
            transcript = t
            library.saveTranscript(t, for: item)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func reconvert(_ mode: ChineseConverter.Mode) {
        guard let t = transcript else { return }
        busy = "簡→繁轉換中…"
        let entries = glossary.entries
        Task {
            let converted = Glossary.apply(to: await Self.convert(t, mode: mode), entries: entries)
            transcript = converted
            library.saveTranscript(converted, for: item)
            busy = nil
        }
    }

    /// 字典載入與轉換都在背景執行，避免卡住畫面。
    nonisolated private static func convert(_ t: Transcript, mode: ChineseConverter.Mode) async -> Transcript {
        let converter = await ChineseConverterCache.shared.converter(mode)
        return await Task.detached(priority: .userInitiated) {
            TranscriptPostProcessor.process(t, with: converter)
        }.value
    }

    private func generateNotes() async {
        guard let transcript else { return }
        let tid = templateID ?? settings.defaultTemplateID
        guard let template = templates.template(id: tid) else { error = "找不到範本"; return }
        busy = "產生筆記中…"; error = nil
        defer { busy = nil; streamingNotes = nil }
        do {
            let config = settings.llm
            let client = try LLMClientFactory.make(config: config,
                                                   apiKey: KeychainStore.get(config.keychainAccount))
            let generator = NoteGenerator(client: client, maxInputCharacters: config.maxInputCharacters)
            let outLang = noteLanguage == .sameAsSource ? "與逐字稿相同的語言" : noteLanguage.rawValue
            let info = current
            let result = try await generator.generate(.init(title: info.title, date: info.noteDate,
                                                            transcript: transcript, template: template,
                                                            outputLanguage: outLang,
                                                            glossary: glossary.entries.map(\.term),
                                                            remark: info.trimmedRemark)) { progress in
                switch progress {
                case .summarizing(let done, let total):
                    busy = done < total ? "分段整理中（\(done + 1)/\(total)）…" : "合併各段重點…"
                case .thinking:
                    busy = "模型思考中…"
                case .writing(let text):
                    busy = "筆記產生中（\(text.count) 字）…"
                    streamingNotes = text
                }
            }
            var md = result.markdown
            // 中文輸出再過一次簡→繁，避免模型混入簡體字
            if noteLanguage == .zhTW, let mode = settings.chineseConversion.mode,
               let conv = await ChineseConverterCache.shared.converter(mode) {
                let raw = md
                md = await Task.detached { conv.convertWithFixups(raw) }.value
            }
            let footer = "\n\n---\n由 \(config.model)（\(config.host)）依範本「\(template.name)」產生；逐字稿分 \(result.chunkCount) 段處理。內容可能有誤，請對照原音確認。\n"
            notes = md + footer
            streamingNotes = nil
            library.saveNotes(md + footer, for: item)
        } catch {
            self.error = error.localizedDescription
            return
        }
        // 同一個供應商順便依筆記建議標題（Plaud 檔名取自行事曆，常與內容不符）；確認對話框已說明
        if let notes { await suggestTitle(from: TitleSuggester.stripNotesFooter(notes)) }
    }

    private func suggestTitle(from content: String) async {
        busy = "建議標題中…"
        defer { busy = nil }
        do {
            let config = settings.llm
            let client = try LLMClientFactory.make(config: config,
                                                   apiKey: KeychainStore.get(config.keychainAccount))
            let outLang = noteLanguage == .sameAsSource ? "與內容相同的語言" : noteLanguage.rawValue
            guard var title = try await TitleSuggester(client: client)
                .suggest(content: content, currentTitle: current.title, outputLanguage: outLang) else { return }
            if noteLanguage == .zhTW, let mode = settings.chineseConversion.mode,
               let conv = await ChineseConverterCache.shared.converter(mode) {
                let raw = title
                title = await Task.detached { conv.convertWithFixups(raw) }.value
            }
            titleSuggestion = title == current.title ? nil : title
        } catch {
            self.error = "標題建議失敗：\(error.localizedDescription)"
        }
    }

    /// 套用建議標題；原檔名（行事曆事件）記到備註，之後整理筆記時仍可當背景資訊
    private func applyTitle(_ title: String) {
        let info = current
        if let original = info.sourceFileName, original != title,
           !(info.remark ?? "").contains(original) {
            let line = "原檔名（行事曆）：\(original)"
            library.setRemark(id: item.id, remark: [info.trimmedRemark, line].compactMap { $0 }.joined(separator: "\n"))
        }
        library.rename(id: item.id, title: title)
        titleSuggestion = nil
    }
}
