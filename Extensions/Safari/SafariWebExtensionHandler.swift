import Foundation
import SafariServices

/// The native half of the Safari extension, and deliberately almost nothing.
///
/// Safari only discovers a web extension that ships inside an app as an appex,
/// so this bundle has to exist. What it does is relay: the extension's
/// background script may not be allowed to reach `http://127.0.0.1` itself,
/// but it can always send a native message, and this sandboxed process can
/// always open a loopback socket. Everything else — which engine, which key,
/// what prompt — stays in Lumi, where the settings and the keychain already are.
///
/// Built with `swiftc` by `build.sh`; there is no Xcode project.
@objc(SafariWebExtensionHandler)
final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    /// Must match `PageBridge.port`.
    static let bridge = "http://127.0.0.1:47121"

    func beginRequest(with context: NSExtensionContext) {
        let item = context.inputItems.first as? NSExtensionItem
        let message = item?.userInfo?[SFExtensionMessageKey] as? [String: Any] ?? [:]

        let path = message["path"] as? String ?? "/v1/status"
        let method = message["method"] as? String ?? "GET"
        guard path.hasPrefix("/v1/"), let url = URL(string: Self.bridge + path) else {
            return Self.reply(context, ["status": 400, "body": #"{"error":"bad path"}"#])
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("safari-appex", forHTTPHeaderField: "X-Lumi-Client")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // A page batch through a language model can take a while; Lumi has
        // its own deadline and answers before this one.
        request.timeoutInterval = 100
        if let body = message["body"] as? String { request.httpBody = Data(body.utf8) }

        // The context is not Sendable, but it is only touched again once, from
        // the completion handler, after this method has returned.
        nonisolated(unsafe) let context = context
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                // Connection refused is the normal "Lumi is not running" case.
                Self.reply(context, ["status": 0, "error": error.localizedDescription])
                return
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            Self.reply(context, ["status": status, "body": body])
        }.resume()
    }

    private static func reply(_ context: NSExtensionContext, _ payload: [String: Any]) {
        let response = NSExtensionItem()
        response.userInfo = [SFExtensionMessageKey: payload]
        context.completeRequest(returningItems: [response], completionHandler: nil)
    }
}
