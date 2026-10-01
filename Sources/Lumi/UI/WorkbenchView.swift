import SwiftUI

/// The 工作台 window: paste a long text, read it a segment at a time with the
/// original beside it.
///
/// Built from the panel's parts — see `Chrome` — but not laid out like the
/// panel, and deliberately so. The panel is an object floating over the
/// desktop, which is why it is glass all the way round. This is a document, and
/// a document window that puts a layer under every row stops reading as one
/// page and starts reading as a stack of cards. So there is exactly one piece
/// of chrome, along the top, and below it nothing but text on paper.
struct WorkbenchView: View {
    @Bindable var document: WorkbenchDocument
    /// Lets the window title follow the document without the view reaching for
    /// the controller singleton.
    var onTitleChange: (String) -> Void = { _ in }

    @Stored private var settings = AppSettings.shared
    @Stored private var showNotes = false
    /// Which flagged segment the warning badge last jumped to, so pressing it
    /// again goes to the next one instead of bouncing on the first.
    @Stored private var lastJumped: Int?

    var body: some View {
        Group {
            if document.isLoaded { reader } else { Color.clear }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: windowTitle) { onTitleChange(windowTitle) }
    }

    private var windowTitle: String { document.isLoaded ? document.title : t("工作台") }


    // MARK: - Reading

    private var reader: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                VStack(spacing: 0) {
                    header(jump: { jumpToFlag(proxy) })
                    if showNotes { NotesStrip(document: document) }
                    if let problem = document.engineProblem {
                        EngineProblemCard(text: problem)
                    }
                }
                progressRule
                segmentList
                    .task(id: document.id) { await restorePlace(proxy) }
            }
            .animation(Motion.settle, value: showNotes)
            .animation(Motion.settle, value: document.engineProblem)
            .onChange(of: document.scrollRequest) { _, request in
                guard let request else { return }
                withAnimation(Motion.settle) { proxy.scrollTo(request, anchor: .top) }
                lastJumped = request
                document.clearScrollRequest()
            }
        }
    }

    private var segmentList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(document.segments) { segment in
                    SegmentRow(
                        segment: segment,
                        number: segment.id + 1,
                        scale: settings.fontScale,
                        target: document.resolvedTarget,
                        markdown: document.format == .markdown,
                        proof: document.isProof,
                        actions: actions(for: segment.id)
                    )
                    .id(segment.id)
                }
            }
            .scrollTargetLayout()
            // A reading measure, not a window width. Left to fill a maximised
            // 27" display each column would set 140-character lines, which is
            // roughly twice what anyone tracks without losing their place.
            .frame(maxWidth: 1180)
            .frame(maxWidth: .infinity)
            .padding(.bottom, 40)
        }
        // Records where the reader is, which is what the start page's 接着读
        // reads.
        .onScrollTargetVisibilityChange(idType: Int.self, threshold: 0.4) { visible in
            guard let top = visible.min() else { return }
            document.noteVisible(top: top, all: visible)
        }
        .background(Paper.fill)
    }

    private func actions(for id: Int) -> SegmentActions {
        let document = document
        return SegmentActions(
            retranslate: { document.retry(id) },
            review: { document.review([id]) },
            accept: { document.accept($0, in: id) },
            undo: { document.undoAccept($0, in: id) },
            dismiss: { document.dismiss($0, in: id) },
            restoreDismissed: { document.restoreDismissed(in: id) },
            edit: { document.edit(id, to: $0) },
            insertGap: { document.insertGap(at: id) },
            pullNext: { document.pullNext(into: id) }
        )
    }

    // MARK: Header

    /// One row. Left to right: what direction, by what engine, then — pushed to
    /// the far side — how it is going and the buttons that start it.
    private func header(jump: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            DirectionChip(source: document.resolvedSource, target: document.resolvedTarget)
            EngineSwitch(document: document)

            Spacer(minLength: 10)

            StatusReadout(document: document, jump: jump)

            IconButton(
                symbol: document.context.isEmpty ? "text.alignleft" : "text.badge.checkmark",
                help: document.isProof ? t("文档说明与术语表") : t("文档说明：领域、术语、语体"),
                active: showNotes || !document.context.isEmpty
            ) {
                withAnimation(Motion.settle) { showNotes.toggle() }
            }

            reviewChip
            actionChip
            overflowMenu
        }
        .padding(.horizontal, 14)
        .frame(height: 46)
    }

    /// Proofreading, offered on a read document once there is a translation
    /// to proofread. On a document brought in for proofreading it is the
    /// primary action instead, and lives in `actionChip`.
    @ViewBuilder
    private var reviewChip: some View {
        if !document.isProof, !document.isRunning, document.doneCount > 0 {
            ActionChip(title: document.hasReview ? t("重新校对") : t("校对"), symbol: "checkmark.seal",
                       prominent: false) { document.review() }
                .help(document.reviewsWithModel ? t("逐段审读译文，并做机检") : t("机检：数字、术语表、格式、篇幅"))
                .transition(.opacity)
        }
    }

    @ViewBuilder
    private var actionChip: some View {
        let total = document.workSegments.count
        if document.isRunning {
            ActionChip(title: t("停止"), symbol: "stop.fill", prominent: false) { document.cancel() }
        } else if document.isProof {
            if document.hasReview {
                ActionChip(title: t("重新校对"), symbol: "arrow.clockwise", prominent: false) { document.review() }
                    .keyboardShortcut(.return, modifiers: .command)
            } else {
                ActionChip(title: t("校对"), symbol: "checkmark.seal", prominent: true) { document.review() }
                    .keyboardShortcut(.return, modifiers: .command)
            }
        } else if document.doneCount == total {
            ActionChip(title: t("重译全文"), symbol: "arrow.clockwise", prominent: false) {
                document.translateAll()
            }
            .keyboardShortcut(.return, modifiers: .command)
        } else if document.doneCount == 0 {
            ActionChip(title: t("翻译"), symbol: "sparkles", prominent: true) { document.translateAll() }
                .keyboardShortcut(.return, modifiers: .command)
        } else {
            ActionChip(title: t("继续"), symbol: "play.fill", prominent: true) {
                document.retryUnfinished()
            }
            .keyboardShortcut(.return, modifiers: .command)
        }
    }

    private var overflowMenu: some View {
        Menu {
            Button(document.format == .markdown ? t("复制全部译文（Markdown）") : t("复制全部译文")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(document.exportedTranslation, forType: .string)
            }
            .disabled(document.exportedTranslation.isEmpty)
            Button(t("导出译文…")) { WorkbenchController.shared.exportTranslation() }
                .disabled(document.exportedTranslation.isEmpty)
            if document.hasReview {
                Button(t("复制校对意见")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(document.reviewReport, forType: .string)
                }
                .disabled(document.openIssueCount == 0)
            }
            Divider()
            Button(t("换一篇…")) { WorkbenchController.shared.navigation.go(.home) }
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

    /// Progress as the line that separates chrome from page.
    ///
    /// The row of numbers beside it already answers "how much is done"; what a
    /// bar adds is *motion*, and 2pt of accent creeping along an edge the
    /// window needed anyway buys that for no layout at all. It doubles as the
    /// only separator under the toolbar, so nothing moves when it fills.
    private var progressRule: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.12))
            .frame(height: 2)
            .overlay(alignment: .leading) {
                GeometryReader { geometry in
                    Rectangle()
                        .fill(Color.accentColor)
                        .frame(width: geometry.size.width * document.progress)
                        .opacity(document.progress < 1 || document.isRunning ? 1 : 0)
                }
            }
            .animation(Motion.settle, value: document.progress)
    }

    /// Opens a document where the reader left it.
    ///
    /// Asked more than once: the reader arrives inside a cross-fade, and a
    /// lazy list mid-transition drops a scroll request it cannot yet measure
    /// its way to. The document says when the row has actually reached the
    /// top; past a second and a half, whatever is on screen is the place.
    private func restorePlace(_ proxy: ScrollViewProxy) async {
        guard let place = document.placeToRestore else { return }
        for _ in 0..<15 {
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled, document.placeToRestore == place else { return }
            proxy.scrollTo(place, anchor: .top)
        }
        document.finishRestoring()
    }

    private func jumpToFlag(_ proxy: ScrollViewProxy) {
        let flagged = document.flaggedIDs
        guard !flagged.isEmpty else { return }
        let next = flagged.first { $0 > (lastJumped ?? -1) } ?? flagged[0]
        lastJumped = next
        withAnimation(Motion.settle) { proxy.scrollTo(next, anchor: .center) }
    }
}

// MARK: - Direction

/// The same capsule the panel wears, doing less.
///
/// Read-only, because the workbench decides direction from the document rather
/// than from a picker — a paper does not change language halfway down. Shaped
/// like the panel's picker anyway: it is the same fact in the same place, and
/// making it look like a different kind of thing would be the lie.
private struct DirectionChip: View {
    let source: Language
    let target: Language

    var body: some View {
        HStack(spacing: 4) {
            Text(source.displayName)
            Image(systemName: "arrow.right")
                .font(.system(size: 7.5, weight: .bold))
                .foregroundStyle(.tertiary)
            Text(target.displayName)
        }
        .font(Chrome.chipFont)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .chipShell()
        .help(t("按文章开头自动判断，整篇统一"))
    }
}

// MARK: - Which engine

/// The control this whole window turns on.
///
/// A switch rather than a menu, because the choice is not a setting buried
/// among others — it is *what kind of translation this is*, and a reader who
/// cannot see that there are two answers will never know they are reading the
/// weaker one. The selected half slides, which is the cheapest way to say the
/// two are alternatives rather than two buttons that happen to be adjacent.
struct EngineSwitch: View {
    @Bindable var document: WorkbenchDocument

    var body: some View {
        EngineToggle(
            selection: $document.engineID,
            onlineUnconfigured: unconfigured,
            disabled: document.isRunning,
            help: detail
        )
        .help(document.isRunning ? t("翻译进行中，停止后才能换引擎") : "")
    }

    private var unconfigured: Bool { AppSettings.shared.workbenchOnlineProvider() == nil }

    private func detail(_ id: WorkbenchEngineID) -> String {
        switch id {
        case .offline: return OfflineWorkbenchEngine().detail
        case .online:
            guard let provider = AppSettings.shared.workbenchOnlineProvider() else {
                return t("尚未启用任何语言模型，请先在设置里开启一个并填好 Key。")
            }
            return t("%@：读得到标题、术语表和上下段，术语前后一致。需要联网。", provider.displayName)
        }
    }
}

// MARK: - How it is going

/// Counts, and one badge that takes you somewhere.
///
/// A number alone tells the reader there are three suspect segments in a
/// forty-segment paper and leaves them to find them; the badge is a button, so
/// pressing it walks through them. That is the difference between reporting a
/// problem and handing over the fix.
private struct StatusReadout: View {
    @Bindable var document: WorkbenchDocument
    let jump: () -> Void

    private var attention: Int {
        document.droppedCount + document.failedCount + document.openIssueCount + document.reviewFailedCount
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(line)
                .font(Chrome.chipFont)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .fixedSize()
            if attention > 0 {
                Button(action: jump) {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 9))
                        Text(document.isProof ? t("%d 处待改", attention) : t("%d 处待查", attention))
                            .font(Chrome.chipFont)
                            .monospacedDigit()
                    }
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background { Capsule().fill(Color.orange.opacity(0.12)) }
                    .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .help(t("跳到下一处要看的段落"))
                .fixedSize()
                .transition(.scale.combined(with: .opacity))
            } else if document.hasReview, !document.isRunning {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.seal.fill").font(.system(size: 9.5))
                    Text(t("无待改")).font(Chrome.chipFont)
                }
                .foregroundStyle(.green)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background { Capsule().fill(Color.green.opacity(0.1)) }
                .fixedSize()
                .help(t("校对完，没有未处理的意见"))
                .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(Motion.pop, value: attention)
    }

    private var line: String {
        let total = document.workSegments.count
        if document.activity == .reviewing {
            return t("已校 %d/%d 段", document.reviewedCount + document.reviewFailedCount, total)
        }
        if document.checkingTerms { return t("全文比对术语…") }
        if document.isProof {
            return document.hasReview ? t("%d 段 · %@", total, document.reviewerLabel) : t("%d 段", total)
        }
        let done = document.doneCount
        let engine = document.engineID == .online
            ? AppSettings.shared.workbenchOnlineProvider()?.displayName
            : nil
        let counts = done == 0 || done == total ? t("%d 段", total) : t("%d/%d 段", done, total)
        return [engine, counts].compactMap(\.self).joined(separator: " · ")
    }
}

// MARK: - Document notes

/// The instructions that ride along with every segment, kept reachable after
/// loading rather than only on the way in.
///
/// It was previously only on the empty-state form, which meant the reader who
/// discovered halfway down a paper that the model was calling 注意力 "care"
/// had no way to say so without starting over.
private struct NotesStrip: View {
    @Bindable var document: WorkbenchDocument

    var body: some View {
        let usable = document.engine.usesDocumentContext
        VStack(alignment: .leading, spacing: 5) {
            TextField(t("这是一篇什么文章？术语、语体上有什么要求？术语表每行一条，如 attention = 注意力"),
                      text: $document.context, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .lineLimit(1...5)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(.rect(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8).strokeBorder(Chrome.chipStroke, lineWidth: 1)
                }
            Text(caption(usable: usable))
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    /// The glossary is checked by machine whatever the engine; the prose is
    /// read only by a model. Saying which is which beats greying out a field
    /// that half works.
    private func caption(usable: Bool) -> String {
        let terms = ProofCheck.glossary(from: document.context).count
        let glossary = terms > 0 ? t("识别到 %d 条术语，校对时逐段核对。", terms) : ""
        if document.isProof {
            return glossary + (usable ? t("改完之后重新校对才会生效。") : t("本机只核对术语表；其余说明要联网模型才读得到。"))
        }
        return glossary + (usable ? t("改完之后重译才会生效。") : t("本机翻译逐句工作，读不到这些说明——换成联网才会用上。"))
    }
}

// MARK: - Engine can't run

/// Inset card, not a full-bleed band.
///
/// A coloured strip edge to edge reads as the window being broken; this is one
/// engine declining one job, and it comes with the button that fixes it.
private struct EngineProblemCard: View {
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 11))
            Text(text)
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            SettingsLink {
                Text(t("打开设置"))
                    .font(Chrome.chipFont)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .overlay { Capsule().strokeBorder(Color.orange.opacity(0.5), lineWidth: 1) }
            }
            .buttonStyle(.plain)
            .fixedSize()
        }
        .foregroundStyle(.orange)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color.orange.opacity(0.1))
        .clipShape(.rect(cornerRadius: 10))
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }
}

// MARK: - The primary action

/// The one saturated thing in either window.
///
/// Same capsule as every chip, filled instead of outlined. A stock
/// `.borderedProminent` button would have been the only AppKit-shaped control
/// in an app built entirely out of capsules; this is the same vocabulary turned
/// up, which is what "primary" should mean.
struct ActionChip: View {
    let title: String
    let symbol: String
    let prominent: Bool
    let action: () -> Void

    @Stored private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 9.5, weight: .bold))
                Text(title).font(.system(size: 11.5, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(prominent ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background {
                Capsule().fill(
                    prominent
                        ? AnyShapeStyle(Color.accentColor.opacity(hovering ? 1 : 0.9))
                        : AnyShapeStyle(Color.clear)
                )
            }
            .overlay {
                if !prominent {
                    Capsule().strokeBorder(Chrome.chipStroke, lineWidth: 1)
                }
            }
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Motion.tap, value: hovering)
    }
}

