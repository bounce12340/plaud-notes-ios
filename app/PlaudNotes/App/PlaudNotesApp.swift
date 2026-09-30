import SwiftUI

@main
struct PlaudNotesApp: App {
    @State private var library = RecordingLibrary()
    @State private var settings = AppSettings()
    @State private var templates = TemplateStore()
    @State private var glossary = GlossaryStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(library)
                .environment(settings)
                .environment(templates)
                .environment(glossary)
        }
    }
}
