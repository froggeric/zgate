import SwiftUI

struct SettingsView: View {
    @Environment(ConfigStore.self) private var configStore
    @Environment(ProxyServer.self) private var proxyServer
    @Environment(TokenStatsStore.self) private var tokenStatsStore
    @Environment(LoginItemService.self) private var loginItemService

    var body: some View {
        TabView {
            // General first (login-flow UI item 4): the human credential
            // surface lives here — status, sign-in, store selector.
            GeneralTabView()
                .tabItem { Label("General", systemImage: "gearshape") }

            RulesTabView()
                .tabItem { Label("Rules", systemImage: "arrow.triangle.branch") }

            VendorsTabView()
                .tabItem { Label("Vendors", systemImage: "server.rack") }

            QuotaTabView()
                .tabItem { Label("Quota", systemImage: "gauge.with.needle") }

            SplashTabView()
                .tabItem { Label("Splash", systemImage: "drop") }

            AdvancedTabView()
                .tabItem { Label("Advanced", systemImage: "wrench.and.screwdriver") }

            ClientsTabView()
                .tabItem { Label("Clients", systemImage: "desktopcomputer") }

            StatisticsTabView()
                .tabItem { Label("Statistics", systemImage: "chart.bar") }

            DebugTabView()
                .tabItem { Label("Debug", systemImage: "ladybug") }

            AboutTabView()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(minWidth: 560, minHeight: 420)
        .environment(configStore)
        .environment(proxyServer)
        .environment(tokenStatsStore)
        .environment(loginItemService)
    }
}

#Preview {
    let statsStore = TokenStatsStore()
    let server = ProxyServer(tokenStatsStore: statsStore)
    SettingsView()
        .environment(ConfigStore())
        .environment(server)
        .environment(statsStore)
        .environment(LoginItemService())
        .environment(QuotaStatusModel.live(server))
        .environment(CredentialStatusModel())
}

// MARK: - Rules tab (spec §2/§6 editor for the Task 6 rule schema)

/// Editor state for one routing rule (the Task 6 `ModelMapping` schema:
/// class patterns, exact models, catch-all, conditions, primary + backup
/// targets, enable flag). Round-trips `ModelMapping`; `validationError`
/// gates persistence — an invalid rule (e.g. no target) is blocked with a
/// message and never written to config.json.
struct RuleEditState: Equatable {
    enum MatchMode: Equatable, Hashable {
        case modelClass(ModelClass)
        case exactModel
        case catchAll
    }

    var matchMode: MatchMode = .modelClass(.auto)
    var exactModel: String = ""
    var isEnabled: Bool = true
    var conditions: [RuleCondition] = []
    var primaryVendorID: UUID?
    var primaryModel: String = ""
    var backupVendorID: UUID?
    var backupModel: String = ""

    init() {}

    init(mapping: ModelMapping) {
        if mapping.catchAll {
            matchMode = .catchAll
        } else if let matchClass = mapping.matchClass {
            matchMode = .modelClass(matchClass)
        } else {
            matchMode = .exactModel
        }
        exactModel = mapping.sourceModel
        isEnabled = mapping.isEnabled
        conditions = mapping.conditions ?? []
        primaryVendorID = mapping.targetVendorID
        primaryModel = mapping.targetModel
        backupVendorID = mapping.backupTargetVendorID
        backupModel = mapping.backupTargetModel ?? ""
    }

    var isCatchAll: Bool {
        if case .catchAll = matchMode { return true }
        return false
    }

    var matchClass: ModelClass? {
        if case let .modelClass(modelClass) = matchMode { return modelClass }
        return nil
    }

    /// Display label stored in `sourceModel` (class rules use the class
    /// name as the label; the router matches on `matchClass`/`catchAll`).
    var sourceLabel: String {
        switch matchMode {
        case .modelClass(let modelClass): return modelClass.rawValue
        case .exactModel: return exactModel.trimmingCharacters(in: .whitespaces)
        case .catchAll: return "fallback"
        }
    }

    /// nil = valid to save. First failing check wins; phrased for display.
    func validationError(vendors: [Vendor]) -> String? {
        if case .exactModel = matchMode,
            exactModel.trimmingCharacters(in: .whitespaces).isEmpty
        {
            return "Enter the model ID this rule matches."
        }
        guard let primaryVendorID,
            vendors.contains(where: { $0.id == primaryVendorID })
        else {
            return "A rule needs a primary target (choose a vendor)."
        }
        if primaryModel.trimmingCharacters(in: .whitespaces).isEmpty {
            return "A rule needs a primary target model."
        }
        let backupTouched = backupVendorID != nil
            || !backupModel.trimmingCharacters(in: .whitespaces).isEmpty
        if backupTouched {
            guard let backupVendorID,
                vendors.contains(where: { $0.id == backupVendorID })
            else {
                return "Choose the backup vendor, or clear the backup."
            }
            if backupModel.trimmingCharacters(in: .whitespaces).isEmpty {
                return "Enter the backup target model, or clear the backup."
            }
        }
        for condition in conditions {
            switch condition.type {
            case .timeWindow:
                guard RuleCondition.minutesFromMidnight(condition.from) != nil,
                    RuleCondition.minutesFromMidnight(condition.to) != nil
                else {
                    return "A time window needs both from/to times as HH:mm."
                }
            case .quotaBelow:
                guard let percent = condition.percent, (0...100).contains(percent) else {
                    return "Quota percent must be a number between 0 and 100."
                }
            }
        }
        return nil
    }

    /// The mapping to persist. `existing` keeps the id on the edit path.
    /// Only call after `validationError` returned nil; the guard below is
    /// the loud invariant for future callers, not a recovery path.
    func toMapping(existing: ModelMapping? = nil) -> ModelMapping {
        guard let primaryVendorID else {
            preconditionFailure(
                "RuleEditState.toMapping requires a primary vendor — call only when validationError(vendors:) is nil"
            )
        }
        let backup = backupModel.trimmingCharacters(in: .whitespaces)
        return ModelMapping(
            id: existing?.id ?? UUID(),
            sourceModel: sourceLabel,
            targetModel: primaryModel.trimmingCharacters(in: .whitespaces),
            targetVendorID: primaryVendorID,
            backupTargetModel: backup.isEmpty ? nil : backup,
            backupTargetVendorID: backup.isEmpty ? nil : backupVendorID,
            isEnabled: isEnabled,
            matchClass: matchClass,
            catchAll: isCatchAll,
            conditions: conditions.isEmpty ? nil : conditions)
    }
}

extension RuleCondition {

    /// Compact badge for the rules list, e.g. "weekdays 07:00–11:00
    /// Europe/Paris" or "quota < 50%".
    var badgeText: String {
        switch type {
        case .timeWindow:
            var parts: [String] = []
            if let from, let to { parts.append("\(from)–\(to)") }
            parts.append((days ?? .daily).rawValue)
            if let tz { parts.append(tz) }
            return parts.joined(separator: " ")
        case .quotaBelow:
            return "quota < \(Int(percent ?? 0))%"
        }
    }
}

struct RulesTabView: View {
    @Environment(ConfigStore.self) private var configStore
    @Environment(ProxyServer.self) private var proxyServer

    @State private var showAddSheet: Bool = false
    @State private var editingMapping: ModelMapping? = nil
    @State private var deletingMapping: ModelMapping? = nil

    var body: some View {
        Form {
            Section {
                if configStore.config.modelMappings.isEmpty {
                    Text("No rules. Add one to route model classes or exact models to a target.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 8)
                } else {
                    ForEach(Array(configStore.config.modelMappings.enumerated()), id: \.element.id) { index, mapping in
                        RuleRow(
                            mapping: mapping,
                            canMoveUp: index > 0,
                            canMoveDown: index < configStore.config.modelMappings.count - 1,
                            onEdit: { editingMapping = mapping },
                            onDelete: { deletingMapping = mapping },
                            onMove: { delta in move(mapping: mapping, by: delta) })
                    }
                }
            } header: {
                HStack {
                    Text("Routing Rules")
                    Spacer()
                    Button("Add Rule…") { showAddSheet = true }
                        .buttonStyle(.link)
                        .disabled(configStore.config.vendors.isEmpty)
                        .accessibilityLabel("Add routing rule")
                }
            } footer: {
                if configStore.config.vendors.isEmpty {
                    Text("Add at least one vendor in the Vendors tab before creating rules.")
                        .foregroundStyle(.secondary)
                } else {
                    Text("Rules are evaluated in order, first match wins; the catch-all serves everything unmatched. Editing persists on Save; reordering and toggling persist immediately.")
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .sheet(isPresented: $showAddSheet) {
            RuleEditorSheet(existing: nil) { _ in }
                .environment(configStore)
                .environment(proxyServer)
        }
        .sheet(item: $editingMapping) { mapping in
            RuleEditorSheet(existing: mapping) { _ in }
                .environment(configStore)
                .environment(proxyServer)
        }
        .confirmationDialog(
            "Delete rule?",
            isPresented: Binding(
                get: { deletingMapping != nil },
                set: { if !$0 { deletingMapping = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let mapping = deletingMapping {
                    configStore.config.modelMappings.removeAll { $0.id == mapping.id }
                    configStore.saveAndReload(proxyServer: proxyServer)
                }
                deletingMapping = nil
            }
            Button("Cancel", role: .cancel) { deletingMapping = nil }
        } message: {
            if let mapping = deletingMapping {
                Text("Remove the rule for \"\(mapping.sourceModel)\"? This cannot be undone.")
            }
        }
    }

    /// Swap a rule with its neighbor (delta −1/＋1) and persist. Order is
    /// evaluation order, so a move takes effect immediately.
    private func move(mapping: ModelMapping, by delta: Int) {
        guard let index = configStore.config.modelMappings.firstIndex(where: { $0.id == mapping.id })
        else { return }
        let target = index + delta
        guard configStore.config.modelMappings.indices.contains(target) else { return }
        configStore.config.modelMappings.swapAt(index, target)
        configStore.saveAndReload(proxyServer: proxyServer)
    }
}

private struct RuleRow: View {
    @Environment(ConfigStore.self) private var configStore
    @Environment(ProxyServer.self) private var proxyServer
    let mapping: ModelMapping
    let canMoveUp: Bool
    let canMoveDown: Bool
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onMove: (Int) -> Void

    private var vendorName: String {
        configStore.config.vendors.first(where: { $0.id == mapping.targetVendorID })?.name
            ?? "Unknown vendor"
    }

    private var backupVendorName: String? {
        guard let id = mapping.backupTargetVendorID else { return nil }
        return configStore.config.vendors.first(where: { $0.id == id })?.name ?? "Unknown"
    }

    private var matchLabel: String {
        if mapping.catchAll { return "other (catch-all)" }
        return mapping.sourceModel  // class rules store the class name here
    }

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    if mapping.catchAll {
                        badge("catch-all", color: .purple)
                    } else if mapping.matchClass != nil {
                        badge("class", color: .blue)
                    } else {
                        badge("model", color: .secondary)
                    }
                    Text(matchLabel)
                        .font(.body.monospaced())
                }
                Text("\(mapping.targetModel) @ \(vendorName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let backupVendorName {
                    Text("⇄ \(mapping.backupTargetModel ?? mapping.targetModel) @ \(backupVendorName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(Array((mapping.conditions ?? []).enumerated()), id: \.offset) { _, condition in
                    Text("when \(condition.badgeText)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .opacity(mapping.isEnabled ? 1 : 0.55)

            Spacer()

            VStack(spacing: 2) {
                Button {
                    onMove(-1)
                } label: {
                    Image(systemName: "chevron.up")
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .disabled(!canMoveUp)
                .accessibilityLabel("Move rule up")
                Button {
                    onMove(1)
                } label: {
                    Image(systemName: "chevron.down")
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .disabled(!canMoveDown)
                .accessibilityLabel("Move rule down")

                Toggle(
                    "Enabled",
                    isOn: Binding(
                        get: { mapping.isEnabled },
                        set: { isEnabled in
                            ModelMappingActivation.setEnabled(
                                isEnabled, for: mapping.id,
                                in: &configStore.config.modelMappings)
                            configStore.saveAndReload(proxyServer: proxyServer)
                        })
                )
                .toggleStyle(.switch)
                .labelsHidden()
                .accessibilityLabel("Enable rule for \(mapping.sourceModel)")
            }

            VStack(spacing: 2) {
                Button("Edit", action: onEdit)
                    .buttonStyle(.link)
                    .accessibilityLabel("Edit rule for \(mapping.sourceModel)")
                Button("Delete", role: .destructive, action: onDelete)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityLabel("Delete rule for \(mapping.sourceModel)")
            }
        }
        .padding(.vertical, 2)
    }

    private func badge(_ title: String, color: Color) -> some View {
        Text(title)
            .font(.caption)
            .foregroundStyle(color)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(color.opacity(0.10))
            .clipShape(Capsule())
    }
}

// MARK: - Rule editor sheet

private struct RuleEditorSheet: View {
    @Environment(ConfigStore.self) private var configStore
    @Environment(ProxyServer.self) private var proxyServer
    @Environment(\.dismiss) private var dismiss

    let existing: ModelMapping?
    let onSaved: (ModelMapping) -> Void

    @State private var draft = RuleEditState()
    @State private var loaded = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
                matchSection
                targetSection
                backupSection
                conditionSection
            }
            .formStyle(.grouped)

            Divider()

            footer
                .padding(12)
        }
        .frame(minWidth: 480, minHeight: 460)
        .onAppear {
            guard !loaded else { return }
            loaded = true
            if let existing {
                draft = RuleEditState(mapping: existing)
            } else {
                draft.primaryVendorID = configStore.config.vendors.first?.id
            }
        }
    }

    // MARK: Match

    private var matchSection: some View {
        Section("Match") {
            Picker("Kind", selection: matchModeBinding) {
                ForEach(ModelClass.allCases, id: \.self) { modelClass in
                    Text("Class \(modelClass.rawValue)")
                        .tag(RuleEditState.MatchMode.modelClass(modelClass))
                }
                Text("Exact model").tag(RuleEditState.MatchMode.exactModel)
                Text("Catch-all (fallback)").tag(RuleEditState.MatchMode.catchAll)
            }

            if case .exactModel = draft.matchMode {
                TextField("Model ID to match, e.g. glm-5.3", text: $draft.exactModel)
                    .font(.body.monospaced())
                    .autocorrectionDisabled()
            } else if case .catchAll = draft.matchMode {
                Text("Serves every request no earlier rule matched. Evaluated after all class rules.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Toggle("Rule enabled", isOn: $draft.isEnabled)
        }
    }

    private var matchModeBinding: Binding<RuleEditState.MatchMode> {
        Binding(
            get: { draft.matchMode },
            set: { draft.matchMode = $0 })
    }

    // MARK: Targets

    private var targetSection: some View {
        Section("Primary target") {
            VendorMenuField(
                placeholder: "Target vendor",
                selection: binding(\.primaryVendorID),
                vendors: configStore.config.vendors,
                clients: configStore.config.clients)
            VendorModelField(
                placeholder: "Target model (vendor model name)",
                text: binding(\.primaryModel),
                vendorSelection: binding(\.primaryVendorID),
                vendors: configStore.config.vendors)
        }
    }

    private var backupSection: some View {
        Section {
            VendorMenuField(
                placeholder: "Backup vendor (optional)",
                selection: binding(\.backupVendorID),
                vendors: configStore.config.vendors,
                clients: configStore.config.clients)
            VendorModelField(
                placeholder: "Backup model (optional)",
                text: binding(\.backupModel),
                vendorSelection: binding(\.backupVendorID),
                vendors: configStore.config.vendors)
        } header: {
            Text("Backup target (failover)")
        } footer: {
            Text("Used when the primary target fails (429/5xx). Leave both empty for no backup.")
        }
    }

    // MARK: Conditions

    private var conditionSection: some View {
        Section {
            ForEach(draft.conditions.indices, id: \.self) { index in
                ConditionEditorRow(condition: $draft.conditions[index]) {
                    draft.conditions.remove(at: index)
                }
            }

            HStack(spacing: 8) {
                Button("Add time window") {
                    draft.conditions.append(
                        RuleCondition(type: .timeWindow, days: .daily, from: "09:00", to: "17:00"))
                }
                .buttonStyle(.link)
                Button("Add quota condition") {
                    draft.conditions.append(RuleCondition(type: .quotaBelow, percent: 25))
                }
                .buttonStyle(.link)
            }
        } header: {
            Text("When (all must hold)")
        } footer: {
            Text("A rule whose conditions fail is skipped and the next matching rule serves the request.")
        }
    }

    // MARK: Footer / save

    private var validationMessage: String? {
        draft.validationError(vendors: configStore.config.vendors)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let message = validationMessage {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(validationMessage != nil)
            }
        }
    }

    private func save() {
        guard validationMessage == nil else { return }
        let mapping = draft.toMapping(existing: existing)
        if let existing,
            let index = configStore.config.modelMappings.firstIndex(where: { $0.id == existing.id })
        {
            configStore.config.modelMappings[index] = mapping
        } else {
            configStore.config.modelMappings.append(mapping)
        }
        // Upstream exact-model semantics: one enabled rule per source model.
        if mapping.isEnabled, mapping.matchClass == nil, !mapping.catchAll {
            ModelMappingActivation.enforceSingleEnabledSource(
                for: mapping.id, in: &configStore.config.modelMappings)
        }
        configStore.saveAndReload(proxyServer: proxyServer)
        onSaved(mapping)
        dismiss()
    }

    private func binding<T>(_ keyPath: WritableKeyPath<RuleEditState, T>) -> Binding<T> {
        Binding(
            get: { draft[keyPath: keyPath] },
            set: { draft[keyPath: keyPath] = $0 })
    }
}

/// Editor for one `when` condition: type is fixed per row (chosen when
/// added), fields shown accordingly. All fields bind straight into the
/// condition — no per-row state.
private struct ConditionEditorRow: View {
    @Binding var condition: RuleCondition
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(
                    condition.type == .timeWindow ? "Time window" : "Quota below",
                    systemImage: condition.type == .timeWindow ? "clock" : "gauge.with.needle")
                    .font(.footnote.weight(.medium))
                Spacer()
                Button("Remove", role: .destructive, action: onRemove)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }

            switch condition.type {
            case .timeWindow:
                Picker("Days", selection: daysBinding) {
                    Text("Weekdays").tag(RuleCondition.DayScope.weekdays)
                    Text("Weekend").tag(RuleCondition.DayScope.weekend)
                    Text("Daily").tag(RuleCondition.DayScope.daily)
                }
                .pickerStyle(.segmented)
                HStack {
                    TextField("From HH:mm", text: fromBinding)
                        .textFieldStyle(.roundedBorder)
                    Text("→")
                    TextField("To HH:mm", text: toBinding)
                        .textFieldStyle(.roundedBorder)
                    TextField("Time zone", text: tzBinding)
                        .textFieldStyle(.roundedBorder)
                }
            case .quotaBelow:
                HStack {
                    Text("Route while remaining quota is below")
                    TextField(
                        "50",
                        value: percentBinding,
                        format: .number
                    )
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 50)
                    .multilineTextAlignment(.trailing)
                    Text("%")
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var daysBinding: Binding<RuleCondition.DayScope> {
        Binding(
            get: { condition.days ?? .daily },
            set: { condition.days = $0 })
    }

    private var fromBinding: Binding<String> {
        Binding(
            get: { condition.from ?? "" },
            set: { condition.from = $0.isEmpty ? nil : $0 })
    }

    private var toBinding: Binding<String> {
        Binding(
            get: { condition.to ?? "" },
            set: { condition.to = $0.isEmpty ? nil : $0 })
    }

    private var tzBinding: Binding<String> {
        Binding(
            get: { condition.tz ?? "" },
            set: { condition.tz = $0.isEmpty ? nil : $0 })
    }

    private var percentBinding: Binding<Double> {
        Binding(
            get: { condition.percent ?? 0 },
            set: { condition.percent = $0 })
    }
}

// MARK: - Quota tab

struct QuotaTabView: View {
    @Environment(QuotaStatusModel.self) private var quotaModel

    var body: some View {
        Form {
            Section {
                QuotaBarView(state: quotaModel.state, fetchedAt: quotaModel.fetchedAt, showsCaption: true)
                HStack {
                    Button("Refresh Now") {
                        Task { await quotaModel.refreshNow() }
                    }
                    .disabled(!quotaModel.canRefresh || quotaModel.isRefreshing)
                    if quotaModel.isDemoSeeded {
                        Text("demo data seeded (debug menu)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            } header: {
                Text("Current quota")
            } footer: {
                Text("Fails open: while no balance is returned, routing keeps working and quota-gated rules are skipped.")
            }

            Section("Polling") {
                row("Cadence", value: "every 30 min")
                row("Request trigger", value: "after every 25 relayed requests")
                row("Staleness policy", value: "last known kept and dimmed")
            }

            Section {
                row("Warning at ≤ 25% remaining", value: "yellow", valueColor: .yellow)
                row("Critical at ≤ 10% remaining", value: "red", valueColor: .red)
            } header: {
                Text("Thresholds")
            } footer: {
                Text("The router's quotaBelow conditions read the same values. Thresholds are fixed in this build.")
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear { quotaModel.recompute() }
    }

    private func row(_ label: String, value: String, valueColor: Color? = nil) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .foregroundStyle(valueColor ?? Color.secondary)
        }
    }
}

// MARK: - Advanced tab

struct AdvancedTabView: View {
    @Environment(ConfigStore.self) private var configStore
    @Environment(ProxyServer.self) private var proxyServer
    @State private var copied: String?
    @State private var chainEvents: [SigningClient.ChainEvent] = []

    var body: some View {
        Form {
            clientSetupSection
            listenersSection
            signingSection
            credentialSection
        }
        .formStyle(.grouped)
        .padding()
        // Refresh the raw chain log whenever credential activity happens;
        // credentialEvents is observable, so the id change re-runs the task.
        .task(id: proxyServer.credentialEvents.events.count) {
            chainEvents = await proxyServer.relayContext?.signingClient.lastChainEvents() ?? []
        }
    }

    private var clientSetupSection: some View {
        Section {
            if let line = EnvExportLine.claudeLine(
                boundPorts: proxyServer.boundPorts,
                clients: configStore.config.clients)
            {
                CopyableLineView(line: line, copiedKey: $copied, key: line)
            } else {
                Text("No client configured.")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Client setup")
        } footer: {
            Text("Point Claude Code at ZGate. The port is the actually bound port (it advances automatically when the configured port is taken).")
        }
    }

    private var listenersSection: some View {
        Section("Listeners") {
            ForEach(configStore.config.clients) { client in
                HStack {
                    Text(client.clientName)
                    Spacer()
                    if let bound = proxyServer.boundPorts[client.clientName] {
                        if bound != client.port {
                            // verbatim: LocalizedStringKey Int interpolation
                            // would group digits ("8,787").
                            Text(verbatim: "configured \(client.port) → bound \(bound)")
                                .foregroundStyle(.orange)
                        } else {
                            Text(verbatim: "127.0.0.1:\(bound)")
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text(verbatim: "configured \(client.port) — not listening")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var signingSection: some View {
        Section {
            HStack {
                Text("Relay signing context")
                Spacer()
                if proxyServer.relayContext != nil {
                    // Green stays reserved for process-up and quota; the
                    // seal carries the positive signal, the word stays primary.
                    Label {
                        Text("ready")
                    } icon: {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                    }
                } else {
                    Text("not built (starts with the proxy)")
                        .foregroundStyle(.secondary)
                }
            }
            Text("Rejected signatures re-handshake automatically (once), then fail open unsigned with a warning.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        } header: {
            Text("Signing")
        }
    }

    /// Raw credential detail (login-flow UI item 4 split): the human surface
    /// (face, sign-in, store selector) lives on General; this keeps the raw
    /// event log — expiry reasons and the last chain build's telemetry
    /// (lengths only, never values).
    private var credentialSection: some View {
        Section {
            HStack {
                Text("Last expiry reason")
                Spacer()
                if case let .expired(reason)? = proxyServer.credentialEvents.events.last {
                    Label(reason, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                } else {
                    Label("ok (no expiry events)", systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Re-login command (terminal fallback, opens a browser for OAuth):")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                CopyableLineView(line: ReloginAlertContent.command, copiedKey: $copied, key: ReloginAlertContent.command)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text("Last chain build (stage · HTTP · duration · outcome length):")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if chainEvents.isEmpty {
                    Text("No chain events yet")
                        .font(.footnote.monospaced())
                        .foregroundStyle(.tertiary)
                } else {
                    ForEach(Array(chainEvents.enumerated()), id: \.offset) { _, event in
                        Text(
                            verbatim: "\(event.stage.rawValue) · HTTP \(event.status) · \(event.ms) ms"
                                + (event.outcomeTokenLength.map { " · \($0) chars" } ?? ""))
                            .font(.footnote.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } header: {
            Text("Credentials — raw event log")
        } footer: {
            Text("The human credential surface (status, sign-in, store selector) is on the General tab. ZGate never displays token values — lengths only.")
        }
    }
}

/// Monospaced line + Copy button with transient feedback.
private struct CopyableLineView: View {
    let line: String
    @Binding var copiedKey: String?
    let key: String

    var body: some View {
        HStack {
            Text(line)
                .font(.footnote.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer(minLength: 4)
            Button(copiedKey == key ? "Copied" : "Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(line, forType: .string)
                copiedKey = key
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    if copiedKey == key { copiedKey = nil }
                }
            }
            .buttonStyle(.link)
            .accessibilityLabel("Copy line")
        }
    }
}

// MARK: - About tab

struct AboutTabView: View {
    @Environment(ConfigStore.self) private var configStore

    var body: some View {
        Form {
            Section("ZGate") {
                row("Version", value: FeedbackMail.versionDisplay)
                Text("A native menu-bar proxy for Claude Code: signed zcode relay routing, local splash fallback, and quota-aware rules.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Credits") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("ZGate — this fork")
                    if let url = URL(string: "https://github.com/froggeric/zgate") {
                        Link("github.com/froggeric/zgate", destination: url)
                            .font(.footnote)
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Built on model-proxy (MIT)")
                    if let url = URL(string: "https://github.com/n0rvyn/model-proxy") {
                        Link("github.com/n0rvyn/model-proxy", destination: url)
                            .font(.footnote)
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Splash local target")
                    Text("Anthropic-protocol local server (splash). Port is configured on the Splash tab (default 8123); the disabled qwen rules under Rules route here once enabled.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Config & data") {
                row("Config", value: "config.json")
                Text(AppPaths.appSupport.path)
                    .font(.footnote.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func row(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
        }
    }
}
