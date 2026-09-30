import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(RecordingLibrary.self) private var library
    @State private var recorder = Recorder()
    @State private var showImporter = false
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            List {
                RecorderSection(recorder: recorder)
                Section("錄音") {
                    if library.items.isEmpty {
                        Text("尚無錄音。可以直接錄音，或從「檔案」匯入。")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(library.items) { item in
                        NavigationLink(value: item) {
                            VStack(alignment: .leading) {
                                Text(item.title)
                                Text(item.createdAt, style: .date)
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .onDelete { idx in idx.map { library.items[$0] }.forEach(library.delete) }
                }
            }
            .navigationTitle("Plaud Notes")
            .navigationDestination(for: RecordingItem.self) { RecordingDetailView(item: $0) }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("設定", systemImage: "gear") { showSettings = true }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("匯入", systemImage: "square.and.arrow.down") { showImporter = true }
                }
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.audio],
                          allowsMultipleSelection: true) { result in
                if case .success(let urls) = result { urls.forEach(library.importFile) }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .alert("錯誤", isPresented: .constant(library.lastError != nil || recorder.lastError != nil)) {
                Button("好") { library.lastError = nil; recorder.lastError = nil }
            } message: {
                Text(library.lastError ?? recorder.lastError ?? "")
            }
        }
    }
}

private struct RecorderSection: View {
    @Environment(RecordingLibrary.self) private var library
    let recorder: Recorder

    var body: some View {
        Section("錄音機") {
            HStack {
                Text(Duration.seconds(recorder.elapsed),
                     format: .time(pattern: .hourMinuteSecond))
                    .font(.title2.monospacedDigit())
                Spacer()
                switch recorder.state {
                case .idle:
                    Button("開始", systemImage: "record.circle") { Task { await recorder.start() } }
                        .tint(.red)
                case .recording:
                    Button("暫停", systemImage: "pause.circle") { recorder.pause() }
                    Button("停止", systemImage: "stop.circle") { stop() }
                case .paused:
                    Button("繼續", systemImage: "play.circle") { recorder.resume() }
                    Button("停止", systemImage: "stop.circle") { stop() }
                }
            }
            .buttonStyle(.bordered)
        }
    }

    private func stop() {
        if let item = recorder.stop() { library.add(item) }
    }
}

struct RecordingDetailView: View {
    @Environment(RecordingLibrary.self) private var library
    let item: RecordingItem
    @State private var language = "auto"
    @State private var transcript: Transcript?
    @State private var working = false
    @State private var error: String?

    var body: some View {
        List {
            Section("轉錄（ElevenLabs）") {
                Picker("語言", selection: $language) {
                    Text("自動偵測").tag("auto")
                    Text("中文").tag("zh")
                    Text("英文").tag("en")
                    Text("日文").tag("ja")
                    Text("韓文").tag("ko")
                }
                Button(working ? "轉錄中…" : "開始轉錄") { Task { await run() } }
                    .disabled(working)
                Text("音檔會上傳到 ElevenLabs。").font(.caption).foregroundStyle(.secondary)
                if let error { Text(error).foregroundStyle(.red) }
            }
            if let transcript {
                Section("逐字稿") {
                    ForEach(Array(transcript.segments.enumerated()), id: \.offset) { _, s in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(TranscriptExporter.timestamp(s.start)) \(s.speaker ?? "")")
                                .font(.caption).foregroundStyle(.secondary)
                            Text(s.text)
                        }
                    }
                }
                Section {
                    ShareLink(item: TranscriptExporter.markdown(title: item.title, transcript: transcript),
                              preview: SharePreview("\(item.title).md"))
                }
            }
        }
        .navigationTitle(item.title)
    }

    private func run() async {
        guard let key = KeychainStore.get("elevenlabs"), !key.isEmpty else {
            error = ProviderError.missingAPIKey.localizedDescription; return
        }
        working = true; error = nil
        defer { working = false }
        do {
            let provider = ElevenLabsProvider(apiKey: key)
            transcript = try await provider.transcribe(
                fileURL: library.url(for: item),
                options: TranscriptionOptions(languageCode: language == "auto" ? nil : language))
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var elevenKey = ""
    @State private var saved = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("ElevenLabs API key", text: $elevenKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: { Text("轉錄服務") } footer: {
                    Text("API key 只存在這台裝置的鑰匙圈，不會同步或寫入檔案。")
                }
                Button("儲存") {
                    try? KeychainStore.set(elevenKey, for: "elevenlabs")
                    saved = true
                }
                if saved { Text("已儲存").foregroundStyle(.secondary) }
            }
            .navigationTitle("設定")
            .toolbar { Button("完成") { dismiss() } }
            .onAppear { elevenKey = KeychainStore.get("elevenlabs") ?? "" }
        }
    }
}
