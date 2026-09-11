import SwiftUI

@main
struct LongToShortApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 520, minHeight: 420)
        }
        .windowResizability(.contentSize)

        Settings {
            SettingsView()
                .frame(width: 420)
        }
    }
}
