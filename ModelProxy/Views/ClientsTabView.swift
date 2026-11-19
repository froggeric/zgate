import SwiftUI

struct ClientsTabView: View {
    @Environment(ConfigStore.self) private var configStore
    @Environment(ProxyServer.self) private var proxyServer

    var body: some View {
        Form {
            ForEach(configStore.config.clients.indices, id: \.self) { index in
                ClientRowSection(index: index)
                    .environment(configStore)
                    .environment(proxyServer)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

private struct ClientRowSection: View {
    @Environment(ConfigStore.self) private var configStore
    @Environment(ProxyServer.self) private var proxyServer
    let index: Int

    @State private var portText: String = ""
    @State private var showCopied: Bool = false

    private var client: ClientConfig { configStore.config.clients[index] }

    private var portChanged: Bool {
        guard let boundPort = proxyServer.boundPorts[client.clientName] else { return false }
        return boundPort != client.port
    }

    /// Per-keystroke validity: invalid text shows in red with a hint, so a
    /// rejected edit is visible instead of silently swallowed.
    private var portIsValid: Bool {
        guard let port = Int(portText) else { return false }
        return (1024...65535).contains(port)
    }

    /// One formatter (EnvExportLine) for the popover env line and this
    /// quick start — same 127.0.0.1 host, same actual-bound-port semantics.
    private var envExportCommand: String {
        EnvExportLine.quickStartCommand(
            client: client,
            boundPort: proxyServer.boundPorts[client.clientName])
    }

    var body: some View {
        Section(client.clientName) {
            TextField("Port", text: $portText)
                .onAppear { portText = "\(client.port)" }
                .onSubmit {
                    guard portIsValid, let port = Int(portText) else { return }
                    configStore.config.clients[index].port = port
                    configStore.saveAndReload(proxyServer: proxyServer)
                }
                .foregroundStyle(portText.isEmpty || portIsValid ? AnyShapeStyle(.primary) : AnyShapeStyle(.red))

            if !portText.isEmpty && !portIsValid {
                Text("Port must be 1024–65535; the change applies when you press Return.")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            // Port change banner (DP-002: port change needs manual Stop/Start)
            if portChanged {
                Text("Port change takes effect after stopping and restarting the proxy.")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }

            TextField("Default upstream", text: Binding(
                get: { configStore.config.clients[index].defaultUpstream },
                set: { newValue in
                    configStore.config.clients[index].defaultUpstream = newValue
                    configStore.saveAndReload(proxyServer: proxyServer)
                }
            ))
            .autocorrectionDisabled()
            .textContentType(nil)

            Picker("Unmapped models", selection: Binding(
                get: { configStore.config.clients[index].unmappedPolicy },
                set: { newValue in
                    configStore.config.clients[index].unmappedPolicy = newValue
                    configStore.saveAndReload(proxyServer: proxyServer)
                }
            )) {
                Text("Passthrough").tag(UnmappedModelPolicy.passthrough)
                Text("Route to vendor").tag(UnmappedModelPolicy.routeAll)
                Text("Block").tag(UnmappedModelPolicy.block)
            }

            if client.unmappedPolicy == .routeAll {
                Picker("Fallback vendor", selection: Binding(
                    get: { configStore.config.clients[index].fallbackVendorID },
                    set: { newValue in
                        configStore.config.clients[index].fallbackVendorID = newValue
                        configStore.saveAndReload(proxyServer: proxyServer)
                    }
                )) {
                    Text("None").tag(UUID?.none)
                    ForEach(configStore.config.vendors) { vendor in
                        Text(vendor.name).tag(UUID?.some(vendor.id))
                    }
                }

                VendorModelField(
                    placeholder: "Fallback model (empty = keep original)",
                    text: fallbackModelBinding,
                    vendorSelection: fallbackVendorBinding,
                    vendors: configStore.config.vendors,
                    emptySelectionTitle: "Keep original model"
                )
            }

            LabeledContent("Quick start") {
                HStack(spacing: 6) {
                    Text(envExportCommand)
                        .font(.footnote.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Button(showCopied ? "Copied" : "Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(envExportCommand, forType: .string)
                        showCopied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            showCopied = false
                        }
                    }
                    .buttonStyle(.link)
                    .accessibilityLabel("Copy quick start command for \(client.clientName)")
                    .accessibilityHint("Copies the export command to clipboard.")
                }
            }
        }
    }

    private var fallbackVendorBinding: Binding<UUID?> {
        Binding(
            get: { configStore.config.clients[index].fallbackVendorID },
            set: { newValue in
                configStore.config.clients[index].fallbackVendorID = newValue
                configStore.saveAndReload(proxyServer: proxyServer)
            }
        )
    }

    private var fallbackModelBinding: Binding<String> {
        Binding(
            get: { configStore.config.clients[index].fallbackTargetModel ?? "" },
            set: { newValue in
                configStore.config.clients[index].fallbackTargetModel = newValue.isEmpty ? nil : newValue
                configStore.saveAndReload(proxyServer: proxyServer)
            }
        )
    }
}
