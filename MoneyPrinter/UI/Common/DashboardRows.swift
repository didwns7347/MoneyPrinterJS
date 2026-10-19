import SwiftUI

struct MetricRow: View {
    let title: String
    var subtitle: String? = nil
    let value: String
    var tone: Double?

    var body: some View {
        LabeledContent {
            Text(value)
                .font(Theme.metricFont)
                .foregroundStyle(QuoteTone.color(tone))
                .monospacedDigit()
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .foregroundStyle(Theme.foreground)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(Theme.muted)
                }
            }
        }
        .listRowBackground(Theme.card)
    }
}

struct ErrorSection: View {
    let message: String?

    var body: some View {
        if let message {
            Section {
                Text(message)
                    .foregroundStyle(Theme.danger)
            }
            .listRowBackground(Theme.card)
        }
    }
}

struct RefreshToolbarButton: ToolbarContent {
    let isLoading: Bool
    let action: () async -> Void

    var body: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button("새로고침", systemImage: "arrow.clockwise") {
                Task { await action() }
            }
            .disabled(isLoading)
        }
    }
}
