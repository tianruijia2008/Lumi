import SwiftUI

/// What the 工作台 window is doing.
@MainActor @Observable
final class WorkbenchNavigation {
    enum Mode: Equatable {
        /// The start page: what to begin, and what to pick up again.
        case home
        /// Typing or pasting a text in by hand.
        case compose
        /// A source and someone else's translation, to be proofread.
        case proofCompose
        /// A document, side by side.
        case read
        case etymology
    }
    var mode: Mode = .home

    func go(_ mode: Mode) {
        withAnimation(Motion.settle) { self.mode = mode }
    }
}

/// The 工作台 window: a sidebar that chooses the work, and the work.
///
/// The sidebar is not a fixed menu. With nothing open it is the list of
/// things this window can do and what was done recently; with a word open it
/// becomes that word's table of contents. Same strip, different job — which
/// is what earns it 228pt of every window width.
struct WorkbenchShell: View {
    @Bindable var navigation: WorkbenchNavigation
    @Bindable var document: WorkbenchDocument
    var onTitleChange: (String) -> Void = { _ in }

    @Stored private var etymology = EtymologyStore.shared
    @Stored private var documents = DocumentStore.shared

    var body: some View {
        HStack(spacing: 0) {
            WorkbenchSidebar(navigation: navigation, store: etymology,
                             documents: documents, document: document)
                .frame(width: 228)
                .overlay(alignment: .trailing) {
                    Rectangle().fill(Color.primary.opacity(0.1)).frame(width: 0.5).ignoresSafeArea()
                }

            Group {
                switch navigation.mode {
                case .home:
                    WorkbenchHome(navigation: navigation, document: document,
                                  documents: documents, etymology: etymology)
                        .task { onTitleChange("工作台") }
                case .compose:
                    ComposeView(document: document)
                        .task { onTitleChange("新文稿") }
                case .proofCompose:
                    ProofComposeView(document: document)
                        .task { onTitleChange("校对译文") }
                case .read:
                    if document.isLoaded {
                        WorkbenchView(document: document, onTitleChange: onTitleChange)
                    } else {
                        WorkbenchHome(navigation: navigation, document: document,
                                      documents: documents, etymology: etymology)
                    }
                case .etymology:
                    EtymologyScreen(store: etymology)
                        .task(id: etymologyTitle) { onTitleChange(etymologyTitle) }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background { WindowGlass() }
    }

    private var etymologyTitle: String {
        etymology.current.map { "词源 · \($0.word)" } ?? "词源"
    }
}

/// The window's own material: the same glass the panel is made of.
///
/// Drawn behind everything and out under the title bar, so the traffic lights
/// sit on glass rather than on a grey strip, and the paper pages laid on top
/// read as sheets on one surface.
private struct WindowGlass: View {
    var body: some View {
        Rectangle()
            .fill(.clear)
            .glassEffect(.regular, in: .rect)
            .ignoresSafeArea()
    }
}

// MARK: - Sidebar

private struct WorkbenchSidebar: View {
    @Bindable var navigation: WorkbenchNavigation
    @Bindable var store: EtymologyStore
    @Bindable var documents: DocumentStore
    @Bindable var document: WorkbenchDocument

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if navigation.mode == .etymology, let lookup = store.current {
                WordNavigator(lookup: lookup, store: store)
            } else if navigation.mode == .read, document.isLoaded {
                DocumentNavigator(navigation: navigation, document: document, documents: documents)
            } else {
                modes
            }
            Spacer(minLength: 0)
            SettingsLink {
                Image(systemName: "gearshape")
                    .font(.system(size: 13))
                    .frame(width: 26, height: 26)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("设置")
        }
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .padding(.bottom, 10)
        .frame(maxHeight: .infinity, alignment: .top)
        .animation(Motion.settle, value: store.current?.word)
        .animation(Motion.settle, value: navigation.mode)
    }

    private var modes: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "rectangle.split.2x1")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                Text("工作台").font(.system(size: 13.5, weight: .semibold))
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 20)

            SidebarRow(symbol: "house", title: "开始", selected: navigation.mode == .home) {
                navigation.go(.home)
            }
            .padding(.bottom, 20)

            SidebarGroup(title: "新建")
            SidebarRow(symbol: "rectangle.split.2x1", title: "通读全文",
                       selected: navigation.mode == .compose) {
                navigation.go(.compose)
            }
            .keyboardShortcut("n", modifiers: .command)
            SidebarRow(symbol: "checkmark.seal", title: "校对译文",
                       selected: navigation.mode == .proofCompose) {
                navigation.go(.proofCompose)
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            SidebarRow(symbol: "point.3.connected.trianglepath.dotted", title: "词源",
                       selected: navigation.mode == .etymology) {
                navigation.go(.etymology)
                store.closeWord()
            }
            .keyboardShortcut("e", modifiers: .command)

            if navigation.mode == .etymology {
                if !store.recents.isEmpty {
                    SidebarGroup(title: "最近查过").padding(.top, 20)
                    RecentWords(store: store, highlighted: nil)
                }
            } else if !documents.recents.isEmpty {
                SidebarGroup(title: "最近文稿").padding(.top, 20)
                RecentDocuments(
                    documents: documents,
                    highlighted: navigation.mode == .read ? document.id : nil
                )
            }
        }
    }
}

/// The open document's table of contents: where its headings are, which
/// segments still need a look, and a way back.
///
/// The same strip that lists what the window can do on the start page — the
/// etymology page already turns it into a word's contents, and a forty-page
/// paper needs it more than a word does.
private struct DocumentNavigator: View {
    @Bindable var navigation: WorkbenchNavigation
    @Bindable var document: WorkbenchDocument
    @Bindable var documents: DocumentStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { navigation.go(.home) } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.left").font(.system(size: 9.5, weight: .semibold))
                    Text("开始").font(Chrome.chipFont)
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .padding(.bottom, 12)

            VStack(alignment: .leading, spacing: 6) {
                Text(document.title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                Text(meta)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 18)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    outline
                    attention
                    others
                }
            }
            .scrollIndicators(.never)
        }
    }

    private var meta: String {
        var parts: [String] = []
        if document.isProof { parts.append("校对稿") }
        if document.format == .markdown { parts.append("Markdown") }
        parts.append("\(document.resolvedSource.displayName) → \(document.resolvedTarget.displayName)")
        parts.append("\(document.workSegments.count) 段")
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var outline: some View {
        let headings = document.headings
        if headings.count >= 2 {
            let top = headings.map(\.level).min() ?? 1
            let current = headings.last { $0.id <= document.readingPosition }?.id
            SidebarGroup(title: "大纲")
            ForEach(headings.prefix(80), id: \.id) { heading in
                Button { document.reveal(heading.id) } label: {
                    Text(heading.title)
                        .font(.system(size: 12, weight: heading.level == top ? .medium : .regular))
                        .foregroundStyle(heading.id == current ? AnyShapeStyle(Color.accentColor)
                                         : AnyShapeStyle(heading.level == top ? .primary : .secondary))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 8 + CGFloat(min(heading.level - top, 3)) * 12)
                        .padding(.trailing, 8)
                        .padding(.vertical, 4.5)
                        .background {
                            if heading.id == current {
                                RoundedRectangle(cornerRadius: 7).fill(Chrome.activeFill.opacity(0.5))
                            }
                        }
                        .contentShape(.rect)
                }
                .buttonStyle(SidebarButtonStyle())
            }
            Color.clear.frame(height: 18)
        }
    }

    @ViewBuilder
    private var attention: some View {
        let flagged = document.flaggedIDs
        if !flagged.isEmpty {
            HStack {
                SidebarGroup(title: document.isProof ? "待改" : "待查")
                Spacer()
                Text("\(flagged.count)")
                    .font(.system(size: 10.5))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .padding(.trailing, 9)
                    .padding(.bottom, 6)
            }
            ForEach(flagged.prefix(60), id: \.self) { id in
                if let segment = document.segments.first(where: { $0.id == id }) {
                    Button { document.reveal(id) } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Circle().fill(tint(segment)).frame(width: 6, height: 6)
                            Text("第 \(id + 1) 段")
                                .font(.system(size: 12))
                                .monospacedDigit()
                                .foregroundStyle(.primary)
                            Text(label(segment))
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4.5)
                        .contentShape(.rect)
                    }
                    .buttonStyle(SidebarButtonStyle())
                }
            }
            Color.clear.frame(height: 18)
        }
    }

    @ViewBuilder
    private var others: some View {
        let rest = documents.recents.filter { $0.id != document.id }.prefix(4)
        if !rest.isEmpty {
            SidebarGroup(title: "最近文稿")
            RecentDocuments(documents: documents, highlighted: nil, limit: 4, excluding: document.id)
        }
    }

    private func tint(_ segment: WorkbenchDocument.Segment) -> Color {
        switch segment.status {
        case .failed: return .red
        case .dropped: return .orange
        default: break
        }
        if case .failed = segment.review { return .red }
        return segment.openIssues.map(\.kind.severity).max()?.tint ?? .orange
    }

    private func label(_ segment: WorkbenchDocument.Segment) -> String {
        switch segment.status {
        case .failed: return "没译成"
        case .dropped: return "疑似漏译"
        default: break
        }
        if case .failed = segment.review { return "没校对成" }
        var kinds: [String] = []
        for issue in segment.openIssues where !kinds.contains(issue.kind.label) { kinds.append(issue.kind.label) }
        return kinds.prefix(3).joined(separator: " · ")
    }
}

/// The last few documents, each with how far it got.
private struct RecentDocuments: View {
    @Bindable var documents: DocumentStore
    let highlighted: UUID?
    var limit = 5
    var excluding: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(documents.recents.filter { $0.id != excluding }.prefix(limit)) { summary in
                Button { WorkbenchController.shared.openDocument(summary.id) } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(summary.title)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        HStack(spacing: 7) {
                            ProgressTrack(value: summary.progress, finished: summary.isTranslated)
                                .frame(width: 44, height: 3)
                            DocumentStatusText(summary: summary)
                                .font(.system(size: 10.5))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background {
                        if summary.id == highlighted {
                            RoundedRectangle(cornerRadius: 7).fill(Chrome.activeFill)
                        }
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(SidebarButtonStyle())
                .contextMenu {
                    Button("从最近移除") { documents.remove(summary.id) }
                }
            }
        }
    }
}

/// A word's table of contents, plus a way back and a way sideways.
private struct WordNavigator: View {
    @Bindable var lookup: EtymologyLookup
    @Bindable var store: EtymologyStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { store.closeWord() } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.left").font(.system(size: 9.5, weight: .semibold))
                    Text("词源").font(Chrome.chipFont)
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .padding(.bottom, 12)

            VStack(alignment: .leading, spacing: 6) {
                Text(lookup.word)
                    .font(.system(size: 26, weight: .semibold, design: .serif).italic())
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if let subtitle {
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 20)

            if let entry = lookup.entry {
                SidebarGroup(title: "本页")
                ForEach(sections(entry), id: \.0) { section, title, count in
                    SidebarRow(title: title, count: count) { store.scrollTarget = section }
                }
            }

            if store.recents.count > 1 {
                SidebarGroup(title: "最近查过").padding(.top, 20)
                RecentWords(store: store, highlighted: lookup.word)
            }
        }
    }

    private var subtitle: String? {
        guard let entry = lookup.entry else { return nil }
        let parts = [entry.partOfSpeechLocal, entry.firstCentury.map { "\($0)进入英语" }].compactMap(\.self)
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func sections(_ entry: EtymologyEntry) -> [(EtymologySection, String, String?)] {
        var rows: [(EtymologySection, String, String?)] = [(.narration, "讲解", nil)]
        if !entry.chain.isEmpty || !entry.folk.isEmpty {
            rows.append((.chain, "来历", entry.folk.isEmpty ? "\(entry.chain.count) 步" : "有民间词源"))
        }
        if !entry.senses.isEmpty {
            rows.append((.senses, entry.datedSenses.count >= 2 ? "词义变迁" : "义项", "\(entry.senses.count)"))
        }
        if !entry.quotes.isEmpty { rows.append((.quotes, "引文", "\(entry.quotes.count)")) }
        let kin = entry.kin.reduce(0) { $0 + $1.words.count }
        if kin > 0 { rows.append((.kin, "同根词", "\(kin)")) }
        return rows
    }
}

private struct RecentWords: View {
    @Bindable var store: EtymologyStore
    let highlighted: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(store.recents.prefix(8)) { recent in
                Button { store.open(recent.word) } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(recent.word)
                            .font(.system(size: 14, weight: .medium, design: .serif).italic())
                            .foregroundStyle(.primary)
                        if let hook = recent.hook {
                            Text(hook)
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background {
                        if recent.word == highlighted {
                            RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.07))
                        }
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(SidebarButtonStyle())
            }
        }
    }
}

private struct SidebarGroup: View {
    let title: String
    var body: some View {
        Text(title)
            .font(.system(size: 10, weight: .medium))
            .tracking(0.9)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 9)
            .padding(.bottom, 6)
    }
}

private struct SidebarRow: View {
    var symbol: String?
    let title: String
    var selected = false
    var muted = false
    var tag: String?
    var count: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 12))
                        .frame(width: 16)
                        .foregroundStyle(selected ? AnyShapeStyle(Color.accentColor)
                                                  : AnyShapeStyle(muted ? .tertiary : .secondary))
                }
                Text(title)
                    .font(.system(size: 12.5))
                    .foregroundStyle(selected ? AnyShapeStyle(Color.accentColor)
                                              : AnyShapeStyle(muted ? .tertiary : .primary))
                Spacer(minLength: 4)
                if let tag {
                    Text(tag)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .overlay { Capsule().strokeBorder(Chrome.chipStroke, lineWidth: 1) }
                }
                if let count {
                    Text(count)
                        .font(.system(size: 10.5))
                        .monospacedDigit()
                        .foregroundStyle(count.contains("民间") ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.tertiary))
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background {
                if selected { RoundedRectangle(cornerRadius: 7).fill(Chrome.activeFill) }
            }
            .contentShape(.rect)
        }
        .buttonStyle(SidebarButtonStyle())
    }
}

/// Hover as the only feedback: the row under the pointer lifts a shade.
struct SidebarButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        SidebarButtonBody(configuration: configuration)
    }

    private struct SidebarButtonBody: View {
        let configuration: Configuration
        @Stored private var hovering = false
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            configuration.label
                .background {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Color.primary.opacity(hovering && enabled ? 0.05 : 0))
                }
                .opacity(configuration.isPressed ? 0.7 : 1)
                .onHover { hovering = $0 }
                .animation(Motion.tap, value: hovering)
        }
    }
}
