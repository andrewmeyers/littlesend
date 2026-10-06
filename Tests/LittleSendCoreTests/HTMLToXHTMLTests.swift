import XCTest
@testable import LittleSendCore

final class HTMLToXHTMLTests: XCTestCase {

    private func assertWellFormed(_ fragment: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(
            EPUBBuilder.isWellFormed(fragment: fragment),
            "not well-formed XML: \(fragment)",
            file: file, line: line
        )
    }

    func testVoidElementsAreSelfClosed() {
        let output = HTMLToXHTML.convert("<p>a<br>b<img src=\"x.png\">c<hr></p>")
        XCTAssertTrue(output.contains("<br/>"))
        XCTAssertTrue(output.contains("<hr/>"))
        XCTAssertTrue(output.contains("<img src=\"x.png\"/>"))
        assertWellFormed(output)
    }

    func testUnclosedParagraphsAreClosed() {
        let output = HTMLToXHTML.convert("<div><p>one<p>two</div>")
        assertWellFormed(output)
        XCTAssertEqual(output, "<div><p>one<p>two</p></p></div>")
    }

    func testStrayEndTagsAreDropped() {
        let output = HTMLToXHTML.convert("<p>text</span></p></div>")
        assertWellFormed(output)
        XCTAssertEqual(output, "<p>text</p>")
    }

    func testScriptAndStyleContentIsRemoved() {
        let html = "<p>before</p><script>if (a < b) { x(); }</script><style>.a{color:red}</style><p>after</p>"
        let output = HTMLToXHTML.convert(html)
        XCTAssertFalse(output.contains("x()"))
        XCTAssertFalse(output.contains("color:red"))
        XCTAssertTrue(output.contains("before"))
        XCTAssertTrue(output.contains("after"))
        assertWellFormed(output)
    }

    func testBareAmpersandIsEscaped() {
        let output = HTMLToXHTML.convert("<p>Tom & Jerry & Q&A</p>")
        XCTAssertEqual(output, "<p>Tom &amp; Jerry &amp; Q&amp;A</p>")
        assertWellFormed(output)
    }

    func testNamedEntitiesBecomeNumeric() {
        let output = HTMLToXHTML.convert("<p>caf&eacute;&nbsp;&mdash;&hellip;</p>")
        XCTAssertEqual(output, "<p>caf&#233;&#160;&#8212;&#8230;</p>")
        assertWellFormed(output)
    }

    func testXMLPredefinedEntitiesSurvive() {
        let output = HTMLToXHTML.convert("<p>a &amp; b &lt; c</p>")
        XCTAssertEqual(output, "<p>a &amp; b &lt; c</p>")
        assertWellFormed(output)
    }

    func testUnknownEntityIsNeutralized() {
        let output = HTMLToXHTML.convert("<p>&notanentity;</p>")
        assertWellFormed(output)
        XCTAssertTrue(output.contains("&amp;notanentity;"))
    }

    func testBooleanAndUnquotedAttributes() {
        let output = HTMLToXHTML.convert("<img src=photo.jpg alt=\"A photo\" loading=lazy>")
        assertWellFormed(output)
        XCTAssertTrue(output.contains("src=\"photo.jpg\""))
        XCTAssertTrue(output.contains("alt=\"A photo\""))
        // loading is not on the allowlist and is dropped.
        XCTAssertFalse(output.contains("loading"))
    }

    func testEventHandlerAttributesAreDropped() {
        let output = HTMLToXHTML.convert("<a href=\"/x\" onclick=\"steal()\">link</a>")
        XCTAssertFalse(output.contains("onclick"))
        XCTAssertTrue(output.contains("href=\"/x\""))
        assertWellFormed(output)
    }

    func testUnknownElementsAreUnwrappedKeepingText() {
        let output = HTMLToXHTML.convert("<custom-widget><p>kept</p></custom-widget>")
        XCTAssertEqual(output, "<p>kept</p>")
        assertWellFormed(output)
    }

    func testCommentsAndDoctypeAreRemoved() {
        let output = HTMLToXHTML.convert("<!DOCTYPE html><!-- hi --><p>x</p>")
        XCTAssertEqual(output, "<p>x</p>")
        assertWellFormed(output)
    }

    func testBareLessThanInTextIsEscaped() {
        let output = HTMLToXHTML.convert("<p>5 < 10 and a<b</p>")
        assertWellFormed(output)
        XCTAssertTrue(output.contains("&lt;"))
    }

    func testAttributeQuotesAreEscaped() {
        let output = HTMLToXHTML.convert("<a href='/a?x=1&y=2' title='He said \"hi\"'>t</a>")
        assertWellFormed(output)
        XCTAssertTrue(output.contains("&amp;"))
        XCTAssertTrue(output.contains("&quot;"))
    }

    func testNestedListsSurvive() {
        let output = HTMLToXHTML.convert("<ul><li>a<ul><li>b</li></ul></li></ul>")
        assertWellFormed(output)
        XCTAssertTrue(output.contains("<li>b</li>"))
    }

    func testControlCharacterReferenceIsDropped() {
        // &#1; is illegal in XML and must not survive as a numeric reference.
        let output = HTMLToXHTML.convert("<p>a&#1;b</p>")
        assertWellFormed(output)
        XCTAssertFalse(output.contains("&#1;"))
    }

    func testPlainTextStripsMarkup() {
        let text = HTMLToXHTML.plainText("<p>Hello <b>world</b></p><p>Second &amp; last</p>")
        XCTAssertTrue(text.contains("Hello"))
        XCTAssertTrue(text.contains("Second & last"))
        XCTAssertFalse(text.contains("<"))
    }

    func testMultiByteTextPassesThroughUnchanged() {
        // The scanner works on UTF-8 bytes; none of this may be split or lost.
        let text = "Café — naïve 東京 🇯🇵 e\u{301} שלום"
        let output = HTMLToXHTML.convert("<p>\(text)</p>")
        XCTAssertEqual(output, "<p>\(text)</p>")
        assertWellFormed(output)
    }

    func testMultiByteAttributeValuesSurvive() {
        let output = HTMLToXHTML.convert("<img src=\"/é.png\" alt='東京 & co'>")
        XCTAssertEqual(output, "<img alt=\"東京 &amp; co\" src=\"/é.png\"/>")
        assertWellFormed(output)
    }

    func testDiscardedElementEndsAtAnyCaseEndTag() {
        let output = HTMLToXHTML.convert("<p>a</p><SCRIPT>x()</Script><p>b</p>")
        XCTAssertEqual(output, "<p>a</p><p>b</p>")
    }

    func testUppercaseTagsAreLowercased() {
        XCTAssertEqual(HTMLToXHTML.convert("<P>x</P>"), "<p>x</p>")
    }

    func testDeeplyNestedInputIsCappedButKeepsContent() {
        let html = String(repeating: "<div>", count: 500) + "deep" + String(repeating: "</div>", count: 500)
        let output = HTMLToXHTML.convert(html)

        // Must stay parseable: libxml2 rejects documents nested past ~256 levels.
        assertWellFormed(output)
        XCTAssertTrue(output.contains("deep"))

        let depth = output.components(separatedBy: "<div>").count - 1
        XCTAssertLessThanOrEqual(depth, HTMLToXHTML.maximumNestingDepth)
    }
}

final class PlainTextTests: XCTestCase {

    func testInlineMarkupLeavesNoExtraSpaces() {
        XCTAssertEqual(HTMLToXHTML.plainText("<p>Hello <b>world</b></p>"), "Hello world")
        XCTAssertEqual(HTMLToXHTML.plainText("<p>a<em>b</em>c</p>"), "abc")
    }

    func testBlockElementsBecomeLineBreaks() {
        XCTAssertEqual(
            HTMLToXHTML.plainText("<p>First</p><p>Second</p>"),
            "First\nSecond"
        )
        XCTAssertEqual(
            HTMLToXHTML.plainText("<h1>Title</h1><p>Body</p><ul><li>one</li><li>two</li></ul>"),
            "Title\nBody\none\ntwo"
        )
    }

    func testLineBreakTagSplitsLines() {
        XCTAssertEqual(HTMLToXHTML.plainText("<p>one<br>two</p>"), "one\ntwo")
    }

    func testEntitiesAreDecoded() {
        XCTAssertEqual(HTMLToXHTML.plainText("<p>Tom &amp; Jerry &mdash; again</p>"), "Tom & Jerry — again")
    }

    func testBlankLinesAreCollapsed() {
        XCTAssertEqual(HTMLToXHTML.plainText("<div><p>a</p></div><div></div><p>b</p>"), "a\nb")
    }

    func testMultiByteTextSurvives() {
        XCTAssertEqual(HTMLToXHTML.plainText("<p>東京</p><p>café 🇯🇵</p>"), "東京\ncafé 🇯🇵")
    }

    func testScriptContentIsAbsent() {
        XCTAssertEqual(HTMLToXHTML.plainText("<p>keep</p><script>drop()</script>"), "keep")
    }
}
