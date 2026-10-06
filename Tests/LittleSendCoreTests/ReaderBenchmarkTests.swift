import XCTest
@testable import LittleSendCore

/// Times the built-in reader against Instaparser on real articles. Skipped
/// unless an API key is given, so the normal suite stays offline:
///
///   INSTAPARSER_API_KEY=… LITTLESEND_BENCH_URLS=https://a,https://b \
///     swift test --filter ReaderBenchmarkTests
///
/// Each article is read twice by each reader, alternating which goes first so
/// neither benefits from the other having warmed a DNS or HTTP cache. Word
/// counts are printed beside the times, since a fast read that drops half the
/// article is not a win.
///
/// Instaparser calls are spaced at least 1.5 s apart: the Trial plan allows
/// one per second and rate-limits (HTTP 429) beyond that, which would show up
/// here as failures rather than timings.
final class ReaderBenchmarkTests: XCTestCase {

    @MainActor
    func testCompareReaders() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let key = env["INSTAPARSER_API_KEY"], !key.isEmpty else {
            throw XCTSkip("INSTAPARSER_API_KEY not set")
        }
        let urls = (env["LITTLESEND_BENCH_URLS"] ?? "")
            .split(separator: ",")
            .compactMap { URL(string: $0.trimmingCharacters(in: .whitespaces)) }
        guard !urls.isEmpty else { throw XCTSkip("LITTLESEND_BENCH_URLS not set") }

        let instaparser = InstaparserClient(apiKey: key)
        var lastInstaparserCall = Date.distantPast

        func time(_ read: () async throws -> ParsedArticle) async -> (seconds: Double, words: Int?, pages: Int, error: String?) {
            let start = Date()
            do {
                let article = try await read()
                return (Date().timeIntervalSince(start), ReadingTime.wordCount(ofHTML: article.html), article.pageCount, nil)
            } catch {
                return (Date().timeIntervalSince(start), nil, 0, error.localizedDescription)
            }
        }

        for url in urls {
            for round in 0..<2 {
                let order: [ArticleReader] = round == 0 ? [.local, .instaparser] : [.instaparser, .local]
                for reader in order {
                    if reader == .instaparser {
                        let wait = 1.5 - Date().timeIntervalSince(lastInstaparserCall)
                        if wait > 0 { try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
                        lastInstaparserCall = Date()
                    }
                    let result = await time {
                        switch reader {
                        case .local: return try await LocalArticleParser().parse(url: url)
                        case .instaparser: return try await instaparser.parse(url: url)
                        }
                    }
                    let outcome = result.error.map { "FAILED \($0)" }
                        ?? "words=\(result.words ?? 0) pages=\(result.pages)"
                    print(String(
                        format: "BENCH\t%@\t%@\tround=%d\t%.2fs\t%@",
                        url.host ?? url.absoluteString, reader.rawValue, round + 1, result.seconds, outcome
                    ))
                }
            }
        }
    }
}
