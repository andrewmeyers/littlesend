import XCTest
@testable import LittleSendCore

final class DesktopExporterTests: XCTestCase {

    private var folder: URL!
    private var exporter: DesktopExporter!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("littlesend-desktop-\(UUID().uuidString)")
        exporter = DesktopExporter(folder: folder)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func testWritesTheFile() throws {
        let saved = try exporter.save(Data("book".utf8), fileName: "Article.epub")

        XCTAssertEqual(saved.url.lastPathComponent, "Article.epub")
        XCTAssertFalse(saved.renamedToAvoidCollision)
        XCTAssertEqual(try Data(contentsOf: saved.url), Data("book".utf8))
    }

    func testCreatesTheFolderIfMissing() throws {
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        _ = try exporter.save(Data("x".utf8), fileName: "A.epub")
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))
    }

    // MARK: - Collisions

    func testSecondSendStepsAsideRatherThanOverwriting() throws {
        let first = try exporter.save(Data("first".utf8), fileName: "Article.epub")
        let second = try exporter.save(Data("second".utf8), fileName: "Article.epub")

        XCTAssertEqual(second.url.lastPathComponent, "Article 2.epub")
        XCTAssertTrue(second.renamedToAvoidCollision)
        // The original is untouched — sending twice keeps both copies.
        XCTAssertEqual(try Data(contentsOf: first.url), Data("first".utf8))
        XCTAssertEqual(try Data(contentsOf: second.url), Data("second".utf8))
    }

    func testCollisionsKeepCounting() throws {
        for _ in 0..<3 { _ = try exporter.save(Data("x".utf8), fileName: "Article.epub") }
        let fourth = try exporter.save(Data("x".utf8), fileName: "Article.epub")
        XCTAssertEqual(fourth.url.lastPathComponent, "Article 4.epub")
    }

    func testCollisionNumberingKeepsTheExtension() throws {
        _ = try exporter.save(Data("x".utf8), fileName: "How-to-Do-Great-Work.epub")
        let second = try exporter.save(Data("x".utf8), fileName: "How-to-Do-Great-Work.epub")

        XCTAssertEqual(second.url.pathExtension, "epub")
        XCTAssertEqual(second.url.lastPathComponent, "How-to-Do-Great-Work 2.epub")
    }

    func testHandlesNamesWithoutAnExtension() throws {
        _ = try exporter.save(Data("x".utf8), fileName: "Article")
        let second = try exporter.save(Data("x".utf8), fileName: "Article")
        XCTAssertEqual(second.url.lastPathComponent, "Article 2")
    }

    func testDefaultFolderIsTheDesktop() throws {
        let desktop = try DesktopExporter.defaultFolder()
        XCTAssertEqual(desktop.lastPathComponent, "Desktop")
    }
}

final class DesktopDestinationTests: XCTestCase {

    private func configuration(
        kindle: Bool = false,
        desktop: Bool = false,
        recipients: [String] = [],
        smtpPassword: String = "pw"
    ) -> SendConfiguration {
        SendConfiguration(
            instaparserAPIKey: "key",
            sendToKindle: kindle,
            kindleAddress: kindle ? "me@kindle.com" : "",
            saveToDesktop: desktop,
            emailRecipients: recipients,
            fromAddress: "me@gmail.com",
            smtpHost: "smtp.gmail.com",
            smtpPort: 465,
            smtpUsername: "me@gmail.com",
            smtpPassword: smtpPassword
        )
    }

    func testDesktopCountsAsADestination() {
        XCTAssertTrue(configuration(desktop: true).validationProblems.isEmpty)
        XCTAssertTrue(
            configuration().validationProblems.contains { $0.contains("No destination") },
            "nothing selected at all should still be rejected"
        )
    }

    func testDesktopNeedsTheEPUBBuilt() {
        XCTAssertTrue(configuration(desktop: true).needsBook)
        XCTAssertFalse(configuration(recipients: ["a@x.com"]).needsBook, "email alone needs no EPUB")
    }

    func testDesktopOnlySendNeedsNoMailCredentials() {
        // Nothing is mailed, so SMTP is irrelevant — this must not block.
        let config = configuration(desktop: true, smtpPassword: "")
        XCTAssertTrue(config.validationProblems.isEmpty, "\(config.validationProblems)")
    }

    func testMailDestinationsStillRequireCredentials() {
        XCTAssertTrue(
            configuration(kindle: true, smtpPassword: "").validationProblems
                .contains { $0.contains("SMTP password") }
        )
        XCTAssertTrue(
            configuration(recipients: ["a@x.com"], smtpPassword: "").validationProblems
                .contains { $0.contains("SMTP password") }
        )
    }

    func testDesktopAppearsInTheSendToSummary() {
        var draft = SettingsDraft(
            instaparserAPIKey: "key",
            sendToKindle: false,
            sendToEmail: false,
            saveToDesktop: true
        )
        XCTAssertEqual(draft.activeDestinationsSummary, "Desktop")

        draft.sendToKindle = true
        XCTAssertEqual(draft.activeDestinationsSummary, "Kindle and Desktop")
    }

    func testDesktopAloneIsCompleteWithoutAnyAddresses() {
        let draft = SettingsDraft(instaparserAPIKey: "key", saveToDesktop: true)
        XCTAssertEqual(draft.settingsProblems, [], "Desktop needs no addresses or SMTP")
    }
}
