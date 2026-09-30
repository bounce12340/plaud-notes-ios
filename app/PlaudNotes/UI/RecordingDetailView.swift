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
        .navigationTitle(item.title)
        .onAppear(perform: loadSaved)
        .confirmationDialog("音檔會上傳到 ElevenLabs 進行轉錄。", isPresented: $confirmUpload,
                            titleVisibility: .visible) {
            Button("上傳並轉錄") { Task { await transcribe() } }
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
        .confirmationDialog("逐字稿會傳送到 \(settings.llm.host)（\(settings.llm.model)）整理成筆記。",
                            isPresented: $confirmLLM, titleVisibility: .visible) {
            Button("傳送並產生筆記") { Task { await generateNotes() } }
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
                ShareLink(item: TranscriptExporter.markdown(title: item.title, transcript: transcript),
                          preview: SharePreview("\(item.title)-逐字稿.md"))
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
            Picker("輸出語言", selection: $noteLanguage) {
                ForEach(NoteLanguage.allCases) { Text($0.rawValue).tag($0) }
            }
            LabeledContent("錄音日期", value: item.noteDate.formatted(date: .abbreviated, time: .shortened))
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
        if let notes {
            Section {
                ShareLink(item: notes, preview: SharePreview("\(item.title)-筆記.md"))
            }
            Section("筆記") {
                Text(Self.renderMarkdown(notes))
                    .textSelection(.enabled)
            }
        }
    }

    /// 只解析粗體、連結等行內語法並保留換行；標題符號會原樣顯示（完整排版請分享 .md 檔）。
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
        Task {
            let converted = await Self.convert(t, mode: mode)
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
        defer { busy = nil }
        do {
            let config = settings.llm
            let client = try LLMClientFactory.make(config: config,
                                                   apiKey: KeychainStore.get(config.keychainAccount))
            let generator = NoteGenerator(client: client, maxInputCharacters: config.maxInputCharacters)
            let outLang = noteLanguage == .sameAsSource ? "與逐字稿相同的語言" : noteLanguage.rawValue
            let result = try await generator.generate(.init(title: item.title, date: item.noteDate,
                                                            transcript: transcript, template: template,
                                                            outputLanguage: outLang,
                                                            glossary: glossary.entries.map(\.term)))
            var md = result.markdown
            // 中文輸出再過一次簡→繁，避免模型混入簡體字
            if noteLanguage == .zhTW, let mode = settings.chineseConversion.mode,
               let conv = await ChineseConverterCache.shared.converter(mode) {
                let raw = md
                md = await Task.detached { conv.convert(raw) }.value
            }
            let footer = "\n\n---\n由 \(config.model)（\(config.host)）依範本「\(template.name)」產生；逐字稿分 \(result.chunkCount) 段處理。內容可能有誤，請對照原音確認。\n"
            notes = md + footer
            library.saveNotes(md + footer, for: item)
        } catch {
            self.error = error.localizedDescription
        }
    }
}
