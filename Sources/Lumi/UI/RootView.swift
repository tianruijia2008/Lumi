import SwiftUI

/// The panel.
///
/// Two glass surfaces and no more: the sheet, because the window is an object
/// floating over the desktop, and the input capsule, because it is the one
/// control the user operates directly. Glass marks *interactive*, not
/// *decorative* — the moment every row gets a layer the window stops reading
/// as one object and starts reading as a stack of lozenges.
struct RootView: View {
    @Bindable var state: AppState
    @Stored private var settings = AppSettings.shared
    @FocusState private var inputFocused: Bool
    @Stored private var draft = ""
    /// Whether the query field is showing its full text. Reset on every new
    /// query — expansion is a decision about one particular selection.
    @Stored private var inputExpanded = false
    @Stored private var fieldHeight: CGFloat = 0
    @Stored private var fullTextHeight: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            input
            results
        }
        .frame(width: settings.panelWidth)
        .fixedSize(horizontal: false, vertical: true)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
        .onAppear { inputFocused = true }
        // A hot-key capture writes straight into state; mirror it into the
        // field so the user can edit what was grabbed.
        //
        // Keyed on the capture counter rather than on `queryText`: the field
        // submitting also changes `queryText`, and mirroring that back would
        // retype the query after "查询后清空输入" had just cleared it. The
        // counter ticks only when text arrives from outside the panel — a
        // selection grab or a screen capture — and ticks again, with an empty
        // `captureText`, the moment one of those starts, so the box empties
        // rather than holding the previous query over a new capture.
        //
        // `task(id:)` rather than `onAppear` plus `onChange`: those two cover
        // the update only if the capture lands either strictly before the view
        // appears or strictly after, and a capture delivered in the same turn
        // the panel opens falls between them — leaving the field blank under a
        // full set of results. This fires on appearance *and* on every later
        // change, so there is no gap.
        .task(id: state.captureSerial) {
            draft = state.captureText
            inputExpanded = false
        }
    }

    // MARK: Header

    /// Language pair, then empty space that drags the window, then the two
    /// window-level controls.
    ///
    /// The old design had a dedicated grab bar above this. A visible handle is
    /// an admission that dragging is undiscoverable, and it spent 12pt at the
    /// very top of the window — the first place the eye lands. A toolbar you
    /// drag by its gaps is the same gesture every Mac window already has.
    private var header: some View {
        HStack(spacing: 6) {
            languageChip

            WindowDragArea()
                .frame(minWidth: 24, maxWidth: .infinity)

            iconButton(settings.pinPanel ? "pin.fill" : "pin",
                       help: settings.pinPanel ? "已固定，点击别处不会收起" : "固定窗口",
                       active: settings.pinPanel) {
                withAnimation(Motion.tap) { settings.pinPanel.toggle() }
            }
            .rotationEffect(.degrees(settings.pinPanel ? 0 : 35))
            .animation(Motion.tap, value: settings.pinPanel)

            SettingsLink {
                Image(systemName: "gearshape")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 22, height: 22)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("设置")
        }
        .padding(.horizontal, 12)
        // The height belongs to the row rather than to padding above it:
        // padding is not part of any view, so a strip along the very top edge
        // of the window would not drag — which is exactly where someone
        // reaches for a window with no title bar.
        .frame(height: 36)
    }

    /// One compact chip instead of a whole row of pills. The direction picker
    /// is used on a small minority of queries; it does not deserve a permanent
    /// line of its own.
    private var languageChip: some View {
        HStack(spacing: 3) {
            languageMenu(title: sourceTitle, selection: $state.sourceOverride, includeAuto: true)

            Button(action: swapDirection) {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 16, height: 18)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help("对调方向")

            languageMenu(title: targetTitle, selection: targetBinding, includeAuto: false)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .chipShell()
    }

    private func languageMenu(
        title: String, selection: Binding<Language>, includeAuto: Bool
    ) -> some View {
        Menu {
            ForEach(Language.allCases.filter { includeAuto || $0 != .auto }) { language in
                Button(language.displayName) {
                    selection.wrappedValue = language
                    if !draft.isEmpty { state.submit(draft) }
                }
            }
        } label: {
            Text(title)
                .font(Chrome.chipFont)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    /// Before the first query there is nothing to detect, so the chip promises
    /// detection rather than naming a language it has not seen yet.
    private var sourceTitle: String {
        guard state.sourceOverride == .auto else { return state.sourceOverride.displayName }
        return state.cards.isEmpty ? "自动" : state.resolvedSource.displayName
    }

    /// Has to show the target that was *used*, not the preference: when the
    /// source turns out to be the preferred target's own language the query is
    /// redirected — asking for 中文→中文 is meaningless — and a chip still
    /// reading "English" over a Chinese translation is simply wrong.
    private var targetTitle: String {
        guard state.targetOverride == nil else { return state.resolvedTarget.displayName }
        return state.cards.isEmpty
            ? settings.secondLanguage.displayName
            : state.resolvedTarget.displayName
    }

    /// Choosing a direction pins it for this query rather than rewriting the
    /// user's language pair — the pair is a preference, not a per-query knob.
    private var targetBinding: Binding<Language> {
        Binding(
            get: { state.targetOverride ?? state.resolvedTarget },
            set: { state.targetOverride = $0 }
        )
    }

    private func swapDirection() {
        let newSource = state.targetOverride ?? state.resolvedTarget
        let newTarget = state.sourceOverride == .auto ? state.resolvedSource : state.sourceOverride
        state.sourceOverride = newSource
        state.targetOverride = newTarget
        if !draft.isEmpty { state.submit(draft) }
    }

    // MARK: Input

    /// The query field.
    ///
    /// A long selection is capped rather than allowed to push the result off
    /// the bottom of the window — but a cap with no way past it hides the very
    /// thing the user wants to check, which is *what got captured*. So the cap
    /// comes with a disclosure control, and it only appears when there is
    /// genuinely something below the fold.
    private var input: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "character.magnify")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(height: lineHeight)

            TextField("输入或粘贴要翻译的文本", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 14.5 * settings.fontScale))
                .lineLimit(1...(inputExpanded ? 14 : settings.inputCollapsedLines))
                .focused($inputFocused)
                .onSubmit(runQuery)
                // Measured rather than estimated: whether the text overflows
                // depends on the field's real width, which changes as the
                // buttons beside it come and go.
                .background(alignment: .topLeading) { overflowProbe }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { fieldHeight = $0 }

            controls
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: inputCornerRadius))
        .padding(.horizontal, 10)
        .padding(.top, 6)
        .padding(.bottom, state.cards.isEmpty && state.lastError == nil ? 10 : 8)
        .animation(Motion.pop, value: state.isRunning)
        .animation(Motion.pop, value: draft.isEmpty)
        .animation(Motion.settle, value: inputExpanded)
    }

    @ViewBuilder
    private var controls: some View {
        VStack(spacing: 2) {
            if state.isRunning {
                iconButton("stop.fill", help: "停止") { state.cancel() }
                    .transition(.scale.combined(with: .opacity))
            } else if !draft.isEmpty {
                iconButton("xmark", help: "清空") { state.clear(); draft = "" }
                    .transition(.scale.combined(with: .opacity))
            }

            if inputOverflows || inputExpanded {
                iconButton(inputExpanded ? "chevron.up" : "chevron.down",
                           help: inputExpanded ? "收起" : "展开全文") {
                    withAnimation(Motion.settle) { inputExpanded.toggle() }
                }
                .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(Motion.tap, value: inputOverflows)
    }

    /// A copy of the text laid out without a line limit, sized to the field's
    /// own width. Never drawn — only its height is read.
    private var overflowProbe: some View {
        Text(draft)
            .font(.system(size: 14.5 * settings.fontScale))
            .fixedSize(horizontal: false, vertical: true)
            .hidden()
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { fullTextHeight = $0 }
    }

    /// True when the collapsed field is showing less than the whole query.
    ///
    /// Comparing the two measured heights rather than counting characters:
    /// a line of Chinese and a line of English hold wildly different numbers
    /// of them.
    private var inputOverflows: Bool { fullTextHeight > fieldHeight + 1 }

    private var lineHeight: CGFloat {
        NSFont.systemFont(ofSize: 14.5 * settings.fontScale).boundingRectForFont.height
    }

    /// A capsule only reads right while the field is one line tall; past that
    /// the curve eats the corners of the text.
    private var inputCornerRadius: CGFloat {
        fieldHeight > lineHeight * 1.6 ? 16 : 999
    }

    private func runQuery() {
        state.submit(draft)
        if settings.clearInputAfterQuery { draft = "" }
    }

    // MARK: Results

    @ViewBuilder
    private var results: some View {
        if let error = state.lastError {
            Text(error)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
                .transition(.opacity)
        }

        if !state.cards.isEmpty {
            ServiceRail(cards: state.cards, focused: state.focusedService) { kind in
                state.focus(kind)
            }
            .padding(.bottom, 9)

            Divider().opacity(0.5)

            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 9) {
                    if let notice = state.fallbackNotice {
                        fallbackLine(notice)
                    }
                    if let card = state.focusedCard {
                        ResultBodyView(card: card, scale: settings.fontScale)
                            .id(card.id)
                            .transition(.bodySwap)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 13)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: settings.resultsMaxHeight)
            .scrollBounceBehavior(.basedOnSize)
            .scrollIndicators(.never)

            if let teaser = state.etymologyTeaser {
                EtymologyTeaserRow(teaser: teaser)
                    .padding(.horizontal, 10)
                    .padding(.top, 8)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            actionBar
        }
    }

    /// One quiet line, not a banner: the user asked for a translation and got
    /// one, so this is a footnote about provenance rather than a problem.
    private func fallbackLine(_ notice: (symbol: String, text: String)) -> some View {
        HStack(spacing: 5) {
            Image(systemName: notice.symbol).font(.system(size: 9.5))
            Text(notice.text).font(.system(size: 11))
        }
        .foregroundStyle(.secondary)
        .transition(.opacity)
    }

    // MARK: Actions

    /// Always present, so arriving results never change the sheet's height by
    /// adding or removing a row.
    private var actionBar: some View {
        HStack(spacing: 2) {
            // The second drag handle, and the larger one: a full-width strip
            // along the bottom edge that only the three buttons interrupt.
            WindowDragArea()

            HStack(spacing: 2) {
                CopyButton(text: state.focusedCard?.text ?? "")
                iconButton("speaker.wave.2", help: "朗读") {
                    guard let text = state.focusedCard?.text, !text.isEmpty else { return }
                    Speaker.shared.speak(text, language: state.resolvedTarget)
                }
                iconButton("arrow.clockwise", help: "重新查询") {
                    state.submit(state.queryText)
                }
            }
            .fixedSize()
            .opacity(state.focusedCard?.hasContent == true ? 1 : 0.35)
        }
        .frame(height: 22)
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 8)
    }

    private func iconButton(
        _ symbol: String, help: String, active: Bool = false, action: @escaping () -> Void
    ) -> some View {
        IconButton(symbol: symbol, help: help, active: active, action: action)
    }
}

/// Copy needs its own state to show that it worked; everything else in the
/// action bar is stateless.
private struct CopyButton: View {
    let text: String
    @Stored private var copied = false

    var body: some View {
        Button {
            guard !text.isEmpty else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            withAnimation(Motion.tap) { copied = true }
            Task {
                try? await Task.sleep(for: .seconds(1.2))
                withAnimation(Motion.tap) { copied = false }
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 22, height: 22)
                .contentShape(.rect)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("复制")
    }
}

/// The word's history in one line, and the way into the whole of it.
///
/// Outside the scrolling result on purpose: it is about the *word*, not about
/// whichever service is in front, so switching chips must not scroll it away.
private struct EtymologyTeaserRow: View {
    let teaser: EtymologyTeaser
    @Stored private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("来历")
                    .font(.system(size: 10.5))
                    .tracking(0.6)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button {
                    WorkbenchController.shared.showEtymology(teaser.word)
                } label: {
                    HStack(spacing: 3) {
                        Text("深究")
                        Image(systemName: "chevron.right").font(.system(size: 8.5, weight: .bold))
                    }
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .opacity(hovering ? 1 : 0.85)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .onHover { hovering = $0 }
                .help("在工作台里看 \(teaser.word) 的完整词源")
            }
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                ForEach(Array(teaser.steps.enumerated()), id: \.offset) { index, step in
                    if index > 0 {
                        Image(systemName: "arrow.right")
                            .font(.system(size: 7.5, weight: .bold))
                            .foregroundStyle(.quaternary)
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        if let language = step.language {
                            Text(language).foregroundStyle(.tertiary)
                        }
                        Text(step.form)
                            .font(.system(size: 14.5, design: .serif).italic())
                            .foregroundStyle(index == teaser.steps.count - 1
                                             ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.primary))
                        if let gloss = step.gloss {
                            Text(gloss).foregroundStyle(.secondary)
                        }
                    }
                    .fixedSize()
                }
            }
            .font(.system(size: 11.5))
            .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04), in: .rect(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(Chrome.rule, lineWidth: 1) }
    }
}
