import XCTest
import ImageIO
@testable import LittleSendCore

final class CoverStyleTests: XCTestCase {

    private func article(
        title: String = "A Reasonably Long Article Title About Something",
        author: String? = "Some Author",
        site: String? = "example.com",
        date: Date? = Date(timeIntervalSince1970: 1_757_000_000)
    ) -> ParsedArticle {
        ParsedArticle(
            url: "https://example.com/a", title: title, siteName: site,
            author: author, description: nil, html: "<p>x</p>", publishedDate: date
        )
    }

    private func pixelSize(of data: Data) throws -> CGSize {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let props = try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        )
        return CGSize(
            width: try XCTUnwrap(props[kCGImagePropertyPixelWidth] as? Int),
            height: try XCTUnwrap(props[kCGImagePropertyPixelHeight] as? Int)
        )
    }

    // MARK: - Sizes

    func testEachSizeRendersAtItsDeclaredDimensions() throws {
        for size in CoverSize.allCases {
            let cover = try XCTUnwrap(CoverGenerator.makeCover(article: article(), size: size))
            XCTAssertEqual(try pixelSize(of: cover.data), size.pixelSize, size.rawValue)
        }
    }

    func testEverySizeKeepsAmazonsCoverRatio() {
        // 1.6:1 is what Amazon asks for; a size option must never change shape.
        for size in CoverSize.allCases {
            let ratio = size.pixelSize.height / size.pixelSize.width
            XCTAssertEqual(ratio, 1.6, accuracy: 0.001, size.rawValue)
        }
    }

    func testLargerSizesProduceLargerFiles() throws {
        let compact = try XCTUnwrap(CoverGenerator.makeCover(article: article(), size: .compact))
        let standard = try XCTUnwrap(CoverGenerator.makeCover(article: article(), size: .standard))
        let large = try XCTUnwrap(CoverGenerator.makeCover(article: article(), size: .large))

        XCTAssertLessThan(compact.data.count, standard.data.count)
        XCTAssertLessThan(standard.data.count, large.data.count)
    }

    // MARK: - Layouts

    func testEveryLayoutRendersForEverySize() throws {
        // The layouts scale off the canvas rather than hardcoding the original
        // 1600×2560, so every combination has to survive.
        for layout in CoverLayout.allCases {
            for size in CoverSize.allCases {
                let cover = CoverGenerator.makeCover(article: article(), layout: layout, size: size)
                let unwrapped = try XCTUnwrap(cover, "\(layout.rawValue)/\(size.rawValue)")
                XCTAssertFalse(unwrapped.data.isEmpty)
                XCTAssertEqual(try pixelSize(of: unwrapped.data), size.pixelSize)
            }
        }
    }

    func testLayoutsActuallyDifferFromEachOther() throws {
        var rendered: [Data] = []
        for layout in CoverLayout.allCases {
            rendered.append(try XCTUnwrap(CoverGenerator.makeCover(article: article(), layout: layout)).data)
        }
        // A picker offering four identical images would be worse than none.
        for (i, a) in rendered.enumerated() {
            for (j, b) in rendered.enumerated() where j > i {
                XCTAssertNotEqual(a, b, "\(CoverLayout.allCases[i]) == \(CoverLayout.allCases[j])")
            }
        }
    }

    func testLayoutsSurviveDegenerateArticles() throws {
        let awkward: [ParsedArticle] = [
            article(title: ""),
            article(title: String(repeating: "Extremely long title ", count: 30)),
            article(title: "日本語のタイトル", author: nil, site: nil, date: nil),
            article(author: nil, site: nil, date: nil),
            // Site identical to the byline: the kicker must not double up.
            article(author: "example.com", site: "example.com"),
        ]
        for piece in awkward {
            for layout in CoverLayout.allCases {
                XCTAssertNotNil(
                    CoverGenerator.makeCover(article: piece, layout: layout),
                    "\(layout.rawValue) / \(piece.title.prefix(20))"
                )
            }
        }
    }

    // MARK: - Persistence and plumbing

    func testRawValuesAreStableForPersistence() {
        XCTAssertEqual(CoverLayout.classic.rawValue, "classic")
        XCTAssertEqual(CoverSize.standard.rawValue, "standard")
        XCTAssertNil(CoverLayout(rawValue: "removedLayout"))
        XCTAssertNil(CoverSize(rawValue: "removedSize"))
    }

    func testDefaultsMatchThePreviousBehaviour() {
        // Anyone who never opens the section keeps the cover they already had.
        XCTAssertEqual(CoverStyle.default.layout, .classic)
        XCTAssertEqual(CoverStyle.default.size, .standard)
        XCTAssertEqual(CoverStyle.default.fontFamily, "")
        XCTAssertEqual(CoverSize.standard.pixelSize, CGSize(width: 1600, height: 2560))
    }

    func testDraftCarriesTheWholeStyleIntoTheConfiguration() {
        var draft = SettingsDraft(kindleAddress: "a@kindle.com")
        draft.coverFontFamily = "Futura"
        draft.coverLayout = .banded
        draft.coverSize = .large

        XCTAssertEqual(draft.configuration.coverStyle,
                       CoverStyle(fontFamily: "Futura", layout: .banded, size: .large))
    }

    // MARK: - Settings previews

    func testPreviewsRenderForEveryLayoutInBothPalettes() throws {
        for layout in CoverLayout.allCases {
            for eInk in [true, false] {
                let image = CoverGenerator.previewImage(
                    article: CoverGenerator.sampleArticle,
                    layout: layout, optimizeForEInk: eInk, height: 348
                )
                let unwrapped = try XCTUnwrap(image, "\(layout.rawValue) eInk:\(eInk)")
                XCTAssertEqual(unwrapped.height, 348)
                // Same 1.6:1 shape as a real cover, so the preview shows the
                // true proportion and not only the arrangement.
                XCTAssertEqual(Double(unwrapped.width), 348.0 / 1.6, accuracy: 1.0)
            }
        }
    }

    func testPreviewSurvivesAbsurdlySmallCanvases() {
        // The layouts scale off the canvas, so a tiny one drives every measured
        // value towards zero. It must clamp rather than fail or divide by it.
        for height in [1.0, 8.0, 32.0] as [CGFloat] {
            XCTAssertNotNil(
                CoverGenerator.previewImage(
                    article: CoverGenerator.sampleArticle, layout: .banded, height: height
                ),
                "height \(height)"
            )
        }
    }

    func testSampleArticleExercisesEveryElement() {
        // A sample missing a byline or date would leave two layouts looking
        // emptier in Settings than they will in the library.
        let sample = CoverGenerator.sampleArticle
        XCTAssertFalse(sample.title.isEmpty)
        XCTAssertNotNil(sample.author)
        XCTAssertNotNil(sample.siteName)
        XCTAssertNotNil(sample.publishedDate)
    }

    func testEveryLayoutAndSizeIsNamedForThePicker() {
        for layout in CoverLayout.allCases {
            XCTAssertFalse(layout.displayName.isEmpty)
            XCTAssertFalse(layout.summary.isEmpty)
        }
        for size in CoverSize.allCases {
            XCTAssertTrue(size.displayName.contains("×"), size.displayName)
            XCTAssertFalse(size.summary.isEmpty)
        }
    }
}
