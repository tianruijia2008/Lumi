import SwiftUI

/// Lays out a parsed dictionary entry.
///
/// A definition has real structure — headword, reading, register label,
/// part-of-speech blocks, ordered senses, examples, trailing usage notes — and
/// printing it as one paragraph throws all of that away. Each part gets
/// typography that matches its job: the headword carries the size, the reading
/// stays quiet beside it, sense numbers form a scannable left rail, and
/// examples sit behind a rule so the eye can skip them.
struct DictionaryEntryView: View {
    let entry: DictionaryEntry
    let scale: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 9 * scale) {
            header
            if let lead = entry.lead, !lead.isEmpty { leadLabel(lead) }
            ForEach(entry.groups) { groupBlock($0) }
            ForEach(entry.notes) { noteBlock($0) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Header

    /// Reading beside the headword when both fit, stacked when they don't —
    /// English IPA with both BrE and AmE variants is easily wider than the card.
    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 8 * scale) {
                headwordText
                pronunciationText
            }
            VStack(alignment: .leading, spacing: 2 * scale) {
                headwordText
                pronunciationText
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var headwordText: some View {
        Text(entry.headword)
            .font(.system(size: 21 * scale, weight: .semibold))
            .textSelection(.enabled)
    }

    @ViewBuilder
    private var pronunciationText: some View {
        if let pronunciation = entry.pronunciation {
            Text(pronunciation)
                .font(.system(size: 12 * scale, design: .serif))
                .italic()
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Usually a register label — "noun formal" — so it is set small and
    /// quiet. But in an entry with no senses and no notes there is nothing else
    /// on the card, which means the lead *is* the definition and has to be
    /// readable as body text.
    private func leadLabel(_ text: String) -> some View {
        let isDefinition = !entry.isStructured
        return Text(text)
            .font(.system(size: isDefinition ? 13.5 * scale : 11.5 * scale,
                          weight: isDefinition ? .regular : .medium))
            .foregroundStyle(isDefinition ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Part-of-speech blocks

    @ViewBuilder
    private func groupBlock(_ group: DictionaryEntry.Group) -> some View {
        VStack(alignment: .leading, spacing: 6 * scale) {
            if let label = group.label { groupLabel(label) }
            if let body = group.body, !body.isEmpty {
                // With no senses under it the block's own text *is* the
                // definition; with senses it is an inflection note about them.
                Text(body)
                    .font(.system(size: group.senses.isEmpty ? 13.5 * scale : 11.5 * scale))
                    .foregroundStyle(group.senses.isEmpty
                        ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(group.senses) { senseRow($0) }
        }
    }

    /// A label plus a rule running to the edge. The blocks are the entry's
    /// coarsest division, so they need to read as a break rather than as one
    /// more line of text.
    private func groupLabel(_ label: String) -> some View {
        HStack(spacing: 6 * scale) {
            Text(label)
                .font(.system(size: 10.5 * scale, weight: .semibold))
                .foregroundStyle(.tint)
                .fixedSize()
            Rectangle()
                .frame(height: 1)
                .foregroundStyle(.quaternary)
        }
    }

    // MARK: Senses

    private func senseRow(_ sense: DictionaryEntry.Sense) -> some View {
        VStack(alignment: .leading, spacing: 3 * scale) {
            HStack(alignment: .firstTextBaseline, spacing: 6 * scale) {
                // A fixed-width rail keeps the definitions aligned no matter
                // how wide the marker glyph renders.
                Text(sense.marker)
                    .font(.system(size: 12.5 * scale, weight: .semibold))
                    .foregroundStyle(.tint)
                    .frame(width: 16 * scale, alignment: .leading)

                if let pos = sense.partOfSpeech {
                    Text(pos)
                        .font(.system(size: 10 * scale, weight: .semibold))
                        .padding(.horizontal, 4 * scale)
                        .padding(.vertical, 1.5 * scale)
                        .background(.quaternary, in: .rect(cornerRadius: 4))
                        .foregroundStyle(.secondary)
                }

                Text(sense.text)
                    .font(.system(size: 13.5 * scale))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !sense.examples.isEmpty {
                VStack(alignment: .leading, spacing: 2 * scale) {
                    ForEach(Array(sense.examples.enumerated()), id: \.offset) { _, example in
                        Text(example)
                            .font(.system(size: 12 * scale))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.leading, 8 * scale)
                .overlay(alignment: .leading) {
                    // A rule rather than a bullet: examples are skimmable
                    // support, and a column of ▸ competes with the sense rail.
                    Rectangle()
                        .frame(width: 1.5)
                        .foregroundStyle(.quaternary)
                }
                .padding(.leading, 22 * scale)
            }
        }
    }

    // MARK: Notes

    private func noteBlock(_ note: DictionaryEntry.Note) -> some View {
        VStack(alignment: .leading, spacing: 3 * scale) {
            Text(note.title)
                .font(.system(size: 10.5 * scale, weight: .bold))
                .foregroundStyle(.secondary)
            Text(note.body)
                .font(.system(size: 12 * scale))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 2 * scale)
    }
}
