import XCTest
@testable import LittleSendCore

final class ArticleTitleTests: XCTestCase {

    private func clean(
        _ title: String, html: String? = nil, site: String? = nil, url: String? = nil
    ) -> String {
        ArticleTitle.clean(rawTitle: title, html: html, siteName: site, url: url)
    }

    // MARK: - Brand suffixes

    func testStripsSuffixMatchingSiteName() {
        XCTAssertEqual(clean("Kindle Direct Publishing - Wikipedia", site: "Wikipedia"), "Kindle Direct Publishing")
        XCTAssertEqual(clean("Some Story | The Verge", site: "The Verge"), "Some Story")
        XCTAssertEqual(clean("A Piece — The Atlantic", site: "the atlantic"), "A Piece")
    }

    func testStripsSuffixUsingTheDomainWhenSiteNameIsMissing() {
        // Site name is often absent; the host still identifies the publication.
        XCTAssertEqual(clean("Some Story | The Verge", url: "https://www.theverge.com/x"), "Some Story")
        XCTAssertEqual(clean("An Article - Wikipedia", url: "https://en.wikipedia.org/wiki/X"), "An Article")
        XCTAssertEqual(clean("Headline · Ars Technica", url: "https://arstechnica.com/x"), "Headline")
    }

    func testStripsSuffixWhenBrandDropsALeadingThe() {
        XCTAssertEqual(clean("Story - Verge", url: "https://www.theverge.com/x"), "Story")
        XCTAssertEqual(clean("Story - The Guardian", url: "https://guardian.co.uk/x"), "Story")
    }

    func testStripsMultipleTrailingBrandSegments() {
        XCTAssertEqual(
            clean("Real Headline - Tech - The Verge", site: "The Verge"),
            "Real Headline - Tech",
            "only segments naming the site should go"
        )
        XCTAssertEqual(
            clean("Real Headline | The Verge | theverge.com", site: "The Verge"),
            "Real Headline"
        )
    }

    func testStripsBrandPrefix() {
        XCTAssertEqual(clean("The Verge: Some Story", site: "The Verge"), "Some Story")
        XCTAssertEqual(clean("Wikipedia — An Article", site: "Wikipedia"), "An Article")
    }

    func testStripsATrailingBylineOnPersonalSites() {
        // Personal blogs append the writer where a publication would put its
        // masthead — the real gatesnotes.com case.
        XCTAssertEqual(
            ArticleTitle.clean(
                rawTitle: "The choices we make about AI now are critical | Bill Gates",
                html: nil, siteName: "gatesnotes.com",
                url: "https://www.gatesnotes.com/x", author: "Bill Gates"
            ),
            "The choices we make about AI now are critical"
        )
    }

    func testBylineStrippingStillRefusesToGutTheTitle() {
        XCTAssertEqual(
            ArticleTitle.clean(
                rawTitle: "AI - Bill Gates", html: nil, siteName: nil,
                url: nil, author: "Bill Gates"
            ),
            "AI - Bill Gates"
        )
    }

    func testAuthorNameInsideTheTitleIsNotStripped() {
        // Only a separator-delimited trailing segment counts, so an article
        // about someone keeps their name.
        XCTAssertEqual(
            ArticleTitle.clean(
                rawTitle: "The Rise and Fall of Bill Gates", html: nil,
                siteName: "Example", url: nil, author: "Bill Gates"
            ),
            "The Rise and Fall of Bill Gates"
        )
    }

    // MARK: - Things that must survive

    func testLeavesTitlesWithoutABrandSuffixAlone() {
        XCTAssertEqual(clean("How to Do Great Work", site: "Paul Graham"), "How to Do Great Work")
        XCTAssertEqual(clean("Dogs - A History", site: "Wikipedia"), "Dogs - A History")
    }

    func testKeepsColonTitlesThatAreNotBranding() {
        XCTAssertEqual(
            clean("Rust: A Language for Systems Programming", site: "Example"),
            "Rust: A Language for Systems Programming"
        )
    }

    func testRefusesToStripDownToNothing() {
        XCTAssertEqual(clean("Go - Wikipedia", site: "Wikipedia"), "Go - Wikipedia")
        XCTAssertEqual(clean("Wikipedia", site: "Wikipedia"), "Wikipedia")
    }

    func testEmptyAndWhitespaceTitles() {
        XCTAssertEqual(clean("   "), "")
        XCTAssertEqual(clean(""), "")
    }

    // MARK: - Heading extraction

    func testExtractsFirstH1Text() {
        let html = "<div><h1>The Real Headline</h1><p>body</p><h1>Later</h1></div>"
        XCTAssertEqual(ArticleTitle.firstHeading(in: html), "The Real Headline")
    }

    func testExtractsH1WithAttributesAndNestedMarkup() {
        let html = #"<h1 class="title" id="x">The <em>Real</em> Headline</h1>"#
        XCTAssertEqual(ArticleTitle.firstHeading(in: html), "The Real Headline")
    }

    func testDecodesEntitiesInHeadings() {
        XCTAssertEqual(ArticleTitle.firstHeading(in: "<h1>Tom &amp; Jerry &mdash; Again</h1>"), "Tom & Jerry — Again")
    }

    func testIgnoresH2AndReturnsNilWhenAbsent() {
        XCTAssertNil(ArticleTitle.firstHeading(in: "<h2>Not the title</h2><p>x</p>"))
        XCTAssertNil(ArticleTitle.firstHeading(in: "<p>no headings</p>"))
        XCTAssertNil(ArticleTitle.firstHeading(in: "<h1></h1>"))
    }

    func testDoesNotMatchH10OrSimilar() {
        XCTAssertNil(ArticleTitle.firstHeading(in: "<h10>Nope</h10>"))
    }

    // MARK: - Heading-driven cleanup

    func testHeadingReplacesTitleWhenTitleMerelyAppendsSiteFurniture() {
        let html = "<h1>The Real Headline</h1><p>body</p>"
        XCTAssertEqual(
            clean("The Real Headline | Some Site You Cannot Guess", html: html),
            "The Real Headline",
            "the h1 should win even when the suffix is not a recognizable brand"
        )
    }

    func testUnrelatedHeadingIsIgnored() {
        // A nav or banner heading must never replace the title.
        let html = "<h1>Menu</h1><p>body</p>"
        XCTAssertEqual(clean("A Completely Different Article Title", html: html), "A Completely Different Article Title")
    }

    func testHeadingThatIsATinyFragmentIsIgnored() {
        let html = "<h1>The</h1>"
        XCTAssertEqual(clean("The Long And Winding Article Title", html: html), "The Long And Winding Article Title")
    }

    func testHeadingIdenticalToTitleChangesNothing() {
        let html = "<h1>Exactly The Same</h1>"
        XCTAssertEqual(clean("Exactly The Same", html: html), "Exactly The Same")
    }

    func testHeadingWinsOverBrandStripping() {
        let html = "<h1>Kindle Direct Publishing</h1>"
        XCTAssertEqual(
            clean("Kindle Direct Publishing - Wikipedia", html: html, site: "Wikipedia"),
            "Kindle Direct Publishing"
        )
    }

    // MARK: - Brand tokens

    func testBrandTokensCoverSiteNameAndDomain() {
        let tokens = ArticleTitle.brandTokens(siteName: "The Verge", url: "https://www.theverge.com/tech")
        XCTAssertTrue(tokens.contains("theverge"))
        XCTAssertTrue(tokens.contains("verge"))
    }

    func testBrandTokensHandleMissingInputs() {
        XCTAssertTrue(ArticleTitle.brandTokens(siteName: nil, url: nil).isEmpty)
        XCTAssertFalse(ArticleTitle.brandTokens(siteName: "X", url: nil).isEmpty)
    }

    func testNormalizationIgnoresPunctuationAndCase() {
        XCTAssertEqual(ArticleTitle.normalize("The N.Y. Times!"), "thenytimes")
    }
}
