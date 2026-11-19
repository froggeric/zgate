import SwiftUI

struct VendorModelField: View {
    let placeholder: String
    @Binding var text: String
    @Binding var vendorSelection: UUID?
    let vendors: [Vendor]
    let emptySelectionTitle: String?
    @FocusState private var isFocused: Bool

    init(
        placeholder: String,
        text: Binding<String>,
        vendorSelection: Binding<UUID?>,
        vendors: [Vendor],
        emptySelectionTitle: String? = nil
    ) {
        self.placeholder = placeholder
        self._text = text
        self._vendorSelection = vendorSelection
        self.vendors = vendors
        self.emptySelectionTitle = emptySelectionTitle
    }

    private var models: [String] {
        guard let vendorID = vendorSelection,
              let vendor = vendors.first(where: { $0.id == vendorID }) else {
            return []
        }
        return vendor.supportedModels
    }

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.roundedBorder)
            .autocorrectionDisabled()
            .focused($isFocused)
            .overlay(alignment: .trailing) {
                // Preset menu: typing stays legitimate for model IDs; the
                // menu only offers the vendor's known models. The hit zone
                // is a full-height 24x24 target, not a bare caption glyph.
                Menu {
                    if let emptySelectionTitle {
                        Button(emptySelectionTitle) {
                            text = ""
                            isFocused = true
                        }
                        Divider()
                    }

                    if vendorSelection == nil {
                        Button("Select vendor first") {}
                            .disabled(true)
                    } else if models.isEmpty {
                        Button("No models configured") {}
                            .disabled(true)
                    } else {
                        ForEach(models, id: \.self) { model in
                            Button(model) { text = model }
                        }
                    }

                    Divider()
                    Button("Custom…") {
                        text = ""
                        isFocused = true
                    }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(width: vendorSelectionMenuIconWidth, height: 24)
                        .contentShape(Rectangle())
                }
                .menuIndicator(.hidden)
                .menuStyle(.borderlessButton)
                .accessibilityLabel("\(placeholder) presets")
                .padding(.trailing, 4)
            }
    }
}

/// Vendor selection as a native pop-up button: full-width hit area,
/// system chevron, keyboard and VoiceOver support (HIG entering-data.md —
/// offer choices instead of requiring text entry).
struct VendorMenuField: View {
    let placeholder: String
    @Binding var selection: UUID?
    let vendors: [Vendor]
    let clients: [ClientConfig]

    var body: some View {
        Picker(placeholder, selection: $selection) {
            Text("None").tag(UUID?.none)
            ForEach(vendors) { vendor in
                Text(vendorPickerLabel(vendor: vendor, clients: clients))
                    .tag(UUID?.some(vendor.id))
            }
        }
        .pickerStyle(.menu)
    }
}

func vendorPickerLabel(vendor: Vendor, clients: [ClientConfig]) -> String {
    guard let clientID = vendor.compatibleClientID,
          let client = clients.first(where: { $0.id == clientID }) else {
        return vendor.name
    }
    return "\(vendor.name) (\(client.clientName) only)"
}

let vendorSelectionMenuIconWidth: CGFloat = 24
