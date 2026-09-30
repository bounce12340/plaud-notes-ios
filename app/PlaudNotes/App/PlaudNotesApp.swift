import SwiftUI

@main
struct PlaudNotesApp: App {
    @State private var library = RecordingLibrary()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(library)
        }
    }
}
