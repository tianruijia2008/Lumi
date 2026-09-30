import SwiftUI

/// The row of service chips under the input.
///
/// This replaces the stack of per-service cards, and the reason is height: with
/// four services enabled the old layout drew four headers, four icon sets, and
/// grew the window every time a slow backend arrived. Here every service still
/// runs, but only one answer occupies the body — so the panel's height stops
/// depending on how many services are switched on, and a late arrival lights a
/// dot instead of shoving the text the user is reading.
struct ServiceRail: View {
    let cards: [ResultCard]
    let focused: ServiceKind?
    let onSelect: (ServiceKind) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(cards) { card in
                    chip(card)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 1)
        }
        .scrollIndicators(.never)
        .scrollBounceBehavior(.basedOnSize)
        // A horizontal ScrollView has no intrinsic height, and the panel sizes
        // itself to its content — without this the rail collapses to nothing.
        .frame(height: 26)
    }

    private func chip(_ card: ResultCard) -> some View {
        let isFocused = card.id == focused
        return Button { onSelect(card.id) } label: {
            HStack(spacing: 5) {
                Image(systemName: card.symbol)
                    .font(.system(size: 10, weight: .semibold))
                Text(card.title)
                    .font(Chrome.chipFont)
                    .lineLimit(1)
                StatusDot(status: card.status)
            }
            .foregroundStyle(card.answered ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .chipShell(active: isFocused)
        }
        .buttonStyle(.plain)
        .help(card.reason)
        .animation(Motion.tap, value: isFocused)
    }
}

private extension ResultCard {
    /// Chips for services that could not answer stay in place but recede —
    /// they are still the only way to retry one.
    var answered: Bool {
        switch status {
        case .empty, .offline, .failed, .needsSetup: false
        default: true
        }
    }
}

/// Five states in five pixels: the rail's whole job is to report progress
/// without moving anything.
struct StatusDot: View {
    let status: ResultCard.Status
    @Stored private var pulsing = false

    var body: some View {
        Circle()
            .fill(tint)
            .frame(width: 5, height: 5)
            .opacity(isStreaming && pulsing ? 0.3 : 1)
            .animation(
                isStreaming
                    ? .easeInOut(duration: 0.65).repeatForever(autoreverses: true)
                    : Motion.tap,
                value: pulsing
            )
            .onAppear { pulsing = isStreaming }
            .onChange(of: isStreaming) { _, streaming in pulsing = streaming }
    }

    private var isStreaming: Bool { status == .streaming }

    private var tint: Color {
        switch status {
        case .waiting:          .secondary.opacity(0.4)
        case .streaming:        .accentColor
        case .done:             .green
        case .empty, .offline:  .secondary.opacity(0.45)
        case .needsSetup:       .orange.opacity(0.7)
        case .failed:           .orange
        }
    }
}
