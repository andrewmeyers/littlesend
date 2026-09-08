import XCTest
@testable import LittleSendCore

final class SendArchiveTests: XCTestCase {

    private var root: URL!
    private var archive: SendArchive!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("littlesend-archive-\(UUID().uuidString)")
        archive = SendArchive(root: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func save(_ title: String, at date: Date, epub: Data? = Data("book".utf8)) throws -> URL {
        try archive.save(
            title: title,
            sourceURL: "https://example.com/\(title)",
            date: date,
            epub: epub.map { (fileName: "\(title).epub", data: $0) },
            cover: Data("cover".utf8),
            emailHTML: "<p>\(title)</p>",
            summary: "Kindle: delivered"
        ).folder
    }

    private func date(_ minute: Int) -> Date {
        Date(timeIntervalSince1970: 1_700_000_000 + TimeInterval(minute * 60))
    }

    // MARK: - Saving

    func testWritesEveryArtifact() throws {
        let folder = try save("Article", at: date(0))
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()

        XCTAssertEqual(names, ["Article.epub", "about.txt", "cover.jpg", "email.html"])
        XCTAssertEqual(
            try Data(contentsOf: folder.appendingPathComponent("Article.epub")),
            Data("book".utf8)
        )
    }

    func testNoteRecordsTitleSourceAndOutcome() throws {
        let folder = try save("Article", at: date(0))
        let note = try String(contentsOf: folder.appendingPathComponent("about.txt"), encoding: .utf8)

        XCTAssertTrue(note.contains("Article"))
        XCTAssertTrue(note.contains("https://example.com/Article"))
        XCTAssertTrue(note.contains("Kindle: delivered"))
    }

    func testEmailOnlySendStillProducesAFolder() throws {
        let folder = try archive.save(
            title: "No Book", sourceURL: "https://example.com/x", date: date(0),
            epub: nil, cover: nil, emailHTML: "<p>hi</p>"
        ).folder
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        XCTAssertEqual(names, ["about.txt", "email.html"])
    }

    // MARK: - Retention

    func testKeepsOnlyTheFiveMostRecent() throws {
        for index in 0..<8 {
            _ = try save("Article\(index)", at: date(index))
        }
        let folders = try archive.folders()

        XCTAssertEqual(folders.count, SendArchive.keepCount)
        // Newest first, so the survivors are 7 down to 3.
        XCTAssertTrue(folders[0].lastPathComponent.hasSuffix("Article7"))
        XCTAssertTrue(folders[4].lastPathComponent.hasSuffix("Article3"))
    }

    func testOlderFoldersAreActuallyDeletedFromDisk() throws {
        let oldest = try save("Oldest", at: date(0))
        for index in 1...5 { _ = try save("Article\(index)", at: date(index)) }

        XCTAssertFalse(FileManager.default.fileExists(atPath: oldest.path))
    }

    func testFewerThanTheLimitAreAllKept() throws {
        for index in 0..<3 { _ = try save("Article\(index)", at: date(index)) }
        XCTAssertEqual(try archive.folders().count, 3)
    }

    func testPruneIsIdempotent() throws {
        for index in 0..<7 { _ = try save("Article\(index)", at: date(index)) }
        try archive.prune()
        try archive.prune()
        XCTAssertEqual(try archive.folders().count, SendArchive.keepCount)
    }

    func testFoldersOnAMissingRootIsEmptyRatherThanThrowing() throws {
        let missing = SendArchive(root: root.appendingPathComponent("never-created"))
        XCTAssertEqual(try missing.folders(), [])
    }

    // MARK: - Naming

    func testFolderNameIsSortableAndReadable() {
        let name = archive.folderName(title: "How to Do Great Work", date: date(0))
        XCTAssertTrue(name.hasPrefix("2023-11-14"), name)
        XCTAssertTrue(name.hasSuffix("How-to-Do-Great-Work"), name)
    }

    func testNamesSortChronologically() {
        let earlier = archive.folderName(title: "A", date: date(0))
        let later = archive.folderName(title: "A", date: date(5))
        XCTAssertLessThan(earlier, later, "name order must match time order")
    }

    func testUnsafeTitleCharactersAreRemoved() {
        let name = archive.folderName(title: "A/B: \"C\" <D>", date: date(0))
        XCTAssertFalse(name.contains("/"))
        XCTAssertFalse(name.contains(":"))
        XCTAssertFalse(name.contains("\""))
    }

    func testEmptyTitleStillProducesAName() {
        XCTAssertFalse(archive.folderName(title: "", date: date(0)).isEmpty)
        XCTAssertFalse(archive.folderName(title: "***", date: date(0)).isEmpty)
    }

    func testVeryLongTitleIsTruncated() {
        let name = archive.folderName(title: String(repeating: "word ", count: 60), date: date(0))
        XCTAssertLessThanOrEqual(name.count, 80)
    }

    func testDefaultRootIsUnderApplicationSupport() throws {
        let root = try SendArchive.defaultRoot()
        XCTAssertTrue(root.path.contains("Application Support"))
        XCTAssertTrue(root.path.hasSuffix("LittleSend/Recent Sends"))
    }
}
