import Foundation
import LongToShortCore

/// Shared, observable view of whether an Anthropic API key is currently saved.
/// SettingsView calls `refresh()` after saving; ContentView observes `hasKey`
/// so the warning banner updates immediately across windows, instead of only
/// re-checking the Keychain on its own next unrelated re-render.
@MainActor
final class APIKeyStatus: ObservableObject {
    @Published private(set) var hasKey: Bool

    init() {
        hasKey = KeychainStore.loadAPIKey() != nil
    }

    func refresh() {
        hasKey = KeychainStore.loadAPIKey() != nil
    }
}
