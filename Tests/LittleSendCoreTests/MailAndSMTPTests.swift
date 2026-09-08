import XCTest
@testable import LittleSendCore

final class MailMessageTests: XCTestCase {

    private func message(subject: String = "Hello", fileName: String = "article.epub") -> MailMessage {
        MailMessage(
            fromAddress: "me@example.com",
            fromName: "LittleSend",
            toAddresses: ["me@kindle.com"],
            subject: subject,
            plainTextBody: "body",
            attachment: MailMessage.Attachment(
                fileName: fileName,
                mediaType: "application/epub+zip",
                data: Data(repeating: 0xAB, count: 500)
            )
        )
    }

    func testStructureIsMultipartWithAttachment() {
        let text = String(decoding: message().serialized(boundary: "BOUND"), as: UTF8.self)

        XCTAssertTrue(text.contains("Content-Type: multipart/mixed; boundary=\"BOUND\""))
        XCTAssertTrue(text.contains("--BOUND\r\n"))
        XCTAssertTrue(text.hasSuffix("--BOUND--\r\n"))
        XCTAssertTrue(text.contains("Content-Disposition: attachment; filename=\"article.epub\""))
        XCTAssertTrue(text.contains("Content-Type: application/epub+zip"))
    }

    func testEveryLineIsWithinTheRFCLimit() {
        let text = String(decoding: message().serialized(), as: UTF8.self)
        for line in text.components(separatedBy: "\r\n") {
            XCTAssertLessThanOrEqual(line.utf8.count, 998, "line too long: \(line.prefix(40))…")
        }
    }

    func testHeadersUseCRLF() {
        let text = String(decoding: message().serialized(), as: UTF8.self)
        XCTAssertFalse(text.replacingOccurrences(of: "\r\n", with: "").contains("\n"), "found a bare LF")
    }

    func testNonASCIISubjectIsEncoded() {
        let text = String(decoding: message(subject: "Café — naïve").serialized(), as: UTF8.self)
        XCTAssertTrue(text.contains("Subject: =?UTF-8?B?"))
        XCTAssertFalse(text.contains("Subject: Café"))
    }

    func testASCIISubjectIsLeftAlone() {
        let text = String(decoding: message(subject: "Plain subject").serialized(), as: UTF8.self)
        XCTAssertTrue(text.contains("Subject: Plain subject"))
    }

    func testHeaderInjectionIsNeutralized() {
        let text = String(decoding: message(subject: "Evil\r\nBcc: attacker@example.com").serialized(), as: UTF8.self)
        // The payload may appear inside the folded Subject value; what must not
        // happen is a new header line starting with it.
        let headerLines = text.components(separatedBy: "\r\n\r\n")[0].components(separatedBy: "\r\n")
        XCTAssertFalse(headerLines.contains { $0.hasPrefix("Bcc:") })
        XCTAssertTrue(headerLines.contains { $0.hasPrefix("Subject: Evil") })
    }

    func testAddressHeadersCannotCarryLineBreaks() {
        let mail = MailMessage(
            fromAddress: "me@example.com\r\nBcc: x@y.com", toAddresses: ["k@kindle.com"],
            subject: "s", plainTextBody: "b",
            attachment: MailMessage.Attachment(
                fileName: "a.epub", mediaType: "application/epub+zip", data: Data()
            )
        )
        let headerLines = String(decoding: mail.serialized(), as: UTF8.self)
            .components(separatedBy: "\r\n\r\n")[0].components(separatedBy: "\r\n")
        XCTAssertFalse(headerLines.contains { $0.hasPrefix("Bcc:") })
    }

    func testAttachmentFileNameIsSanitized() {
        XCTAssertEqual(MailMessage.sanitizeFileName("Café — Süß.epub"), "Caf----S--.epub")
        XCTAssertEqual(MailMessage.sanitizeFileName("a\"b.epub"), "a-b.epub")
        XCTAssertEqual(MailMessage.sanitizeFileName("---"), "article.epub")
    }

    func testAttachmentRoundTripsThroughBase64() throws {
        let payload = Data((0..<2048).map { UInt8($0 % 251) })
        let mail = MailMessage(
            fromAddress: "me@example.com", toAddresses: ["me@kindle.com"],
            subject: "s", plainTextBody: "b",
            attachment: MailMessage.Attachment(
                fileName: "a.epub", mediaType: "application/epub+zip", data: payload
            )
        )
        let text = String(decoding: mail.serialized(boundary: "B"), as: UTF8.self)

        let part = try XCTUnwrap(text.components(separatedBy: "--B").first { $0.contains("a.epub") })
        let encoded = try XCTUnwrap(part.components(separatedBy: "\r\n\r\n").last)
            .replacingOccurrences(of: "\r\n", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        XCTAssertEqual(Data(base64Encoded: encoded), payload)
    }

    func testMessageIDUsesTheSenderDomain() {
        let text = String(decoding: message().serialized(boundary: "B"), as: UTF8.self)
        let line = text.components(separatedBy: "\r\n").first { $0.hasPrefix("Message-ID:") }

        XCTAssertNotNil(line)
        XCTAssertTrue(line?.hasSuffix("@example.com>") == true, "got \(line ?? "none")")
        // The old fixed value was unresolvable by construction: ".local" is
        // reserved for multicast DNS, which some filters treat as a spam signal.
        XCTAssertFalse(text.contains("littlesend.local"))
    }

    func testMessageIDDomainFallsBackWhenThereIsNoUsableDomain() {
        XCTAssertEqual(MailMessage.messageIDDomain(for: "gmail.com"), "littlesend.invalid")
        XCTAssertEqual(MailMessage.messageIDDomain(for: "me@"), "littlesend.invalid")
        // Sub-domains and hyphens are legitimate and must survive intact.
        XCTAssertEqual(MailMessage.messageIDDomain(for: "me@mail.some-corp.co.uk"), "mail.some-corp.co.uk")
    }

    func testMessageIDCannotCarryHeaderSyntax() {
        // A domain is dropped into the header verbatim, so anything that could
        // close the angle brackets or start a new header has to be stripped.
        // The domain is taken after the *last* "@", which is the correct parse
        // for a real address; what matters here is only that whatever survives
        // cannot close the brackets or open a new header.
        XCTAssertEqual(MailMessage.messageIDDomain(for: "me@evil.com>\r\nBcc: x@y.com"), "y.com")

        let mail = MailMessage(
            fromAddress: "me@evil.com>\r\nBcc: attacker@example.com",
            toAddresses: ["me@kindle.com"], subject: "s", plainTextBody: "b"
        )
        let text = String(decoding: mail.serialized(boundary: "B"), as: UTF8.self)
        let headers = text.components(separatedBy: "\r\n\r\n")[0]
        XCTAssertFalse(headers.components(separatedBy: "\r\n").contains { $0.hasPrefix("Bcc:") })
    }
}

final class SMTPProtocolTests: XCTestCase {

    func testSingleLineReplyIsParsed() {
        var buffer = Data("220 smtp.example.com ESMTP\r\n".utf8)
        let reply = SMTPClient.parseReply(from: &buffer)

        XCTAssertEqual(reply?.code, 220)
        XCTAssertEqual(reply?.text, "smtp.example.com ESMTP")
        XCTAssertTrue(buffer.isEmpty)
    }

    func testMultilineReplyIsAccumulated() {
        var buffer = Data("250-smtp.example.com\r\n250-PIPELINING\r\n250 AUTH LOGIN PLAIN\r\n".utf8)
        let reply = SMTPClient.parseReply(from: &buffer)

        XCTAssertEqual(reply?.code, 250)
        XCTAssertEqual(reply?.lines.count, 3)
        XCTAssertTrue(reply?.text.contains("AUTH LOGIN PLAIN") == true)
        XCTAssertTrue(buffer.isEmpty)
    }

    func testPartialReplyReturnsNothingAndKeepsBuffer() {
        var buffer = Data("250-smtp.example.com\r\n250-PIPE".utf8)
        XCTAssertNil(SMTPClient.parseReply(from: &buffer))
        XCTAssertFalse(buffer.isEmpty)
    }

    func testTrailingBytesAfterReplyAreRetained() {
        var buffer = Data("220 ready\r\n250 later\r\n".utf8)
        XCTAssertEqual(SMTPClient.parseReply(from: &buffer)?.code, 220)
        XCTAssertEqual(SMTPClient.parseReply(from: &buffer)?.code, 250)
        XCTAssertTrue(buffer.isEmpty)
    }

    func testDotStuffing() {
        let input = Data("line one\r\n.hidden\r\n..double\r\nnormal\r\n".utf8)
        let output = String(decoding: SMTPClient.dotStuffed(input), as: UTF8.self)

        XCTAssertEqual(output, "line one\r\n..hidden\r\n...double\r\nnormal\r\n")
    }

    func testDotStuffingLeavesMidLineDotsAlone() {
        let input = Data("a.b.c\r\n".utf8)
        XCTAssertEqual(String(decoding: SMTPClient.dotStuffed(input), as: UTF8.self), "a.b.c\r\n")
    }
}
