import Foundation

/// Instaparser's Article API, the optional faster reader. See `ArticleReader`
/// for when it is used and `ArticleReading` for the fallback to this Mac's own.

public struct InstaparserError: LocalizedError, Equatable {
    public let statusCode: Int?
    public let message: String
    public var errorDescription: String? { message }

    public init(statusCode: Int?, message: String) {
        self.statusCode = statusCode
        self.message = message
    }
}

/// Client for `POST https://www.instaparser.com/api/1/article`.
public struct InstaparserClient {
    private let apiKey: String
    private let endpoint: URL
    private let session: URLSession

    public init(
        apiKey: String,
        endpoint: URL = URL(string: "https://www.instaparser.com/api/1/article")!,
        session: URLSession = .shared
    ) {
        self.apiKey = apiKey
        self.endpoint = endpoint
        self.session = session
    }

    public func parse(url: URL) async throws -> ParsedArticle {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("LittleSend/1.0", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 45
        request.httpBody = try JSONSerialization.data(
            withJSONObject: ["url": url.absoluteString, "output": "html"]
        )

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw InstaparserError(statusCode: nil, message: "Could not reach Instaparser: \(error.localizedDescription)")
        }

        guard let http = response as? HTTPURLResponse else {
            throw InstaparserError(statusCode: nil, message: "Unexpected response from Instaparser.")
        }
        guard http.statusCode == 200 else {
            throw InstaparserError(statusCode: http.statusCode, message: Self.describe(status: http.statusCode, body: data))
        }

        return try Self.decode(data: data, requestedURL: url)
    }

    static func decode(data: Data, requestedURL: URL) throws -> ParsedArticle {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw InstaparserError(statusCode: 200, message: "Instaparser returned a response that could not be read.")
        }

        let html = (object["html"] as? String) ?? (object["text"] as? String) ?? ""
        guard !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw InstaparserError(statusCode: 200, message: "Instaparser found no article text on that page.")
        }

        var publishedDate: Date?
        if let timestamp = object["date"] as? Double, timestamp > 0 {
            publishedDate = Date(timeIntervalSince1970: timestamp)
        }

        let siteName = nonEmpty(object["site_name"])
        let canonicalURL = (object["url"] as? String) ?? requestedURL.absoluteString
        let rawTitle = (object["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = rawTitle.map {
            ArticleTitle.clean(
                rawTitle: $0, html: html, siteName: siteName,
                url: canonicalURL, author: nonEmpty(object["author"])
            )
        }

        return ParsedArticle(
            url: canonicalURL,
            title: (title?.isEmpty == false ? title! : requestedURL.host) ?? "Untitled",
            siteName: siteName,
            author: nonEmpty(object["author"]),
            description: nonEmpty(object["description"]),
            html: html,
            publishedDate: publishedDate,
            wordCount: object["words"] as? Int,
            isRightToLeft: (object["is_rtl"] as? Bool) ?? false
        )
    }

    private static func nonEmpty(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func describe(status: Int, body: Data) -> String {
        let detail = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])
            .flatMap { $0?["error"] as? String ?? $0?["message"] as? String }

        let base: String
        switch status {
        case 400: base = "Instaparser rejected the request (bad URL?)."
        case 401: base = "Instaparser rejected the API key. Check it in Settings."
        case 403: base = "This Instaparser account is suspended."
        case 409: base = "Instaparser monthly quota exceeded."
        case 412: base = "Instaparser could not extract an article from that page."
        case 429: base = "Instaparser rate limit reached. Try again in a moment."
        case 500...599: base = "Instaparser is having trouble (HTTP \(status)). Try again shortly."
        default: base = "Instaparser returned HTTP \(status)."
        }
        if let detail, !detail.isEmpty { return "\(base) (\(detail))" }
        return base
    }
}
