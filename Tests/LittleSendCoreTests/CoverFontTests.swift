import XCTest
import CoreText
@testable import LittleSendCore

final class CoverFontTests: XCTestCase {

    private func article() -> ParsedArticle {
        ParsedArticle(
            url: "https://example.com/a", title: "A Title", siteName: "Example",
            author: "Someone", description: nil, html: "<p>x</p>", publishedDate: nil
        )
    }

    // MARK: - Resolution

    func testEmptyPreferenceIsTheSystemFontAndNeverFallsBack() {
        // San Francisco ships with macOS, so the default has no failure case.
        let resolved = CoverFont.resolveFace(preferredFamily: "")
        XCTAssertEqual(resolved.face, .systemUI)
        XCTAssertFalse(resolved.usedFallback)
    }

    func testSystemFaceResolvesToTheRealSystemFontNotASubstitute() {
        // Asking CoreText for ".SFNS-Bold" by name returns Times New Roman —
        // it logs a warning saying to use the UI-font API. This asserts we are
        // going through that API and actually getting San Francisco.
        let font = CoverFont.Face.systemUI.ctFont(size: 24)
        let name = CTFontCopyPostScriptName(font) as String
        XCTAssertTrue(name.contains("SFNS") || name.contains("AppleSystemUIFont"), name)
        XCTAssertFalse(name.contains("Times"), "fell back to a substitute: \(name)")
        XCTAssertTrue(CTFontGetSymbolicTraits(font).contains(CTFontSymbolicTraits.traitBold))
    }

    func testSystemFaceIsSuppliedByTheOperatingSystem() throws {
        // "SF Pro" in the font list is Apple's separate developer download in
        // /Library/Fonts and is absent on a stock Mac. The default must come
        // from the OS itself.
        let font = CoverFont.Face.systemUI.ctFont(size: 24)
        let url = try XCTUnwrap(CTFontCopyAttribute(font, kCTFontURLAttribute) as? URL)
        XCTAssertTrue(url.path.hasPrefix("/System/"), url.path)
    }

    func testUninstalledFamilyFallsBackRatherThanSubstitutingSilently() {
        // The bug this guards: CTFontCreateWithName returns *some* font for an
        // unknown name, so without an explicit family check a typo would render
        // in a mystery face and report success.
        let resolved = CoverFont.resolveFace(preferredFamily: "Definitely Not A Font 12345")
        XCTAssertTrue(resolved.usedFallback)
        XCTAssertEqual(resolved.face, .named(CoverFont.fallbackFaceName))
    }

    func testKnownFamilyResolvesToAFaceInThatFamily() throws {
        let resolved = CoverFont.resolveFace(preferredFamily: "Georgia")
        XCTAssertFalse(resolved.usedFallback)

        let font = resolved.face.ctFont(size: 24)
        XCTAssertEqual(CTFontCopyFamilyName(font) as String, "Georgia")
    }

    func testResolutionPrefersUprightNormalWidthFaces() throws {
        // Ranking on weight alone picks condensed and italic cuts, because those
        // carry the extreme weights in large families.
        try XCTSkipUnless(CoverFont.availableFamilies().contains("Helvetica Neue"))

        let name = try XCTUnwrap(CoverFont.boldFaceName(inFamily: "Helvetica Neue"))
        XCTAssertFalse(name.localizedCaseInsensitiveContains("Condensed"), name)
        XCTAssertFalse(name.localizedCaseInsensitiveContains("Italic"), name)

        let traits = CTFontGetSymbolicTraits(CTFontCreateWithName(name as CFString, 24, nil))
        XCTAssertFalse(traits.contains(CTFontSymbolicTraits.traitItalic))
        XCTAssertFalse(traits.contains(CTFontSymbolicTraits.traitCondensed))
    }

    func testResolutionPicksABoldWeightWhenTheFamilyHasOne() throws {
        let name = try XCTUnwrap(CoverFont.boldFaceName(inFamily: "Georgia"))
        let traits = CTFontGetSymbolicTraits(CTFontCreateWithName(name as CFString, 24, nil))
        XCTAssertTrue(traits.contains(CTFontSymbolicTraits.traitBold), name)
    }

    func testWhitespaceOnlyPreferenceIsTreatedAsUnset() {
        XCTAssertEqual(
            CoverFont.resolveFace(preferredFamily: "   ").face,
            CoverFont.resolveFace(preferredFamily: "").face
        )
    }

    // MARK: - The family list

    func testAvailableFamiliesAreUsableAndSorted() {
        let families = CoverFont.availableFamilies()
        XCTAssertFalse(families.isEmpty)
        // System-private families would be noise in a picker.
        XCTAssertFalse(families.contains { $0.hasPrefix(".") })
        XCTAssertEqual(families, families.sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        })
    }

    func testEveryListedFamilyActuallyResolves() {
        // A family offered in the picker that cannot be rendered would be a
        // choice that silently falls back to Georgia.
        for family in CoverFont.availableFamilies() {
            XCTAssertNotNil(CoverFont.boldFaceName(inFamily: family), family)
        }
    }

    // MARK: - Rendering and plumbing

    func testCoverRendersWithAChosenFamily() throws {
        let cover = try XCTUnwrap(
            CoverGenerator.makeCover(article: article(), fontFamily: "Georgia")
        )
        XCTAssertFalse(cover.usedFallbackFont)
        XCTAssertFalse(cover.data.isEmpty)
    }

    func testCoverStillRendersWhenTheFamilyIsMissing() throws {
        let cover = try XCTUnwrap(
            CoverGenerator.makeCover(article: article(), fontFamily: "No Such Family 99")
        )
        XCTAssertTrue(cover.usedFallbackFont)
        XCTAssertFalse(cover.data.isEmpty)
    }

    func testDraftCarriesTheCoverFamilyIntoTheConfiguration() {
        var draft = SettingsDraft(kindleAddress: "a@kindle.com")
        draft.coverFontFamily = "  Futura  "
        // Trimmed on the way through, so stray paste whitespace is not a
        // different value than the same font typed by hand.
        XCTAssertEqual(draft.configuration.coverStyle.fontFamily, "Futura")
    }

    // MARK: - The book carries no fonts

    func testBookInheritsTheReadersOwnFontSettings() throws {
        let book = EPUBBuilder.build(article: article())
        let entries = try ZipInspector.entries(in: book.data)
        let css = try XCTUnwrap(entries.first { $0.name == "OEBPS/style.css" })
        XCTAssertFalse(String(decoding: css.contents, as: UTF8.self).contains("font-family"))
    }
}
