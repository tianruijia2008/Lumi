import CoreServices
import Foundation

/// Definitions straight from the dictionaries installed in Dictionary.app.
///
/// Offline, keyless and instant — the best first result for a single word, and
/// unlike every network service it still works on a plane.
struct AppleDictionaryProvider: TranslationProvider {
    let kind = ServiceKind.appleDictionary
    let requiresNetwork = false

    func availability(for request: TranslationRequest) async -> ProviderAvailability {
        request.isLookup ? .ready : .notApplicable(tDetached("查不到"))
    }

    func translate(_ request: TranslationRequest) -> AsyncThrowingStream<TranslationEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let term = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
                // DCSCopyTextDefinition reads dictionary files synchronously, so
                // it runs off the main actor with a deadline like every other
                // out-of-process call in the app.
                let definition = await withBlockingTimeout(2.0) { () -> String? in
                    let range = CFRangeMake(0, term.utf16.count)
                    guard let result = DCSCopyTextDefinition(nil, term as CFString, range) else {
                        return nil
                    }
                    return result.takeRetainedValue() as String
                }
                guard let raw = definition ?? nil, !raw.isEmpty,
                      let entry = DictionaryFormatter.parse(raw, term: term) else {
                    continuation.finish(throwing: TranslationFailure.emptyResult)
                    return
                }
                // Which dictionary answers is the system's choice, not ours —
                // `DCSCopyTextDefinition` walks Dictionary.app's own priority
                // list and there is no public way to steer it. So it will hand
                // back a 现代汉语 entry for a 中文 → English request: correct
                // Chinese, and no answer at all to the question that was
                // asked. Standing down lets the ladder fall through to a
                // translator that will answer it, which beats sitting at the
                // top of the card holding a definition in the wrong language.
                guard entry.answers(in: request.target) else {
                    continuation.finish(throwing: TranslationFailure.emptyResult)
                    return
                }
                continuation.yield(.dictionary(entry))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
