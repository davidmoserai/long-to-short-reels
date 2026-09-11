import SwiftUI
import LongToShortCore

struct SettingsView: View {
    @EnvironmentObject private var apiKeyStatus: APIKeyStatus
    @State private var apiKey: String = ""
    @State private var saved = false

    var body: some View {
        Form {
            Section {
                SecureField("sk-ant-...", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                Text("Get your own key at [console.anthropic.com](https://console.anthropic.com) — stored only in your Mac's Keychain, never sent anywhere except Anthropic's API.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("Save") {
                    KeychainStore.saveAPIKey(apiKey)
                    apiKeyStatus.refresh()
                    saved = true
                }
                .disabled(apiKey.trimmingCharacters(in: .whitespaces).isEmpty)

                if saved {
                    Text("Saved ✓").foregroundStyle(.green)
                }
            }
        }
        .padding(20)
        .onAppear {
            apiKey = KeychainStore.loadAPIKey() ?? ""
        }
    }
}
