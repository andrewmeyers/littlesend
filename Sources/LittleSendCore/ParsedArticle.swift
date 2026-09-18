import Foundation

/// A readable article, extracted from a web page by `LocalArticleParser`.
///
/// Everything downstream — the EPUB, the email, the Desktop copy — is built
/// from this one value, so how the article was read never leaks further in.
public struct ParsedArticle: Sendable, Equatable {
    public var url: String
    public var title: String
    public var siteName: String?
    public var author: String?
    public var description: String?
    public var html: String
    public var publishedDate: Date?
    public var wordCount: Int?
    public var isRightToLeft: Bool
    /// How many web pages the article was read from — more than 1 when it was
    /// paginated and the later pages were followed.
    public var pageCount: Int

    public init(
        url: String,
        title: String,
        siteName: String? = nil,
        author: String? = nil,
        description: String? = nil,
        html: String,
        publishedDate: Date? = nil,
        wordCount: Int? = nil,
        isRightToLeft: Bool = false,
        pageCount: Int = 1
    ) {
        self.url = url
        self.title = title
        self.siteName = siteName
        self.author = author
        self.description = description
        self.html = html
        self.publishedDate = publishedDate
        self.wordCount = wordCount
        self.isRightToLeft = isRightToLeft
        self.pageCount = pageCount
    }
}
