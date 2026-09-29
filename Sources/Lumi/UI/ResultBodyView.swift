import SwiftUI

/// The focused service's answer, and nothing else.
///
/// There is deliberately no header here: the chip in the rail *is* the header.
/// The old per-card title row cost 22pt and an icon set per service, repeated
/// for every backend the user had switched on.
struct ResultBodyView: View {
    let card: ResultCard
    var scale: CGFloat = 1

    var body: some View {
        switch card.status {
        case .waiting:
            ShimmerLines()
        case .streaming, .done:
            if let entry = card.entry {
                DictionaryEntryView(entry: entry, scale: scale)
            } else if card.text.isEmpty {
                ShimmerLines()
            } else {
                Text(rendered(card.text))
                    .font(.system(size: 14 * scale))
                    .lineSpacing(3 * scale)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .animation(Motion.stream, value: card.text)
            }
        case .empty(let why):
            statusLine("text.magnifyingglass", why, .secondary)
        case .offline:
            statusLine("wifi.slash", "离线不可用", .secondary)
        case .needsSetup(let message):
            statusLine("gearshape", message, .secondary)
        case .failed(let message):
            statusLine("exclamationmark.triangle", message, .orange)
        }
    }

    private func statusLine(_ symbol: String, _ message: String, _ tint: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol).font(.system(size: 11))
            Text(message).font(.system(size: 12.5))
        }
        .foregroundStyle(tint)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// LLM providers answer in Markdown; the plain ones answer in plain text.
    /// Parsing both through the same path keeps every service looking alike.
    private func rendered(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
    }
}

/// Placeholder shown between "request sent" and "first token" — motion here
/// tells the user the app is alive, which is exactly what a frozen app cannot do.
struct ShimmerLines: View {
    @Stored private var phase: CGFloat = -1

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            bar(width: 0.9)
            bar(width: 0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            withAnimation(.linear(duration: 1.3).repeatForever(autoreverses: false)) {
                phase = 2
            }
        }
    }

    private func bar(width: CGFloat) -> some View {
        GeometryReader { geometry in
            Capsule()
                .fill(.quaternary)
                .overlay {
                    LinearGradient(
                        colors: [.clear, .primary.opacity(0.18), .clear],
                        startPoint: .leading, endPoint: .trailing
                    )
                    .offset(x: phase * geometry.size.width)
                }
                .clipShape(.capsule)
                .frame(width: geometry.size.width * width)
        }
        .frame(height: 9)
    }
}
