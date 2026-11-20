import AppKit
import SwiftUI

struct GeneralTabView: View {
    @Environment(LoginItemService.self) private var loginItemService
    @Environment(ConfigStore.self) private var configStore
    @Environment(ProxyServer.self) private var proxyServer
    @Environment(CredentialStatusModel.self) private var credentialModel
    /// Update-preference toggles sync the center's settings copy (Task 11).
    @Environment(UpdateCenter.self) private var updateCenter

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
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityLabel("Launch at Login")
                .accessibilityHint("When enabled, ZGate starts automatically after you log in.")
            }

            credentialsSection

            offPeakSection

            Section("Web Search") {
                Picker("Search Provider", selection: binding(\.provider)) {
                    ForEach(WebSearchConfig.Provider.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }

                apiKeyFields

                if let link = URL(string: configStore.config.webSearch.provider.registrationURL) {
                    Link("Get API Key", destination: link)
                        .font(.callout)
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
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if credentialModel.loginInFlight {
                    Button("Cancel") {
                        credentialModel.cancelSignIn()
                    }
                    .buttonStyle(.link)
                    .accessibilityLabel("Cancel sign-in")
                } else {
                    Button("Sign In…") {
                        credentialModel.startSignIn()
                    }
                    .buttonStyle(.link)
                    .accessibilityLabel("Sign in to ZCode")
                    .accessibilityHint("Opens the browser for the ZCode login flow.")
                }
            }

            HStack {
                Button("Reload credentials") {
                    Task { await credentialModel.reloadCredentials() }
                }
                .buttonStyle(.link)
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

    // MARK: - Off-Peak (off-peak wave 2 Task 6)

    /// The opt-in toggle for the async ticket-plane surface. The status
    /// line under the title reads the live monitor (`displayString` on the
    /// @Observable monitor — "Off" while disabled or before the first
    /// poll). saveAndReload carries the flip to the running proxy: the
    /// monitor's lifecycle rides the live toggle (Task 5), no restart.
    /// Advanced knobs (origin/maxWait/poll/keepalive) stay config-only.
    private var offPeakSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { configStore.config.offPeak.enabled },
                set: { enabled in
                    configStore.config.offPeak.enabled = enabled
                    configStore.saveAndReload(proxyServer: proxyServer)
                }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Use ZCode off-peak compute")
                    Text(proxyServer.offPeakMonitor?.displayString ?? "Off")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityLabel("Use ZCode off-peak compute")
            .accessibilityHint(
                "Rules targeting the ZCode Off-Peak vendor ride the ticket plane while the window is open, and use their backup target otherwise.")
        } header: {
            Text("Off-Peak")
        } footer: {
            Text("Rules targeting the “ZCode Off-Peak” vendor ride the ticket plane while the window is open, and use their backup target otherwise. Enabling mints the coding-plan key on the first availability check.")
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        Section("About") {
            LabeledContent("Version", value: FeedbackMail.versionDisplay)

            Toggle("Check for updates automatically", isOn: Binding(
                get: { configStore.config.update?.autoCheck ?? true },
                set: { enabled in updateSettings { $0.autoCheck = enabled } }))

            Toggle("Update splash automatically when stopped", isOn: Binding(
                get: { configStore.config.update?.splashAutoApply ?? true },
                set: { enabled in updateSettings { $0.splashAutoApply = enabled } }))

            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Feedback & Support")
                    Text("Opens your mail app with the app and macOS version filled in. No configuration, API keys, or request data is included.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Send Feedback…") {
                    sendFeedback()
                }
                .buttonStyle(.link)
                .accessibilityLabel("Send Feedback")
                .accessibilityHint("Opens a prefilled email to \(FeedbackMail.recipient).")
            }
        }
    }

    /// Creates the update-preferences struct on first toggle (pre-update
    /// configs carry no `update` key; `UpdateSettings` defaults apply),
    /// applies the mutation, and persists — the brief's
    /// `ensureUpdateSettings()` pattern folded into one inout pass (a
    /// returned struct copy could not be mutated in place).
    private func updateSettings(_ mutate: (inout UpdateSettings) -> Void) {
        var settings = configStore.config.update ?? UpdateSettings()
        mutate(&settings)
        configStore.config.update = settings
        configStore.save()
        syncUpdateCenter()
    }

    /// Two-writer sync (UpdateCenter.adoptSettings carries the detail):
    /// this tab persists through ConfigStore while the center holds its
    /// own copy — without re-adoption the center's next check would
    /// round-trip a stale struct over the toggle. The toggle's live
    /// effect rides exactly this call: the repeat loop re-reads the
    /// adopted copy every cycle, so OFF stops the scheduled checks at
    /// the next cycle boundary and ON resumes them — no timer restart,
    /// no relaunch.
    private func syncUpdateCenter() {
        updateCenter.adoptSettings(configStore.config.update)
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
                .font(.callout)
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
            .buttonStyle(.link)
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
        .environment(UpdateCenter())
}
