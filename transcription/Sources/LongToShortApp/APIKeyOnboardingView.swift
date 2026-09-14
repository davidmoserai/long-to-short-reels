import SwiftUI
import LongToShortCore

struct APIKeyOnboardingView: View {
    @EnvironmentObject private var apiKeyStatus: APIKeyStatus
    @State private var apiKey = ""

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "key.fill")
                .font(.system(size: 42))
                .foregroundStyle(Color.accentColor)

            Text("One quick setup")
                .font(.largeTitle.bold())

            Text("This app uses your own Anthropic account to find the best clips. Your key stays in your Mac's Keychain and is sent only to Anthropic.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 440)

            Link("Get an Anthropic API key", destination: URL(string: "https://console.anthropic.com/settings/keys")!)
                .buttonStyle(.bordered)

            VStack(alignment: .leading, spacing: 8) {
                Text("Paste your API key")
                    .font(.headline)
                SecureField("sk-ant-...", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
            }
            .frame(maxWidth: 440)

            Button("Save and continue") {
                KeychainStore.saveAPIKey(apiKey.trimmingCharacters(in: .whitespacesAndNewlines))
                apiKeyStatus.refresh()
            }
            .buttonStyle(.borderedProminent)
            .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(32)
    }
}
