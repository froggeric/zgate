import AppKit
import SwiftUI

struct GeneralTabView: View {
    @Environment(LoginItemService.self) private var loginItemService
    @Environment(ConfigStore.self) private var configStore
    @Environment(ProxyServer.self) private var proxyServer
    @Environment(CredentialStatusModel.self) private var credentialModel

    @State private var showAPIKey = false
    @State private var showMailFallback = false

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(
                    get: { loginItemService.isEnabled },
                    set: { loginItemService.setEnabled($0) }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Launch at Login")
                        Text("ZGate will start automatically when you log in.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityLabel("Launch at Login")
                .accessibilityHint("When enabled, ZGate starts automatically after you log in.")
            }

            credentialsSection

            Section("Web Search") {
                Picker("Search Provider", selection: binding(\.provider)) {
                    ForEach(WebSearchConfig.Provider.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }

                apiKeyFields

                if let link = URL(string: configStore.config.webSearch.provider.registrationURL) {
                    Link("Get API Key", destination: link)
                        .font(.footnote)
                }
            }

            aboutSection
        }
        .formStyle(.grouped)
        .padding()
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            loginItemService.refreshStatus()
        }
        .task { await credentialModel.recompute() }
        .alert("No Mail App Available", isPresented: $showMailFallback) {
            Button("OK") { }
        } message: {
            Text("The support address \(FeedbackMail.recipient) was copied to the clipboard.")
        }
    }

    // MARK: - Credentials (login-flow UI item 4)

    private var storeChoice: CredentialStoreSelection {
        CredentialStoreSelection.selection(for: configStore.config.credentialStoreBase)
    }

    private var credentialsSection: some View {
        Section {
            HStack {
                let chip = credentialModel.face.chip
                Text(chip.text)
                    .font(.callout)
                    .foregroundStyle(chip.color)
                if let retry = credentialModel.lastLoginOutcome?.retryText {
                    Text(retry)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if credentialModel.loginInFlight {
                    Button("Cancel") {
                        credentialModel.cancelSignIn()
                    }
                    .buttonStyle(.mpInline)
                    .accessibilityLabel("Cancel sign-in")
                } else {
                    Button("Sign In…") {
                        credentialModel.startSignIn()
                    }
                    .buttonStyle(.mpInline)
                    .accessibilityLabel("Sign in to ZCode")
                    .accessibilityHint("Opens the browser for the ZCode login flow.")
                }
            }

            HStack {
                Button("Reload credentials") {
                    Task { await credentialModel.reloadCredentials() }
                }
                .buttonStyle(.mpInline)
                .accessibilityLabel("Reload credentials")
                .accessibilityHint("Adopts an external login (GUI or CLI) without a restart.")
                Spacer()
            }

            Picker("Credential store", selection: storeChoiceBinding) {
                Text("Shared with ZCode GUI (~/.zcode)").tag(StoreChoice.sharedGUI)
                Text("Isolated scratch (~/.zcode-scratch-v3)").tag(StoreChoice.scratch)
                Text("Custom path").tag(StoreChoice.custom)
            }
            if case .custom = storeChoice {
                TextField(
                    "Absolute data-base path (e.g. /Volumes/backup/zcode-store)",
                    text: customPathBinding)
                    .autocorrectionDisabled()
            }
        } header: {
            Text("Credentials")
        } footer: {
            Text("Sign in opens the browser; after approval ZGate picks up the new session without a restart. Reload adopts an external (GUI/CLI) login. Store changes apply immediately.")
        }
    }

    private enum StoreChoice: Hashable {
        case sharedGUI, scratch, custom
    }

    private var storeChoiceBinding: Binding<StoreChoice> {
        Binding(
            get: {
                switch storeChoice {
                case .sharedWithGUI: .sharedGUI
                case .legacyScratch: .scratch
                case .custom: .custom
                }
            },
            set: { choice in
                switch choice {
                case .sharedGUI:
                    configStore.config.credentialStoreBase = nil
                case .scratch:
                    configStore.config.credentialStoreBase = CredentialStoreSelection.legacyScratchSetting
                case .custom:
                    // Keep any custom path already typed; empty shows the
                    // field below and behaves as the shared default until
                    // a path is entered (resolveBase treats "" as default).
                    if case .sharedWithGUI = storeChoice {
                        configStore.config.credentialStoreBase = ""
                    }
                }
                configStore.saveAndReload(proxyServer: proxyServer)
            })
    }

    private var customPathBinding: Binding<String> {
        Binding(
            get: {
                if case let .custom(path) = storeChoice { return path }
                return ""
            },
            set: { path in
                configStore.config.credentialStoreBase = path.isEmpty ? "" : path
                configStore.saveAndReload(proxyServer: proxyServer)
            })
    }

    // MARK: - About

    private var aboutSection: some View {
        Section("About") {
            LabeledContent("Version", value: FeedbackMail.versionDisplay)

            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Feedback & Support")
                    Text("Opens your mail app with the app and macOS version filled in. No configuration, API keys, or request data is included.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Send Feedback") {
                    sendFeedback()
                }
                .buttonStyle(.mpInline)
                .accessibilityLabel("Send Feedback")
                .accessibilityHint("Opens a prefilled email to \(FeedbackMail.recipient).")
            }
        }
    }

    private func sendFeedback() {
        guard let url = FeedbackMail.currentMailtoURL(), NSWorkspace.shared.open(url) else {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(FeedbackMail.recipient, forType: .string)
            showMailFallback = true
            return
        }
    }

    @ViewBuilder
    private var apiKeyFields: some View {
        switch configStore.config.webSearch.provider {
        case .forwardAsIs:
            Text("The web_search tool will be forwarded to the vendor unchanged.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        case .brave:
            apiKeyField("Brave API Key", binding: binding(\.braveAPIKey))
        case .google:
            apiKeyField("Google API Key", binding: binding(\.googleAPIKey))
            TextField("Search Engine ID", text: binding(\.googleSearchEngineID))
                .autocorrectionDisabled()
        case .tavily:
            apiKeyField("Tavily API Key", binding: binding(\.tavilyAPIKey))
        }
    }

    private func apiKeyField(_ label: String, binding: Binding<String>) -> some View {
        HStack {
            if showAPIKey {
                TextField(label, text: binding)
                    .autocorrectionDisabled()
            } else {
                SecureField(label, text: binding)
            }
            Button(showAPIKey ? "Hide" : "Reveal") {
                showAPIKey.toggle()
            }
            .buttonStyle(.mpInline)
            .accessibilityLabel(showAPIKey ? "Hide API Key" : "Reveal API Key")
        }
    }

    private func binding<T>(_ keyPath: WritableKeyPath<WebSearchConfig, T>) -> Binding<T> {
        Binding(
            get: { configStore.config.webSearch[keyPath: keyPath] },
            set: { newValue in
                configStore.config.webSearch[keyPath: keyPath] = newValue
                configStore.saveAndReload(proxyServer: proxyServer)
            }
        )
    }
}

#Preview {
    GeneralTabView()
        .environment(LoginItemService())
        .environment(ConfigStore())
        .environment(ProxyServer(tokenStatsStore: TokenStatsStore()))
        .environment(CredentialStatusModel())
}
