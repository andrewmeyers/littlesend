import XCTest
@testable import LittleSendCore

final class SettingsMigrationTests: XCTestCase {
    private let oldDomain = "littlesend.tests.migration.old"
    private let newDomain = "littlesend.tests.migration.new"
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removePersistentDomain(forName: oldDomain)
        UserDefaults.standard.removePersistentDomain(forName: newDomain)
        defaults = UserDefaults(suiteName: newDomain)
    }

    override func tearDown() {
        UserDefaults.standard.removePersistentDomain(forName: oldDomain)
        UserDefaults.standard.removePersistentDomain(forName: newDomain)
        super.tearDown()
    }

    private func seedOld(_ values: [String: Any]) {
        UserDefaults.standard.setPersistentDomain(values, forName: oldDomain)
    }

    func testCopiesEverySettingAcross() {
        seedOld(["kindleAddress": "me@kindle.com", "smtpPort": 465, "sendToEmail": false])
        SettingsMigration.run(into: defaults, from: oldDomain)

        XCTAssertEqual(defaults.string(forKey: "kindleAddress"), "me@kindle.com")
        XCTAssertEqual(defaults.integer(forKey: "smtpPort"), 465)
        XCTAssertEqual(defaults.object(forKey: "sendToEmail") as? Bool, false)
    }

    func testValuesAlreadySetUnderTheNewIDWin() {
        seedOld(["kindleAddress": "old@kindle.com"])
        defaults.set("new@kindle.com", forKey: "kindleAddress")
        SettingsMigration.run(into: defaults, from: oldDomain)

        XCTAssertEqual(defaults.string(forKey: "kindleAddress"), "new@kindle.com")
    }

    /// A value cleared after the move must not come back on the next launch.
    func testRunsOnlyOnce() {
        seedOld(["kindleAddress": "me@kindle.com"])
        SettingsMigration.run(into: defaults, from: oldDomain)
        defaults.removeObject(forKey: "kindleAddress")
        SettingsMigration.run(into: defaults, from: oldDomain)

        XCTAssertNil(defaults.string(forKey: "kindleAddress"))
    }

    func testLeavesTheOldSettingsInPlace() {
        seedOld(["kindleAddress": "me@kindle.com"])
        SettingsMigration.run(into: defaults, from: oldDomain)

        XCTAssertEqual(
            UserDefaults.standard.persistentDomain(forName: oldDomain)?["kindleAddress"] as? String,
            "me@kindle.com"
        )
    }

    func testNothingToMoveIsFine() {
        SettingsMigration.run(into: defaults, from: oldDomain)
        XCTAssertNil(defaults.string(forKey: "kindleAddress"))
        XCTAssertEqual(defaults.string(forKey: SettingsMigration.doneKey), oldDomain)
    }
}
