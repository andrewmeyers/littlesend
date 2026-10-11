import XCTest
@testable import LittleSendCore

final class ArticleLinkTests: XCTestCase {
    private func url(_ text: String) -> String? {
        ArticleLink.normalizedURL(from: text)?.absoluteString
    }

    func testAcceptsAddressesWithOrWithoutAScheme() {
        XCTAssertEqual(url("https://example.com/post"), "https://example.com/post")
        XCTAssertEqual(url("http://example.com"), "http://example.com")
        XCTAssertEqual(url("example.com/post"), "https://example.com/post")
        XCTAssertEqual(url("  https://example.com/a?b=1#c \n"), "https://example.com/a?b=1#c")
    }

    /// The bug: `name@kindle.com` became `https://name@kindle.com`, a page on
    /// kindle.com with a username, and filled the link field — notably after
    /// copying your own address during setup.
    func testAnEmailAddressIsNotALink() {
        XCTAssertNil(url("T7UhPAkctvHM3w@kindle.com"))
        XCTAssertNil(url("me@gmail.com"))
        XCTAssertNil(url("first.last@example.co.uk"))
        XCTAssertNil(url("me@example.com/path"))
        XCTAssertNil(url("https://me@example.com"))
        XCTAssertNil(url("mailto:me@example.com"))
    }

    func testRefusesWhatIsNotAnArticle() {
        XCTAssertNil(url(""))
        XCTAssertNil(url("   "))
        XCTAssertNil(url("two words.com"))
        XCTAssertNil(url("localhost"), "a bare host needs a dot")
        XCTAssertNil(url("ftp://example.com/file"))
        XCTAssertNil(url("just some text"))
    }
}
