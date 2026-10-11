import XCTest
@testable import LittleSendCore

final class SettingsSearchTests: XCTestCase {
    private func panes(matching query: String) -> Set<SettingsPane> {
        Set(SettingsPane.allCases.filter { $0.matches(query) })
    }

    func testEmptyQueryShowsEveryPane() {
        XCTAssertEqual(panes(matching: ""), Set(SettingsPane.allCases))
        XCTAssertEqual(panes(matching: "   "), Set(SettingsPane.allCases))
    }

    /// The point of indexing everything: any text a pane shows finds it.
    func testEveryPieceOfTextFindsItsPane() {
        for pane in SettingsPane.allCases {
            for text in pane.searchableText + [pane.title] {
                XCTAssertTrue(pane.matches(text), "\(pane) not found by “\(text)”")
            }
        }
    }

    func testRowDescriptionsAreSearchable() {
        XCTAssertEqual(panes(matching: "gmail"), [.account])
        XCTAssertEqual(panes(matching: "port 465"), [.account])
        XCTAssertTrue(panes(matching: "dock").contains(.general))
        XCTAssertTrue(panes(matching: "paywall").contains(.reading))
    }

    func testMenuChoicesAreSearchable() {
        XCTAssertEqual(panes(matching: "banded"), [.cover], "a cover layout name")
        XCTAssertTrue(panes(matching: "scribe").contains(.cover), "a cover size description")
        XCTAssertTrue(panes(matching: "chrome").contains(.general), "a browser in Fill the link from")
        XCTAssertTrue(panes(matching: "instaparser").contains(.reading))
    }

    func testRunningSetupAgainIsSearchable() {
        XCTAssertEqual(panes(matching: "run setup again"), [.general])
        XCTAssertTrue(panes(matching: "first run").contains(.general))
        XCTAssertTrue(panes(matching: "onboarding").contains(.general))
    }

    func testSynonymsFindPanesTheirTextDoesNotName() {
        XCTAssertEqual(panes(matching: "smtp"), [.account])
        XCTAssertTrue(panes(matching: "grey").contains(.cover))
    }

    func testEveryWordMustMatch() {
        XCTAssertTrue(panes(matching: "kindle address").contains(.destinations))
        XCTAssertFalse(panes(matching: "kindle address").contains(.images))
        XCTAssertTrue(panes(matching: "xyzzy").isEmpty)
        XCTAssertTrue(panes(matching: "gmail banded").isEmpty, "words from two different panes")
    }

    func testCaseAndAccentsAreIgnored() {
        XCTAssertTrue(panes(matching: "GMAIL").contains(.account))
        XCTAssertTrue(panes(matching: "clipböard").contains(.general))
    }

    /// Stored by raw value to reopen Settings on the last pane.
    func testRawValuesAreStable() {
        XCTAssertEqual(SettingsPane.allCases.map(\.rawValue),
                       ["general", "destinations", "account", "reading", "cover", "images"])
    }
}
