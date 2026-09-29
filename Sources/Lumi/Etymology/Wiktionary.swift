import Foundation

/// The MediaWiki API, for the three questions the 词源 page asks.
enum Wiktionary {
    enum Failure: LocalizedError {
        case missing
        case badResponse(String)

        var errorDescription: String? {
            switch self {
            case .missing:               "Wiktionary 没有这个词条"
            case .badResponse(let why):  "Wiktionary 返回异常：\(why)"
            }
        }
    }

    private static let endpoint = URL(string: "https://en.wiktionary.org/w/api.php")!

    /// Both renderings of a page in one request.
    static func page(_ title: String) async throws -> (wikitext: String, html: String) {
        let json = try await call(["action": "parse", "page": title, "prop": "wikitext|text", "redirects": "1"])
        guard let parse = json["parse"] as? [String: Any] else { throw failure(json) }
        guard let wikitext = parse["wikitext"] as? String, let html = parse["text"] as? String else {
            throw Failure.badResponse("缺少正文")
        }
        return (wikitext, html)
    }

    static func wikitext(_ title: String) async throws -> String {
        let json = try await call(["action": "parse", "page": title, "prop": "wikitext", "redirects": "1"])
        guard let text = (json["parse"] as? [String: Any])?["wikitext"] as? String else { throw failure(json) }
        return text
    }

    static func categories(of title: String) async throws -> [String] {
        let json = try await call(["action": "query", "prop": "categories", "titles": title, "cllimit": "max"])
        let pages = (json["query"] as? [String: Any])?["pages"] as? [[String: Any]]
        return (pages?.first?["categories"] as? [[String: Any]])?.compactMap { $0["title"] as? String } ?? []
    }

    static func members(of category: String) async throws -> [String] {
        let json = try await call([
            "action": "query", "list": "categorymembers", "cmtitle": category,
            "cmlimit": "500", "cmnamespace": "0",
        ])
        let list = (json["query"] as? [String: Any])?["categorymembers"] as? [[String: Any]]
        return list?.compactMap { $0["title"] as? String } ?? []
    }

    static func url(for title: String) -> URL? {
        let path = title.replacingOccurrences(of: " ", with: "_")
            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? title
        return URL(string: "https://en.wiktionary.org/wiki/\(path)")
    }

    private static func call(_ items: [String: String]) async throws -> [String: Any] {
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = items.merging(["format": "json", "formatversion": "2"]) { a, _ in a }
            .sorted { $0.key < $1.key }
            .map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: components.url!, timeoutInterval: 15)
        // Wikimedia asks API clients to identify themselves and throttles
        // anonymous default agents first.
        request.setValue("Lumi/1.0 (macOS dictionary utility)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw Failure.badResponse("HTTP \(http.statusCode)")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.badResponse("无法解析")
        }
        return json
    }

    private static func failure(_ json: [String: Any]) -> Failure {
        let code = (json["error"] as? [String: Any])?["code"] as? String
        return code == "missingtitle" ? .missing : .badResponse(code ?? "未知错误")
    }
}
