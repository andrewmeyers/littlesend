import XCTest
@testable import LittleSendCore

final class ReadingTimeTests: XCTestCase {

    func testCountsWordsAndIgnoresTags() {
        let html = "<h1>Title here</h1><p>One <em>two</em> three.</p>"
        XCTAssertEqual(ReadingTime.wordCount(ofHTML: html), 5)
    }

    func testScriptsAndStylesAreNotCountedEvenAcrossLines() {
        let html = """
        <p>Only these four words.</p>
        <script>
          var lots = "of words that are code and must not count";
        </script>
        <style>
          p { margin: 0 lots of words here }
        </style>
        """
        XCTAssertEqual(ReadingTime.wordCount(ofHTML: html), 4)
    }

    func testEntitiesDoNotGlueWordsTogether() {
        XCTAssertEqual(ReadingTime.wordCount(ofHTML: "<p>one&nbsp;two&mdash;three</p>"), 3)
    }

    func testTextWithoutSpacesIsStillCountedAsManyWords() {
        // Splitting on whitespace would call this one word. Japanese has no
        // spaces between words, which is why the tokenizer is used at all.
        let japanese = "今日は良い天気なので公園へ散歩に行きました"
        XCTAssertEqual(japanese.split(separator: " ").count, 1)
        XCTAssertGreaterThan(ReadingTime.wordCount(ofText: japanese), 5)
    }

    func testMinutesRoundAndNeverReachZero() {
        XCTAssertEqual(ReadingTime.minutes(forWords: 0), 1)
        XCTAssertEqual(ReadingTime.minutes(forWords: 50), 1)
        XCTAssertEqual(ReadingTime.minutes(forWords: 238), 1)
        XCTAssertEqual(ReadingTime.minutes(forWords: 2380), 10)
        XCTAssertEqual(ReadingTime.minutes(forWords: 2500), 11)
    }
}

final class SendCopyTests: XCTestCase {

    func testSuccessNamesWhatWasSentAndWhereItWent() {
        for destination in ["your Kindle", "someone@example.com", "your Kindle and 2 recipients"] {
            let line = SendCopy.success(title: "The Quiet Part", destination: destination, minutes: 7)
            XCTAssertTrue(line.contains("The Quiet Part"), line)
            XCTAssertTrue(line.contains(destination), line)
        }
    }

    func testSuccessReadsPlainly() {
        XCTAssertEqual(
            SendCopy.success(title: "T", destination: "your Kindle", minutes: 4),
            "Sent “T” to your Kindle. A 4-minute read."
        )
    }

    func testAFileHasNoReadingTime() {
        // A file is sent as-is and never opened, so there is nothing to time.
        let line = SendCopy.success(title: "Report", destination: "your Kindle", minutes: nil)
        XCTAssertEqual(line, "Sent “Report” to your Kindle.")
        XCTAssertFalse(line.contains("minute"))
    }
}

final class BrowserSourceTests: XCTestCase {

    func testRawValuesAreStableForPersistence() {
        XCTAssertEqual(BrowserSource.off.rawValue, "off")
        XCTAssertEqual(BrowserSource.automatic.rawValue, "automatic")
        XCTAssertEqual(BrowserSource.chrome.rawValue, "chrome")
        XCTAssertNil(BrowserSource(rawValue: "netscape"))
    }

    func testOffAsksNothingAndAutomaticAsksSeveral() {
        XCTAssertTrue(BrowserSource.off.candidates.isEmpty)
        XCTAssertNil(BrowserSource.off.script)
        XCTAssertNil(BrowserSource.automatic.script)
        XCTAssertGreaterThan(BrowserSource.automatic.candidates.count, 1)
        // Automatic must only ever expand to real browsers, never to itself or
        // off — that would recurse or ask nothing.
        XCTAssertFalse(BrowserSource.automatic.candidates.contains(.automatic))
        XCTAssertFalse(BrowserSource.automatic.candidates.contains(.off))
    }

    func testAChosenBrowserAsksOnlyItself() {
        XCTAssertEqual(BrowserSource.safari.candidates, [.safari])
        XCTAssertEqual(BrowserSource.chrome.candidates, [.chrome])
    }

    func testEveryRealBrowserIsFullyDescribed() {
        for source in BrowserSource.allCases where source != .off && source != .automatic {
            XCTAssertNotNil(source.bundleIdentifier, source.rawValue)
            XCTAssertNotNil(source.scriptingName, source.rawValue)
            let script = source.script
            XCTAssertNotNil(script, source.rawValue)
            // `tell application "X"` has to name the app AppleScript knows,
            // which is not always the bundle's name.
            XCTAssertTrue(
                script?.contains("\"\(source.scriptingName!)\"") == true,
                "\(source.rawValue): \(script ?? "nil")"
            )
            XCTAssertFalse(source.displayName.isEmpty)
        }
    }

    func testSafariAndChromiumUseTheirOwnPhrasing() {
        // Verified by compiling both against the real dictionaries.
        XCTAssertTrue(BrowserSource.safari.script?.contains("front document") == true)
        for chromium in [BrowserSource.chrome, .brave, .edge, .vivaldi] {
            XCTAssertTrue(
                chromium.script?.contains("active tab of front window") == true,
                chromium.rawValue
            )
        }
    }

    func testEveryCaseIsOfferedInThePicker() {
        // allCases drives the Settings picker, so a case missing a name would
        // show as an empty row.
        for source in BrowserSource.allCases {
            XCTAssertFalse(source.displayName.isEmpty, source.rawValue)
        }
    }
}
