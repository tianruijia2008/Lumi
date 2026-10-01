import Foundation

/// The networked engine: whichever LLM the reader has configured.
///
/// Deliberately not "the DeepSeek engine". Document context travels inside
/// `TranslationRequest`, and every provider that speaks a system prompt picks
/// it up through `Prompts.system` — so DeepSeek, Claude, Gemini, an OpenAI
/// gateway and a local Ollama model are all already document translators, and
/// this engine only has to schedule them.
struct OnlineWorkbenchEngine: WorkbenchEngine {
    /// `nil` when the reader has no language model configured.
    ///
    /// Optional rather than substituted with a working translator on
    /// purpose: an earlier draft fell back to the on-device provider here,
    /// which meant an unconfigured 联网模型 quietly produced a whole document
    /// of on-device translations under the label of the better engine. A
    /// missing key has to look missing.
    let provider: (any TranslationProvider)?

    let id = WorkbenchEngineID.online
    var displayName: String { provider?.displayName ?? tDetached("联网模型") }
    var detail: String { tDetached("读得到标题、术语表和上下段，术语前后一致。需要联网。") }
    var requiresNetwork: Bool { provider?.requiresNetwork ?? true }
    let usesDocumentContext = true

    /// Segments translated at once.
    ///
    /// Three, not "as many as possible": every vendor rate-limits, and a paper
    /// that fires 60 simultaneous requests gets 429s that look to the reader
    /// like 60 failed paragraphs. Segments also finish in roughly source order
    /// this way, so the column fills from the top instead of speckling.
    private static let width = 3

    func availability(source: Language, target: Language) async -> ProviderAvailability {
        guard let provider else {
            return .needsSetup(tDetached("还没有启用语言模型。在设置里开启一个（如 DeepSeek）并填好 API Key，或改用本机翻译。"))
        }
        let online = await MainActor.run { NetworkMonitor.shared.isOnline }
        if provider.requiresNetwork, !online { return .unavailable(tDetached("当前离线")) }
        // Availability is per-service configuration, not per-text, so any
        // request of the right shape answers the question.
        return await provider.availability(
            for: TranslationRequest(
                text: "x", source: source, target: target, document: DocumentContext()
            )
        )
    }

    func run(_ jobs: [WorkbenchJob], source: Language, target: Language)
        -> AsyncStream<WorkbenchEvent>
    {
        AsyncStream { continuation in
            guard let provider else {
                for job in jobs {
                    continuation.yield(.failed(index: job.index, message: tDetached("未配置语言模型")))
                }
                continuation.finish()
                return
            }
            let task = Task {
                await withTaskGroup(of: WorkbenchEvent.self) { group in
                    var next = jobs.startIndex
                    var running = 0

                    func launch() {
                        guard next < jobs.endIndex else { return }
                        let job = jobs[next]
                        next += 1
                        running += 1
                        group.addTask {
                            await Self.translate(job, source: source, target: target,
                                                 provider: provider)
                        }
                    }

                    for _ in 0..<Self.width { launch() }
                    while running > 0, let event = await group.next() {
                        running -= 1
                        continuation.yield(event)
                        if Task.isCancelled { break }
                        launch()
                    }
                    group.cancelAll()
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func translate(
        _ job: WorkbenchJob, source: Language, target: Language,
        provider: any TranslationProvider
    ) async -> WorkbenchEvent {
        let request = TranslationRequest(
            text: job.text, source: source, target: target, document: job.context
        )
        var text = ""
        do {
            for try await event in provider.translate(request) {
                try Task.checkCancellation()
                switch event {
                case .delta(let chunk):  text += chunk
                case .replace(let full): text = full
                case .dictionary:        break   // a document segment is never a lookup
                }
            }
            return .finished(index: job.index, text: text)
        } catch is CancellationError {
            return .failed(index: job.index, message: tDetached("已取消"))
        } catch {
            // Whatever arrived before the failure is still worth showing: a
            // stream that died three sentences in leaves three usable
            // sentences, and the row is marked either way.
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return .finished(index: job.index, text: text)
            }
            return .failed(index: job.index, message: error.localizedDescription)
        }
    }
}
