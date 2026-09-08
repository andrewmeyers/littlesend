import XCTest
import ImageIO
import CoreGraphics
@testable import LittleSendCore

final class CoverEInkTests: XCTestCase {

    private func article(site: String = "example.com") -> ParsedArticle {
        ParsedArticle(
            url: "https://\(site)/a", title: "A Reasonably Long Cover Title",
            siteName: site, author: "Some Author", description: nil,
            html: "<p>x</p>", publishedDate: Date(timeIntervalSince1970: 1_757_000_000)
        )
    }

    private func grayHistogram(_ data: Data) throws -> [Int] {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let w = image.width, h = image.height
        // Read back in the space the file is authored in. Drawing a DeviceGray
        // image into an RGB context applies a gamma conversion that shifts the
        // values — grey 17 reads back as 21 — which would look exactly like the
        // encoder having moved them.
        var buffer = [UInt8](repeating: 0, count: w * h)
        let context = try XCTUnwrap(CGContext(
            data: &buffer, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

        var histogram = [Int](repeating: 0, count: 256)
        for value in buffer { histogram[Int(value)] += 1 }
        return histogram
    }

    private func level(_ n: Int) -> CGFloat { CGFloat(n) * 17 / 255 }

    // MARK: - The panel's own levels

    func testEveryPixelLandsOnADeviceGreyLevel() throws {
        // The whole point of the e-ink palette. A grey between the panel's 16
        // levels is dithered by the device, which on a large flat field shows
        // up as texture. Lossy encoding was what broke this before: the same
        // check against the JPEG build found 243 distinct greys and the title
        // arriving at 21 instead of 17.
        let cover = try XCTUnwrap(
            CoverGenerator.makeCover(article: article(), optimizeForEInk: true)
        )
        let histogram = try grayHistogram(cover.data)

        let total = histogram.reduce(0, +)
        let onLevel = (0...15).map { $0 * 17 }.reduce(0) { $0 + histogram[$1] }
        // Not 100%: glyph edges are antialiased, which is wanted.
        XCTAssertGreaterThan(Double(onLevel) / Double(total), 0.90)

        // Every *flat area* value must be a device level. Anything holding more
        // than 1% of the image is a flat area, not an antialiased edge.
        for (value, count) in histogram.enumerated() where Double(count) / Double(total) > 0.01 {
            XCTAssertEqual(value % 17, 0, "flat area at grey \(value) is between device levels")
        }
    }

    func testEInkCoverIsFullyDesaturated() throws {
        let cover = try XCTUnwrap(
            CoverGenerator.makeCover(article: article(), optimizeForEInk: true)
        )
        let source = try XCTUnwrap(CGImageSourceCreateWithData(cover.data as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        // Authored in greyscale rather than converted afterwards.
        XCTAssertEqual(image.colorSpace?.model, .monochrome)
    }

    // MARK: - Per-site identity survives

    func testSitesSpreadAcrossSeveralGreyLevels() {
        // The colour palette put every site's background at the same
        // brightness, so in greyscale they collapsed onto 2 of 16 levels and
        // every cover looked alike. Identity now rides on grey, which survives.
        let sites = [
            "gatesnotes.com", "nytimes.com", "theatlantic.com", "stratechery.com",
            "arstechnica.com", "newyorker.com", "wired.com", "bbc.co.uk",
        ]
        var levels = Set<Int>()
        for site in sites {
            let accent = CoverGenerator.accentColor(for: article(site: site), eInk: true)
            let value = try? XCTUnwrap(accent.accentText.components?.first)
            levels.insert(Int(((value ?? 0) * 255).rounded() / 17))
        }
        XCTAssertGreaterThanOrEqual(levels.count, 3, "sites collapsed onto \(levels)")
    }

    func testTheSameSiteAlwaysGetsTheSameGrey() {
        let first = CoverGenerator.accentColor(for: article(site: "example.com"), eInk: true)
        let second = CoverGenerator.accentColor(for: article(site: "example.com"), eInk: true)
        XCTAssertEqual(first.accentText.components, second.accentText.components)
    }

    func testAccentStaysInTheReversibleBand() {
        // The banded layout reverses paper-white out of the accent, so an
        // accent that drifts too light would leave the title unreadable.
        for site in ["a.com", "b.org", "c.net", "d.io", "e.dev", "f.co", "g.uk", "h.us"] {
            let accent = CoverGenerator.accentColor(for: article(site: site), eInk: true)
            let value = accent.accentText.components?.first ?? 0
            XCTAssertGreaterThanOrEqual(value, level(3) - 0.001, site)
            XCTAssertLessThanOrEqual(value, level(7) + 0.001, site)
        }
    }

    // MARK: - Palette shape

    func testEInkIsDarkOnPaperAndColourIsLightOnDark() {
        let eInk = CoverGenerator.accentColor(for: article(), eInk: true)
        let colour = CoverGenerator.accentColor(for: article(), eInk: false)

        // Paper background, near-black ink.
        XCTAssertGreaterThan(eInk.background.components?.first ?? 0, 0.9)
        XCTAssertLessThan(eInk.primaryText.components?.first ?? 1, 0.15)

        // The colour palette is the other way round, and stays that way.
        XCTAssertLessThan(colour.background.components?.first ?? 1, 0.4)
    }

    func testEInkColoursAreOpaque() {
        // The colour palette leans on alpha over a dark ground; the same values
        // over paper would be close to invisible.
        let accent = CoverGenerator.accentColor(for: article(), eInk: true)
        for colour in [accent.background, accent.primaryText, accent.secondaryText,
                       accent.accentText, accent.hairline] {
            XCTAssertEqual(colour.alpha, 1, accuracy: 0.001)
        }
    }

    func testLevelHelperClampsRatherThanCrashing() {
        XCTAssertEqual(CoverGenerator.eInkLevel(-5).components?.first, 0)
        XCTAssertEqual(CoverGenerator.eInkLevel(99).components?.first, 1)
    }

    // MARK: - Every layout still works in greyscale

    func testEveryLayoutAndSizeRendersInEInk() throws {
        for layout in CoverLayout.allCases {
            for size in CoverSize.allCases {
                let cover = CoverGenerator.makeCover(
                    article: article(), layout: layout, size: size, optimizeForEInk: true
                )
                let unwrapped = try XCTUnwrap(cover, "\(layout.rawValue)/\(size.rawValue)")
                XCTAssertEqual(unwrapped.mediaType, "image/png")
                XCTAssertFalse(unwrapped.data.isEmpty)
            }
        }
    }
}
