import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The page the 工作台 opens on: a way to begin, and a way back to what was
/// being read.
///
/// It replaces a window that opened straight onto an empty text box. That box
/// asked for a paste before saying what the window was for, and had nothing
/// to offer anyone who had come back to finish a paper.
struct WorkbenchHome: View {
    @Bindable var navigation: WorkbenchNavigation
    @Bindable var document: WorkbenchDocument
    @Bindable var documents: DocumentStore
    @Bindable var etymology: EtymologyStore

    @Stored private var clipboard = ClipboardPeek()
    @Stored private var dropping = false
    @Stored private var width: CGFloat = 1000

    private var narrow: Bool { width < 780 }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Color.primary.opacity(0.12)).frame(height: 2)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    NewDocumentCard(navigation: navigation, etymology: etymology,
                                    clipboard: clipboard, dropping: dropping, narrow: narrow)
                    recents
                    tools
                }
                .padding(.horizontal, 30)
                .padding(.top, 24)
                .padding(.bottom, 40)
                .frame(maxWidth: 1180, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Paper.fill)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width = $0 }
        }
        // The whole page takes a drop, not only the card that says so:
        // aiming at a box is the part of dragging people get wrong.
        .dropDestination(for: DroppedText.self) { items, _ in
            guard let item = items.first else { return false }
            return WorkbenchController.shared.start(item.text, fallbackTitle: item.name,
                                                     format: item.isMarkdownFile ? .markdown : nil)
        } isTargeted: { dropping = $0 }
        .animation(Motion.settle, value: dropping)
        .onAppear { clipboard.start() }
        .onDisappear { clipboard.stop() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("开始").font(.system(size: 14, weight: .semibold))
            Text("逐段对照读长文、校对别人的译文、追一个词的来历")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 10)
            Text("新文稿用").font(Chrome.chipFont).foregroundStyle(.tertiary)
            EngineSwitch(document: document)
        }
        .padding(.horizontal, 16)
        .frame(height: 46)
    }

    // MARK: Recents

    @ViewBuilder
    private var recents: some View {
        let docs = Array(documents.recents.prefix(5))
        let words = Array(etymology.recents.prefix(5))
        if docs.isEmpty && words.isEmpty {
            FirstRunHint().padding(.top, 22)
        } else {
            let layout = narrow ? AnyLayout(VStackLayout(alignment: .leading, spacing: 0))
                                : AnyLayout(HStackLayout(alignment: .top, spacing: 28))
            layout {
                VStack(alignment: .leading, spacing: 0) {
                    SectionHead(title: "最近文稿", note: docs.isEmpty ? nil : "译文存在本机，重开不再花钱")
                    if docs.isEmpty {
                        FirstRunHint()
                    } else {
                        VStack(spacing: 0) {
                            ForEach(Array(docs.enumerated()), id: \.element.id) { offset, summary in
                                DocumentRow(summary: summary, leading: offset == 0,
                                            last: offset == docs.count - 1)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if !words.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        SectionHead(title: "最近查过的词", note: nil)
                        ForEach(words) { recent in
                            WordRow(recent: recent) {
                                navigation.go(.etymology)
                                etymology.open(recent.word)
                            }
                        }
                        Button {
                            navigation.go(.etymology)
                            etymology.closeWord()
                        } label: {
                            HStack(spacing: 3) {
                                Text("全部词源")
                                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                            }
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(Color.accentColor)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 10)
                    }
                    .frame(width: narrow ? nil : 260, alignment: .leading)
                }
            }
        }
    }

    // MARK: Tools

    private var tools: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHead(title: "能做的事", note: nil)
            HStack(alignment: .top, spacing: 14) {
                ToolTile(title: "通读全文", shortcut: "⌘N",
                         text: "原文和译文一段对一段。机器悄悄漏掉的句子，会在那一段旁边标出来。") {
                    ReadArt()
                } action: { navigation.go(.compose) }
                ToolTile(title: "校对译文", shortcut: "⇧⌘N",
                         text: "放进原文和别人的译文，逐段标出漏译、错译和前后不一的术语，一键采纳改法。") {
                    ProofArt()
                } action: { navigation.go(.proofCompose) }
                ToolTile(title: "词源", shortcut: "⌘E",
                         text: "一个英文单词从哪来、意思怎么一步步变过来，每一步都有历代原句作证。") {
                    EtymologyArt()
                } action: {
                    navigation.go(.etymology)
                    etymology.closeWord()
                }
            }
        }
    }
}

// MARK: - New document

private struct NewDocumentCard: View {
    @Bindable var navigation: WorkbenchNavigation
    @Bindable var etymology: EtymologyStore
    @Bindable var clipboard: ClipboardPeek
    let dropping: Bool
    let narrow: Bool

    var body: some View {
        let layout = narrow ? AnyLayout(VStackLayout(alignment: .leading, spacing: 0))
                            : AnyLayout(HStackLayout(alignment: .top, spacing: 0))
        layout {
            invitation
                .frame(maxWidth: .infinity, alignment: .leading)
            if let content = clipboard.content {
                Rectangle().fill(Chrome.rule)
                    .frame(width: narrow ? nil : 1, height: narrow ? 1 : nil)
                ClipboardCard(content: content) { word in
                    navigation.go(.etymology)
                    etymology.open(word)
                }
                .frame(width: narrow ? nil : 340, alignment: .leading)
                .frame(maxWidth: narrow ? .infinity : nil,
                       maxHeight: narrow ? nil : .infinity, alignment: .topLeading)
                .background(Color.primary.opacity(0.025))
                .transition(.opacity)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.7), in: .rect(cornerRadius: 14))
        .clipShape(.rect(cornerRadius: 14))
        .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(Chrome.chipStroke, lineWidth: 1) }
        .overlay {
            if dropping { DropOverlay().transition(.opacity) }
        }
        .animation(Motion.settle, value: clipboard.content)
    }

    private var invitation: some View {
        HStack(alignment: .top, spacing: 18) {
            Image(systemName: "doc.text")
                .font(.system(size: 36, weight: .ultraLight))
                .foregroundStyle(.tertiary)
                .frame(width: 44)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 0) {
                Text("粘贴、拖入，或打开一篇长文")
                    .font(.system(size: 17, weight: .semibold))
                Text("论文、合同、小说的一章、Markdown 文档都行。在这一页任何地方按 ⌘V，直接进入逐段对照，不用先点输入框。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 470, alignment: .leading)
                    .padding(.top, 7)
                HStack(spacing: 8) {
                    HomeButton(title: "粘贴", symbol: "doc.on.clipboard", key: "⌘V", prominent: true) {
                        // A click on a button named 粘贴 is a paste the user
                        // asked for, the kind the system lets through.
                        WorkbenchController.shared.paste(nil)
                    }
                    HomeButton(title: "打开文件…", symbol: "folder", key: "⌘O") {
                        WorkbenchController.shared.openFile()
                    }
                    HomeButton(title: "手动输入", symbol: "square.and.pencil") {
                        navigation.go(.compose)
                    }
                }
                .padding(.top, 16)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 22)
    }
}

private struct DropOverlay: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "arrow.down.to.line").font(.system(size: 22, weight: .medium))
            Text("松手就开始").font(.system(size: 16, weight: .semibold))
            Text("文本、Markdown 文件或拖进来的文字都行")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .foregroundStyle(Color.accentColor)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial, in: .rect(cornerRadius: 14))
        .background(Color.accentColor.opacity(0.08), in: .rect(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
        }
    }
}

private struct ClipboardCard: View {
    let content: ClipboardPeek.Content
    let lookUp: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Label(heading, systemImage: "clipboard")
                .font(.system(size: 10.5, weight: .medium))
                .tracking(0.6)
                .foregroundStyle(.tertiary)
            switch content {
            case .text(let preview, let stats):
                Text(preview)
                    .font(.system(size: 14, design: .serif))
                    .lineSpacing(3)
                    .lineLimit(3)
                    .padding(.top, 12)
                Text(stats)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 8)
                Spacer(minLength: 12)
                link("通读这篇") { WorkbenchController.shared.paste(nil) }
            case .known(let summary):
                Text(summary.title)
                    .font(.system(size: 14, design: .serif))
                    .lineSpacing(3)
                    .lineLimit(3)
                    .padding(.top, 12)
                DocumentStatusText(summary: summary)
                    .font(.system(size: 11))
                    .padding(.top, 8)
                Spacer(minLength: 12)
                link(summary.isMidway ? "接着读第 \(summary.readingPosition + 1) 段" : "打开") {
                    WorkbenchController.shared.openDocument(summary.id)
                }
            case .word(let word, let hook):
                Text(word)
                    .font(.system(size: 30, weight: .semibold, design: .serif).italic())
                    .padding(.top, 12)
                if let hook {
                    Text(hook)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(.top, 8)
                }
                Spacer(minLength: 12)
                link("查它的来历") { lookUp(word) }
            case .unread:
                Text("按 ⌘V 或点「粘贴」，直接进入逐段对照。")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 12)
                Text("系统不让程序自己读剪贴板。在系统设置的隐私与安全性里允许 Lumi 读取剪贴板，这里就会先给你看前几行。")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 20)
    }

    private var heading: String {
        switch content {
        case .text: "剪贴板里有一篇"
        case .known: "剪贴板里是读过的一篇"
        case .word: "剪贴板里是一个词"
        case .unread: "剪贴板里有文字"
        }
    }

    private func link(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title)
                Image(systemName: "chevron.right").font(.system(size: 9.5, weight: .semibold))
            }
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(Color.accentColor)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

private struct FirstRunHint: View {
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "rectangle.split.2x1")
                .font(.system(size: 15))
                .foregroundStyle(.tertiary)
            Text("读过的文章会留在这里，连同译文和标出的漏译。下次打开工作台，从上次停下的那一段接着读。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 15)
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Chrome.chipStroke, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        }
    }
}

// MARK: - Rows

private struct DocumentRow: View {
    let summary: DocumentSummary
    /// The most recent document: the one "接着读" means.
    let leading: Bool
    let last: Bool
    @Stored private var hovering = false

    private var resumes: Bool { leading && summary.isMidway }

    var body: some View {
        Button { WorkbenchController.shared.openDocument(summary.id) } label: {
            HStack(spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(summary.title)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    meta
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 5) {
                    ProgressTrack(value: summary.progress, finished: summary.isTranslated)
                        .frame(height: 4)
                    DocumentStatusText(summary: summary).font(.system(size: 10.5))
                }
                .frame(width: 140)

                Text(resumes ? "接着读" : DocumentDate.label(summary.modified))
                    .font(.system(size: 11, weight: resumes ? .medium : .regular))
                    .monospacedDigit()
                    .foregroundStyle(resumes ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
                    .frame(width: 78, alignment: .trailing)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 11)
            .background {
                RoundedRectangle(cornerRadius: 9)
                    .fill(Color.primary.opacity(hovering ? 0.05 : (resumes ? 0.03 : 0)))
            }
            .overlay(alignment: .bottom) {
                if !last { Rectangle().fill(Chrome.rule).frame(height: 1).padding(.horizontal, 10) }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, -10)
        .onHover { hovering = $0 }
        .animation(Motion.tap, value: hovering)
        .contextMenu {
            Button("从最近移除") { DocumentStore.shared.remove(summary.id) }
        }
    }

    private var meta: some View {
        var parts: [String] = []
        if summary.isProof { parts.append("校对稿") }
        if summary.isMidway { parts.append("读到第 \(summary.readingPosition + 1) 段") }
        parts.append("\(summary.source.displayName) → \(summary.target.displayName)")
        if !summary.engineLabel.isEmpty { parts.append(summary.engineLabel) }
        let notes = summary.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty { parts.append("附说明：\(notes.replacingOccurrences(of: "\n", with: " "))") }
        return Text(parts.joined(separator: " · "))
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
            .lineLimit(1)
    }
}

private struct WordRow: View {
    let recent: RecentWord
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Text(recent.word)
                    .font(.system(size: 15.5, weight: .medium, design: .serif).italic())
                    .foregroundStyle(.primary)
                if let hook = recent.hook {
                    Text(hook)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(.rect)
        }
        .buttonStyle(SidebarButtonStyle())
        .padding(.horizontal, -10)
    }
}

/// How far a document got, as a line.
struct ProgressTrack: View {
    let value: Double
    let finished: Bool

    var body: some View {
        GeometryReader { geometry in
            Capsule().fill(Color.primary.opacity(0.1))
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(finished ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Color.accentColor))
                        .frame(width: geometry.size.width * value)
                }
        }
    }
}

/// One short phrase: what state the translation is in, and whether anything
/// in it needs a second look.
struct DocumentStatusText: View {
    let summary: DocumentSummary

    var body: some View {
        Text(text)
            .foregroundStyle(warning ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.tertiary))
            .lineLimit(1)
    }

    private var warning: Bool { summary.flaggedCount > 0 || summary.failedCount > 0 || summary.issueCount > 0 }

    private var text: String {
        let total = summary.segmentCount
        if summary.isProof {
            if summary.issueCount > 0 { return "\(summary.issueCount) 处待改" }
            if summary.reviewedCount == 0 { return "未校对 · \(total) 段" }
            if summary.reviewedCount < total { return "已校 \(summary.reviewedCount) / \(total) 段" }
            return "校对完 · 无待改"
        }
        if summary.flaggedCount > 0 { return "\(summary.flaggedCount) 段疑似漏译" }
        if summary.failedCount > 0 { return "\(summary.failedCount) 段没译成" }
        if summary.issueCount > 0 { return "\(summary.issueCount) 处校对意见" }
        if summary.doneCount == 0 { return "未翻译 · \(total) 段" }
        if summary.doneCount < total { return "已译 \(summary.doneCount) / \(total) 段" }
        return "已译完 · \(total) 段"
    }
}

enum DocumentDate {
    static func label(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "今天 " + date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)) }
        if calendar.isDateInYesterday(date) { return "昨天" }
        let month = calendar.component(.month, from: date)
        let day = calendar.component(.day, from: date)
        if calendar.isDate(date, equalTo: Date(), toGranularity: .year) { return "\(month)月\(day)日" }
        return "\(calendar.component(.year, from: date))年\(month)月\(day)日"
    }
}

// MARK: - Tools

private struct ToolTile<Art: View>: View {
    let title: String
    var tag: String?
    var shortcut: String?
    let text: String
    @ViewBuilder let art: () -> Art
    let action: () -> Void

    @Stored private var hovering = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                art()
                    .frame(maxWidth: .infinity)
                    .frame(height: 72)
                    .background(Color.primary.opacity(0.03), in: .rect(cornerRadius: 9))
                    .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(Chrome.rule, lineWidth: 1) }
                    .clipShape(.rect(cornerRadius: 9))
                HStack(spacing: 8) {
                    Text(title).font(.system(size: 13.5, weight: .semibold))
                    if let tag {
                        Text(tag)
                            .font(.system(size: 9.5))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .overlay { Capsule().strokeBorder(Chrome.chipStroke, lineWidth: 1) }
                    }
                    Spacer(minLength: 0)
                    if let shortcut {
                        Text(shortcut)
                            .font(.system(size: 10.5, weight: .medium, design: .rounded))
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.top, 14)
                Text(text)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineSpacing(2.5)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 5)
                Spacer(minLength: 0)
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color.primary.opacity(hovering && enabled ? 0.05 : 0.025), in: .rect(cornerRadius: 13))
            .overlay {
                RoundedRectangle(cornerRadius: 13)
                    .strokeBorder(hovering && enabled ? Chrome.activeStroke : Chrome.rule, lineWidth: 1)
            }
            .contentShape(.rect(cornerRadius: 13))
            .opacity(enabled ? 1 : 0.6)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Motion.tap, value: hovering)
    }
}

/// Two aligned columns, one paragraph on the right gone missing.
private struct ReadArt: View {
    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
            row("1", 0.92, 0.84)
            row("2", 0.78, 0.52, soft: true)
            GridRow {
                Color.clear.frame(width: 8, height: 6)
                bar(0.64)
                Capsule()
                    .strokeBorder(Color.orange, style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                    .frame(height: 6)
                    .scaleEffect(x: 0.42, anchor: .leading)
            }
            row("3", 0.88, 0.8)
        }
        .padding(.horizontal, 14)
    }

    private func row(_ number: String, _ left: CGFloat, _ right: CGFloat, soft: Bool = false) -> some View {
        GridRow {
            Text(number).font(.system(size: 8.5, weight: .medium)).foregroundStyle(.tertiary).frame(width: 8)
            bar(left)
            Capsule()
                .fill(soft ? Color.orange.opacity(0.18) : Color.primary.opacity(0.12))
                .frame(height: 6)
                .scaleEffect(x: right, anchor: .leading)
        }
    }

    private func bar(_ fraction: CGFloat) -> some View {
        Capsule().fill(Color.primary.opacity(0.12)).frame(height: 6)
            .scaleEffect(x: fraction, anchor: .leading)
    }
}

/// Lines of translation with one phrase underlined and a note in the margin.
private struct ProofArt: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) { bar(60); marked(34); bar(30) }
            HStack(spacing: 6) {
                bar(110)
                Spacer(minLength: 0)
                Text("术语不一致")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .overlay { Capsule().strokeBorder(Color.orange, lineWidth: 1) }
            }
            HStack(spacing: 6) { bar(46); marked(46); bar(36) }
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func bar(_ width: CGFloat) -> some View {
        Capsule().fill(Color.primary.opacity(0.12)).frame(width: width, height: 6)
    }

    private func marked(_ width: CGFloat) -> some View {
        Rectangle().fill(Color.orange.opacity(0.14)).frame(width: width, height: 7)
            .overlay(alignment: .bottom) { Rectangle().fill(Color.orange).frame(height: 1.5) }
    }
}

/// A word's line of descent, the way the 词源 page draws it.
private struct EtymologyArt: View {
    var body: some View {
        HStack(spacing: 8) {
            step("nescius", "拉丁语 · 无知的", now: false)
            arrow
            step("nice", "中古英语 · 愚蠢的", now: false)
            arrow
            step("nice", "今天 · 令人愉快的", now: true)
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var arrow: some View {
        Image(systemName: "arrow.right").font(.system(size: 8, weight: .semibold)).foregroundStyle(.tertiary)
    }

    private func step(_ form: String, _ caption: String, now: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(form)
                .font(.system(size: 14, weight: now ? .semibold : .medium, design: .serif).italic())
                .foregroundStyle(now ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
            Text(caption).font(.system(size: 9)).foregroundStyle(.tertiary)
        }
        .fixedSize()
    }
}

// MARK: - Buttons

private struct HomeButton: View {
    let title: String
    let symbol: String
    var key: String?
    var prominent = false
    let action: () -> Void

    @Stored private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 11, weight: .medium))
                Text(title).font(.system(size: 12, weight: .medium))
                if let key {
                    Text(key)
                        .font(.system(size: 10.5, weight: .medium, design: .rounded))
                        .foregroundStyle(prominent ? AnyShapeStyle(Color.white.opacity(0.7)) : AnyShapeStyle(.tertiary))
                }
            }
            .foregroundStyle(prominent ? AnyShapeStyle(Color.white) : AnyShapeStyle(.primary))
            .padding(.horizontal, 13)
            .padding(.vertical, 7)
            .background {
                Capsule().fill(prominent ? AnyShapeStyle(Color.accentColor.opacity(hovering ? 0.88 : 1))
                                         : AnyShapeStyle(Color.primary.opacity(hovering ? 0.07 : 0.03)))
            }
            .overlay {
                if !prominent { Capsule().strokeBorder(Chrome.chipStroke, lineWidth: 1) }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Motion.tap, value: hovering)
    }
}

// MARK: - Clipboard

/// What is on the clipboard, looked at without asking the system for it.
///
/// macOS asks the user before an app reads the general pasteboard on its own,
/// so the text itself is only read where the user has already said yes for
/// good. Everywhere else this looks at the *types* on the pasteboard — which
/// is not a read of its contents — and offers the paste, which is.
@MainActor @Observable
final class ClipboardPeek {
    enum Content: Equatable {
        case text(preview: String, stats: String)
        /// A text already read here: offered back rather than started again.
        case known(DocumentSummary)
        case word(String, hook: String?)
        /// There is text, but reading it would raise a permission alert.
        case unread
    }

    private(set) var content: Content?
    private var seen = -1
    private var timer: Task<Void, Never>?

    func start() {
        // Looked at afresh each time the page appears: the same clipboard
        // may have become a document read since.
        seen = -1
        refresh()
        timer?.cancel()
        timer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1.5))
                self?.refresh()
            }
        }
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func refresh() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != seen else { return }
        seen = pasteboard.changeCount
        guard pasteboard.availableType(from: [.string]) != nil else {
            content = nil
            return
        }
        guard pasteboard.accessBehavior == .alwaysAllow else {
            content = .unread
            return
        }
        content = pasteboard.string(forType: .string).flatMap(Self.classify)
    }

    static func classify(_ raw: String) -> Content? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if EtymologyStore.isWord(text) {
            let word = EtymologyStore.normalised(text)
            return .word(word, hook: EtymologyStore.shared.cached(word)?.hook)
        }
        if let known = DocumentStore.shared.summary(fingerprint: DocumentStore.fingerprint(of: text)) {
            return .known(known)
        }
        let sample = String(text.prefix(200_000))
        let language = Language.detect(sample)
        let cjk = [.simplifiedChinese, .traditionalChinese, .japanese, .korean].contains(language)
        let size = cjk ? sample.count { !$0.isWhitespace } : sample.split(whereSeparator: \.isWhitespace).count
        // Below this it is a sentence, and a sentence is the panel's job.
        guard size >= (cjk ? 120 : 40) else { return nil }
        let (format, blocks) = DocumentParser.parse(sample)
        let segments = blocks.count { !$0.kind.isVerbatim }
        let unit = cjk ? "字" : "词"
        let kind = format == .markdown ? " · Markdown" : ""
        let stats = "\(language.displayName)\(kind) · \(size.formatted()) \(unit) · 约 \(segments) 段"
        let preview = text.prefix(400).split(whereSeparator: \.isNewline).joined(separator: " ")
        return .text(preview: preview, stats: stats)
    }
}

/// A text dropped on the page: a file, or a selection dragged out of
/// another app.
struct DroppedText: Transferable {
    let text: String
    /// The file's name, for when the text has no title of its own.
    var name: String?
    var isMarkdownFile = false

    static var transferRepresentation: some TransferRepresentation {
        // Markdown first: it is also plain text, and the plain-text
        // representation would take it without knowing what it was.
        FileRepresentation(importedContentType: UTType("net.daringfireball.markdown") ?? .plainText) { received in
            DroppedText(text: try Self.read(received.file),
                        name: received.file.deletingPathExtension().lastPathComponent,
                        isMarkdownFile: true)
        }
        FileRepresentation(importedContentType: .plainText) { received in
            DroppedText(text: try Self.read(received.file),
                        name: received.file.deletingPathExtension().lastPathComponent,
                        isMarkdownFile: DocumentParser.isMarkdownFile(received.file))
        }
        ProxyRepresentation(importing: { (text: String) in DroppedText(text: text) })
    }

    /// Plain text in whatever encoding it was saved in; UTF-8 first because
    /// it almost always is.
    static func read(_ url: URL) throws -> String {
        if let text = try? String(contentsOf: url, encoding: .utf8) { return text }
        var encoding = String.Encoding.utf8
        return try String(contentsOf: url, usedEncoding: &encoding)
    }
}
