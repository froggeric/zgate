import SwiftUI

/// Settings → Clients → "Claude Code settings file": what the file says
/// against what ZGate recommends. One write, always confirmed, always backed
/// up — the file holds keys that are nobody else's business.
struct ClaudeSetupSection: View {
    @Environment(ConfigStore.self) private var configStore
    @Environment(ProxyServer.self) private var proxyServer

    @State private var model = ClaudeSetupModel()
    @State private var confirmApply = false
    @State private var confirmRestore = false
    @State private var showValues = false
    @State private var showLocal = false

    private var settings: ClaudeSetupSettings {
        configStore.config.claudeSetup ?? ClaudeSetupSettings()
    }

    /// Re-reads whenever something the recommendation depends on changes.
    private var reviewKey: String {
        "\(settings)|\(configStore.config.modelMappings.count)|\(proxyServer.boundPorts)"
    }

    var body: some View {
        Section("Claude Code settings file") {
            status
            if model.isLoading {
                Text("Reading the file…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            ForEach(model.review.rows) { row in
                LabeledContent(row.title) {
                    HStack(spacing: 6) {
                        Text(verbatim: row.current)
                        if row.differs {
                            Image(systemName: "arrow.right")
                            Text(verbatim: row.recommended)
                        }
                    }
                    .font(.callout.monospaced())
                    .foregroundStyle(row.differs ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                }
                // One element for assistive technology: what the key is, and
                // what the file says against what is recommended.
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(row.title)
                .accessibilityValue(row.differs
                    ? "\(row.current), recommended \(row.recommended)" : row.current)
                .accessibilityIdentifier("claudeSetup.row.\(row.id)")
            }

            if !model.review.ids.isEmpty {
                LabeledContent("Context windows") {
                    EmptyView()
                }
                .accessibilityHidden(true)
                ForEach(model.review.ids) { line in
                    LabeledContent(line.modelID) {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("window \(ClaudeSetupReviewer.formatted(line.window)) · "
                                 + "compacts at \(ClaudeSetupReviewer.formatted(line.threshold))")
                            Text(verbatim: "\(sourceName(line.source))\(line.target.map { " · \($0)" } ?? "")")
                                .foregroundStyle(.secondary)
                        }
                        .font(.callout)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(line.modelID) context window")
                    .accessibilityValue("window \(line.window), compacts at \(line.threshold)")
                    .accessibilityIdentifier("claudeSetup.window.\(line.id)")
                }
            }

            ForEach(model.review.warnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
            if let error = model.errorMessage {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            HStack(spacing: 12) {
                Button("Apply recommended…") { confirmApply = true }
                    .disabled(!model.review.canApply)
                    .accessibilityLabel("Apply the recommended settings")
                    .accessibilityIdentifier("claudeSetup.apply")
                Button("Restore last backup…") { confirmRestore = true }
                    .disabled(model.backups.isEmpty)
                    .accessibilityLabel("Restore the last backup")
                    .accessibilityIdentifier("claudeSetup.restore")
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([model.store.fileURL])
                }
                .accessibilityLabel("Reveal the settings file in Finder")
                .accessibilityIdentifier("claudeSetup.reveal")
            }

            DisclosureGroup("Recommended values", isExpanded: $showValues) {
                recommendedValues
            }
            DisclosureGroup("Local model id", isExpanded: $showLocal) {
                localModelID
            }

            Text("Writes only the keys listed here, and saves a backup beside the file before every write. "
                 + "Project and managed settings can override these values. Applies to new sessions: "
                 + "a session keeps the environment it was started with. "
                 + "Window and compaction behaviour measured on Claude Code 2.1.323.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .task(id: reviewKey) {
            await model.refresh(context: ClaudeSetupModel.Context.from(
                config: configStore.config, boundPorts: proxyServer.boundPorts))
        }
        .sheet(isPresented: $confirmApply) { applySheet }
        .sheet(isPresented: $confirmRestore) { restoreSheet }
    }

    // MARK: - Status

    private var status: some View {
        VStack(alignment: .leading, spacing: 2) {
            switch model.review.state {
            case .upToDate:
                Label("Up to date", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .differs:
                Label("\(model.review.changes.count) changes recommended", systemImage: "arrow.triangle.2.circlepath")
                    .foregroundStyle(.orange)
            case .noSettingsFile:
                Label("No settings file found", systemImage: "doc.badge.plus").foregroundStyle(.orange)
            case .unreadable(let reason):
                Label("The file can't be read: \(reason)", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
            Text(model.filePath)
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            if let backup = model.lastBackup {
                Text("Last backup: \(backup)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .accessibilityIdentifier("claudeSetup.status")
    }

    private func sourceName(_ source: ClaudeSetupRecommendation.Window.Source) -> String {
        switch source {
        case .setHere: return "window set here"
        case .splash: return "window from splash"
        case .defaultWindow: return "default window"
        }
    }

    // MARK: - Recommended values

    private func textBinding(_ keyPath: WritableKeyPath<ClaudeSetupSettings, String>) -> Binding<String> {
        Binding(
            get: { settings[keyPath: keyPath] },
            set: { value in
                var next = settings
                next[keyPath: keyPath] = value
                save(next)
            })
    }

    private func numberBinding(_ keyPath: WritableKeyPath<ClaudeSetupSettings, Int>,
                               clamped to: ClosedRange<Int> = 1...10_000_000) -> Binding<Int> {
        Binding(
            get: { settings[keyPath: keyPath] },
            set: { value in
                var next = settings
                next[keyPath: keyPath] = min(max(value, to.lowerBound), to.upperBound)
                save(next)
            })
    }

    private func windowBinding(_ role: String) -> Binding<String> {
        Binding(
            get: { settings.contextWindows[role].map(String.init) ?? "" },
            set: { text in
                var next = settings
                if let window = Int(text.trimmingCharacters(in: .whitespaces)), window > 0 {
                    next.contextWindows[role] = max(window, ClaudeSetupRecommendation.minimumWindow)
                } else {
                    next.contextWindows[role] = nil
                }
                save(next)
            })
    }

    /// Saves the recommended values. They change no route, so the proxy keeps
    /// its snapshot; the section re-reads the file against the new values.
    private func save(_ next: ClaudeSetupSettings) {
        configStore.config.claudeSetup = next == ClaudeSetupSettings() ? nil : next
        configStore.save()
    }

    private var recommendedValues: some View {
        Group {
            TextField("Opus tier id", text: textBinding(\.opusID))
                .autocorrectionDisabled()
            TextField("Sonnet tier id", text: textBinding(\.sonnetID))
                .autocorrectionDisabled()
            TextField("Haiku tier id", text: textBinding(\.haikuID))
                .autocorrectionDisabled()
            Text("Claude Code asks for these ids; ZGate's rules decide which model answers. "
                 + "[1m] is added for you to an id whose window is 1M or more: it pins the window "
                 + "there, and the window written beside it keeps compaction on.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Toggle("Offer the local model id", isOn: Binding(
                get: { settings.localIDEnabled },
                set: { value in
                    var next = settings
                    next.localIDEnabled = value
                    save(next)
                }))
            TextField("Default context window", value: numberBinding(\.defaultContextWindow, clamped: 1...10_000_000),
                      format: .number)
            TextField("Compaction percentage", value: numberBinding(\.compactPercent, clamped: 1...100), format: .number)
            Text("Claude Code holds back 20,000 tokens of a window for the reply and compacts at this "
                 + "percentage of the rest. 70 leaves room for the reply and for whatever one step adds.")
                .font(.callout)
                .foregroundStyle(.secondary)
            ForEach(ClaudeSetupSettings.roles, id: \.self) { role in
                TextField("\(role.capitalized) window (empty: follow the route)", text: windowBinding(role))
                    .autocorrectionDisabled()
            }
            Text("A window set here wins over the route. Otherwise the window is the context length splash "
                 + "reports for the routed model, or the default.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Local model id

    private var localModelID: some View {
        Group {
            if let rule = ClaudeSetupLocalRule.rule(in: configStore.config) {
                let vendor = configStore.config.vendors.first { $0.id == rule.targetVendorID }?.name ?? "?"
                LabeledContent("Routing rule") {
                    Text(verbatim: "local → \(rule.targetModel) @ \(vendor)")
                        .font(.callout.monospaced())
                }
                if ClaudeSetupLocalRule.isStale(in: configStore.config) {
                    Text("The active splash profile is \(ClaudeSetupLocalRule.activeModel(in: configStore.config) ?? "?"); "
                         + "the rule still points at \(rule.targetModel).")
                        .font(.callout)
                        .foregroundStyle(.orange)
                    Button("Point the rule at the active profile") { syncLocalRule() }
                }
            } else {
                Text("No routing rule sends local to the local model: a local request would be answered "
                     + "by the catch-all rule.")
                    .font(.callout)
                    .foregroundStyle(.orange)
                Button("Create the rule") { syncLocalRule() }
            }
            Text("A session goes local with /model local or claude --model local.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func syncLocalRule() {
        if ClaudeSetupLocalRule.sync(into: configStore.config) {
            configStore.saveAndReload(proxyServer: proxyServer)
        }
    }

    // MARK: - Confirmations

    private func line(_ change: ClaudeSettingsChange) -> String {
        let key = change.label
        switch change.kind {
        case .set:
            return "\(key): \(change.previous ?? "not set") → \(change.value ?? "")"
        case .remove:
            return "\(key): \(change.previous ?? "set") → removed"
        case .rename:
            return "\(key) → \(change.destination?.joined(separator: ".") ?? "") (saved settings follow the id)"
        case .copy:
            return "\(key) → \(change.destination?.joined(separator: ".") ?? "") (copy; two tiers shared one id)"
        }
    }

    private var applySheet: some View {
        confirmation(
            title: "Apply the recommended settings?",
            lead: "Only the lines below are written. Every other byte of the file stays as it is.\n"
                + "A backup is saved beside the file first.",
            confirm: "Apply"
        ) {
            Task { await model.apply() }
        } content: {
            ForEach(model.review.changes) { change in
                Text(verbatim: line(change))
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
            }
        }
    }

    private var restoreSheet: some View {
        confirmation(
            title: "Restore the previous file?",
            lead: "The file is put back as it was in \(model.backups.first?.lastPathComponent ?? ""). "
                + "The current file is backed up first.",
            confirm: "Restore"
        ) {
            Task { await model.restoreLastBackup() }
        } content: {
            EmptyView()
        }
    }

    private func confirmation<Content: View>(
        title: String, lead: String, confirm: String,
        action: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.title2.bold())
            Text(lead)
                .font(.callout)
            Text(model.filePath)
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    content()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 280)
            HStack {
                Spacer()
                Button("Cancel") { confirmApply = false; confirmRestore = false }
                    .keyboardShortcut(.cancelAction)
                Button(confirm) {
                    confirmApply = false
                    confirmRestore = false
                    action()
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("claudeSetup.confirm")
            }
        }
        .padding(20)
        .frame(width: 620)
    }
}
