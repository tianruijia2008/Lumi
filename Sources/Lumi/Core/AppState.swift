import AppKit
import Observation
import SwiftUI

struct ResultCard: Identifiable, Sendable {
    enum Status: Equatable, Sendable {
        case waiting, streaming, done
        /// Ran fine, had nothing to say — a dictionary handed a sentence, or a
        /// word no installed dictionary carries. Not an error: there is
        /// nothing for the user to fix, so it must not look like one.
        case empty(String)
        case offline
        case failed(String)
        case needsSetup(String)
    }
    let id: ServiceKind
    let title: String
    let symbol: String
    var text: String = ""
    /// Set instead of `text` when a service returns something the card should
    /// lay out rather than print — currently only the dictionary.
    var entry: DictionaryEntry?
    var status: Status = .waiting

    var hasContent: Bool { !text.isEmpty || entry != nil }

    /// Whether this service might still produce something. The fallback notice
    /// waits on this: a slower service is not a failed one, and claiming a
    /// fallback while a higher-priority answer is still arriving would be a
    /// lie that corrects itself half a second later.
    var mayStillAnswer: Bool {
        switch status {
        case .waiting, .streaming: true
        default: hasContent
        }
    }

    /// Rail tooltip and fallback notice wording.
    var reason: String {
        switch status {
        case .waiting:     tDetached("等待中")
        case .streaming:   tDetached("正在输出")
        case .done:        tDetached("已完成")
        case .empty(let why):  why
        case .offline:     tDetached("离线不可用")
        case .failed(let message): message
        case .needsSetup(let message): message
        }
    }
}

@MainActor @Observable
final class AppState {
    var queryText = ""
    var sourceOverride: Language = .auto
    /// Set when the user picks a target for this query; otherwise the direction
    /// comes from their language pair.
    var targetOverride: Language?
    var resolvedSource: Language = .english
    var resolvedTarget: Language = .simplifiedChinese
    var cards: [ResultCard] = []
    var lastError: String?
    /// The one-line "来历" under a looked-up English word. `nil` until it
    /// arrives, and it stays `nil` when there is nothing to say — the row is
    /// absent rather than empty.
    private(set) var etymologyTeaser: EtymologyTeaser?
    private var teaserTask: Task<Void, Never>?

    /// Which service the body is showing. Every service still runs; this only
    /// decides which answer is in front.
    private(set) var focusedService: ServiceKind?
    /// Once locked, focus never moves on its own again.
    private var focusLocked = false

    private var runTask: Task<Void, Never>?
    private var focusLockTask: Task<Void, Never>?
    private var hasDeliveredSideEffects = false

    /// A backstop on automatic promotion, not the normal way it ends.
    ///
    /// Promotion naturally stops mattering once every service ranked above the
    /// current one has reported — nothing left can outrank it. This only
    /// guards against a provider that hangs without ever failing.
    ///
    /// An earlier version closed this window after 1.5s to avoid swapping the
    /// body under someone mid-read. That was the wrong instinct: because
    /// promotion only ever moves focus *up* the ladder, a swap means the
    /// user's preferred service just arrived, and 1.5s is shorter than an
    /// LLM's first token — so the ladder lost nearly every race to whichever
    /// service happened to be fastest, which is exactly what ordering the list
    /// is supposed to override.
    private static let promotionDeadline = Duration.seconds(10)

    var isRunning: Bool {
        cards.contains { $0.status == .waiting || $0.status == .streaming }
    }

    var focusedCard: ResultCard? {
        guard let focusedService else { return nil }
        return cards.first { $0.id == focusedService }
    }

    /// Explains a body that is not coming from the user's first-choice service.
    ///
    /// Only appears once every service above it has definitively given up —
    /// see `mayStillAnswer`.
    var fallbackNotice: (symbol: String, text: String)? {
        guard let focusedService,
              let index = cards.firstIndex(where: { $0.id == focusedService }),
              index > 0 else { return nil }
        let skipped = cards[..<index]
        guard skipped.allSatisfy({ !$0.mayStillAnswer }) else { return nil }
        let landed = cards[index].title

        // Offline is a property of the machine, not of any one service, so it
        // is worth saying plainly instead of blaming whichever one is listed
        // first.
        if skipped.contains(where: { $0.status == .offline }) {
            return ("wifi.slash", t("离线，已回退到「%@」", landed))
        }
        guard let first = skipped.first else { return nil }
        // Corner brackets rather than a space: the ladder mixes Latin and CJK
        // service names, and a bare space reads as a typo next to one of them.
        return ("arrow.turn.down.right", t("%@%@，改用「%@」", first.title, first.reason, landed))
    }

    // MARK: - Captures

    /// The text most recently handed to the panel from *outside* it — a
    /// selection grab or a screen capture — and a counter that ticks once per
    /// hand-off.
    ///
    /// The input field mirrors these two rather than `queryText`. Submitting
    /// from the field also changes `queryText`, so a field that mirrored it
    /// would type the query straight back in after "查询后清空输入" had just
    /// cleared it.
    private(set) var captureText = ""
    private(set) var captureSerial = 0

    /// A capture is starting.
    ///
    /// Empties the panel first. The previous query and its translation are
    /// answers to a question the user has already moved on from, and leaving
    /// them up while a new grab runs makes a failed grab indistinguishable
    /// from a successful one — the window looks full either way.
    func beginCapture() {
        clear()
        captureText = ""
        captureSerial += 1
    }

    /// A capture arrived: show it in the field and translate it.
    ///
    /// Trimmed on the way in, not just on the way to the translator: selecting
    /// a whole line takes its newline with it, and an untrimmed field grows a
    /// blank second row under every sentence the user grabs.
    func deliverCapture(_ text: String) {
        captureText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        captureSerial += 1
        submit(text)
    }

    /// Kicks off every enabled provider at once.
    ///
    /// Fallback is a rule about *which answer is shown*, not about the order
    /// requests go out in. Running the ladder sequentially would make every
    /// query wait for the dictionary to miss before the translator even
    /// started; running it in parallel and choosing afterwards costs nothing
    /// and is always at least as fast as the fastest rung.
    func submit(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        runTask?.cancel()
        focusLockTask?.cancel()
        queryText = text
        lastError = nil
        hasDeliveredSideEffects = false
        focusedService = nil
        focusLocked = false

        let source = sourceOverride == .auto ? Language.detect(text) : sourceOverride
        let settings = AppSettings.shared
        let target = targetOverride ?? Language.target(
            for: source, first: settings.firstLanguage, second: settings.secondLanguage
        )
        resolvedSource = source
        resolvedTarget = target
        requestTeaser(for: text, source: source)

        let request = TranslationRequest(text: text, source: source, target: target)
        let providers = settings.activeProviders()

        guard !providers.isEmpty else {
            cards = []
            lastError = t("没有启用任何翻译服务，请在设置中开启至少一个。")
            return
        }

        withAnimation(Motion.pop) {
            cards = providers.map {
                ResultCard(id: $0.kind, title: $0.displayName, symbol: $0.symbolName)
            }
            // Focus the top of the ladder straight away. Waiting for the first
            // content would leave the body blank for the whole round trip —
            // and blank is the one thing the panel must never look like, since
            // it is indistinguishable from the app having hung.
            focusedService = providers.first?.kind
        }

        focusLockTask = Task { [weak self] in
            try? await Task.sleep(for: Self.promotionDeadline)
            guard !Task.isCancelled else { return }
            self?.focusLocked = true
        }

        runTask = Task { [weak self] in
            await withTaskGroup(of: Void.self) { group in
                for provider in providers {
                    group.addTask { await self?.drive(provider, request) }
                }
            }
        }
    }

    /// The user picking a chip settles the question for good.
    func focus(_ kind: ServiceKind) {
        focusLocked = true
        focusLockTask?.cancel()
        guard focusedService != kind else { return }
        withAnimation(Motion.settle) { focusedService = kind }
    }

    func cancel() {
        runTask?.cancel()
        runTask = nil
        focusLockTask?.cancel()
        for index in cards.indices where cards[index].status == .waiting || cards[index].status == .streaming {
            cards[index].status = cards[index].hasContent ? .done : .failed(t("已取消"))
        }
    }

    func clear() {
        cancel()
        teaserTask?.cancel()
        etymologyTeaser = nil
        withAnimation(Motion.settle) {
            cards = []
            queryText = ""
            lastError = nil
            focusedService = nil
        }
        focusLocked = false
    }

    // MARK: - Etymology teaser

    /// Fetched beside the translators, never ahead of them: it is Wiktionary
    /// and the system translator, costs nothing, and a word whose history
    /// cannot be found simply gets no row.
    private func requestTeaser(for text: String, source: Language) {
        teaserTask?.cancel()
        etymologyTeaser = nil
        let word = EtymologyStore.normalised(text)
        guard source == .english, EtymologyStore.isWord(word) else { return }
        teaserTask = Task { [weak self] in
            guard let entry = try? await EtymologyStore.shared.entry(word),
                  !Task.isCancelled, let self,
                  EtymologyStore.normalised(self.queryText) == word,
                  let teaser = EtymologyTeaser(entry) else { return }
            withAnimation(Motion.settle) { self.etymologyTeaser = teaser }
        }
    }

    // MARK: - One provider, one card

    private func drive(_ provider: any TranslationProvider, _ request: TranslationRequest) async {
        // Checked before anything is dispatched: a dead link swallows packets
        // rather than refusing them, so discovering this by timeout would make
        // offline the slowest state in the app instead of the fastest.
        if provider.requiresNetwork, !NetworkMonitor.shared.isOnline {
            update(provider.kind) { $0.status = .offline }
            return
        }

        switch await provider.availability(for: request) {
        case .needsSetup(let message):
            update(provider.kind) { $0.status = .needsSetup(message) }
            return
        case .unavailable(let message):
            update(provider.kind) { $0.status = .failed(message) }
            return
        case .notApplicable(let why):
            // The chip stays. Dropping it would make the rail's width depend on
            // which services happened to answer, so it would twitch on every
            // query — and a greyed chip is also the only way to retry one.
            update(provider.kind) { $0.status = .empty(why) }
            return
        case .ready:
            break
        }

        update(provider.kind) {
            $0.status = .streaming
            $0.text = ""
        }

        do {
            for try await event in provider.translate(request) {
                try Task.checkCancellation()
                update(provider.kind, animated: false) { card in
                    switch event {
                    case .delta(let chunk):  card.text += chunk
                    case .replace(let full): card.text = full
                    case .dictionary(let entry):
                        card.entry = entry
                        // Keep a plain-text copy so Copy and Speak still work.
                        card.text = entry.plainText
                    }
                }
            }
            update(provider.kind) {
                $0.status = $0.hasContent ? .done : .empty(t("无结果"))
            }
            finishSideEffects(for: provider.kind)
        } catch is CancellationError {
            // A newer query is already on screen; leave this card alone.
        } catch TranslationFailure.emptyResult {
            // A dictionary with no entry for this word is the ordinary case the
            // ladder exists for, not a failure to report.
            update(provider.kind) { $0.status = .empty(t("查不到")) }
        } catch {
            update(provider.kind) { $0.status = .failed(error.localizedDescription) }
        }
    }

    /// Sound, auto-copy and auto-speak all fire once a card completes.
    ///
    /// Only the first finishing service may copy or speak: several run at once,
    /// and having the last one to arrive overwrite the pasteboard — or talk
    /// over the previous one — is not what "auto" should mean.
    private func finishSideEffects(for kind: ServiceKind) {
        let settings = AppSettings.shared
        if settings.playSoundOnResult { NSSound(named: "Tink")?.play() }

        guard !hasDeliveredSideEffects,
              let card = cards.first(where: { $0.id == kind }),
              !card.text.isEmpty else { return }
        hasDeliveredSideEffects = true

        if settings.autoCopyResult {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(card.text, forType: .string)
        }
        if settings.autoSpeakWords, TranslationRequest(
            text: queryText, source: resolvedSource, target: resolvedTarget
        ).isLookup {
            Speaker.shared.speak(card.text, language: resolvedTarget)
        }
    }

    /// Streaming deltas arrive many times a second — animating each one would
    /// fight the text layout, so only status changes get a curve.
    private func update(
        _ id: ServiceKind,
        animated: Bool = true,
        _ mutate: (inout ResultCard) -> Void
    ) {
        guard let index = cards.firstIndex(where: { $0.id == id }) else { return }
        if animated {
            withAnimation(Motion.settle) { mutate(&cards[index]) }
        } else {
            mutate(&cards[index])
        }
        promoteFocus()
    }

    /// The fallback rule itself: the body shows the highest-priority service
    /// that has actually produced something.
    ///
    /// `cards` is already in the user's service order, so "first with content"
    /// walks their ladder — which is why the chain needs no vendor names in it.
    /// Reordering the list in Settings is what changes the fallback order.
    private func promoteFocus() {
        // An empty body is worse than a body that moves, so the very first
        // answer always takes focus even after the grace period has closed.
        guard !focusLocked else { return }
        guard let best = cards.first(where: \.hasContent), best.id != focusedService else { return }
        withAnimation(Motion.settle) { focusedService = best.id }
    }
}
