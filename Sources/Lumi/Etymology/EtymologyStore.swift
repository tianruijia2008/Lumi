import Foundation
import NaturalLanguage
import Observation
import SwiftUI
import Translation

/// Where 词源 pages come from and where they are kept.
///
/// One instance for the app, because the panel and the workbench ask about the
/// same words: a word looked up in the panel is fetched once, and opening it
/// with 深究 finds it already here.
@MainActor @Observable
final class EtymologyStore {
    static let shared = EtymologyStore()

    /// The word the 词源 page is showing. `nil` is the search page.
    private(set) var current: EtymologyLookup?
    private(set) var recents: [RecentWord] = []
    /// Set by the sidebar's 本页 list; the page scrolls and clears it.
    var scrollTarget: EtymologySection?

    var engine: WorkbenchEngineID {
        get { AppSettings.shared.etymologyEngine }
        set {
            guard newValue != AppSettings.shared.etymologyEngine else { return }
            AppSettings.shared.etymologyEngine = newValue
            current?.engineChanged()
        }
    }

    private var memory: [String: EtymologyEntry] = [:]
    private var inflight: [String: Task<EtymologyEntry, any Error>] = [:]

    private init() {
        if let data = UserDefaults.standard.data(forKey: "etymologyRecents"),
           let decoded = try? JSONDecoder().decode([RecentWord].self, from: data) {
            recents = decoded
        }
    }

    // MARK: Navigation

    func open(_ raw: String) {
        let word = Self.normalised(raw)
        guard Self.isWord(word) else { return }
        if current?.word == word { return }
        current?.cancel()
        let lookup = EtymologyLookup(word: word, store: self)
        withAnimation(Motion.settle) { current = lookup }
        lookup.start()
    }

    func closeWord() {
        current?.cancel()
        withAnimation(Motion.settle) { current = nil }
    }

    /// Only single English words. Phrases and other languages have no
    /// etymology section to read, and the panel's dictionary serves them.
    static func isWord(_ text: String) -> Bool {
        text.range(of: #"^[A-Za-z][A-Za-z'\-]{0,29}$"#, options: .regularExpression) != nil
    }

    static func normalised(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    fileprivate func remember(_ entry: EtymologyEntry) {
        recents.removeAll { $0.word == entry.word }
        recents.insert(RecentWord(word: entry.word, hook: entry.hook), at: 0)
        if recents.count > 12 { recents.removeLast(recents.count - 12) }
        if let data = try? JSONEncoder().encode(recents) {
            UserDefaults.standard.set(data, forKey: "etymologyRecents")
        }
    }

    // MARK: Entries

    /// The target the `…Local` fields are written in: the reader's own
    /// language, since every word here is English.
    static var localLanguage: Language {
        let settings = AppSettings.shared
        return Language.target(for: .english, first: settings.firstLanguage, second: settings.secondLanguage)
    }

    func cached(_ word: String) -> EtymologyEntry? {
        let language = Self.localLanguage.rawValue
        if let hit = memory[word], hit.localLanguage == language,
           hit.schema == EtymologyEntry.currentSchema { return hit }
        guard let data = try? Data(contentsOf: Self.file(for: word)),
              let entry = try? JSONDecoder().decode(EtymologyEntry.self, from: data),
              entry.localLanguage == language, entry.schema == EtymologyEntry.currentSchema else { return nil }
        memory[word] = entry
        return entry
    }

    /// Chain, senses and quotations, with glosses translated. Deduplicated,
    /// so the panel and the page asking at once make one request.
    func entry(_ raw: String) async throws -> EtymologyEntry {
        let word = Self.normalised(raw)
        if let hit = cached(word) { return hit }
        if let running = inflight[word] { return try await running.value }
        let task = Task { try await self.build(word) }
        inflight[word] = task
        defer { inflight[word] = nil }
        let entry = try await task.value
        save(entry)
        return entry
    }

    func save(_ entry: EtymologyEntry) {
        memory[entry.word] = entry
        // A recent word's one-line summary follows its entry, so a refetch
        // under a newer build does not leave yesterday's wording in the list.
        if let index = recents.firstIndex(where: { $0.word == entry.word }),
           recents[index].hook != entry.hook {
            recents[index].hook = entry.hook
            if let data = try? JSONEncoder().encode(recents) {
                UserDefaults.standard.set(data, forKey: "etymologyRecents")
            }
        }
        let url = Self.file(for: entry.word)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(entry) { try? data.write(to: url, options: .atomic) }
    }

    func forget(_ word: String) {
        memory[word] = nil
        try? FileManager.default.removeItem(at: Self.file(for: word))
    }

    private static func file(for word: String) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let safe = word.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? word
        return base.appending(path: "Lumi/Etymology/\(safe).json")
    }

    private func build(_ word: String) async throws -> EtymologyEntry {
        let page = try await Wiktionary.page(word)
        // Parsing a long entry's HTML takes tens of milliseconds; not on the
        // main thread.
        var (entry, root) = try await Task.detached(priority: .userInitiated) {
            try EtymologyParser.parse(word: word, wikitext: page.wikitext, html: page.html)
        }.value
        if let root, let title = root.pageTitle, let rootPage = try? await Wiktionary.wikitext(title) {
            EtymologyParser.applyRoot(root, page: rootPage, to: &entry)
        }
        await localise(&entry)
        entry.schema = EtymologyEntry.currentSchema
        return entry
    }

    /// Glosses and sense labels, through the system translator — short,
    /// literal, and free, which is what a gloss wants.
    private func localise(_ entry: inout EtymologyEntry) async {
        let target = Self.localLanguage
        entry.localLanguage = target.rawValue
        var texts: [String] = []
        texts += entry.chain.compactMap(\.gloss)
        texts += entry.chain.flatMap(\.addends).compactMap(\.gloss)
        texts += entry.folk.flatMap(\.parts).compactMap(\.gloss)
        // The whole definition, not the label: "Pleasant" alone comes back as
        // 悦耳的 (pleasing to the *ear*); "Pleasant, satisfactory,
        // complimentary" comes back as 令人愉快的、令人满意的…, whose first
        // clause is the right label.
        texts += entry.senses.map(\.text)
        texts.append(entry.word)
        let local = await SystemTranslator.translate(texts, to: target)
        guard !local.isEmpty else { return }
        for i in entry.chain.indices {
            entry.chain[i].glossLocal = entry.chain[i].gloss.flatMap { local[$0] }
            for j in entry.chain[i].addends.indices {
                entry.chain[i].addends[j].glossLocal = entry.chain[i].addends[j].gloss.flatMap { local[$0] }
            }
        }
        for i in entry.folk.indices {
            for j in entry.folk[i].parts.indices {
                entry.folk[i].parts[j].glossLocal = entry.folk[i].parts[j].gloss.flatMap { local[$0] }
            }
        }
        for i in entry.senses.indices {
            guard let full = local[entry.senses[i].text] else { continue }
            entry.senses[i].textLocal = full
            entry.senses[i].labelLocal = Self.firstClause(full)
        }
        entry.wordLocal = local[entry.word].map(Self.firstClause)
        if let last = entry.chain.indices.last, entry.chain[last].isToday {
            entry.chain[last].glossLocal = entry.nowGloss
        }
    }

    static func firstClause(_ text: String) -> String {
        let cut = text.split(whereSeparator: { "，,；;、（(".contains($0) }).first.map(String.init) ?? text
        return cut.trimmingCharacters(in: .whitespaces)
    }

    /// Other common English words from the same reconstructed roots.
    func kin(for entry: EtymologyEntry) async -> [KinGroup] {
        let prefix = "Category:English terms derived from the Proto-Indo-European root "
        guard let categories = try? await Wiktionary.categories(of: entry.word) else { return [] }
        let vocabulary = NLEmbedding.wordEmbedding(for: .english)
        var groups: [KinGroup] = []
        for category in categories where category.hasPrefix(prefix) {
            guard let members = try? await Wiktionary.members(of: category) else { continue }
            let words = EtymologyParser.kin(from: members, excluding: entry.word,
                                            isCommon: { vocabulary?.contains($0) ?? true })
            guard !words.isEmpty else { continue }
            // "*ḱer- (grow)" names the root and, in brackets, which of the
            // several roots spelt that way — which doubles as its meaning.
            var root = String(category.dropFirst(prefix.count))
            var gloss: String?
            if let open = root.firstIndex(of: "("), root.hasSuffix(")") {
                gloss = String(root[root.index(after: open)..<root.index(before: root.endIndex)])
                root = root[..<open].trimmingCharacters(in: .whitespaces)
            } else if let node = entry.chain.first(where: { $0.form == root }) {
                gloss = node.gloss
            }
            groups.append(KinGroup(root: root, gloss: gloss, words: words.map { KinWord(word: $0) }))
            if groups.count == 3 { break }
        }
        let target = Self.localLanguage
        let local = await SystemTranslator.translate(
            groups.flatMap { $0.words.map(\.word) } + groups.compactMap(\.gloss), to: target)
        for g in groups.indices {
            groups[g].glossLocal = groups[g].gloss.flatMap { local[$0] }
            for w in groups[g].words.indices {
                groups[g].words[w].gloss = local[groups[g].words[w].word]
            }
        }
        return groups
    }
}

enum EtymologySection: String, CaseIterable, Identifiable {
    case narration, chain, senses, quotes, kin
    var id: String { rawValue }
}

struct RecentWord: Codable, Identifiable, Equatable {
    var word: String
    var hook: String?
    var id: String { word }
}

// MARK: - One word on screen

/// A word being shown, and the work still running for it.
///
/// The facts arrive first and in one piece. What follows — words from the
/// same root, translated quotations, the narration — each fill in on their
/// own, so a slow model never holds back the part that came from the source.
@MainActor @Observable
final class EtymologyLookup {
    enum Phase: Equatable {
        case loading
        case ready
        case failed(String)
    }

    enum Narration: Equatable {
        case off
        case unavailable(String)
        case running
        case done
        case failed(String)
    }

    let word: String
    private(set) var phase: Phase = .loading
    private(set) var entry: EtymologyEntry?
    private(set) var kinLoading = false
    private(set) var quotesTranslating = false
    private(set) var narration: Narration = .off
    private(set) var narrationText = ""
    private(set) var narrator: String?


    private weak var store: EtymologyStore?
    private var tasks: [Task<Void, Never>] = []
    private var narrationTask: Task<Void, Never>?

    init(word: String, store: EtymologyStore) {
        self.word = word
        self.store = store
    }

    func start() {
        tasks.append(Task { await self.load() })
    }

    func cancel() {
        tasks.forEach { $0.cancel() }
        narrationTask?.cancel()
    }

    func retry() {
        cancel()
        store?.forget(word)
        phase = .loading
        entry = nil
        narrationText = ""
        narration = .off
        start()
    }

    private func load() async {
        guard let store else { return }
        do {
            let loaded = try await store.entry(word)
            guard !Task.isCancelled else { return }
            withAnimation(Motion.settle) {
                entry = loaded
                phase = .ready
            }
            store.remember(loaded)
            if let cached = loaded.narration, !cached.isEmpty {
                narrationText = cached
                narrator = loaded.narrator
                narration = .done
            }
        } catch {
            guard !Task.isCancelled else { return }
            let offline = (error as? URLError)?.code == .notConnectedToInternet
            phase = .failed(offline ? "需要联网才能查 Wiktionary。" : error.localizedDescription)
            return
        }
        tasks.append(Task { await self.loadKin() })
        tasks.append(Task { await self.translateQuotes() })
        narrate()
    }

    /// Switching 本机 / AI changes who translates the quotations and whether
    /// there is prose at all; the facts stay where they are.
    func engineChanged() {
        guard phase == .ready else { return }
        narrationTask?.cancel()
        if narration == .running { narration = .off; narrationText = "" }
        tasks.append(Task { await self.translateQuotes() })
        narrate()
    }

    private func update(_ change: (inout EtymologyEntry) -> Void) {
        guard var current = entry else { return }
        change(&current)
        entry = current
        store?.save(current)
    }

    private func loadKin() async {
        guard let store, let entry, !entry.kinLoaded else { return }
        kinLoading = true
        let groups = await store.kin(for: entry)
        guard !Task.isCancelled else { return }
        kinLoading = false
        withAnimation(Motion.settle) {
            update { $0.kin = groups; $0.kinLoaded = true }
        }
    }

    // MARK: Quotations

    private func translateQuotes() async {
        guard let entry, !entry.quotes.isEmpty else { return }
        let engine = AppSettings.shared.etymologyEngine
        let provider = engine == .online ? AppSettings.shared.workbenchOnlineProvider() : nil
        let translator = provider?.displayName ?? "system"
        guard entry.quoteTranslator != translator || entry.quotes.contains(where: { $0.translation == nil }) else {
            return
        }
        quotesTranslating = true
        defer { quotesTranslating = false }
        let target = EtymologyStore.localLanguage
        var results: [Int: String] = [:]

        if let provider {
            // The model is told which sense each quotation uses. Handed "I am
            // not so nice / To change true rules" cold, it translates nice as
            // 友好; told the sense is "silly, foolish", it does not.
            let jobs = entry.quotes.map { quote in
                var context = DocumentContext()
                context.title = "Dated quotations showing how the English word '\(entry.word)' was used"
                let sense = quote.senseID.flatMap { id in entry.senses.first { $0.id == id } }
                context.notes = """
                    Each segment is a separate quotation\(quote.year.map { " from \($0)" } ?? ""). \
                    In it, '\(entry.word)' has the sense: "\(sense?.text ?? "")". Translate '\(entry.word)' \
                    in that sense, not the modern one, and keep the period flavour of the English.
                    """
                context.index = quote.id
                context.count = entry.quotes.count
                return WorkbenchJob(index: quote.id, text: quote.plainPassage, context: context)
            }
            let online = OnlineWorkbenchEngine(provider: provider)
            for await event in online.run(jobs, source: .english, target: target) {
                if case .finished(let index, let text) = event { results[index] = text }
            }
        }
        // The system translator fills whatever the model did not — including
        // everything, when no model was asked.
        let missing = entry.quotes.filter { results[$0.id] == nil }
        if !missing.isEmpty {
            let local = await SystemTranslator.translate(missing.map(\.plainPassage), to: target)
            for quote in missing { results[quote.id] = local[quote.plainPassage] }
        }
        guard !Task.isCancelled else { return }
        withAnimation(Motion.settle) {
            update { current in
                for i in current.quotes.indices {
                    if let text = results[current.quotes[i].id] { current.quotes[i].translation = text }
                }
                current.quoteTranslator = translator
            }
        }
    }

    // MARK: Narration

    func narrate(force: Bool = false) {
        guard let entry else { return }
        guard AppSettings.shared.etymologyEngine == .online else {
            narration = .off
            return
        }
        guard let provider = AppSettings.shared.workbenchOnlineProvider() else {
            narration = .unavailable("还没有启用语言模型。在设置里开启一个并填好 API Key，或改用本机。")
            return
        }
        if !force, narration == .done, entry.narrator == provider.displayName, !narrationText.isEmpty { return }
        guard NetworkMonitor.shared.isOnline || !provider.requiresNetwork else {
            narration = .unavailable("当前离线，讲解需要联网。下面的资料不受影响。")
            return
        }
        narrationTask?.cancel()
        narrationText = ""
        narrator = provider.displayName
        narration = .running
        let target = EtymologyStore.localLanguage
        let request = TranslationRequest(
            text: EtymologyNarration.material(for: entry),
            source: .english, target: target,
            instructions: EtymologyNarration.instructions(target: target)
        )
        narrationTask = Task {
            do {
                if case .needsSetup(let why) = await provider.availability(for: request) {
                    narration = .unavailable(why)
                    return
                }
                for try await event in provider.translate(request) {
                    try Task.checkCancellation()
                    switch event {
                    case .delta(let chunk):  narrationText += chunk
                    case .replace(let full): narrationText = full
                    case .dictionary:        break
                    }
                }
                narrationText = narrationText.trimmingCharacters(in: .whitespacesAndNewlines)
                narration = narrationText.isEmpty ? .failed("模型没有返回内容") : .done
                if narration == .done {
                    let text = narrationText, name = provider.displayName
                    update { $0.narration = text; $0.narrator = name }
                }
            } catch is CancellationError {
            } catch {
                narration = .failed(error.localizedDescription)
            }
        }
    }
}

// MARK: - Narration prompt

enum EtymologyNarration {
    static func instructions(target: Language) -> String {
        """
        You write the short narrative at the top of an etymology page in a dictionary app. \
        Write it in \(target.promptName).

        Use ONLY the material the user gives you. It was extracted from Wiktionary. Do not add \
        any fact, date, person, place, anecdote or explanation that is not in the material, even \
        if you believe it is true — etymology is full of popular stories that are false, and the \
        reader relies on this text containing nothing the material does not support. If the \
        material lists a folk etymology, you may mention it only to say it is not the origin.

        Write two short paragraphs, together about 150 words (or 220 Chinese characters), as a \
        story someone would enjoy reading — not a list:
        1. Where the word comes from: follow the chain from its oldest form to today and say \
        what the old forms meant. Skip steps that add nothing.
        2. How its meaning changed. Pick the three or four most striking turns, in order; do \
        not walk through every sense and do not give a date range for each. Say which old \
        meaning survives, if one does.
        Render every meaning in \(target.promptName) — never leave a definition in English.
        Order in time only what the material dates. Senses listed without dates have no known \
        order: do not say which came first, "early", "later" or "then" about them — say only \
        which are still in use and which are marked archaic, obsolete or rare, and that the \
        source gives no dates. The order senses are listed in is not a chronology.

        Cite a quotation by its number in square brackets, like [3], right after the claim it \
        supports, and only for the sense it is listed under. Cite nothing else.
        Wrap every word form from another language in curly braces, like {nescius} or {*skey-} \
        — keep the asterisk that marks a reconstructed form, inside the braces. Use no other \
        markup: no asterisks for emphasis, no bold.
        No headings, no lists, no preamble, no closing remark.
        """
    }

    static func material(for entry: EtymologyEntry) -> String {
        var lines = ["Word: \(entry.word)\(entry.partOfSpeech.map { " (\($0))" } ?? "")"]
        if !entry.chain.isEmpty {
            lines.append("")
            lines.append("Chain, oldest first (* marks a reconstructed form with no written record):")
            for node in entry.chain {
                var line = "- \(node.language) (\(node.lang)) \(node.form)"
                if let gloss = node.gloss { line += " \"\(gloss)\"" }
                if node.isToday { line += " — the word today" }
                if !node.addends.isEmpty {
                    line += "; combined with " + node.addends.map { a in
                        "\(a.form)" + (a.gloss.map { " \"\($0)\"" } ?? "")
                    }.joined(separator: ", ")
                }
                lines.append(line)
            }
        }
        for claim in entry.folk {
            lines.append("")
            lines.append("Folk etymology, NOT the origin: \(claim.parts.map(\.form).joined(separator: " + ")). "
                         + "Source note: \(claim.sourceSentence)")
        }
        if !entry.senses.isEmpty {
            lines.append("")
            lines.append(entry.datedSenses.isEmpty
                ? "Senses (the source gives NO dates for any of them):"
                : "Senses (dates are Wiktionary's, to the century; undated ones have no known date):")
            for sense in entry.senses {
                var dates = ""
                if let start = sense.start {
                    dates = sense.end.map { " — \(start) to \($0)" } ?? " — from \(start)"
                }
                lines.append("S\(sense.id) \"\(sense.text)\"\(dates) [\(sense.status.rawValue)]")
            }
        }
        if !entry.quotes.isEmpty {
            lines.append("")
            lines.append("Quotations:")
            for quote in entry.quotes {
                let year = quote.year.map { (quote.approximate ? "c. " : "") + String($0) } ?? "undated"
                let who = [quote.author, quote.title].compactMap(\.self).joined(separator: ", ")
                lines.append("[\(quote.id)] \(year), \(who) — sense S\(quote.senseID ?? -1): \"\(quote.plainPassage)\"")
            }
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - System translator

/// Apple's on-device translator, for short things in bulk.
enum SystemTranslator {
    /// Returns a map from each input to its translation. Empty when the
    /// language pack is missing — callers show the English instead, which is
    /// what an untranslated gloss should fall back to.
    @MainActor
    static func translate(_ texts: [String], to target: Language) async -> [String: String] {
        let unique = Array(Set(texts.filter { !$0.isEmpty }))
        guard !unique.isEmpty, target != .english,
              let from = Language.english.localeLanguage, let to = target.localeLanguage else { return [:] }
        guard await LanguageAvailability().status(from: from, to: to) == .installed else { return [:] }
        let session = TranslationSession(installedSource: from, target: to)
        let requests = unique.enumerated().map {
            TranslationSession.Request(sourceText: $0.element, clientIdentifier: String($0.offset))
        }
        var out: [String: String] = [:]
        do {
            for try await response in session.translate(batch: requests) {
                guard let id = response.clientIdentifier, let index = Int(id) else { continue }
                out[unique[index]] = response.targetText
                    .trimmingCharacters(in: .whitespacesAndNewlines.union(.init(charactersIn: "。．.")))
            }
        } catch {
            Log.window.error("gloss translation failed: \(error.localizedDescription, privacy: .public)")
        }
        return out
    }
}
