import SwiftUI

// MARK: - Nothing loaded yet

/// Typing or pasting a text in by hand — reached from 手动输入 or ⌘N. Most
/// texts arrive without it: pasted, dropped or opened on the start page.
struct ComposeView: View {
    @Bindable var document: WorkbenchDocument
    @Stored private var draft = ""
    /// Its own, not the document's: the document on the model may still be
    /// the previous paper, which must not pick up this one's notes.
    @Stored private var notesDraft = ""
    @Stored private var dropping = false
    /// Set when a Markdown file was dropped in, so it is cut as Markdown
    /// whether or not it looks like it.
    @Stored private var droppedFormat: TextFormat?
    @Stored private var droppedTitle: String?
    @FocusState private var editorFocused: Bool

    private var isBlank: Bool {
        draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The editor fills the pane. Someone pasting a paper needs to see a
    /// paper's worth of it, and a 620pt box floated in the middle of a wide
    /// window — the previous layout — spent most of the window on margins.
    var body: some View {
        VStack(spacing: 0) {
            masthead
            Rectangle().fill(Color.primary.opacity(0.12)).frame(height: 2)
            VStack(alignment: .leading, spacing: 12) {
                editor.frame(maxHeight: .infinity)
                notes
                footer
            }
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Paper.fill)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { editorFocused = true }
    }

    private var masthead: some View {
        HStack(spacing: 10) {
            Text("新文稿").font(.system(size: 14, weight: .semibold))
            Text("输入或粘贴原文，逐段对照着读。漏掉的句子会被标出来。")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 16)
        .frame(height: 46)
    }

    private var editor: some View {
        TextEditor(text: $draft)
            .font(.system(size: 13))
            .scrollContentBackground(.hidden)
            // The system attaches a Writing Tools affordance to every text
            // view, and it floats outside a custom-clipped one — but the real
            // reason to drop it is that this box holds the *source*. Rewriting
            // the text to be translated corrupts the only reference the reader
            // has to check the translation against.
            .writingToolsBehavior(.disabled)
            .focused($editorFocused)
            .padding(10)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(.rect(cornerRadius: 12))
            .overlay(alignment: .topLeading) {
                if isBlank {
                    Text("在这里粘贴原文，或把选中的文字拖进来")
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 15)
                        .padding(.vertical, 18)
                        .allowsHitTesting(false)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(borderTint, style: StrokeStyle(
                        lineWidth: dropping ? 2 : 1,
                        dash: dropping ? [5, 4] : []
                    ))
            }
            .dropDestination(for: DroppedText.self) { items, _ in
                guard let item = items.first else { return false }
                if draft.isEmpty {
                    droppedTitle = item.name
                    droppedFormat = item.isMarkdownFile ? .markdown : nil
                }
                draft = draft.isEmpty ? item.text : draft + "\n\n" + item.text
                return true
            } isTargeted: { dropping = $0 }
            .animation(Motion.tap, value: dropping)
            .animation(Motion.tap, value: editorFocused)
    }

    private var borderTint: Color {
        if dropping { return .accentColor }
        return editorFocused ? Color.accentColor.opacity(0.5) : Chrome.chipStroke
    }

    /// Greyed out under the on-device engine rather than hidden. Hiding it
    /// would make the feature look absent; disabling it with the reason
    /// attached is what tells the reader that the choice of engine is what
    /// costs them their glossary.
    @ViewBuilder
    private var notes: some View {
        let usable = document.engine.usesDocumentContext
        VStack(alignment: .leading, spacing: 5) {
            TextField("这是一篇什么文章？术语、语体上有什么要求？（可留空）",
                      text: $notesDraft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .lineLimit(1...3)
                .disabled(!usable)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Color(nsColor: .textBackgroundColor).opacity(usable ? 1 : 0.4))
                .clipShape(.rect(cornerRadius: 9))
                .overlay {
                    RoundedRectangle(cornerRadius: 9)
                        .strokeBorder(Chrome.chipStroke, lineWidth: 1)
                }
            if !usable {
                Text("本机翻译逐句工作，读不到这些说明——换成联网才会用上。")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            EngineSwitch(document: document)
            if droppedFormat == .markdown || (!isBlank && Markdown.looksLikeMarkdown(draft)) {
                Text("Markdown")
                    .font(Chrome.chipFont)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .overlay { Capsule().strokeBorder(Chrome.chipStroke, lineWidth: 1) }
                    .help("按标题、列表、表格分段；代码块和公式原样保留，不翻译")
                    .fixedSize()
                    .transition(.opacity)
            }
            Spacer()
            if !isBlank {
                Text("⌘↩")
                    .font(.system(size: 10.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.tertiary)
                    .transition(.opacity)
            }
            ActionChip(title: "开始", symbol: "sparkles", prominent: true) {
                guard !isBlank else { return }
                let text = draft
                if WorkbenchController.shared.start(text, fallbackTitle: droppedTitle, format: droppedFormat) {
                    if !notesDraft.isEmpty { document.context = notesDraft }
                    draft = ""
                    notesDraft = ""
                    droppedTitle = nil
                    droppedFormat = nil
                    document.translateAll()
                }
            }
            .disabled(isBlank)
            .keyboardShortcut(.return, modifiers: .command)
        }
        .animation(Motion.tap, value: isBlank)
    }
}

// MARK: - Proofreading

/// A source and someone else's translation, side by side, before they are
/// paired and checked.
///
/// Two boxes of equal weight, because both are inputs: this page is for the
/// reader who already has a translation — a colleague's, a vendor's, their
/// own draft — and wants to know what is wrong with it, not for getting one.
struct ProofComposeView: View {
    @Bindable var document: WorkbenchDocument

    @Stored private var source = ""
    @Stored private var translation = ""
    @Stored private var notes = ""
    @Stored private var fileTitle: String?
    @Stored private var fileFormat: TextFormat?
    @FocusState private var focus: Side?

    enum Side: Hashable { case source, translation }

    private var ready: Bool {
        !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var markdown: Bool {
        fileFormat == .markdown || Markdown.looksLikeMarkdown(source) || Markdown.looksLikeMarkdown(translation)
    }

    var body: some View {
        VStack(spacing: 0) {
            masthead
            Rectangle().fill(Color.primary.opacity(0.12)).frame(height: 2)
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    pane(.source)
                    pane(.translation)
                }
                .frame(maxHeight: .infinity)
                notesField
                footer
            }
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Paper.fill)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { focus = .source }
    }

    private var masthead: some View {
        HStack(spacing: 10) {
            Text("校对译文").font(.system(size: 14, weight: .semibold))
            Text("放进原文和译文，逐段标出漏译、错译和前后不一的术语。")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 16)
        .frame(height: 46)
    }

    private func binding(_ side: Side) -> Binding<String> {
        side == .source ? $source : $translation
    }

    private func pane(_ side: Side) -> some View {
        let text = side == .source ? source : translation
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text(side == .source ? "原文" : "译文")
                    .font(.system(size: 12, weight: .semibold))
                Text(stats(text))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
                Spacer()
                Button {
                    WorkbenchController.shared.chooseFile { content, title, format in
                        binding(side).wrappedValue = content
                        if side == .source { fileTitle = title }
                        if format == .markdown { fileFormat = .markdown }
                    }
                } label: {
                    Label("打开文件…", systemImage: "folder")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
            }
            ProofEditor(
                text: binding(side),
                placeholder: side == .source
                    ? "粘贴原文，或把 .txt、.md 文件拖进来"
                    : "粘贴要校对的译文",
                focused: focus == side
            ) { dropped in
                binding(side).wrappedValue = dropped.text
                if side == .source, let name = dropped.name { fileTitle = name }
                if dropped.isMarkdownFile { fileFormat = .markdown }
            }
            .focused($focus, equals: side)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func stats(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let sample = String(trimmed.prefix(4000))
        let language = Language.detect(sample)
        let cjk = [.simplifiedChinese, .traditionalChinese, .japanese, .korean].contains(language)
        let size = cjk ? trimmed.count { !$0.isWhitespace } : trimmed.split(whereSeparator: \.isWhitespace).count
        return "\(language.displayName) · \(size.formatted()) \(cjk ? "字" : "词")"
    }

    private var notesField: some View {
        VStack(alignment: .leading, spacing: 5) {
            TextField("术语表和要求（可留空）。术语每行一条，如：attention = 注意力",
                      text: $notes, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .lineLimit(1...4)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(.rect(cornerRadius: 9))
                .overlay {
                    RoundedRectangle(cornerRadius: 9).strokeBorder(Chrome.chipStroke, lineWidth: 1)
                }
            let terms = ProofCheck.glossary(from: notes).count
            if terms > 0 {
                Text("识别到 \(terms) 条术语，每段都会核对译法。")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            EngineSwitch(document: document)
            Text(engineCaption)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            if markdown {
                Text("Markdown")
                    .font(Chrome.chipFont)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .overlay { Capsule().strokeBorder(Chrome.chipStroke, lineWidth: 1) }
                    .help("按标题、列表、表格对齐，代码块不参与校对")
                    .fixedSize()
            }
            Spacer(minLength: 8)
            if ready, !document.aligning {
                Text("⌘↩")
                    .font(.system(size: 10.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.tertiary)
                    .transition(.opacity)
            }
            if document.aligning {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("正在按意思对齐段落…").font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
                .transition(.opacity)
            }
            ActionChip(title: document.aligning ? "对齐中" : "开始校对", symbol: "checkmark.seal",
                       prominent: true) { begin() }
                .disabled(!ready || document.aligning)
                .keyboardShortcut(.return, modifiers: .command)
        }
        .animation(Motion.tap, value: ready)
        .animation(Motion.tap, value: document.aligning)
    }

    private var engineCaption: String {
        if document.engineID == .offline { return "本机只做机检：数字、术语表、格式、篇幅" }
        guard let provider = AppSettings.shared.workbenchOnlineProvider() else {
            return "没有启用语言模型，只能做机检"
        }
        return "\(provider.displayName) 逐段审读意思，外加机检"
    }

    private func begin() {
        guard ready, !document.aligning else { return }
        Task {
            let started = await WorkbenchController.shared.startProof(
                source: source, translation: translation, fallbackTitle: fileTitle,
                format: fileFormat, notes: notes
            )
            if started {
                source = ""
                translation = ""
                notes = ""
                fileTitle = nil
                fileFormat = nil
            }
        }
    }
}

/// One side of the pair: a plain editor that also takes a dropped file.
private struct ProofEditor: View {
    @Binding var text: String
    let placeholder: String
    let focused: Bool
    let onDrop: (DroppedText) -> Void

    @Stored private var dropping = false

    var body: some View {
        TextEditor(text: $text)
            .font(.system(size: 12.5))
            .scrollContentBackground(.hidden)
            .writingToolsBehavior(.disabled)
            .padding(10)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(.rect(cornerRadius: 12))
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 15)
                        .padding(.vertical, 18)
                        .allowsHitTesting(false)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(dropping ? Color.accentColor
                                           : (focused ? Color.accentColor.opacity(0.5) : Chrome.chipStroke),
                                  style: StrokeStyle(lineWidth: dropping ? 2 : 1, dash: dropping ? [5, 4] : []))
            }
            .dropDestination(for: DroppedText.self) { items, _ in
                guard let item = items.first else { return false }
                onDrop(item)
                return true
            } isTargeted: { dropping = $0 }
            .animation(Motion.tap, value: dropping)
            .animation(Motion.tap, value: focused)
    }
}
