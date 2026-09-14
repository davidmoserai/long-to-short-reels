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
            .frame(minWidth: 960, minHeight: 640)
            .environmentObject(apiKeyStatus)
        }
        .defaultSize(width: 1200, height: 800)
        .windowResizability(.automatic)

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
