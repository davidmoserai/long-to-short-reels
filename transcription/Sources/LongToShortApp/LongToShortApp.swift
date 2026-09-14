import SwiftUI

@main
struct LongToShortApp: App {
    @StateObject private var apiKeyStatus = APIKeyStatus()

    var body: some Scene {
        WindowGroup {
            Group {
                if apiKeyStatus.hasKey {
                    ContentView()
                } else {
                    APIKeyOnboardingView()
                }
            }
            .frame(minWidth: 520, minHeight: 420)
            .environmentObject(apiKeyStatus)
        }
        .windowResizability(.contentSize)

        Settings {
            SettingsView()
                .frame(width: 420)
                .environmentObject(apiKeyStatus)
        }
    }
}
