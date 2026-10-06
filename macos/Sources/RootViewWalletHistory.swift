import SwiftUI

extension RootView {
    func paidRouteWalletHistory(_ history: NativePaidRouteWalletHistoryState) -> some View {
        DisclosureGroup("Transaction history", isExpanded: $paidRouteWalletHistoryExpanded) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Recent wallet activity on this device")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        manager.refreshPaidRouteWalletHistory()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("Refresh transaction history")
                    .disabled(manager.actionInFlight)
                }
                if !history.error.isEmpty {
                    Text(history.error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
                if !history.loaded && history.error.isEmpty {
                    ProgressView("Loading history…")
                        .controlSize(.small)
                } else if history.loaded && history.entries.isEmpty {
                    Text("No transactions yet")
                        .foregroundStyle(.secondary)
                }
                LazyVStack(spacing: 0) {
                    ForEach(history.entries, id: \.id) { entry in
                        walletHistoryRow(entry)
                        if entry.id != history.entries.last?.id {
                            Divider()
                        }
                    }
                }
            }
            .padding(.top, 8)
        }
        .disabled(manager.actionInFlight)
        .onChange(of: paidRouteWalletHistoryExpanded) { _, expanded in
            if expanded { manager.refreshPaidRouteWalletHistory() }
        }
    }

    private func walletHistoryRow(_ entry: NativePaidRouteWalletActivityState) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(walletHistoryTitle(entry.kind))
                    Text(walletHistoryStatus(entry.status))
                        .font(.caption)
                        .foregroundStyle(entry.status == "pending" ? Color.orange : Color.secondary)
                }
                Text(entry.mintUrl)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(entry.mintUrl)
                Text(Date(timeIntervalSince1970: TimeInterval(entry.createdAtUnix)), format: .dateTime.month(.abbreviated).day().year().hour().minute())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 4) {
                Text("\(entry.amountSat) sat")
                    .monospacedDigit()
                if entry.feeSat > 0 {
                    Text("Fee: \(entry.feeSat) sat")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 10)
    }

    private func walletHistoryTitle(_ kind: String) -> String {
        switch kind {
        case "top_up": return "Lightning receive"
        case "lightning_payment": return "Lightning payment"
        case "token_send": return "Token sent"
        case "token_receive": return "Token received"
        case "channel_collect": return "Channel collection"
        default: return "Transaction"
        }
    }

    private func walletHistoryStatus(_ status: String) -> String {
        switch status {
        case "pending": return "Pending"
        case "complete": return "Completed"
        case "reclaimed": return "Reclaimed"
        case "expired": return "Expired"
        default: return status.capitalized
        }
    }
}
