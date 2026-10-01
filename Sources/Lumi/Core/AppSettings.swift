import Foundation
import Observation

@MainActor @Observable
final class AppSettings {
    static let shared = AppSettings()

    /// The pair the user actually works between. Easydict's model, and a
    /// better one than a single "target": with 母语 ↔ 外语 the direction flips
    /// automatically, so the same shortcut works on Chinese and on English
    /// without ever touching a picker.
    var firstLanguage: Language { didSet { store(firstLanguage.rawValue, "firstLanguage") } }
    var secondLanguage: Language { didSet { store(secondLanguage.rawValue, "secondLanguage") } }

    var appearance: AppearanceMode { didSet { store(appearance.rawValue, "appearance") } }
    /// Multiplies every font size in the result panel.
    var fontScale: Double { didSet { store(fontScale, "fontScale") } }
    var panelWidth: Double { didSet { store(panelWidth, "panelWidth") } }
    /// How tall the result stack may grow before it scrolls. A 10-sense
    /// dictionary entry needs far more room than a one-line translation.
    var resultsMaxHeight: Double { didSet { store(resultsMaxHeight, "resultsMaxHeight") } }

    /// How many lines of the query stay visible before the field collapses.
    /// Collapsing is only acceptable because the field can be expanded again —
    /// see `RootView.input`.
    var inputCollapsedLines: Int { didSet { store(inputCollapsedLines, "inputCollapsedLines") } }

    var autoCopyResult: Bool { didSet { store(autoCopyResult, "autoCopyResult") } }
    var autoSpeakWords: Bool { didSet { store(autoSpeakWords, "autoSpeakWords") } }
    var clearInputAfterQuery: Bool { didSet { store(clearInputAfterQuery, "clearInputAfterQuery") } }
    var keepPreviousOnEmptySelection: Bool {
        didSet { store(keepPreviousOnEmptySelection, "keepPreviousOnEmptySelection") }
    }

    /// User-chosen order of result cards; unknown/new services fall back to the
    /// catalog order so an upgrade never hides one.
    var serviceOrder: [String] { didSet { store(serviceOrder, "serviceOrder") } }
    var enabledServices: Set<ServiceKind> {
        didSet { store(enabledServices.map(\.rawValue), "enabledServices") }
    }
    /// Per-service model names, free text because vendors rename models often.
    var models: [String: String] { didSet { store(models, "serviceModels") } }
    /// Only the OpenAI-compatible services need one, and only `customOpenAI`
    /// normally departs from its default.
    var baseURLs: [String: String] { didSet { store(baseURLs, "serviceBaseURLs") } }
    var llmEffort: String { didSet { store(llmEffort, "llmEffort") } }
    var ollamaHost: String { didSet { store(ollamaHost, "ollamaHost") } }
    var playSoundOnResult: Bool { didSet { store(playSoundOnResult, "playSoundOnResult") } }
    var pinPanel: Bool { didSet { store(pinPanel, "pinPanel") } }

    /// Which engine the workbench translates with.
    ///
    /// Defaults to offline, and deliberately so: it works on a fresh install
    /// with no key and no network, so the window has something to show the
    /// first time it is opened rather than a setup error.
    var workbenchEngine: WorkbenchEngineID {
        didSet { store(workbenchEngine.rawValue, "workbenchEngine") }
    }
    /// Whether the 词源 page asks a language model to narrate. The facts come
    /// from Wiktionary either way; this only decides whether they are also
    /// strung into prose, and who translates the quotations.
    var etymologyEngine: WorkbenchEngineID {
        didSet { store(etymologyEngine.rawValue, "etymologyEngine") }
    }
    /// Which configured service the workbench's online engine uses. `nil` means
    /// "the highest-ranked LLM the user has enabled", which is almost always
    /// what they meant.
    var workbenchOnlineService: ServiceKind? {
        didSet { store(workbenchOnlineService?.rawValue ?? "", "workbenchOnlineService") }
    }

    /// Where the user last put the panel — its **top-left** corner, in screen
    /// coordinates. `nil` means "never moved it", which keeps the default
    /// follow-the-pointer behaviour.
    ///
    /// Deliberately not AppKit's bottom-left origin: that value shifts every
    /// time the panel changes height, so persisting it made the window walk
    /// down the screen a little further on each query until it fell off the
    /// bottom. The top-left corner is what the user actually aimed at, and it
    /// does not move when results arrive.
    var panelTopLeft: CGPoint? {
        didSet {
            store(panelTopLeft.map(\.x), "panelTopLeftX")
            store(panelTopLeft.map(\.y), "panelTopLeftY")
        }
    }

    // Keys never touch UserDefaults; they are read from and written straight
    // to the keychain.
    func apiKey(for kind: ServiceKind) -> String {
        Keychain.get(kind.keychainAccount) ?? ""
    }

    func setAPIKey(_ key: String, for kind: ServiceKind) {
        Keychain.set(key, for: kind.keychainAccount)
    }

    func model(for kind: ServiceKind) -> String {
        models[kind.rawValue] ?? kind.defaultModel
    }

    func setModel(_ model: String, for kind: ServiceKind) {
        models[kind.rawValue] = model
    }

    func baseURL(for kind: ServiceKind) -> String {
        let stored = baseURLs[kind.rawValue] ?? ""
        return stored.isEmpty ? kind.defaultBaseURL : stored
    }

    func setBaseURL(_ url: String, for kind: ServiceKind) {
        baseURLs[kind.rawValue] = url
    }

    /// Shortcuts live as JSON so a combo stays one value; storing key code and
    /// modifiers as separate keys invites half-updated pairs.
    private var hotKeys: [String: HotKeyCombo] {
        didSet {
            guard let data = try? JSONEncoder().encode(hotKeys) else { return }
            store(data, "hotKeys")
        }
    }

    func hotKey(for action: HotKeyAction) -> HotKeyCombo {
        hotKeys[action.rawValue] ?? action.defaultCombo
    }

    func setHotKey(_ combo: HotKeyCombo, for action: HotKeyAction) {
        hotKeys[action.rawValue] = combo
    }

    private let defaults = UserDefaults.standard

    private init() {
        let d = UserDefaults.standard
        firstLanguage  = Language(rawValue: d.string(forKey: "firstLanguage") ?? "") ?? .simplifiedChinese
        secondLanguage = Language(rawValue: d.string(forKey: "secondLanguage") ?? "") ?? .english
        appearance     = AppearanceMode(rawValue: d.string(forKey: "appearance") ?? "") ?? .system
        fontScale      = d.object(forKey: "fontScale") as? Double ?? 1.0
        panelWidth     = d.object(forKey: "panelWidth") as? Double ?? 440
        resultsMaxHeight = d.object(forKey: "resultsMaxHeight") as? Double ?? 460
        inputCollapsedLines = d.object(forKey: "inputCollapsedLines") as? Int ?? 3
        autoCopyResult = d.bool(forKey: "autoCopyResult")
        autoSpeakWords = d.bool(forKey: "autoSpeakWords")
        clearInputAfterQuery = d.bool(forKey: "clearInputAfterQuery")
        keepPreviousOnEmptySelection =
            d.object(forKey: "keepPreviousOnEmptySelection") as? Bool ?? true
        serviceOrder   = d.array(forKey: "serviceOrder") as? [String] ?? []
        let enabled: Set<ServiceKind>
        if let raw = d.array(forKey: "enabledServices") as? [String] {
            enabled = Set(raw.compactMap(ServiceKind.init(rawValue:)))
        } else {
            enabled = [.appleTranslate, .appleDictionary, .claude]
        }
        enabledServices = enabled
        // Drop model names the vendor has retired since they were stored, so
        // an upgrade heals itself instead of failing with an opaque 400.
        models      = (d.dictionary(forKey: "serviceModels") as? [String: String] ?? [:])
            .filter { !ServiceKind.retiredModels.contains($0.value) }
        baseURLs    = d.dictionary(forKey: "serviceBaseURLs") as? [String: String] ?? [:]
        llmEffort   = d.string(forKey: "llmEffort") ?? "low"
        workbenchEngine = WorkbenchEngineID(rawValue: d.string(forKey: "workbenchEngine") ?? "")
            ?? .offline
        workbenchOnlineService = ServiceKind(rawValue: d.string(forKey: "workbenchOnlineService") ?? "")
        ollamaHost  = d.string(forKey: "ollamaHost") ?? "http://127.0.0.1:11434"
        playSoundOnResult = d.bool(forKey: "playSoundOnResult")
        pinPanel    = d.bool(forKey: "pinPanel")
        if d.object(forKey: "panelTopLeftX") != nil, d.object(forKey: "panelTopLeftY") != nil {
            panelTopLeft = CGPoint(x: d.double(forKey: "panelTopLeftX"),
                                   y: d.double(forKey: "panelTopLeftY"))
        } else {
            panelTopLeft = nil
        }
        // The old bottom-left key drifted; drop it rather than migrate a value
        // that was wrong by construction.
        d.removeObject(forKey: "panelOriginX")
        d.removeObject(forKey: "panelOriginY")
        if let data = d.data(forKey: "hotKeys"),
           let decoded = try? JSONDecoder().decode([String: HotKeyCombo].self, from: data) {
            hotKeys = decoded
        } else {
            hotKeys = [:]
        }
        // Last, because the default reads another setting. Narration is on by
        // default only for someone who already has a model switched on;
        // otherwise the first visit would open on a setup error.
        let llmEnabled = enabled.contains(where: \.isLLM)
        etymologyEngine = WorkbenchEngineID(rawValue: d.string(forKey: "etymologyEngine") ?? "")
            ?? (llmEnabled ? .online : .offline)
    }

    private func store(_ value: Any?, _ key: String) {
        defaults.set(value, forKey: key)
    }

    /// Enabled services in display order: the user's arrangement first, then
    /// anything they have never reordered (including services added by a later
    /// version) in catalog order.
    var orderedServices: [ServiceKind] {
        let chosen = serviceOrder.compactMap(ServiceKind.init(rawValue:))
        let rest = ServiceKind.catalogOrder.filter { !chosen.contains($0) }
        return chosen + rest
    }

    /// Moves a service one rung up or down the ladder the user can actually
    /// see — which contains only the enabled ones.
    ///
    /// Stepping through the raw order instead would swap with whatever
    /// disabled service happened to sit in between, and the row would appear
    /// not to move at all.
    func moveService(_ kind: ServiceKind, by offset: Int) {
        var order = orderedServices
        guard let index = order.firstIndex(of: kind), offset != 0 else { return }
        let step = offset > 0 ? 1 : -1
        var target = index + step
        while order.indices.contains(target), !enabledServices.contains(order[target]) {
            target += step
        }
        guard order.indices.contains(target) else { return }
        order.swapAt(index, target)
        serviceOrder = order.map(\.rawValue)
    }

    /// Builds the provider objects for the currently enabled set, in display
    /// order so the result stack does not reshuffle between queries.
    func activeProviders() -> [any TranslationProvider] {
        orderedServices.compactMap { kind in
            guard enabledServices.contains(kind) else { return nil }
            switch kind.family {
            case .appleTranslate:  return AppleProvider()
            case .appleDictionary: return AppleDictionaryProvider()
            case .googleWeb:       return WebProvider()
            case .deepL:           return DeepLProvider()
            case .claude:          return ClaudeProvider(model: model(for: kind), effort: llmEffort)
            case .gemini:          return GeminiProvider(model: model(for: kind))
            case .ollama:          return OllamaProvider(model: model(for: kind), host: ollamaHost)
            case .openAICompatible:
                return OpenAICompatibleProvider(
                    kind: kind, model: model(for: kind), baseURL: baseURL(for: kind)
                )
            }
        }

    }

    /// The provider the workbench's online engine should use.
    ///
    /// Falls back to the reader's own service order rather than naming a
    /// vendor: whoever they put at the top of the ladder for popup queries is
    /// who they trust, and a document is the same judgement at greater length.
    /// Only LLMs qualify — a fixed-function API cannot be told about a
    /// document, so offering one as the "reads context" engine would be a lie.
    func workbenchOnlineProvider() -> (any TranslationProvider)? {
        let candidates = activeProviders().filter { $0.kind.isLLM }
        if let chosen = workbenchOnlineService,
           let match = candidates.first(where: { $0.kind == chosen }) {
            return match
        }
        return candidates.first
    }
}
