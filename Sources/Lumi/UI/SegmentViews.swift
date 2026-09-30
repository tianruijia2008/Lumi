import SwiftUI

/// What a row can ask its document to do. Closures rather than the document
/// itself, so a row re-renders when its own segment changes and not when
/// any of the other forty do.
struct SegmentActions {
    let retranslate: () -> Void
    let review: () -> Void
    let accept: (UUID) -> Void
    let undo: (UUID) -> Void
    let dismiss: (UUID) -> Void
    let restoreDismissed: () -> Void
    let edit: (String) -> Void
    /// Pairing repairs, for a translation brought in from elsewhere.
    let insertGap: () -> Void
    let pullNext: () -> Void
}

extension ProofIssue.Severity {
    var tint: Color {
        switch self {
        case .serious: .red
        case .warning: .orange
        case .minor: .blue
        }
    }
}

// MARK: - One aligned segment

/// Source and translation, with a gutter between them and the page edge.
///
/// The gutter is what replaced the old design's full-height dividers. Ruling
/// every row top to bottom turned the paper into a spreadsheet; a numbered
/// margin does the same separating job, gives every segment an address to be
/// referred to by, and — the part that earns it — collects all the status in
/// one narrow strip, so finding the two suspect paragraphs in a long document
/// is a glance down one column instead of a hunt through tinted blocks.
struct SegmentRow: View {
    let segment: WorkbenchDocument.Segment
    let number: Int
    let scale: CGFloat
    let target: Language
    let markdown: Bool
    let proof: Bool
    let actions: SegmentActions

    @Stored private var hovering = false
    @Stored private var editing = false
    @Stored private var draft = ""
    @FocusState private var editorFocused: Bool

    private var open: [ProofIssue] {
        segment.openIssues.sorted { $0.kind.severity > $1.kind.severity }
    }
    private var worst: ProofIssue.Severity? { open.map(\.kind.severity).max() }

    var body: some View {
        Group {
            if segment.block.isVerbatim { verbatimRow } else { alignedRow }
        }
        .padding(.vertical, verticalPadding)
        .fixedSize(horizontal: false, vertical: true)
        .background(hovering && !editing ? Chrome.hover : .clear)
        .overlay(alignment: .leading) { flag }
        .overlay(alignment: .bottom) {
            if !segment.block.isHeading {
                Rectangle().fill(Chrome.rule).frame(height: 1).padding(.leading, 44)
            }
        }
        .onHover { hovering = $0 }
        .animation(Motion.tap, value: hovering)
        .animation(Motion.settle, value: segment.issues)
        .animation(Motion.settle, value: editing)
    }

    /// A heading is a pause in the page, not another paragraph: more air
    /// above, no rule under.
    private var verticalPadding: CGFloat {
        if case .heading(let level) = segment.block { return level <= 2 ? 16 : 12 }
        if segment.block.isListItem { return 8 }
        return 13
    }

    private var alignedRow: some View {
        HStack(alignment: .top, spacing: 0) {
            gutter
            sourceColumn
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(.trailing, 20)
            translationColumn
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(.leading, 20)
            marginMark
                .frame(width: 26, alignment: .top)
                .padding(.top, headingNudge)
        }
    }

    /// Code, maths, an image: shown once, across both columns. Printing the
    /// same code block twice side by side would double its length and say
    /// nothing the reader does not already know.
    private var verbatimRow: some View {
        HStack(alignment: .top, spacing: 0) {
            gutter
            VerbatimBlock(block: segment.block,
                          text: segment.source.isEmpty ? segment.translation : segment.source,
                          scale: scale)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(.trailing, 22)
        }
    }

    @ViewBuilder
    private var sourceColumn: some View {
        if segment.source.isEmpty {
            Text("原文里没有这一段")
                .font(.system(size: 12 * scale))
                .italic()
                .foregroundStyle(.tertiary)
        } else {
            BlockText(
                text: segment.source, block: segment.block, markdown: markdown, scale: scale,
                secondary: true,
                highlights: open.compactMap { issue in
                    issue.sourceQuote.isEmpty ? nil
                        : Highlight(text: issue.sourceQuote, tint: issue.kind.severity.tint, strong: false)
                }
            )
        }
    }

    /// The number, and on hover the things you can do to this one segment.
    /// They swap rather than sit side by side: at 44pt there is room for one,
    /// and a permanent row of icons down a page of prose is unreadable.
    private var gutter: some View {
        ZStack(alignment: .top) {
            VStack(spacing: 3) {
                Text("\(number)")
                    .font(.system(size: 10.5, weight: .medium, design: .rounded))
                    .foregroundStyle(numberTint)
                    .monospacedDigit()
                if segment.review == .done, open.isEmpty, !segment.block.isVerbatim {
                    Image(systemName: "checkmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.green.opacity(0.8))
                        .help("校对过，没有待改")
                }
            }
            .frame(width: 44, alignment: .center)
            .padding(.top, 2 * scale + headingNudge)
            .opacity(hovering ? 0 : 1)

            if hovering {
                SegmentMenu(segment: segment, target: target, proof: proof,
                            actions: actions, edit: beginEditing)
                    .frame(width: 44)
                    .padding(.top, headingNudge)
                    .transition(.opacity)
            }
        }
    }

    private var headingNudge: CGFloat {
        if case .heading(let level) = segment.block { return level <= 2 ? 4 * scale : 2 * scale }
        return 0
    }

    /// A 2pt bar in the margin, and only for the states that need finding.
    /// Tinting the whole row — the previous design — made a long document a
    /// heat map and buried the one state worth crossing the room for.
    @ViewBuilder
    private var flag: some View {
        switch segment.status {
        case .dropped: Rectangle().fill(.orange).frame(width: 2)
        case .failed:  Rectangle().fill(.red).frame(width: 2)
        default:
            if let worst { Rectangle().fill(worst.tint).frame(width: 2) }
            else if case .failed = segment.review { Rectangle().fill(.red).frame(width: 2) }
        }
    }

    private var numberTint: AnyShapeStyle {
        switch segment.status {
        case .dropped:          return AnyShapeStyle(.orange)
        case .failed:           return AnyShapeStyle(.red)
        case .pending, .running: return AnyShapeStyle(.quaternary)
        case .done:
            if let worst { return AnyShapeStyle(worst.tint) }
            return AnyShapeStyle(.tertiary)
        }
    }

    // MARK: Translation

    @ViewBuilder
    private var translationColumn: some View {
        if editing {
            editor
        } else {
            VStack(alignment: .leading, spacing: 8) {
                translationBody
                reviewStatus
                if !open.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(open) { issue in
                            IssueCard(issue: issue, scale: scale, markdown: markdown,
                                      applicable: issue.canApply && segment.translation.contains(issue.quote),
                                      accept: { actions.accept(issue.id) },
                                      dismiss: { actions.dismiss(issue.id) })
                                .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }
                }
                handled
            }
        }
    }

    @ViewBuilder
    private var translationBody: some View {
        switch segment.status {
        case .pending:
            // Nothing. "待翻译" printed down forty rows is forty lines of noise
            // saying what the empty column and the dimmed number already say.
            Color.clear.frame(height: 1)
        case .running:
            // The panel's own waiting state. Same shimmer, same meaning: the
            // request is out and the tokens have not landed.
            ShimmerLines().padding(.trailing, 40)
        case .done:
            if segment.translation.isEmpty {
                Text(proof ? "译文里没有这一段" : "没有译文")
                    .font(.system(size: 12 * scale))
                    .italic()
                    .foregroundStyle(.tertiary)
            } else {
                translated
            }
        case .dropped(let why):
            // The translation stays visible. A segment flagged for losing one
            // number is still mostly right, and hiding it would cost the reader
            // far more than the flag saves them — the flag exists to stop them
            // trusting it blindly, not to stop them reading it.
            VStack(alignment: .leading, spacing: 7) {
                if !segment.translation.isEmpty { translated }
                note(why, tint: .orange, action: "重译", perform: actions.retranslate)
            }
        case .failed(let reason):
            note(reason, tint: .red, action: "重试", perform: actions.retranslate)
        }
    }

    private var translated: some View {
        BlockText(
            text: segment.translation, block: segment.block, markdown: markdown, scale: scale,
            secondary: false,
            highlights: open.compactMap { issue in
                issue.quote.isEmpty ? nil : Highlight(text: issue.quote, tint: issue.kind.severity.tint, strong: true)
            }
        )
    }

    /// In the right margin: a pencil while the pointer is on the row, a
    /// quiet 已改 once the reader has changed the text. Editing is the most
    /// common thing a proofreader does, too common to hide in a menu.
    @ViewBuilder
    private var marginMark: some View {
        if hovering, !editing, !segment.block.isVerbatim, segment.status != .running,
           segment.status != .pending || proof {
            Button(action: beginEditing) {
                Image(systemName: "pencil")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help("编辑这一段译文")
            .accessibilityLabel("编辑译文")
            .transition(.opacity)
        } else if segment.edited, !editing {
            Text("已改")
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(.tertiary)
                .frame(width: 20, height: 20)
                .help("这一段的译文改过")
        }
    }

    @ViewBuilder
    private var reviewStatus: some View {
        switch segment.review {
        case .running:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("审读中…").font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            .transition(.opacity)
        case .failed(let why):
            note("没校对成：\(why)", tint: .red, action: "重试", perform: actions.review)
        case .none, .done:
            EmptyView()
        }
    }

    /// Accepted suggestions stay visible, dimmed, with a way back — a change
    /// the reader cannot see having made is one they cannot trust.
    @ViewBuilder
    private var handled: some View {
        let accepted = segment.issues.filter { $0.state == .accepted }
        let dismissed = segment.issues.count { $0.state == .dismissed }
        if !accepted.isEmpty || dismissed > 0 {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(accepted) { issue in
                    HStack(spacing: 5) {
                        Image(systemName: "checkmark").font(.system(size: 8.5, weight: .bold))
                        Text("已采纳 · 「\(issue.replaced ?? issue.quote)」→「\(issue.suggestion ?? "")」")
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("撤销") { actions.undo(issue.id) }
                            .buttonStyle(.plain)
                            .foregroundStyle(Color.accentColor)
                    }
                }
                if dismissed > 0 {
                    HStack(spacing: 5) {
                        Text("已忽略 \(dismissed) 条")
                        Button("恢复", action: actions.restoreDismissed)
                            .buttonStyle(.plain)
                            .foregroundStyle(Color.accentColor)
                    }
                }
            }
            .font(.system(size: 10.5))
            .foregroundStyle(.tertiary)
        }
    }

    private func note(_ text: String, tint: Color, action: String,
                      perform: @escaping () -> Void) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 9))
            Text(text)
            Button(action, action: perform)
                .buttonStyle(.plain)
                .underline()
        }
        .font(.system(size: 11))
        .foregroundStyle(tint)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Editing

    private func beginEditing() {
        draft = segment.translation
        editing = true
        editorFocused = true
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextEditor(text: $draft)
                .font(.system(size: 13 * scale))
                .lineSpacing(4 * scale)
                .scrollContentBackground(.hidden)
                .writingToolsBehavior(.disabled)
                .focused($editorFocused)
                .frame(minHeight: 64)
                .padding(6)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(.rect(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor.opacity(0.5), lineWidth: 1)
                }
                .onKeyPress(.escape) {
                    editing = false
                    return .handled
                }
            HStack(spacing: 8) {
                ActionChip(title: "完成", symbol: "checkmark", prominent: true) {
                    actions.edit(draft)
                    editing = false
                }
                ActionChip(title: "取消", symbol: "xmark", prominent: false) { editing = false }
                Text("Esc 取消").font(.system(size: 10.5)).foregroundStyle(.tertiary)
            }
        }
    }
}

/// Per-segment actions, in the margin, on hover.
private struct SegmentMenu: View {
    let segment: WorkbenchDocument.Segment
    let target: Language
    let proof: Bool
    let actions: SegmentActions
    let edit: () -> Void

    var body: some View {
        Menu {
            Button("复制译文") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(segment.translation, forType: .string)
            }
            .disabled(segment.translation.isEmpty)
            Button("朗读译文") {
                guard !segment.translation.isEmpty else { return }
                Speaker.shared.speak(Markdown.plainText(segment.translation), language: target)
            }
            .disabled(segment.translation.isEmpty)
            if !segment.block.isVerbatim {
                Button("编辑译文…", action: edit)
                    .disabled(segment.status == .running)
                Divider()
                Button("重新校对这一段", action: actions.review)
                    .disabled(segment.translation.isEmpty || segment.source.isEmpty)
                Button(proof ? "用引擎重译这一段" : "重译这一段", action: actions.retranslate)
                    .disabled(segment.source.isEmpty)
                if segment.issues.contains(where: { $0.state == .dismissed }) {
                    Button("恢复已忽略的意见", action: actions.restoreDismissed)
                }
                if proof {
                    Divider()
                    Section("对错了段落？") {
                        Button("这里空出一段（译文整体下移）", action: actions.insertGap)
                        Button("把下一段译文并进来", action: actions.pullNext)
                    }
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 11, weight: .medium))
                .frame(width: 22, height: 22)
                .contentShape(.rect)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .foregroundStyle(.secondary)
        .fixedSize()
    }
}

// MARK: - One review note

/// A note, the words it is about, and what to do with it.
///
/// Laid out like an editor's margin note rather than a warning: the kind in
/// a small tinted tag, the correction as struck-out text becoming new text,
/// the reason underneath in plain words. Accepting it is one click, because
/// a proofread that costs a retype per note does not get finished.
private struct IssueCard: View {
    let issue: ProofIssue
    let scale: CGFloat
    /// Quotes keep their syntax so accepting can find them in the
    /// translation; the card shows what the reader sees instead of `**2,100**`.
    let markdown: Bool
    let applicable: Bool
    let accept: () -> Void
    let dismiss: () -> Void

    @Stored private var hovering = false

    var body: some View {
        let tint = issue.kind.severity.tint
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(issue.kind.label)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(tint)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1.5)
                    .background { Capsule().fill(tint.opacity(0.12)) }
                    .fixedSize()
                change
                Spacer(minLength: 6)
                buttons
            }
            Text(issue.note)
                .font(.system(size: 11.5 * scale))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if let origin = issue.origin.label {
                Text(origin)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(tint.opacity(hovering ? 0.075 : 0.05), in: .rect(cornerRadius: 8))
        .overlay(alignment: .leading) {
            UnevenRoundedRectangle(topLeadingRadius: 8, bottomLeadingRadius: 8)
                .fill(tint.opacity(0.6))
                .frame(width: 2)
        }
        .onHover { hovering = $0 }
        .animation(Motion.tap, value: hovering)
    }

    @ViewBuilder
    private var change: some View {
        if !issue.quote.isEmpty, let suggestion = issue.suggestion {
            (Text(shown(issue.quote)).strikethrough(color: .secondary).foregroundStyle(.secondary)
             + Text("  →  ").foregroundStyle(.tertiary)
             + Text(shown(suggestion)).foregroundStyle(.primary))
                .font(.system(size: 12 * scale))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        } else if let suggestion = issue.suggestion {
            (Text("建议  ").foregroundStyle(.tertiary) + Text(shown(suggestion)))
                .font(.system(size: 12 * scale))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        } else if !issue.quote.isEmpty {
            Text("「\(shown(issue.quote))」")
                .font(.system(size: 12 * scale))
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }

    private func shown(_ text: String) -> String {
        markdown ? Markdown.plainText(text) : text
    }

    private var buttons: some View {
        HStack(spacing: 10) {
            if applicable {
                Button(action: accept) {
                    Text("采纳").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
                .help("用建议替换译文里的这几个字")
            }
            Button(action: dismiss) {
                Text("忽略").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("这条不算问题")
        }
        .fixedSize()
    }
}

// MARK: - Text with its structure

struct Highlight: Hashable {
    let text: String
    let tint: Color
    /// Translation spans are marked; the source spans they answer to are
    /// only underlined, so the eye lands on the text to fix.
    let strong: Bool
}

/// A segment's text, drawn as the block it is: a heading as a heading, a
/// list item with its marker, a table as a table.
struct BlockText: View {
    let text: String
    let block: SegmentBlock
    let markdown: Bool
    let scale: CGFloat
    let secondary: Bool
    var highlights: [Highlight] = []

    var body: some View {
        switch block {
        case .heading(let level):
            styled
                .font(.system(size: headingSize(level) * scale, weight: .semibold))
                .lineSpacing(2 * scale)
        case .listItem(let marker, let depth):
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                ListMarker(marker: marker, scale: scale)
                styled.font(.system(size: 13 * scale)).lineSpacing(4 * scale)
            }
            .padding(.leading, CGFloat(depth) * 16 * scale)
        case .quote:
            styled
                .font(.system(size: 13 * scale))
                .lineSpacing(4 * scale)
                .padding(.leading, 12)
                .overlay(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.18)).frame(width: 2.5)
                }
        case .table:
            if let table = Markdown.table(text) {
                TableBlock(table: table, scale: scale, secondary: secondary, highlights: highlights)
            } else {
                styled.font(.system(size: 12 * scale, design: .monospaced))
            }
        default:
            styled.font(.system(size: 13 * scale)).lineSpacing(4 * scale)
        }
    }

    private var styled: some View {
        Text(Self.attributed(text, markdown: markdown, highlights: highlights))
            .foregroundStyle(secondary ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: 19
        case 2: 16.5
        case 3: 14.5
        default: 13.5
        }
    }

    static func attributed(_ text: String, markdown: Bool, highlights: [Highlight]) -> AttributedString {
        var result = markdown ? Markdown.attributed(text) : AttributedString(text)
        for highlight in highlights {
            let candidates = [highlight.text, Markdown.plainText(highlight.text)]
            guard let range = candidates.lazy.compactMap({ result.range(of: $0) }).first else { continue }
            if highlight.strong {
                result[range].backgroundColor = highlight.tint.opacity(0.16)
            }
            result[range].underlineStyle = Text.LineStyle(pattern: highlight.strong ? .solid : .dot,
                                                          color: highlight.tint.opacity(0.8))
        }
        return result
    }
}

private struct ListMarker: View {
    let marker: String
    let scale: CGFloat

    var body: some View {
        Group {
            if marker.hasSuffix("[ ]") {
                Image(systemName: "square").font(.system(size: 11 * scale))
            } else if marker.lowercased().hasSuffix("[x]") {
                Image(systemName: "checkmark.square").font(.system(size: 11 * scale))
            } else if marker.first?.isNumber == true {
                Text(marker).font(.system(size: 12.5 * scale).monospacedDigit())
            } else {
                Text("•").font(.system(size: 13 * scale, weight: .bold))
            }
        }
        .foregroundStyle(.tertiary)
    }
}

private struct TableBlock: View {
    let table: Markdown.Table
    let scale: CGFloat
    let secondary: Bool
    let highlights: [Highlight]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                GridRow {
                    ForEach(Array(table.header.enumerated()), id: \.offset) { _, cell in
                        cellText(cell).font(.system(size: 12 * scale, weight: .semibold))
                    }
                }
                Divider().gridCellUnsizedAxes(.horizontal)
                ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            cellText(cell).font(.system(size: 12 * scale))
                        }
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func cellText(_ cell: String) -> some View {
        Text(BlockText.attributed(cell, markdown: true, highlights: highlights))
            .foregroundStyle(secondary ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
            .textSelection(.enabled)
            .frame(maxWidth: 220, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Blocks that are carried across as they are.
private struct VerbatimBlock: View {
    let block: SegmentBlock
    let text: String
    let scale: CGFloat

    var body: some View {
        switch block {
        case .code(let language):
            VStack(alignment: .leading, spacing: 5) {
                caption(language == "math" ? "公式 · 原样保留" : (language.isEmpty ? "代码 · 不翻译" : "\(language) · 不翻译"))
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(Self.body(ofFence: text))
                        .font(.system(size: 12 * scale, design: .monospaced))
                        .lineSpacing(2.5 * scale)
                        .textSelection(.enabled)
                        .fixedSize()
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.04), in: .rect(cornerRadius: 8))
                .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(Chrome.rule, lineWidth: 1) }
            }
        case .image(let alt, let source):
            HStack(spacing: 8) {
                Image(systemName: "photo").font(.system(size: 12))
                Text(alt.isEmpty ? "图片" : alt).font(.system(size: 12 * scale, weight: .medium))
                Text(source).font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(0.04), in: .rect(cornerRadius: 8))
            .fixedSize(horizontal: false, vertical: true)
        case .rule:
            Rectangle().fill(Color.primary.opacity(0.15)).frame(height: 1).padding(.vertical, 6)
        default:
            VStack(alignment: .leading, spacing: 5) {
                caption("原样保留")
                Text(text)
                    .font(.system(size: 11.5 * scale, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(8)
                    .textSelection(.enabled)
            }
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.system(size: 10, weight: .medium)).foregroundStyle(.tertiary)
    }

    /// The code inside a fence, without the fence.
    static func body(ofFence text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        if let first = lines.first, first.trimmingCharacters(in: .whitespaces).hasPrefix("```")
            || first.trimmingCharacters(in: .whitespaces).hasPrefix("~~~")
            || first.trimmingCharacters(in: .whitespaces) == "$$" {
            lines.removeFirst()
            if let last = lines.last?.trimmingCharacters(in: .whitespaces),
               last.hasPrefix("```") || last.hasPrefix("~~~") || last == "$$" {
                lines.removeLast()
            }
        }
        return lines.joined(separator: "\n")
    }
}
