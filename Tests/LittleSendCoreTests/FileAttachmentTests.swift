import XCTest
@testable import LittleSendCore

final class FileAttachmentTests: XCTestCase {

    private var folder: URL!

    override func setUpWithError() throws {
        folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("littlesend-files-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func write(_ name: String, bytes: Int = 64) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Data(repeating: 0xAB, count: bytes).write(to: url)
        return url
    }

    // MARK: - Reading

    func testReadsAFileAndDerivesItsMediaType() throws {
        let attachment = try FileAttachment(contentsOf: write("Report.pdf", bytes: 500))
        XCTAssertEqual(attachment.fileName, "Report.pdf")
        XCTAssertEqual(attachment.mediaType, "application/pdf")
        XCTAssertEqual(attachment.byteCount, 500)
        XCTAssertEqual(attachment.displayTitle, "Report")
        XCTAssertTrue(attachment.isAcceptedByKindle)
    }

    func testEmptyFileIsRejected() throws {
        let url = try write("Empty.pdf", bytes: 0)
        XCTAssertThrowsError(try FileAttachment(contentsOf: url)) { error in
            guard case FileAttachment.Failure.empty = error else {
                return XCTFail("wrong error: \(error)")
            }
        }
    }

    func testMissingFileIsRejectedWithAReadableMessage() {
        let url = folder.appendingPathComponent("nope.pdf")
        XCTAssertThrowsError(try FileAttachment(contentsOf: url)) { error in
            guard case FileAttachment.Failure.unreadable = error else {
                return XCTFail("wrong error: \(error)")
            }
            XCTAssertTrue(
                (error as? LocalizedError)?.errorDescription?.hasPrefix("Couldn't read") == true
            )
        }
    }

    func testOversizeFileIsCaughtBeforeSendingRatherThanBySMTP() throws {
        // Gmail caps a message at 25 MB and base64 inflates by about a third,
        // so a file over the limit would fail mid-upload with an SMTP code.
        let url = folder.appendingPathComponent("Huge.pdf")
        try Data(count: FileAttachment.sizeLimitBytes + 1).write(to: url)

        XCTAssertThrowsError(try FileAttachment(contentsOf: url)) { error in
            guard case FileAttachment.Failure.tooLarge = error else {
                return XCTFail("wrong error: \(error)")
            }
        }
    }

    func testFileNameIsSanitizedForTheMailHeader() throws {
        let attachment = try FileAttachment(contentsOf: write("we\"ird name.pdf"))
        XCTAssertFalse(attachment.fileName.contains("\""))
    }

    // MARK: - What Kindle takes

    func testKindleFormatsAreAcceptedAndOthersAreNot() throws {
        for ext in ["epub", "pdf", "docx", "txt", "rtf", "html", "jpg", "png"] {
            let attachment = try FileAttachment(contentsOf: write("f.\(ext)"))
            XCTAssertTrue(attachment.isAcceptedByKindle, ext)
        }
        for ext in ["zip", "mp3", "key", "dmg", "mobi"] {
            let attachment = try FileAttachment(contentsOf: write("f.\(ext)"))
            XCTAssertFalse(attachment.isAcceptedByKindle, ext)
        }
    }

    func testExtensionMatchingIsCaseInsensitive() throws {
        let attachment = try FileAttachment(contentsOf: write("SCAN.PDF"))
        XCTAssertTrue(attachment.isAcceptedByKindle)
        XCTAssertEqual(attachment.mediaType, "application/pdf")
    }

    func testUnknownExtensionFallsBackToOctetStream() {
        XCTAssertEqual(FileAttachment.mediaType(forExtension: "xyz"), "application/octet-stream")
        XCTAssertEqual(FileAttachment.mediaType(forExtension: "JPEG"), "image/jpeg")
    }

    func testDisplayTitleSurvivesAFileWithNoExtension() throws {
        let attachment = try FileAttachment(contentsOf: write("Notes"))
        XCTAssertEqual(attachment.displayTitle, "Notes")
        XCTAssertFalse(attachment.isAcceptedByKindle)
    }

    // MARK: - Destination rules

    func testSendingAFileRequiresKindleToBeOn() async throws {
        var draft = SettingsDraft(kindleAddress: "k@kindle.com", fromAddress: "me@x.com",
                                  smtpHost: "smtp.x.com", smtpUsername: "me@x.com",
                                  smtpPassword: "pw")
        draft.sendToKindle = false
        draft.saveToDesktop = true
        draft.emailAddresses = ["someone@x.com"]
        draft.sendToEmail = true

        let sender = ArticleSender(configuration: draft.configuration)
        let url = try write("Doc.pdf")

        // Email and Desktop being on must not make a file send "work" — files
        // go to Kindle only.
        do {
            _ = try await sender.send(file: url)
            XCTFail("expected a refusal")
        } catch let error as FileAttachment.Failure {
            guard case .kindleNotSelected = error else {
                return XCTFail("wrong error: \(error)")
            }
        }
    }

    func testUnsupportedFileIsRefusedBeforeAnySMTPConnection() async throws {
        var draft = SettingsDraft(kindleAddress: "k@kindle.com", fromAddress: "me@x.com",
                                  smtpHost: "smtp.invalid", smtpUsername: "me@x.com",
                                  smtpPassword: "pw")
        draft.sendToKindle = true

        let sender = ArticleSender(configuration: draft.configuration)
        let url = try write("Archive.zip")

        // smtpHost is unroutable: reaching the network at all would hang or
        // fail differently, so this also proves the check comes first.
        do {
            _ = try await sender.send(file: url)
            XCTFail("expected a refusal")
        } catch let error as FileAttachment.Failure {
            guard case .unsupportedByKindle(let ext) = error else {
                return XCTFail("wrong error: \(error)")
            }
            XCTAssertEqual(ext, "zip")
        }
    }
}
