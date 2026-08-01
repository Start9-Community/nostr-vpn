import SwiftUI

struct ExitDnsSettingsCard: View {
    private enum FocusedField: Hashable {
        case customUrl
        case bootstrapIps
        case throughExitServers
    }

    @ObservedObject var model: AppModel
    @State private var mode = "automatic"
    @State private var provider = "cloudflare"
    @State private var customUrl = ""
    @State private var bootstrapIps = ""
    @State private var throughExitServers = ""
    @State private var lastSyncedRev: UInt64?
    @State private var hasUnsavedChanges = false
    @State private var saveAcknowledgement = ""
    @FocusState private var focusedField: FocusedField?

    private var validationError: String? {
        if mode == "encrypted" && provider == "custom" {
            let normalizedUrl = customUrl.trimmingCharacters(in: .whitespacesAndNewlines)
            if normalizedUrl.isEmpty {
                return "Enter an HTTPS DoH URL."
            }
            if !normalizedUrl.lowercased().hasPrefix("https://") {
                return "DoH URL must use HTTPS."
            }
            if bootstrapIps.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "Enter at least one bootstrap IP."
            }
        }
        if mode == "through_exit"
            && throughExitServers.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Enter at least one DNS server IP."
        }
        return nil
    }

    var body: some View {
        AppCard {
            Text("Exit DNS")
                .font(.headline)
            Text("MagicDNS stays local. Public DNS follows this policy while an internet exit is active.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Picker("Mode", selection: Binding(
                get: { mode },
                set: {
                    focusedField = nil
                    mode = $0
                    markUnsaved()
                }
            )) {
                Text("Automatic (recommended)").tag("automatic")
                    .accessibilityIdentifier("exit-dns-mode-automatic")
                Text("Encrypted DNS").tag("encrypted")
                    .accessibilityIdentifier("exit-dns-mode-encrypted")
                Text("DNS through exit").tag("through_exit")
                    .accessibilityIdentifier("exit-dns-mode-through-exit")
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("exit-dns-mode-picker")

            if mode == "encrypted" {
                Picker("Provider", selection: Binding(
                    get: { provider },
                    set: {
                        focusedField = nil
                        provider = $0
                        markUnsaved()
                    }
                )) {
                    Text("Cloudflare").tag("cloudflare")
                        .accessibilityIdentifier("exit-dns-provider-cloudflare")
                    Text("Quad9").tag("quad9")
                        .accessibilityIdentifier("exit-dns-provider-quad9")
                    Text("Custom DoH").tag("custom")
                        .accessibilityIdentifier("exit-dns-provider-custom")
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("exit-dns-provider-picker")
                if provider == "custom" {
                    TextField("https://dns.example/dns-query", text: Binding(
                        get: { customUrl },
                        set: {
                            customUrl = $0
                            markUnsaved()
                        }
                    ))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focusedField, equals: .customUrl)
                        .submitLabel(.done)
                        .onSubmit { focusedField = nil }
                        .accessibilityIdentifier("exit-dns-custom-url")
                    TextField("Bootstrap IPs (comma separated)", text: Binding(
                        get: { bootstrapIps },
                        set: {
                            bootstrapIps = $0
                            markUnsaved()
                        }
                    ))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focusedField, equals: .bootstrapIps)
                        .submitLabel(.done)
                        .onSubmit { focusedField = nil }
                        .accessibilityIdentifier("exit-dns-custom-bootstrap-ips")
                }
            } else if mode == "through_exit" {
                TextField("DNS server IPs (comma separated)", text: Binding(
                    get: { throughExitServers },
                    set: {
                        throughExitServers = $0
                        markUnsaved()
                    }
                ))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focusedField, equals: .throughExitServers)
                    .submitLabel(.done)
                    .onSubmit { focusedField = nil }
                    .accessibilityIdentifier("exit-dns-through-exit-servers")
                Text("These DNS packets are sent only through the selected exit.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Text("Uses the WireGuard profile DNS when present; otherwise uses Cloudflare encrypted DNS.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Text("The selected DNS operator can receive your DNS queries and ordinary connection metadata under its own policy. Sirius Business Oy does not operate these resolvers.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            if let validationError {
                Text(validationError)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("exit-dns-validation-error")
            }

            Button("Save Exit DNS") {
                let patch: [String: Any] = [
                    "exitDnsMode": mode,
                    "exitDnsDohProvider": provider,
                    "exitDnsCustomDohUrl": customUrl,
                    "exitDnsCustomDohBootstrapIps": bootstrapIps,
                    "exitDnsThroughExitServers": throughExitServers,
                ]
                focusedField = nil
                if model.dispatch(NativeActions.updateSettings(patch), status: "Saving DNS") {
                    hasUnsavedChanges = false
                    syncFromState(force: true)
                    saveAcknowledgement = "Exit DNS saved"
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.actionInFlight || validationError != nil)
            .accessibilityIdentifier("exit-dns-save")

            if !saveAcknowledgement.isEmpty {
                Text(saveAcknowledgement)
                    .font(.footnote)
                    .foregroundStyle(.green)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("exit-dns-save-acknowledgement")
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") {
                    focusedField = nil
                }
                .accessibilityIdentifier("exit-dns-keyboard-done")
            }
        }
        .onAppear { syncFromState(force: true) }
        .onChange(of: model.state.rev) { _, _ in syncFromState() }
    }

    private func markUnsaved() {
        hasUnsavedChanges = true
        saveAcknowledgement = ""
    }

    private func syncFromState(force: Bool = false) {
        guard !hasUnsavedChanges else { return }
        guard force || lastSyncedRev != model.state.rev else { return }
        mode = model.state.exitDnsMode
        provider = model.state.exitDnsDohProvider
        customUrl = model.state.exitDnsCustomDohUrl
        bootstrapIps = model.state.exitDnsCustomDohBootstrapIps
        throughExitServers = model.state.exitDnsThroughExitServers
        lastSyncedRev = model.state.rev
    }
}
