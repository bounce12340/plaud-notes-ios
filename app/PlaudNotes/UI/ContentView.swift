import SwiftUI

struct ContentView: View {
    @Environment(RecordingLibrary.self) private var library
    @Environment(Recorder.self) private var recorder
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
                                Text(item.noteDate, style: .date)
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
                case .paused, .interrupted:
                    Button("繼續", systemImage: "play.circle") { recorder.resume() }
                    Button("停止", systemImage: "stop.circle") { stop() }
                }
            }
            .buttonStyle(.bordered)
            if let notice = recorder.notice {
                Text(notice).font(.caption).foregroundStyle(.orange)
            } else if recorder.state == .recording {
                Text("可以關閉螢幕或切到其他 App，錄音會繼續。不要從多工畫面滑掉 App。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func stop() {
        if let item = recorder.stop() { library.add(item) }
    }
}
