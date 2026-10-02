import XCTest
@testable import LittleSendCore

final class RecipientParsingTests: XCTestCase {

    func testSplitsOnCommasSemicolonsAndNewlines() {
        XCTAssertEqual(
            SettingsDraft.parseRecipients("a@x.com, b@x.com; c@x.com\nd@x.com"),
            ["a@x.com", "b@x.com", "c@x.com", "d@x.com"]
        )
    }

    func testTrimsWhitespaceAndSkipsBlanks() {
        XCTAssertEqual(
            SettingsDraft.parseRecipients("  a@x.com ,, \n\n  b@x.com  \n"),
            ["a@x.com", "b@x.com"]
        )
    }

    func testExtractsAddressFromDisplayNameForm() {
        // Pasting straight out of a mail client.
        XCTAssertEqual(
            SettingsDraft.parseRecipients("Jane Doe <jane@x.com>, bob@y.com"),
            ["jane@x.com", "bob@y.com"]
        )
    }

    func testDeduplicatesCaseInsensitivelyKeepingWhatWasTyped() {
        XCTAssertEqual(
            SettingsDraft.parseRecipients("Jane@x.com, jane@x.com, JANE@X.COM"),
            ["Jane@x.com"]
        )
    }

    func testEmptyInputYieldsNoRecipients() {
        XCTAssertTrue(SettingsDraft.parseRecipients("").isEmpty)
        XCTAssertTrue(SettingsDraft.parseRecipients("  ,  ; \n ").isEmpty)
    }

    func testNormalizationTrimsAddressesConsistently() {
        // Whitespace alone must not register as an unsaved change.
        var a = SettingsDraft(emailAddresses: ["  a@x.com  ", "b@x.com"])
        var b = SettingsDraft(emailAddresses: ["a@x.com", " b@x.com"])
        a.kindleAddress = "k@kindle.com"
        b.kindleAddress = "k@kindle.com"
        XCTAssertEqual(a.normalized, b.normalized)
    }
}

final class DestinationValidationTests: XCTestCase {

    private func configuration(
        kindle: Bool = true,
        kindleAddress: String = "me@kindle.com",
        recipients: [String] = []
    ) -> SendConfiguration {
        SendConfiguration(
            sendToKindle: kindle,
            kindleAddress: kindleAddress,
            emailRecipients: recipients,
            fromAddress: "me@gmail.com",
            smtpHost: "smtp.gmail.com",
            smtpPort: 465,
            smtpUsername: "me@gmail.com",
            smtpPassword: "p"
        )
    }

    func testKindleOnlyIsValid() {
        XCTAssertTrue(configuration().validationProblems.isEmpty)
    }

    func testEmailOnlyIsValid() {
        // A blank Kindle address is fine once Kindle is switched off.
        let config = configuration(kindle: false, kindleAddress: "", recipients: ["a@x.com"])
        XCTAssertTrue(config.validationProblems.isEmpty, "\(config.validationProblems)")
    }

    func testNoDestinationIsRejected() {
        let problems = configuration(kindle: false, recipients: []).validationProblems
        XCTAssertTrue(problems.contains { $0.contains("No destination") })
    }

    func testMalformedRecipientIsNamed() {
        let problems = configuration(recipients: ["good@x.com", "nope"]).validationProblems
        XCTAssertTrue(problems.contains { $0.contains("nope") })
        XCTAssertFalse(problems.contains { $0.contains("good@x.com") })
    }

    func testBookIsOnlyBuiltWhenSomethingNeedsIt() {
        XCTAssertTrue(configuration().needsBook, "Kindle always needs an EPUB")
        XCTAssertFalse(
            configuration(kindle: false, recipients: ["a@x.com"]).needsBook,
            "an HTML-only email should not pay for EPUB generation"
        )

        var attaching = configuration(kindle: false, recipients: ["a@x.com"])
        attaching.attachBookToEmail = true
        XCTAssertTrue(attaching.needsBook)
    }
}

final class MultiRecipientMailTests: XCTestCase {

    private func message(
        recipients: [String] = ["a@x.com", "b@x.com"],
        html: String? = "<p>hello</p>",
        attachment: MailMessage.Attachment? = nil
    ) -> MailMessage {
        MailMessage(
            fromAddress: "me@example.com",
            fromName: "LittleSend",
            toAddresses: recipients,
            subject: "Subject",
            plainTextBody: "plain body",
            htmlBody: html,
            attachment: attachment
        )
    }

    func testAllRecipientsAppearInTheToHeader() {
        let text = String(decoding: message().serialized(), as: UTF8.self)
        XCTAssertTrue(text.contains("To: a@x.com, b@x.com"))
    }

    func testHTMLBodyProducesMultipartAlternative() {
        let text = String(decoding: message().serialized(boundary: "B"), as: UTF8.self)

        XCTAssertTrue(text.contains("Content-Type: multipart/alternative; boundary=\"B-alt\""))
        XCTAssertTrue(text.contains("Content-Type: text/plain; charset=\"utf-8\""))
        XCTAssertTrue(text.contains("Content-Type: text/html; charset=\"utf-8\""))
        XCTAssertTrue(text.contains("--B-alt--"))
        XCTAssertFalse(text.contains("multipart/mixed"), "no attachment, so no mixed wrapper")
    }

    func testPlainOnlyMessageIsNotMultipart() {
        let text = String(decoding: message(html: nil).serialized(), as: UTF8.self)
        XCTAssertTrue(text.contains("Content-Type: text/plain; charset=\"utf-8\""))
        XCTAssertFalse(text.contains("multipart"))
    }

    func testHTMLPlusAttachmentNestsAlternativeInsideMixed() {
        let attachment = MailMessage.Attachment(
            fileName: "a.epub", mediaType: "application/epub+zip", data: Data(repeating: 1, count: 64)
        )
        let text = String(decoding: message(attachment: attachment).serialized(boundary: "B"), as: UTF8.self)

        XCTAssertTrue(text.contains("Content-Type: multipart/mixed; boundary=\"B\""))
        XCTAssertTrue(text.contains("Content-Type: multipart/alternative; boundary=\"B-alt\""))
        XCTAssertTrue(text.contains("Content-Disposition: attachment; filename=\"a.epub\""))
        XCTAssertTrue(text.hasSuffix("--B--\r\n"))

        // The alternative block must close before the mixed part that follows it.
        let altClose = try! XCTUnwrap(text.range(of: "--B-alt--"))
        let attachmentStart = try! XCTUnwrap(text.range(of: "Content-Disposition: attachment"))
        XCTAssertLessThan(altClose.upperBound, attachmentStart.lowerBound)
    }

    func testBodiesRoundTripThroughBase64() throws {
        let text = String(decoding: message(html: "<p>hé &amp; now</p>").serialized(boundary: "B"), as: UTF8.self)
        let parts = text.components(separatedBy: "--B-alt")

        let htmlPart = try XCTUnwrap(parts.first { $0.contains("text/html") })
        let encoded = try XCTUnwrap(htmlPart.components(separatedBy: "\r\n\r\n").last)
            .replacingOccurrences(of: "\r\n", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let decoded = String(decoding: try XCTUnwrap(Data(base64Encoded: encoded)), as: UTF8.self)

        XCTAssertEqual(decoded, "<p>hé &amp; now</p>")
    }

    func testEveryLineStaysWithinTheRFCLimit() {
        let attachment = MailMessage.Attachment(
            fileName: "a.epub", mediaType: "application/epub+zip", data: Data(repeating: 7, count: 5000)
        )
        let text = String(decoding: message(attachment: attachment).serialized(), as: UTF8.self)
        for line in text.components(separatedBy: "\r\n") {
            XCTAssertLessThanOrEqual(line.utf8.count, 998)
        }
    }
}

final class ArticleEmailRendererTests: XCTestCase {

    private func article(html: String, url: String = "https://example.com/post/index.html") -> ParsedArticle {
        ParsedArticle(
            url: url, title: "The Title", siteName: "Example", author: "Jane Doe",
            html: html, publishedDate: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    func testHTMLCarriesTitleBylineAndSourceLink() {
        let rendered = ArticleEmailRenderer.render(article: article(html: "<p>Body.</p>"))

        XCTAssertTrue(rendered.html.contains("The Title"))
        XCTAssertTrue(rendered.html.contains("Jane Doe"))
        XCTAssertTrue(rendered.html.contains("https://example.com/post/index.html"))
        XCTAssertTrue(rendered.html.contains("Body."))
        XCTAssertEqual(rendered.subject, "The Title")
    }

    func testPlainTextAlternativeHasNoMarkup() {
        let rendered = ArticleEmailRenderer.render(article: article(html: "<p>Hello <b>world</b></p>"))
        XCTAssertTrue(rendered.plainText.contains("Hello world"), rendered.plainText)
        XCTAssertFalse(rendered.plainText.contains("<b>"))
    }

    func testRelativeImageAndLinkURLsAreMadeAbsolute() {
        let rendered = ArticleEmailRenderer.render(
            article: article(html: #"<p><img src="/a.png"><a href="../other.html">link</a></p>"#)
        )
        XCTAssertTrue(rendered.html.contains("https://example.com/a.png"))
        XCTAssertTrue(rendered.html.contains("https://example.com/other.html"))
    }

    func testAbsoluteAndDataURLsAreLeftAlone() {
        let html = #"<p><img src="https://cdn.example.com/a.png"><img src="data:image/png;base64,xx"></p>"#
        let rendered = ArticleEmailRenderer.render(article: article(html: html))
        XCTAssertTrue(rendered.html.contains("https://cdn.example.com/a.png"))
        XCTAssertTrue(rendered.html.contains("data:image/png;base64,xx"))
    }

    func testImagesAreKeptRatherThanStrippedAsTheEPUBDoes() {
        // Mail clients fetch remote images; unlike the EPUB, nothing is removed.
        let rendered = ArticleEmailRenderer.render(
            article: article(html: #"<p><img src="https://example.com/photo.jpg"></p>"#)
        )
        XCTAssertTrue(rendered.html.contains("photo.jpg"))
    }

    func testMarkupCharactersInTitleAreEscaped() {
        var subject = article(html: "<p>x</p>")
        subject.title = "A & B <c>"
        let rendered = ArticleEmailRenderer.render(article: subject)
        XCTAssertTrue(rendered.html.contains("A &amp; B &lt;c&gt;"))
    }
}

final class EmailResponsiveRenderingTests: XCTestCase {

    private func article(html: String, url: String = "https://example.com/post/") -> ParsedArticle {
        ParsedArticle(
            url: url, title: "The Title", siteName: "Example", author: "Jane Doe",
            html: html, publishedDate: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private func render(_ html: String) -> String {
        ArticleEmailRenderer.render(article: article(html: html)).html
    }

    // MARK: - Fonts

    func testUsesTheSystemUIFontStack() {
        let html = render("<p>x</p>")
        XCTAssertTrue(html.contains("-apple-system"))
        XCTAssertTrue(html.contains("BlinkMacSystemFont"))
        XCTAssertTrue(html.contains("Segoe UI"))
        XCTAssertTrue(html.contains("sans-serif"))
        XCTAssertFalse(html.contains("Georgia"), "the serif stack should be gone")
    }

    func testFontStackIsInlineSoItSurvivesStyleStripping() {
        // Several clients drop <style> blocks; the wrapper must carry it inline.
        let html = render("<p>x</p>")
        let body = html.components(separatedBy: "</head>")[1]
        XCTAssertTrue(body.contains("font-family:-apple-system"))
    }

    // MARK: - Responsive images

    func testEveryImageGetsInlineResponsiveStyles() {
        let html = render(#"<p><img src="https://cdn.example.com/wide.jpg"></p>"#)
        XCTAssertTrue(html.contains("max-width:100%"))
        XCTAssertTrue(html.contains("height:auto"))
    }

    func testMultipleImagesAreAllStyled() {
        let html = render("""
        <p><img src="https://e.com/a.jpg"><img src="https://e.com/b.jpg"></p>
        """)
        let styled = html.components(separatedBy: "max-width:100%;height:auto").count - 1
        XCTAssertEqual(styled, 2, "both images need the inline style")
    }

    func testImageStyleSurvivesAlongsideExistingAttributes() {
        let html = render(#"<img src="https://e.com/a.jpg" alt="A photo">"#)
        XCTAssertTrue(html.contains("alt=\"A photo\""))
        XCTAssertTrue(html.contains("src=\"https://e.com/a.jpg\""))
        XCTAssertTrue(html.contains("max-width:100%;height:auto"))
    }

    func testRelativeImageIsBothAbsolutizedAndStyled() {
        let html = render(#"<img src="photo.jpg">"#)
        XCTAssertTrue(html.contains("https://example.com/post/photo.jpg"))
        XCTAssertTrue(html.contains("max-width:100%;height:auto"))
    }

    func testEveryRelativeLinkIsAbsolutizedInOnePass() {
        let xhtml = #"<a href="/a" title="x">1</a><a href="b?x=1&amp;y=2">2</a>"#
            + ##"<a href="https://other.com/c">3</a><a href="#top">4</a><img src="../d.png" alt="/e"/>"##
        let result = ArticleEmailRenderer.absolutizeURLs(
            in: xhtml, relativeTo: URL(string: "https://example.com/post/")
        )

        XCTAssertTrue(result.contains(#"href="https://example.com/a""#))
        XCTAssertTrue(result.contains(#"href="https://example.com/post/b?x=1&amp;y=2""#))
        XCTAssertTrue(result.contains(#"href="https://other.com/c""#))
        XCTAssertTrue(result.contains(##"href="#top""##))
        XCTAssertTrue(result.contains(#"src="https://example.com/d.png""#))
        // Only src and href carry addresses; other attributes are left alone.
        XCTAssertTrue(result.contains(#"title="x""#))
        XCTAssertTrue(result.contains(#"alt="/e""#))
    }

    func testNoFixedWidthAttributesLeakThrough() {
        // A hard-coded width would defeat the responsive style.
        let html = render(#"<img src="https://e.com/a.jpg" width="1600" height="900">"#)
        XCTAssertFalse(html.contains("width=\"1600\""))
        XCTAssertFalse(html.contains("height=\"900\""))
    }

    // MARK: - Other overflow sources

    func testWideTablesAndPreAreConstrained() {
        let html = render("<table><tr><td>cell</td></tr></table><pre>a very long line</pre>")
        XCTAssertTrue(html.contains("max-width:100%;border-collapse:collapse"))
        XCTAssertTrue(html.contains("white-space:pre-wrap"))
    }

    func testLongSourceURLCanWrap() {
        XCTAssertTrue(render("<p>x</p>").contains("word-break:break-word"))
    }

    func testBlockquotesAndFiguresAreStyled() {
        let html = render("<blockquote>quoted</blockquote><figure><figcaption>cap</figcaption></figure>")
        XCTAssertTrue(html.contains("border-left:3px solid"))
        XCTAssertTrue(html.contains("text-align:center"))
    }

    // MARK: - Document shape

    func testCarriesViewportMetaForMobileClients() {
        XCTAssertTrue(render("<p>x</p>").contains(#"name="viewport" content="width=device-width, initial-scale=1""#))
    }

    func testHasSmallScreenMediaQuery() {
        XCTAssertTrue(render("<p>x</p>").contains("@media only screen and (max-width: 620px)"))
    }

    func testContentIsWidthCappedAndCentred() {
        XCTAssertTrue(render("<p>x</p>").contains("max-width:680px;margin:0 auto"))
    }

    func testTagNameMatchingIsExact() {
        // <tablet> must not be treated as <table>.
        let injected = ArticleEmailRenderer.injectStyle("S", intoTag: "table", in: "<tablet><table>")
        XCTAssertTrue(injected.contains("<table style=\"S\">"))
        XCTAssertFalse(injected.contains("<tablet style"))
    }

    func testBodyContentIsPreserved() {
        let html = render("<p>The quick brown fox</p>")
        XCTAssertTrue(html.contains("The quick brown fox"))
    }
}

final class DestinationToggleTests: XCTestCase {

    private func draft(
        kindle: Bool = true,
        kindleAddress: String = "me@kindle.com",
        email: Bool = true,
        recipients: String = "a@x.com, b@x.com",
        excluded: Set<String> = []
    ) -> SettingsDraft {
        SettingsDraft(
            kindleAddress: kindleAddress,
            fromAddress: "me@gmail.com",
            smtpHost: "smtp.gmail.com",
            smtpPort: 465,
            smtpUsername: "me@gmail.com",
            smtpPassword: "pw",
            sendToKindle: kindle,
            sendToEmail: email,
            emailAddresses: SettingsDraft.parseRecipients(recipients),
            emailRecipientExclusions: excluded
        )
    }

    // MARK: - Master switch (top level, independent of which recipients are checked)

    func testMasterSwitchOffSendsToNobodyRegardlessOfSelection() {
        // Every recipient still individually selected — the top-level switch
        // alone must be what turns delivery off.
        let off = draft(email: false)
        XCTAssertTrue(off.configuration.emailRecipients.isEmpty)
        XCTAssertEqual(off.selectedEmailRecipients, ["a@x.com", "b@x.com"], "selection itself is untouched")
    }

    func testMasterSwitchOnWithNothingCheckedSendsToNobody() {
        // The reverse: switch on, but every individual recipient unchecked.
        let onButEmpty = draft(email: true, excluded: ["a@x.com", "b@x.com"])
        XCTAssertTrue(onButEmpty.configuration.emailRecipients.isEmpty)
    }

    func testMasterSwitchAndSelectionCombineCorrectly() {
        let active = draft(email: true, excluded: ["a@x.com"])
        XCTAssertEqual(active.configuration.emailRecipients, ["b@x.com"])
    }

    func testTogglingTheMasterSwitchNeverTouchesWhichAddressesAreChecked() {
        var mutable = draft(email: true)
        mutable.setRecipient("a@x.com", selected: false)
        mutable.sendToEmail = false
        XCTAssertFalse(mutable.isRecipientSelected("a@x.com"), "turning email off must not reset selection")
        mutable.sendToEmail = true
        XCTAssertFalse(mutable.isRecipientSelected("a@x.com"), "turning email back on must not reselect it either")
    }

    func testAllRecipientsSelectedByDefault() {
        XCTAssertEqual(draft().configuration.emailRecipients, ["a@x.com", "b@x.com"])
        XCTAssertEqual(draft().selectedEmailRecipients, ["a@x.com", "b@x.com"])
    }

    func testDeselectingOneRecipientExcludesOnlyThatOneFromTheSend() {
        let excluded = draft(excluded: ["a@x.com"])
        XCTAssertEqual(excluded.configuration.emailRecipients, ["b@x.com"])
        // The address is still there, just not selected.
        XCTAssertEqual(excluded.emailRecipients, ["a@x.com", "b@x.com"])
    }

    func testDeselectingEveryRecipientTurnsEmailOff() {
        let none = draft(excluded: ["a@x.com", "b@x.com"])
        XCTAssertTrue(none.configuration.emailRecipients.isEmpty)
        // Still keeps the addresses for next time.
        XCTAssertEqual(none.emailRecipients, ["a@x.com", "b@x.com"])
    }

    func testExclusionMatchingIsCaseInsensitive() {
        let excluded = draft(recipients: "A@X.com, b@x.com", excluded: ["a@x.com"])
        XCTAssertEqual(excluded.selectedEmailRecipients, ["b@x.com"])
    }

    func testIsRecipientSelectedAndSetRecipientRoundTrip() {
        var mutable = draft()
        XCTAssertTrue(mutable.isRecipientSelected("a@x.com"))
        mutable.setRecipient("a@x.com", selected: false)
        XCTAssertFalse(mutable.isRecipientSelected("a@x.com"))
        XCTAssertEqual(mutable.selectedEmailRecipients, ["b@x.com"])
        mutable.setRecipient("a@x.com", selected: true)
        XCTAssertTrue(mutable.isRecipientSelected("a@x.com"))
    }

    // MARK: - "Send to" label summary

    func testSummaryNamesEachActiveDestination() {
        XCTAssertEqual(draft(kindle: true, excluded: ["a@x.com", "b@x.com"]).activeDestinationsSummary, "Kindle")
        XCTAssertEqual(draft(kindle: false).activeDestinationsSummary, "Email")
        XCTAssertEqual(draft(kindle: true).activeDestinationsSummary, "Kindle and Email")
    }

    func testSummaryIgnoresRecipientsWhileTheEmailButtonIsOff() {
        // Addresses exist and are all still checked, but Email is switched
        // off — the label must not claim it is sending there.
        let off = draft(kindle: false, email: false)
        XCTAssertFalse(off.selectedEmailRecipients.isEmpty, "recipients are still checked")
        XCTAssertEqual(off.activeDestinationsSummary, "")

        let on = draft(kindle: false, email: true)
        XCTAssertEqual(on.activeDestinationsSummary, "Email")
    }

    func testSummaryIsEmptyWhenNothingIsActive() {
        XCTAssertEqual(draft(kindle: false, excluded: ["a@x.com", "b@x.com"]).activeDestinationsSummary, "")
        XCTAssertTrue(draft(kindle: false, excluded: ["a@x.com", "b@x.com"]).activeDestinationNames.isEmpty)
    }

    func testSummaryReflectsSelectionNotJustConfiguration() {
        // Both destinations are configured, but only Kindle is actually on.
        let kindleOnly = draft(kindle: true, excluded: ["a@x.com", "b@x.com"])
        XCTAssertEqual(kindleOnly.activeDestinationsSummary, "Kindle")

        // Deselecting one of two recipients still counts as Email being active.
        let partialEmail = draft(kindle: false, excluded: ["a@x.com"])
        XCTAssertEqual(partialEmail.activeDestinationsSummary, "Email")
    }

    func testSummaryIgnoresUnselectableEmailWithNoAddresses() {
        XCTAssertEqual(draft(kindle: true, recipients: "").activeDestinationsSummary, "Kindle")
    }

    func testNormalizationDropsExclusionsForRemovedAddresses() {
        // Editing the address list must not leave orphaned exclusions behind.
        let edited = draft(recipients: "b@x.com", excluded: ["a@x.com", "b@x.com"])
        XCTAssertEqual(edited.normalized.emailRecipientExclusions, ["b@x.com"])
    }

    // MARK: - Address book editing (Settings' table, not free text)

    func testAddingAnAddressAppendsItSelected() {
        var mutable = draft(recipients: "a@x.com")
        mutable.addEmailAddresses(from: "b@x.com")
        XCTAssertEqual(mutable.emailAddresses, ["a@x.com", "b@x.com"])
        XCTAssertTrue(mutable.isRecipientSelected("b@x.com"), "newly added addresses start selected")
    }

    func testAddingAcceptsMultipleAddressesAtOnce() {
        // The "Add" field still tolerates a paste of several addresses.
        var mutable = draft(recipients: "")
        mutable.addEmailAddresses(from: "a@x.com, Name <b@x.com>")
        XCTAssertEqual(mutable.emailAddresses, ["a@x.com", "b@x.com"])
    }

    func testAddingADuplicateIsIgnoredCaseInsensitively() {
        var mutable = draft(recipients: "a@x.com")
        mutable.addEmailAddresses(from: "A@X.com")
        XCTAssertEqual(mutable.emailAddresses, ["a@x.com"])
    }

    func testRemovingAnAddressDropsItAndItsSelectionState() {
        var mutable = draft(recipients: "a@x.com, b@x.com")
        mutable.setRecipient("a@x.com", selected: false)
        mutable.removeEmailAddress("a@x.com")

        XCTAssertEqual(mutable.emailAddresses, ["b@x.com"])
        // Re-adding it later should start fresh (selected), not remember the
        // old exclusion.
        mutable.addEmailAddresses(from: "a@x.com")
        XCTAssertTrue(mutable.isRecipientSelected("a@x.com"))
    }

    func testRemovingAnUnknownAddressDoesNothing() {
        var mutable = draft(recipients: "a@x.com")
        mutable.removeEmailAddress("nobody@x.com")
        XCTAssertEqual(mutable.emailAddresses, ["a@x.com"])
    }

    func testBothDestinationsOffIsInvalid() {
        XCTAssertTrue(
            draft(kindle: false, email: false).validationProblems.contains { $0.contains("No destination") }
        )
        // Same net effect, reached by deselecting every recipient instead.
        XCTAssertTrue(
            draft(kindle: false, excluded: ["a@x.com", "b@x.com"]).validationProblems
                .contains { $0.contains("No destination") }
        )
    }

    func testEmailOffLeavesKindleValid() {
        XCTAssertTrue(draft(email: false).validationProblems.isEmpty)
        XCTAssertTrue(draft(excluded: ["a@x.com", "b@x.com"]).validationProblems.isEmpty)
    }

    func testKindleOffLeavesEmailValid() {
        XCTAssertTrue(draft(kindle: false, kindleAddress: "").validationProblems.isEmpty)
    }

    func testAvailabilityReflectsWhatIsConfigured() {
        XCTAssertTrue(draft().canSendToKindle)
        XCTAssertFalse(draft(kindleAddress: "").canSendToKindle)
        XCTAssertFalse(draft(kindleAddress: "nonsense").canSendToKindle)

        XCTAssertTrue(draft().canSendToEmail)
        XCTAssertFalse(draft(recipients: "").canSendToEmail)
        // Configured but switched off, or all deselected: still "can" be
        // turned on, just isn't sending right now.
        XCTAssertTrue(draft(email: false).canSendToEmail)
        XCTAssertTrue(draft(excluded: ["a@x.com", "b@x.com"]).canSendToEmail)
    }

    func testNoConfiguredRecipientsIsNotADestination() {
        let empty = draft(kindle: false, recipients: "")
        XCTAssertTrue(empty.validationProblems.contains { $0.contains("No destination") })
        XCTAssertFalse(empty.configuration.needsBook)
    }
}

final class InlineEmailImageTests: XCTestCase {

    private let image = EmbeddedImage(
        sourceURL: "https://cdn.example.com/photo.jpg",
        fileName: "img0.jpg",
        mediaType: "image/jpeg",
        data: Data(repeating: 0xAB, count: 300),
        wasResized: true
    )

    private func article(html: String) -> ParsedArticle {
        ParsedArticle(
            url: "https://example.com/post/", title: "T", siteName: "Example",
            html: html, publishedDate: nil
        )
    }

    // MARK: - Content IDs

    func testContentIDIsDerivedFromTheFileName() {
        XCTAssertEqual(image.contentID, "img0@littlesend")
    }

    func testHTMLReferencesTheEmbeddedCopy() {
        let rendered = ArticleEmailRenderer.render(
            article: article(html: #"<p><img src="https://cdn.example.com/photo.jpg"></p>"#),
            inlineImages: [image]
        )
        XCTAssertTrue(rendered.html.contains("src=\"cid:img0@littlesend\""))
        XCTAssertFalse(rendered.html.contains("https://cdn.example.com/photo.jpg"))
    }

    func testRelativeSourceIsMatchedAfterAbsolutization() {
        let rendered = ArticleEmailRenderer.render(
            article: article(html: #"<p><img src="photo.jpg"></p>"#),
            inlineImages: [EmbeddedImage(
                sourceURL: "https://example.com/post/photo.jpg",
                fileName: "img0.jpg", mediaType: "image/jpeg", data: Data()
            )]
        )
        XCTAssertTrue(rendered.html.contains("src=\"cid:img0@littlesend\""))
    }

    func testImagesThatFailedToDownloadStayRemote() {
        // Degrade to the old behaviour rather than showing a broken image.
        let rendered = ArticleEmailRenderer.render(
            article: article(html: #"<p><img src="https://other.example.com/x.jpg"></p>"#),
            inlineImages: [image]
        )
        XCTAssertTrue(rendered.html.contains("https://other.example.com/x.jpg"))
    }

    func testWithoutEmbeddingImagesRemainRemote() {
        let rendered = ArticleEmailRenderer.render(
            article: article(html: #"<p><img src="https://cdn.example.com/photo.jpg"></p>"#)
        )
        XCTAssertTrue(rendered.html.contains("https://cdn.example.com/photo.jpg"))
        XCTAssertFalse(rendered.html.contains("cid:"))
    }

    func testEmbeddedImagesKeepTheirResponsiveStyles() {
        let rendered = ArticleEmailRenderer.render(
            article: article(html: #"<p><img src="https://cdn.example.com/photo.jpg"></p>"#),
            inlineImages: [image]
        )
        XCTAssertTrue(rendered.html.contains("max-width:100%;height:auto"))
    }

    // MARK: - MIME structure

    private func message(
        inline: [MailMessage.InlineImage],
        attachment: MailMessage.Attachment? = nil
    ) -> String {
        String(decoding: MailMessage(
            fromAddress: "me@x.com", toAddresses: ["a@x.com"],
            subject: "S", plainTextBody: "text", htmlBody: "<p>html</p>",
            inlineImages: inline, attachment: attachment
        ).serialized(boundary: "B"), as: UTF8.self)
    }

    private var inlineImage: MailMessage.InlineImage {
        MailMessage.InlineImage(
            contentID: "img0@littlesend", fileName: "img0.jpg",
            mediaType: "image/jpeg", data: Data(repeating: 0xAB, count: 300)
        )
    }

    func testInlineImagesProduceMultipartRelated() {
        let text = message(inline: [inlineImage])

        XCTAssertTrue(text.contains("Content-Type: multipart/related"))
        XCTAssertTrue(text.contains("type=\"multipart/alternative\""))
        XCTAssertTrue(text.contains("Content-ID: <img0@littlesend>"))
        XCTAssertTrue(text.contains("Content-Disposition: inline; filename=\"img0.jpg\""))
        XCTAssertTrue(text.hasSuffix("--B-rel--\r\n"))
    }

    func testAlternativeIsNestedInsideRelated() {
        let text = message(inline: [inlineImage])
        let relatedStart = text.range(of: "multipart/related")!
        let alternativeStart = text.range(of: "multipart/alternative; boundary")!
        XCTAssertLessThan(relatedStart.lowerBound, alternativeStart.lowerBound)
    }

    func testAttachmentWrapsTheRelatedBlockInMixed() {
        let attachment = MailMessage.Attachment(
            fileName: "a.epub", mediaType: "application/epub+zip", data: Data(repeating: 1, count: 100)
        )
        let text = message(inline: [inlineImage], attachment: attachment)

        XCTAssertTrue(text.contains("Content-Type: multipart/mixed; boundary=\"B\""))
        XCTAssertTrue(text.contains("Content-Type: multipart/related"))
        XCTAssertTrue(text.hasSuffix("--B--\r\n"))

        // related closes before the attachment part begins
        let relatedClose = text.range(of: "--B-rel--")!
        let attachmentPart = text.range(of: "Content-Disposition: attachment")!
        XCTAssertLessThan(relatedClose.upperBound, attachmentPart.lowerBound)
    }

    func testNoInlineImagesLeavesTheOldStructure() {
        let text = message(inline: [])
        XCTAssertFalse(text.contains("multipart/related"))
        XCTAssertTrue(text.contains("multipart/alternative"))
    }

    func testInlineImageBytesRoundTrip() throws {
        let payload = Data((0..<900).map { UInt8($0 % 251) })
        let text = message(inline: [MailMessage.InlineImage(
            contentID: "c@k", fileName: "i.jpg", mediaType: "image/jpeg", data: payload
        )])

        let part = try XCTUnwrap(text.components(separatedBy: "--B-rel").first { $0.contains("Content-ID") })
        let encoded = try XCTUnwrap(part.components(separatedBy: "\r\n\r\n").last)
            .replacingOccurrences(of: "\r\n", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(Data(base64Encoded: encoded), payload)
    }

    func testEveryLineStaysWithinTheRFCLimit() {
        let text = message(inline: [MailMessage.InlineImage(
            contentID: "c@k", fileName: "i.jpg", mediaType: "image/jpeg",
            data: Data(repeating: 9, count: 6000)
        )])
        for line in text.components(separatedBy: "\r\n") {
            XCTAssertLessThanOrEqual(line.utf8.count, 998)
        }
    }

    func testContentIDCannotInjectHeaders() {
        let text = message(inline: [MailMessage.InlineImage(
            contentID: "x@k>\r\nBcc: attacker@evil.com", fileName: "i.jpg",
            mediaType: "image/jpeg", data: Data()
        )])
        let lines = text.components(separatedBy: "\r\n")
        XCTAssertFalse(lines.contains { $0.hasPrefix("Bcc:") })
    }

    // MARK: - Fetch planning

    func testImagesAreFetchedForEmailEvenWithoutAnEPUB() {
        var config = SendConfiguration(
            sendToKindle: false, kindleAddress: "",
            emailRecipients: ["a@x.com"], fromAddress: "me@x.com",
            smtpHost: "h", smtpPort: 465, smtpUsername: "u", smtpPassword: "p"
        )
        XCTAssertFalse(config.needsBook)
        XCTAssertTrue(config.needsImages, "email embedding still requires downloads")

        config.embedImagesInEmail = false
        XCTAssertFalse(config.needsImages, "nothing needs images now")
    }

    func testEmbedImagesOffSuppressesBothDestinations() {
        var config = SendConfiguration(
            kindleAddress: "k@kindle.com",
            emailRecipients: ["a@x.com"], fromAddress: "me@x.com",
            smtpHost: "h", smtpPort: 465, smtpUsername: "u", smtpPassword: "p"
        )
        config.embedImages = false
        XCTAssertFalse(config.needsImages)
    }
}
