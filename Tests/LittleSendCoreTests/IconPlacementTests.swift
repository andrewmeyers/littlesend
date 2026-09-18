import XCTest
@testable import LittleSendCore

final class IconPlacementTests: XCTestCase {
    func testEveryPlacementKeepsAWayBackIntoTheApp() {
        for placement in IconPlacement.allCases {
            XCTAssertTrue(
                placement.showsDockIcon || placement.showsMenuBarIcon,
                "\(placement) shows no icon at all"
            )
        }
    }

    func testEachPlacementShowsWhatItsNameSays() {
        XCTAssertTrue(IconPlacement.both.showsDockIcon)
        XCTAssertTrue(IconPlacement.both.showsMenuBarIcon)

        XCTAssertTrue(IconPlacement.dock.showsDockIcon)
        XCTAssertFalse(IconPlacement.dock.showsMenuBarIcon)

        XCTAssertFalse(IconPlacement.menuBar.showsDockIcon)
        XCTAssertTrue(IconPlacement.menuBar.showsMenuBarIcon)
    }

    /// Stored in UserDefaults by raw value, so renaming a case would silently
    /// reset everyone's choice.
    func testRawValuesAreStable() {
        XCTAssertEqual(IconPlacement.both.rawValue, "both")
        XCTAssertEqual(IconPlacement.dock.rawValue, "dock")
        XCTAssertEqual(IconPlacement.menuBar.rawValue, "menuBar")
        XCTAssertNil(IconPlacement(rawValue: "neither"))
    }

    func testDraftDefaultsToBoth() {
        XCTAssertEqual(SettingsDraft().iconPlacement, .both)
    }
}
