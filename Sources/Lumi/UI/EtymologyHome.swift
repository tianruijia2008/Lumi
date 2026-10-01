import SwiftUI

/// The 词源 page with no word open: a field, a word of the day, and a shelf
/// of words whose meaning travelled furthest.
///
/// Every line on the cards comes from the same pipeline as a full page — the
/// cards are small pages, fetched as they appear — so nothing here is a
/// caption someone typed and nobody checked.
struct EtymologyHome: View {
    @Bindable var store: EtymologyStore
    @Stored private var query = ""
    @Stored private var rejected = false
    @FocusState private var focused: Bool

    /// Words whose histories are good stories. Only the words are chosen by
    /// hand; what the cards say about them is read from the source.
    static let shelf = ["nice", "silly", "muscle", "clue", "sincere", "deer",
                        "window", "awful", "sad", "girl", "salary", "meat"]

    private var featured: String {
        let day = Calendar.current.ordinality(of: .day, in: .era, for: Date()) ?? 0
        return Self.shelf[day % Self.shelf.count]
    }

    private var cards: [String] {
        let start = (Self.shelf.firstIndex(of: featured) ?? 0) + 1
        return (0..<6).map { Self.shelf[(start + $0) % Self.shelf.count] }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ActivityRule(active: false)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    field
                    Text(rejected ? t("只查单个英文单词。句子和其他语言，交给面板。")
                                  : t("只查英文单词。句子和其他语言，交给面板。"))
                        .font(.system(size: 11.5))
                        .foregroundStyle(rejected ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.tertiary))
                        .padding(.leading, 18)
                        .padding(.top, 9)

                    SectionHead(title: t("今日一词"), note: t("每天换一个"))
                    FeaturedCard(word: featured, store: store)

                    SectionHead(title: t("有故事的词"), note: t("意思变得最远的几个"))
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3),
                              spacing: 12) {
                        ForEach(cards, id: \.self) { word in ShelfCard(word: word, store: store) }
                    }

                    HStack(spacing: 8) {
                        Label(t("面板"), systemImage: "character.magnify")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .chipShell()
                        Text(t("在面板里查一个英文单词，词典下面那行「来历」点「深究」，也会来到这里。"))
                            .font(.system(size: 11.5))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.top, 26)
                }
                .padding(.horizontal, 30)
                .padding(.top, 22)
                .padding(.bottom, 40)
                .frame(maxWidth: 1080, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Paper.fill)
        }
        .onAppear { focused = true }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text(t("词源")).font(.system(size: 14, weight: .semibold))
            Text(t("英文单词从哪来、意思怎么变过来、历代怎么用"))
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 10)
            Text(t("讲解")).font(Chrome.chipFont).foregroundStyle(.tertiary)
            EngineToggle(
                selection: Binding(get: { store.engine }, set: { store.engine = $0 }),
                onlineName: "AI", onlineSymbol: "sparkles",
                onlineUnconfigured: AppSettings.shared.workbenchOnlineProvider() == nil
            )
        }
        .padding(.horizontal, 16)
        .frame(height: 46)
    }

    private var field: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.tertiary)
            TextField(t("输入一个英文单词"), text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 16))
                .focused($focused)
                .onSubmit(submit)
                .onChange(of: query) { rejected = false }
            if !query.isEmpty {
                Text("↩")
                    .font(.system(size: 10.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(Chrome.chipStroke, lineWidth: 1) }
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 48)
        .background(Color(nsColor: .textBackgroundColor), in: .capsule)
        .overlay {
            Capsule().strokeBorder(focused ? Chrome.activeStroke : Chrome.chipStroke, lineWidth: 1)
        }
        .shadow(color: focused ? Color.accentColor.opacity(0.18) : .clear, radius: 5)
        .animation(Motion.tap, value: focused)
    }

    private func submit() {
        let word = EtymologyStore.normalised(query)
        guard EtymologyStore.isWord(word) else {
            withAnimation(Motion.tap) { rejected = true }
            return
        }
        store.open(word)
        query = ""
    }
}

/// A card loads its own word, so the shelf fills in as answers arrive
/// instead of waiting for the slowest.
private struct CardLoader<Content: View>: View {
    let word: String
    let store: EtymologyStore
    @ViewBuilder let content: (EtymologyEntry?) -> Content
    @Stored private var entry: EtymologyEntry?

    var body: some View {
        content(entry ?? store.cached(word))
            .task(id: word) {
                if entry == nil { entry = try? await store.entry(word) }
            }
    }
}

private struct ShelfCard: View {
    let word: String
    let store: EtymologyStore
    @Stored private var hovering = false

    var body: some View {
        CardLoader(word: word, store: store) { entry in
            Button { store.open(word) } label: {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(word).font(.system(size: 25, weight: .semibold, design: .serif).italic())
                        Spacer()
                        if entry?.folk.isEmpty == false {
                            Text(t("有民间词源"))
                                .font(.system(size: 9.5))
                                .foregroundStyle(.orange)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .overlay { Capsule().strokeBorder(Color.orange.opacity(0.7), lineWidth: 1) }
                        }
                    }
                    if let entry {
                        if let arc = entry.arc {
                            HStack(spacing: 8) {
                                Text(arc.from)
                                    .font(arc.fromIsForm ? .system(size: 14, design: .serif).italic() : nil)
                                    .foregroundStyle(.tertiary)
                                Image(systemName: "arrow.right").font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(.quaternary)
                                Text(arc.to)
                            }
                            .font(.system(size: 13))
                            .lineLimit(1)
                            .padding(.top, 12)
                        }
                        Text(meta(entry))
                            .font(.system(size: 10.5))
                            .foregroundStyle(.tertiary)
                            .padding(.top, 8)
                    } else {
                        ShimmerLines().padding(.top, 14)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
                .background(Color.primary.opacity(hovering ? 0.05 : 0.025), in: .rect(cornerRadius: 13))
                .overlay { RoundedRectangle(cornerRadius: 13).strokeBorder(Chrome.rule, lineWidth: 1) }
                .contentShape(.rect(cornerRadius: 13))
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .animation(Motion.tap, value: hovering)
        }
    }

    private func meta(_ entry: EtymologyEntry) -> String {
        var parts = [entry.oldestRecorded?.language].compactMap(\.self)
        if let century = entry.firstCentury { parts.append(t("%@进入英语", century)) }
        return parts.joined(separator: " · ")
    }
}

private struct FeaturedCard: View {
    let word: String
    let store: EtymologyStore

    var body: some View {
        CardLoader(word: word, store: store) { entry in
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(t("意思怎么一步步变过来"))
                        .font(.system(size: 10.5))
                        .tracking(0.8)
                        .foregroundStyle(.tertiary)
                    HStack(alignment: .lastTextBaseline, spacing: 12) {
                        Text(word).font(.system(size: 38, weight: .semibold, design: .serif).italic())
                        if let ipa = entry?.ipa {
                            Text(ipa).font(.system(size: 15, design: .serif).italic()).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.top, 8)
                    .padding(.bottom, 14)
                    if let entry { steps(entry) } else { ShimmerLines() }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)

                Rectangle().fill(Chrome.rule).frame(width: 1)

                VStack(alignment: .leading, spacing: 14) {
                    if let entry {
                        miniChain(entry)
                        if let quote = entry.quotes.first {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(EtymologyText.passage(quote.passage))
                                    .font(.system(size: 15, design: .serif))
                                    .lineLimit(3)
                                Text([quote.year.map(String.init), quote.author, quote.title.map { "《\($0)》" }]
                                    .compactMap(\.self).joined(separator: " "))
                                    .font(.system(size: 11))
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                            }
                        }
                    } else {
                        ShimmerLines()
                    }
                    Spacer(minLength: 0)
                    Button { store.open(word) } label: {
                        HStack(spacing: 4) {
                            Text(t("打开 %@", word))
                            Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
                        }
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 170)
            .background(Color.primary.opacity(0.025), in: .rect(cornerRadius: 15))
            .overlay { RoundedRectangle(cornerRadius: 15).strokeBorder(Chrome.rule, lineWidth: 1) }
        }
    }

    /// The meanings in the order they appeared. Falls back to the chain's
    /// glosses when the source gives no dates, which is still a sequence the
    /// source vouches for.
    @ViewBuilder
    private func steps(_ entry: EtymologyEntry) -> some View {
        let shown = Self.steps(entry)
        HStack(spacing: 0) {
            ForEach(Array(shown.enumerated()), id: \.offset) { index, label in
                if index > 0 { Rectangle().fill(Color.primary.opacity(0.18)).frame(width: 16, height: 1) }
                let last = index == shown.count - 1
                Text(label)
                    .font(.system(size: 12.5, weight: last ? .semibold : .regular))
                    .foregroundStyle(last ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background {
                        if last { Capsule().fill(Chrome.activeFill) }
                        else { Capsule().strokeBorder(Chrome.rule, lineWidth: 1) }
                    }
                    .fixedSize()
            }
        }
    }

    /// Up to four meanings, oldest first, ending on today's.
    ///
    /// Dated senses when the source dates them. Otherwise its own register
    /// labels stand in for dates — a sense marked obsolete is older than one
    /// marked rare, which is older than one in use — which is still an order
    /// the source vouches for rather than one invented here.
    static func steps(_ entry: EtymologyEntry) -> [String] {
        var source: [String]
        let dated = entry.datedSenses.sorted { ($0.start ?? 0, $0.id) < ($1.start ?? 0, $1.id) }
        if dated.count >= 2 {
            source = dated.filter { $0.id != entry.senses.first?.id }.map(\.shownLabel)
        } else {
            let old = entry.senses.filter { $0.status == .dead } + entry.senses.filter { $0.status == .fading }
            source = old.isEmpty ? [entry.oldestRecorded?.shownGloss].compactMap(\.self) : old.map(\.shownLabel)
        }
        var labels: [String] = []
        for label in source.map({ EtymologyEntry.clip($0, to: 7) }) where !labels.contains(label) {
            labels.append(label)
        }
        let now = entry.nowGloss.map { EtymologyEntry.clip($0, to: 7) }
        labels.removeAll { $0 == now }
        return Array(labels.suffix(3)) + [now].compactMap(\.self)
    }

    private func miniChain(_ entry: EtymologyEntry) -> some View {
        let nodes = Array(entry.chain.suffix(4))
        return HStack(alignment: .firstTextBaseline, spacing: 7) {
            ForEach(nodes) { node in
                if node.id != nodes.first?.id {
                    Image(systemName: "arrow.right").font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.quaternary)
                }
                Text(node.form).font(.system(size: 15, design: .serif).italic())
                    .foregroundStyle(node.isToday ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.primary))
                if !node.isToday {
                    Text(node.language).font(.system(size: 10.5)).foregroundStyle(.tertiary)
                }
            }
        }
        .lineLimit(1)
    }
}
