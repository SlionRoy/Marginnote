import SwiftUI

@main
struct StudyReaderApp: App {
    @StateObject private var session = StudySession()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(session)
        }
    }
}
