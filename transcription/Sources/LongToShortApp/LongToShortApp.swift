import SwiftUI
import Sparkle

@main
struct LongToShortApp: App {
    @StateObject private var apiKeyStatus = APIKeyStatus()
    private let updaterController: SPUStandardUpdaterController

    init() {
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

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

        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    updaterController.checkForUpdates(nil)
                }
            }
        }
    }
}
