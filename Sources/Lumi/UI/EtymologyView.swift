import SwiftUI

/// The 词源 half of the workbench: a search page, or one word.
struct EtymologyScreen: View {
    @Bindable var store: EtymologyStore

    var body: some View {
        Group {
            if let lookup = store.current {
                EtymologyPage(lookup: lookup, store: store)
                    .id(lookup.word)
                    .transition(.opacity)
            } else {
                EtymologyHome(store: store)
                    .transition(.opacity)
            }
        }
        .animation(Motion.settle, value: store.current?.word)
    }
}

// MARK: - One word

struct EtymologyPage: View {
    @Bindable var lookup: EtymologyLookup
    @Bindable var store: EtymologyStore
    @Stored private var flashed: Int?

    var body: some View {
        VStack(spacing: 0) {
            header
            ActivityRule(active: lookup.phase == .loading || lookup.narration == .running
                         || lookup.quotesTranslating)
            content
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Button {
                if let url = Wiktionary.url(for: lookup.word) { NSWorkspace.shared.open(url) }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "books.vertical").font(.system(size: 9.5, weight: .semibold))
                    Text("Wiktionary").font(Chrome.chipFont)
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .chipShell()
                .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .help("所有资料都来自 Wiktionary，点击打开原词条")

            Text("讲解")
                .font(Chrome.chipFont)
                .foregroundStyle(.tertiary)
                .padding(.leading, 6)

            if lookup.narration == .running {
                RunningChip(text: "\(lookup.narrator ?? "模型") 在整理讲解")
                    .transition(.opacity)
            } else {
                EngineToggle(
                    selection: Binding(get: { store.engine }, set: { store.engine = $0 }),
                    onlineName: "AI", onlineSymbol: "sparkles",
                    onlineUnconfigured: AppSettings.shared.workbenchOnlineProvider() == nil,
                    help: { $0 == .offline
                        ? "只整理 Wiktionary 的资料，引文用系统翻译。不联网调用模型。"
                        : "由语言模型把资料串成一段讲解，每句标出处；引文也交给它翻译。" }
                )
                .transition(.opacity)
            }

            Spacer(minLength: 10)

            if let entry = lookup.entry {
                Text(counts(entry))
                    .font(Chrome.chipFont)
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
            IconButton(symbol: "doc.on.doc", help: "拷贝本页文字") { copy() }
                .disabled(lookup.entry == nil)
            Menu {
                Button("在 Wiktionary 中打开") {
                    if let url = Wiktionary.url(for: lookup.word) { NSWorkspace.shared.open(url) }
                }
                Button("重写讲解") { lookup.narrate(force: true) }
                    .disabled(store.engine == .offline || lookup.entry == nil)
                Divider()
                Button("重新获取") { lookup.retry() }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 22, height: 22)
                    .contentShape(.rect)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .foregroundStyle(.secondary)
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .frame(height: 46)
        .animation(Motion.tap, value: lookup.narration)
    }

    private func counts(_ entry: EtymologyEntry) -> String {
        var parts = ["\(entry.senses.count) 个义项"]
        if !entry.quotes.isEmpty { parts.append("\(entry.quotes.count) 条引文") }
        return parts.joined(separator: " · ")
    }

    private func copy() {
        guard let entry = lookup.entry else { return }
        var lines = [entry.word + (entry.ipa.map { " \($0)" } ?? "")]
        if !lookup.narrationText.isEmpty { lines += ["", EtymologyText.plain(lookup.narrationText)] }
        if !entry.chain.isEmpty {
            lines += ["", entry.chain.map { "\($0.language) \($0.form)" + ($0.shownGloss.map { "（\($0)）" } ?? "") }
                .joined(separator: " → ")]
        }
        for quote in entry.quotes {
            lines += ["", "\(quote.year.map(String.init) ?? "") \(quote.plainPassage)"]
            if let t = quote.translation { lines.append(t) }
        }
        lines += ["", "资料来源：Wiktionary（CC BY-SA 4.0）"]
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }

    // MARK: Body

    @ViewBuilder
    private var content: some View {
        switch lookup.phase {
        case .loading:
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    Text(lookup.word).font(.system(size: 42, weight: .bold)).tracking(-0.8)
                    ShimmerLines().frame(maxWidth: 560)
                    ShimmerLines().frame(maxWidth: 760)
                }
                .padding(.horizontal, 34)
                .padding(.vertical, 28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Paper.fill)
        case .failed(let why):
            VStack(alignment: .leading, spacing: 12) {
                Text(lookup.word).font(.system(size: 42, weight: .bold)).tracking(-0.8)
                Notice(symbol: "exclamationmark.circle", text: why) {
                    Button("重试") { lookup.retry() }.buttonStyle(.plain).foregroundStyle(Color.accentColor)
                }
                Spacer()
            }
            .padding(.horizontal, 34)
            .padding(.vertical, 28)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Paper.fill)
        case .ready:
            if let entry = lookup.entry { page(entry) }
        }
    }

    private func page(_ entry: EtymologyEntry) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Hero(entry: entry).id(EtymologySection.narration)
                    NarrationBlock(lookup: lookup, store: store) { cite($0, proxy) }
                        .padding(.top, 20)

                    if !entry.chain.isEmpty || !entry.folk.isEmpty {
                        SectionHead(title: "来历", note: "从最早能追到的地方，到今天")
                            .id(EtymologySection.chain)
                        ForEach(Array(entry.folk.enumerated()), id: \.offset) { _, claim in
                            FolkCard(claim: claim).padding(.bottom, 14)
                        }
                        if !entry.chain.isEmpty { ChainView(nodes: entry.chain) }
                    }

                    SensesBlock(entry: entry) { cite($0, proxy) }
                        .id(EtymologySection.senses)

                    Lower(entry: entry, lookup: lookup, store: store, flashed: flashed) { cite($0, proxy) }
                }
                .padding(.horizontal, 34)
                .padding(.top, 26)
                .padding(.bottom, 48)
                .frame(maxWidth: 1080, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Paper.fill)
            .environment(\.openURL, OpenURLAction { url in
                guard url.scheme == "lumi-cite", let n = Int(url.host() ?? "") else { return .systemAction }
                cite(n, proxy)
                return .handled
            })
            .onChange(of: store.scrollTarget) { _, target in
                guard let target else { return }
                withAnimation(Motion.settle) { proxy.scrollTo(target, anchor: .top) }
                store.scrollTarget = nil
            }
        }
    }

    /// Jumps to a quotation and lights it briefly, so the eye finds which of
    /// eight similar rows it landed on.
    private func cite(_ number: Int, _ proxy: ScrollViewProxy) {
        withAnimation(Motion.settle) { proxy.scrollTo("q\(number)", anchor: .center) }
        withAnimation(Motion.tap) { flashed = number }
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            withAnimation(Motion.settle) { if flashed == number { flashed = nil } }
        }
    }
}

// MARK: - Hero

private struct Hero: View {
    let entry: EtymologyEntry

    var body: some View {
        HStack(alignment: .lastTextBaseline, spacing: 12) {
            Text(entry.word)
                .font(.system(size: 42, weight: .bold))
                .tracking(-0.8)
                .textSelection(.enabled)
            if let ipa = entry.ipa {
                Text(ipa)
                    .font(.system(size: 16, design: .serif).italic())
                    .foregroundStyle(.secondary)
            }
            if let pos = entry.partOfSpeechLocal {
                Text(pos).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            }
            IconButton(symbol: "speaker.wave.2", help: "朗读") {
                Speaker.shared.speak(entry.word, language: .english)
            }
            .alignmentGuide(.lastTextBaseline) { $0[.bottom] - 3 }

            Spacer(minLength: 16)

            HStack(alignment: .lastTextBaseline, spacing: 22) {
                if let century = entry.firstCentury { fact(century, "进入英语") }
                if entry.chain.count > 1 { fact("\(entry.chain.count) 步", "从最早到今天") }
                if entry.senses.count > 1, entry.goneCount > 0 {
                    fact("\(entry.goneCount) / \(entry.senses.count)", "个意思已不用或少用")
                }
            }
        }
    }

    private func fact(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 15, weight: .semibold)).monospacedDigit()
            Text(label).font(.system(size: 11)).foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Narration

private struct NarrationBlock: View {
    @Bindable var lookup: EtymologyLookup
    @Bindable var store: EtymologyStore
    let cite: (Int) -> Void

    var body: some View {
        Group {
            switch lookup.narration {
            case .off:
                Notice(symbol: "info.circle",
                       text: "本机模式只整理资料，不写讲解。切到 AI，会把下面几部分串成一段话，每句标出处。") {
                    Button("切到 AI") { store.engine = .online }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                }
            case .unavailable(let why):
                Notice(symbol: "exclamationmark.circle", text: why) {
                    SettingsLink { Text("打开设置") }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                }
            case .failed(let why):
                Notice(symbol: "exclamationmark.triangle", text: "讲解没写成：\(why)") {
                    Button("重试") { lookup.narrate(force: true) }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                }
            case .running, .done:
                prose
            }
        }
        .frame(maxWidth: 760, alignment: .leading)
    }

    private var prose: some View {
        VStack(alignment: .leading, spacing: 10) {
            let paragraphs = lookup.narrationText
                .components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            ForEach(Array(paragraphs.enumerated()), id: \.offset) { index, paragraph in
                let last = index == paragraphs.count - 1 && lookup.narration == .running
                Text(EtymologyText.narration(paragraph + (last ? " ▍" : "")))
                    .font(.system(size: 15))
                    .lineSpacing(6)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if lookup.narration == .running, paragraphs.count < 2 {
                ShimmerLines()
            }
            if lookup.narration == .done {
                HStack(spacing: 5) {
                    Image(systemName: "sparkles").font(.system(size: 9.5))
                    Text("\(lookup.narrator ?? "模型") 按本页资料整理 · 圈号是下面的引文 · 资料里没有的不写")
                }
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            }
        }
    }
}

// MARK: - Chain

private struct FolkCard: View {
    let claim: FolkClaim

    var body: some View {
        HStack(spacing: 16) {
            Text("民间词源")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.orange)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .overlay { Capsule().strokeBorder(Color.orange.opacity(0.7), lineWidth: 1) }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                ForEach(Array(claim.parts.enumerated()), id: \.offset) { index, part in
                    if index > 0 { Text("+").foregroundStyle(.tertiary) }
                    Text(part.form)
                        .font(.system(size: 19, design: .serif).italic())
                        .strikethrough(color: .orange)
                        .foregroundStyle(.secondary)
                    if let gloss = part.shownGloss {
                        Text(gloss).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
            }
            .fixedSize()
            Text("流传很广，但 Wiktionary 明确标注这不是它的来历。放在这里，是因为你多半听过这个说法。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .help(claim.sourceSentence)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.1), in: .rect(cornerRadius: 12))
    }
}

private struct ChainView: View {
    let nodes: [EtymNode]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                row(fixed: false)
                ScrollView(.horizontal) { row(fixed: true) }.scrollIndicators(.never)
            }
            if nodes.contains(where: \.isReconstructed) {
                HStack(spacing: 18) {
                    legend(dashed: true, "虚线：构拟形式，没有文字记录，是语言学家倒推出来的")
                    legend(dashed: false, "实线：有文献")
                }
            }
        }
        .padding(.top, nodes.contains { !$0.addends.isEmpty } ? 30 : 4)
    }

    private func row(fixed: Bool) -> some View {
        HStack(alignment: .center, spacing: 0) {
            ForEach(nodes) { node in
                NodeCard(node: node)
                    .frame(minWidth: fixed ? 124 : 84, maxWidth: fixed ? 124 : .infinity)
                if node.id != nodes.last?.id {
                    // The arrow's frame is as tall as the row, so a side
                    // branch can sit just above the cards it joins.
                    Image(systemName: "arrow.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.quaternary)
                        .frame(width: 24)
                        .frame(maxHeight: .infinity)
                        .overlay(alignment: .top) {
                            if !node.addends.isEmpty { AddendChip(parts: node.addends).offset(y: -30) }
                        }
                }
            }
        }
        .fixedSize(horizontal: fixed, vertical: true)
    }

    private func legend(dashed: Bool, _ text: String) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 3)
                .strokeBorder(Color.primary.opacity(0.25),
                              style: StrokeStyle(lineWidth: 1, dash: dashed ? [3, 2] : []))
                .frame(width: 14, height: 10)
            Text(text).font(.system(size: 11)).foregroundStyle(.tertiary)
        }
    }
}

private struct NodeCard: View {
    let node: EtymNode

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(caption)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            Text(node.form)
                .font(.system(size: 20, weight: .medium, design: .serif).italic())
                .foregroundStyle(node.isToday ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.primary))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(node.shownGloss ?? " ")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .help(node.gloss ?? "")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            let shape = RoundedRectangle(cornerRadius: 11)
            if node.isToday {
                shape.fill(Chrome.activeFill)
            } else if node.isReconstructed {
                shape.strokeBorder(Color.primary.opacity(0.22), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            } else {
                shape.fill(Color.primary.opacity(0.03))
                    .overlay { shape.strokeBorder(Chrome.rule, lineWidth: 1) }
            }
        }
        .help(node.isReconstructed ? "构拟形式：没有文字记录，由语言学家根据后代语言倒推" : "")
    }

    private var caption: String {
        if node.isToday { return "英语 · 今天" }
        return node.isReconstructed ? "\(node.language) · 构拟" : node.language
    }
}

private struct AddendChip: View {
    let parts: [Part]

    var body: some View {
        HStack(spacing: 4) {
            Text("+").foregroundStyle(.tertiary)
            ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                Text(part.form).font(.system(size: 13, design: .serif).italic())
                if let gloss = part.shownGloss {
                    Text(EtymologyEntry.clip(gloss, to: 6)).foregroundStyle(.secondary)
                }
            }
        }
        .font(.system(size: 10.5))
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(Paper.fill, in: .rect(cornerRadius: 7))
        .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(Chrome.rule, lineWidth: 1) }
        .fixedSize()
    }
}

// MARK: - Senses

private struct SensesBlock: View {
    let entry: EtymologyEntry
    let cite: (Int) -> Void

    var body: some View {
        let dated = entry.datedSenses
        if !entry.senses.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                if dated.count >= 2 {
                    SectionHead(title: "词义变迁", note: "每条横线是一个意思活着的年代")
                    SenseChart(senses: dated, quotes: entry.quotes, cite: cite)
                    let undated = entry.senses.filter { $0.start == nil }
                    if !undated.isEmpty {
                        Text("另有 \(undated.count) 个义项没有年代标注：" + undated.map(\.shownLabel).joined(separator: "；"))
                            .font(.system(size: 11.5))
                            .foregroundStyle(.tertiary)
                            .lineSpacing(3)
                            .padding(.top, 12)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    SectionHead(title: "义项", note: nil)
                    Notice(symbol: "info.circle",
                           text: "这一条没有年代标注，画不出时间线，只列义项。不拿 AI 去猜年代。") { EmptyView() }
                        .padding(.bottom, 8)
                    ForEach(entry.senses) { sense in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(sense.shownLabel).font(.system(size: 13))
                                .help(sense.textLocal ?? sense.text)
                            Spacer()
                            StatusTag(status: sense.status)
                        }
                        .padding(.vertical, 9)
                        .overlay(alignment: .bottom) { Rectangle().fill(Chrome.rule).frame(height: 1) }
                    }
                }
            }
        }
    }
}

private struct SenseChart: View {
    let senses: [Sense]
    let quotes: [Quote]
    let cite: (Int) -> Void

    private static let labelWidth: CGFloat = 170
    private let now = Calendar.current.component(.year, from: Date())

    private var lanes: [Sense] {
        Array(senses.sorted { ($0.start ?? 0, $0.id) < ($1.start ?? 0, $1.id) }.prefix(10))
    }
    private var first: Int { ((lanes.compactMap(\.start).min() ?? 1500) / 100) * 100 }
    private var span: Double { Double(now - first) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 16) {
                key(Color.accentColor, "还在用")
                key(Color.accentColor.opacity(0.5), "渐少")
                key(Color.primary.opacity(0.2), "已不用")
                Text("圆圈是下面的引文 · 年代只精确到世纪")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            .padding(.leading, Self.labelWidth)
            .padding(.bottom, 12)

            ForEach(lanes) { sense in
                HStack(spacing: 0) {
                    HStack(spacing: 6) {
                        Text(sense.shownLabel)
                            .font(.system(size: 12, weight: sense.id == senses.first?.id ? .semibold : .regular))
                            .foregroundStyle(sense.status == .dead ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                            .lineLimit(2)
                            .help(sense.textLocal ?? sense.text)
                        if sense.status != .alive {
                            Text(sense.status == .dead ? "已不用" : "少见")
                                .font(.system(size: 9.5))
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .overlay { Capsule().strokeBorder(Chrome.rule, lineWidth: 1) }
                                .fixedSize()
                        }
                    }
                    .frame(width: Self.labelWidth - 12, alignment: .leading)
                    .padding(.trailing, 12)
                    track(sense)
                }
                // Room for a label on two lines: the translated labels run
                // long, and a lane whose name ends in "…" says nothing.
                .frame(height: 36)
            }

            GeometryReader { g in
                ForEach(centuries, id: \.self) { year in
                    Text(String(year))
                        .font(.system(size: 10))
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                        .fixedSize()
                        .position(x: x(year, g.size.width), y: 10)
                }
            }
            .frame(height: 22)
            .padding(.leading, Self.labelWidth)
        }
    }

    private var centuries: [Int] { Array(stride(from: first, through: now, by: 100)) }

    private func x(_ year: Int, _ width: CGFloat) -> CGFloat {
        CGFloat(Double(year - first) / span) * width
    }

    private func track(_ sense: Sense) -> some View {
        GeometryReader { g in
            let w = g.size.width
            ZStack(alignment: .topLeading) {
                ForEach(centuries, id: \.self) { year in
                    Rectangle().fill(Chrome.rule).frame(width: 1, height: g.size.height)
                        .offset(x: x(year, w))
                }
                let start = sense.start ?? first
                let end = sense.end ?? now
                bar(sense.status)
                    .frame(width: max(8, x(end, w) - x(start, w)), height: 8)
                    .offset(x: x(start, w), y: g.size.height / 2 - 4)
                ForEach(quotes.filter { $0.senseID == sense.id && $0.year != nil }) { quote in
                    Button { cite(quote.id) } label: {
                        Text("\(quote.id)")
                            .font(.system(size: 9, weight: .semibold))
                            .monospacedDigit()
                            .frame(width: 17, height: 17)
                            .background(Paper.fill, in: .circle)
                            .overlay {
                                Circle().strokeBorder(sense.status == .dead ? Color.secondary : Color.accentColor,
                                                      lineWidth: 1.3)
                            }
                            .foregroundStyle(sense.status == .dead ? AnyShapeStyle(.secondary)
                                                                   : AnyShapeStyle(Color.accentColor))
                            .contentShape(.circle)
                    }
                    .buttonStyle(.plain)
                    .help("\(quote.year ?? 0) · \(quote.author ?? "")")
                    .offset(x: x(quote.year ?? first, w) - 8.5, y: g.size.height / 2 - 8.5)
                }
            }
        }
    }

    /// Dates are to the century, so no bar starts or ends on a hard edge.
    @ViewBuilder
    private func bar(_ status: SenseStatus) -> some View {
        let fadeIn = Gradient.Stop(color: .clear, location: 0)
        switch status {
        case .alive:
            Capsule().fill(Color.accentColor)
                .mask(LinearGradient(stops: [fadeIn, .init(color: .black, location: 0.12)],
                                     startPoint: .leading, endPoint: .trailing))
        case .fading:
            Capsule().fill(Color.accentColor.opacity(0.5))
                .mask(LinearGradient(stops: [fadeIn, .init(color: .black, location: 0.08),
                                             .init(color: .black, location: 0.6), .init(color: .clear, location: 1)],
                                     startPoint: .leading, endPoint: .trailing))
        case .dead:
            Capsule().fill(Color.primary.opacity(0.2))
                .mask(LinearGradient(stops: [fadeIn, .init(color: .black, location: 0.12),
                                             .init(color: .black, location: 0.88), .init(color: .clear, location: 1)],
                                     startPoint: .leading, endPoint: .trailing))
        }
    }

    private func key(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 6) {
            Capsule().fill(color).frame(width: 22, height: 6)
            Text(label).font(.system(size: 11)).foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Quotations and kin

private struct Lower: View {
    let entry: EtymologyEntry
    @Bindable var lookup: EtymologyLookup
    @Bindable var store: EtymologyStore
    let flashed: Int?
    let cite: (Int) -> Void

    @Stored private var width: CGFloat = 1000

    /// Decided from the measured width rather than with `ViewThatFits`: that
    /// asks each quotation how wide it would like to be, which is the whole
    /// passage on one line, so the two-column layout never "fit".
    var body: some View {
        Group {
            if width >= 760 {
                HStack(alignment: .top, spacing: 44) {
                    quotes.frame(maxWidth: .infinity, alignment: .leading)
                    aside.frame(width: 256)
                }
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    quotes
                    aside
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }

    private var quotes: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHead(title: "引文", note: entry.quotes.isEmpty ? nil : "按年代").id(EtymologySection.quotes)
            if entry.quotes.isEmpty {
                Text("Wiktionary 这一条没有带年份的引文。资料少就显示少，不让 AI 补例句。")
                    .font(.system(size: 12)).foregroundStyle(.tertiary)
            }
            ForEach(entry.quotes) { quote in
                QuoteRow(quote: quote, sense: entry.senses.first { $0.id == quote.senseID },
                         translating: lookup.quotesTranslating && quote.translation == nil,
                         flashed: flashed == quote.id)
                    .id("q\(quote.id)")
            }
            if !entry.quotes.isEmpty, entry.quotes.count < 3 {
                Text("这一条的引文就这么多。资料少就显示少，不让 AI 补例句。")
                    .font(.system(size: 11.5)).foregroundStyle(.tertiary).padding(.top, 12)
            }
        }
    }

    private var aside: some View {
        VStack(alignment: .leading, spacing: 0) {
            if lookup.kinLoading || !entry.kin.isEmpty {
                SectionHead(title: "同根词", note: nil).id(EtymologySection.kin)
                if lookup.kinLoading && entry.kin.isEmpty { ShimmerLines() }
                ForEach(entry.kin) { group in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline, spacing: 5) {
                            Text("同一词根")
                            Text(group.root).font(.system(size: 13, design: .serif).italic())
                                .foregroundStyle(.secondary)
                            if let gloss = group.glossLocal ?? group.gloss { Text(gloss) }
                        }
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .padding(.bottom, 4)
                        ForEach(group.words) { word in KinRow(word: word) { store.open(word.word) } }
                    }
                    .padding(.bottom, 16)
                }
            }
            SectionHead(title: "资料", note: nil)
            VStack(alignment: .leading, spacing: 5) {
                ForEach(entry.pages, id: \.self) { page in
                    Button {
                        if let url = Wiktionary.url(for: page) { NSWorkspace.shared.open(url) }
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 7) {
                            Text("Wiktionary").fontWeight(.medium).foregroundStyle(.primary)
                            Text(page.replacingOccurrences(of: "Reconstruction:", with: ""))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Image(systemName: "arrow.up.right").font(.system(size: 8.5)).foregroundStyle(.tertiary)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
                Rectangle().fill(Chrome.rule).frame(height: 1).padding(.vertical, 5)
                Text("CC BY-SA 4.0 · \(entry.fetched.formatted(.iso8601.year().month().day())) 取得\n引文年代是词条自带的标注，不是推算的")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .lineSpacing(3)
            }
            .font(.system(size: 11.5))
            .padding(13)
            .background(Color.primary.opacity(0.03), in: .rect(cornerRadius: 11))
            .overlay { RoundedRectangle(cornerRadius: 11).strokeBorder(Chrome.rule, lineWidth: 1) }
        }
    }
}

private struct QuoteRow: View {
    let quote: Quote
    let sense: Sense?
    let translating: Bool
    let flashed: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text(quote.year.map(String.init) ?? "—")
                    .font(.system(size: 13, weight: .semibold))
                    .monospacedDigit()
                if quote.approximate {
                    Text("前后").font(.system(size: 10)).foregroundStyle(.tertiary)
                }
                Text("\(quote.id)")
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 15, height: 15)
                    .overlay { Circle().strokeBorder(Color.accentColor, lineWidth: 1.2) }
            }
            .frame(width: 56, alignment: .leading)

            VStack(alignment: .leading, spacing: 7) {
                Text(EtymologyText.passage(quote.passage))
                    .font(.system(size: 15.5, design: .serif))
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if let translation = quote.translation {
                    Text(translation)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .transition(.opacity)
                } else if translating {
                    ShimmerLines().frame(maxWidth: 360)
                }
                HStack(spacing: 8) {
                    if let sense { SenseTag(sense: sense) }
                    Text([quote.author, quote.title.map { "《\($0)》" }].compactMap(\.self).joined(separator: " "))
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 15)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 9)
                .fill(LinearGradient(colors: [Chrome.activeFill, .clear], startPoint: .leading, endPoint: .trailing))
                .opacity(flashed ? 1 : 0)
        }
        .padding(.horizontal, -10)
        .overlay(alignment: .bottom) { Rectangle().fill(Chrome.rule).frame(height: 1) }
    }
}

private struct KinRow: View {
    let word: KinWord
    let action: () -> Void
    @Stored private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(word.word)
                    .font(.system(size: 16, weight: .medium, design: .serif).italic())
                    .frame(minWidth: 88, alignment: .leading)
                Text(word.gloss ?? "")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .opacity(hovering ? 1 : 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 7).fill(hovering ? Chrome.hover : .clear))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, -8)
        .onHover { hovering = $0 }
        .help("查 \(word.word) 的词源")
    }
}

// MARK: - Small parts

struct SectionHead: View {
    let title: String
    let note: String?

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .tracking(0.5)
            Rectangle().fill(Chrome.rule).frame(height: 1)
            if let note {
                Text(note).font(.system(size: 11)).foregroundStyle(.tertiary).fixedSize()
            }
        }
        .padding(.top, 38)
        .padding(.bottom, 16)
    }
}

struct Notice<Trailing: View>: View {
    let symbol: String
    let text: String
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(.tertiary)
            Text(text).font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            trailing().font(.system(size: 12, weight: .medium))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .overlay {
            RoundedRectangle(cornerRadius: 11)
                .strokeBorder(Color.primary.opacity(0.18), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        }
    }
}

private struct SenseTag: View {
    let sense: Sense

    var body: some View {
        Text(EtymologyEntry.clip(sense.shownLabel, to: 10))
            .font(.system(size: 10))
            .padding(.horizontal, 8)
            .padding(.vertical, 2.5)
            .foregroundStyle(sense.status == .alive ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
            .background {
                Capsule().fill(sense.status == .alive ? Chrome.activeFill : Color.primary.opacity(0.04))
            }
            .overlay {
                if sense.status != .alive { Capsule().strokeBorder(Chrome.rule, lineWidth: 1) }
            }
            .fixedSize()
            .help(sense.textLocal ?? sense.text)
    }
}

private struct StatusTag: View {
    let status: SenseStatus
    var body: some View {
        Text(status.label)
            .font(.system(size: 10))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .overlay { Capsule().strokeBorder(Chrome.rule, lineWidth: 1) }
    }
}

struct RunningChip: View {
    let text: String
    @Stored private var dim = false

    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(Color.accentColor).frame(width: 6, height: 6).opacity(dim ? 0.25 : 1)
            Text(text).font(Chrome.chipFont)
        }
        .foregroundStyle(Color.accentColor)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Chrome.activeFill, in: .capsule)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.55).repeatForever()) { dim = true }
        }
    }
}

/// The separator under the chrome, which moves while something is on its way.
struct ActivityRule: View {
    let active: Bool
    @Stored private var phase: CGFloat = -0.35

    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.12))
            .frame(height: 2)
            .overlay(alignment: .leading) {
                GeometryReader { g in
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: g.size.width * 0.3)
                        .offset(x: phase * g.size.width)
                        .opacity(active ? 1 : 0)
                }
            }
            .clipped()
            .onAppear {
                withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: false)) { phase = 1.05 }
            }
    }
}

// MARK: - Text

enum EtymologyText {
    /// `**nice**` → the headword in bold on a tint of the accent.
    static func passage(_ text: String) -> AttributedString {
        var out = AttributedString()
        for (index, piece) in text.components(separatedBy: "**").enumerated() {
            var run = AttributedString(piece)
            if index % 2 == 1 {
                run.font = .system(size: 15.5, weight: .bold, design: .serif)
                run.backgroundColor = Color.accentColor.opacity(0.14)
            }
            out += run
        }
        return out
    }

    /// The model's prose: `{forma}` in italics, `[3]` as a circled link that
    /// scrolls to quotation 3.
    ///
    /// Braces rather than Markdown's `*…*`, because an etymology is full of
    /// asterisks that mean something else — `*skey-` is a reconstructed form —
    /// and one stray one flipped a whole paragraph into italic serif.
    static func narration(_ text: String) -> AttributedString {
        var out = AttributedString()
        var buffer = ""
        let chars = Array(text.replacingOccurrences(of: "**", with: ""))

        func flush() {
            guard !buffer.isEmpty else { return }
            out += AttributedString(buffer)
            buffer = ""
        }

        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "{", let close = chars[i...].firstIndex(of: "}"), close - i <= 40 {
                flush()
                var form = AttributedString(String(chars[(i + 1)..<close]))
                form.font = .system(size: 16, design: .serif).italic()
                out += form
                i = close + 1
                continue
            }
            if c == "[", let close = chars[i...].firstIndex(of: "]"), close - i <= 12 {
                let inside = String(chars[(i + 1)..<close])
                let pieces = inside.split(whereSeparator: { $0 == "," || $0 == "，" })
                let numbers = pieces.compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
                if !numbers.isEmpty, numbers.count == pieces.count {
                    flush()
                    for n in numbers {
                        var cite = AttributedString(circled(n))
                        cite.link = URL(string: "lumi-cite://\(n)")
                        cite.foregroundColor = .accentColor
                        cite.font = .system(size: 14)
                        out += cite
                    }
                    i = close + 1
                    continue
                }
            }
            buffer.append(c)
            i += 1
        }
        flush()
        return out
    }

    static func plain(_ text: String) -> String {
        text.replacingOccurrences(of: "{", with: "").replacingOccurrences(of: "}", with: "")
    }

    private static func circled(_ n: Int) -> String {
        guard (1...20).contains(n), let scalar = Unicode.Scalar(0x2460 + n - 1) else { return "[\(n)]" }
        return String(Character(scalar))
    }
}
