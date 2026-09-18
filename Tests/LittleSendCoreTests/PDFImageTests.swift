import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import LittleSendCore

final class PDFImageTests: XCTestCase {

    /// An opaque JPEG of the given pixel size, striped so the encoder has real
    /// detail to keep rather than a flat colour it can compress to nothing.
    private func jpeg(width: Int, height: Int) -> Data {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        for x in stride(from: 0, to: width, by: 40) {
            context.setFillColor(CGColor(red: CGFloat(x) / CGFloat(width), green: 0.45, blue: 0.6, alpha: 1))
            context.fill(CGRect(x: x, y: 0, width: 40, height: height))
        }
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return output as Data
    }

    private func pixelWidth(of data: Data) -> Int? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return nil }
        return properties[kCGImagePropertyPixelWidth] as? Int
    }

    private func article(_ html: String) -> ParsedArticle {
        ParsedArticle(url: "https://example.com/articles/one", title: "Pictures", html: html)
    }

    // MARK: - Sizing

    func testTheColumnIs2100PixelsAt300DPI() {
        // Letter with ¾-inch margins leaves a 7-inch column: 504 points.
        XCTAssertEqual(PDFRenderer.maxPixelWidth(forColumnWidth: 504), 2100)
    }

    func testOversizeImageIsBroughtDownToPrintResolution() throws {
        let big = EmbeddedImage(
            sourceURL: "https://example.com/big.jpg", fileName: "img0.jpg",
            mediaType: "image/jpeg", data: jpeg(width: 4000, height: 2000)
        )
        let ready = PDFRenderer.printReady(big, maxPixelWidth: 2100)
        let width = try XCTUnwrap(pixelWidth(of: ready.data))
        XCTAssertEqual(Double(width), 2100, accuracy: 1)
        XCTAssertEqual(ready.mediaType, "image/jpeg")
    }

    func testTallImagesAreJudgedByWidthNotTheLongerSide() throws {
        // A portrait image narrower than the column must not be shrunk just
        // because its height exceeds 2100.
        let tall = jpeg(width: 1200, height: 3000)
        let image = EmbeddedImage(
            sourceURL: "https://example.com/tall.jpg", fileName: "img0.jpg",
            mediaType: "image/jpeg", data: tall
        )
        XCTAssertEqual(PDFRenderer.printReady(image, maxPixelWidth: 2100).data, tall)
    }

    func testSmallImagesAreNeverEnlargedOrReencoded() {
        let small = jpeg(width: 800, height: 400)
        let image = EmbeddedImage(
            sourceURL: "https://example.com/small.jpg", fileName: "img0.jpg",
            mediaType: "image/jpeg", data: small
        )
        XCTAssertEqual(PDFRenderer.printReady(image, maxPixelWidth: 2100).data, small)
    }

    // MARK: - Embedding

    func testImagesAreEmbeddedAndRelativeSourcesResolve() {
        let image = EmbeddedImage(
            sourceURL: "https://example.com/pics/a.jpg", fileName: "img0.jpg",
            mediaType: "image/jpeg", data: jpeg(width: 300, height: 200)
        )
        let html = PDFRenderer.document(
            for: article(#"<p><img src="../pics/a.jpg" alt="A"/></p>"#),
            images: [image]
        )
        XCTAssertTrue(html.contains("data:image/jpeg;base64,"), "image was not embedded")
        XCTAssertFalse(html.contains("../pics/a.jpg"), "the web address survived embedding")
    }

    func testAnImageThatWasNotFetchedKeepsItsAddress() {
        let html = PDFRenderer.document(for: article(#"<p><img src="https://example.com/missing.jpg"/></p>"#))
        XCTAssertTrue(html.contains("https://example.com/missing.jpg"))
        XCTAssertFalse(html.contains("data:image"))
    }

    // MARK: - The resolution survives into the PDF

    @MainActor
    func testEmbeddedImageReachesThePDFAtPrintResolution() async throws {
        // The real question: WebKit's print path could quietly downsample to
        // screen resolution, and every check above would still pass.
        let big = EmbeddedImage(
            sourceURL: "https://example.com/big.jpg", fileName: "img0.jpg",
            mediaType: "image/jpeg", data: jpeg(width: 4000, height: 2000)
        )
        let data = try await PDFRenderer.render(
            article: article(#"<p><img src="/big.jpg"/></p>"#), images: [big], timeout: 20
        )

        let widths = imageWidths(inPDF: data)
        XCTAssertFalse(widths.isEmpty, "no image made it into the PDF")
        let widest = try XCTUnwrap(widths.max())
        XCTAssertGreaterThanOrEqual(widest, 2000, "the PDF image was downsampled below print resolution")
        XCTAssertLessThanOrEqual(widest, 2100, "the PDF image was not brought down to 300 dpi")
    }

    /// Pixel widths of every image XObject in the PDF, including ones nested in
    /// form XObjects, which is where WebKit tends to put page content.
    private func imageWidths(inPDF data: Data) -> [Int] {
        guard let provider = CGDataProvider(data: data as CFData),
              let document = CGPDFDocument(provider)
        else { return [] }

        var widths: [Int] = []

        func scan(_ resources: CGPDFDictionaryRef) {
            var xobjects: CGPDFDictionaryRef?
            guard CGPDFDictionaryGetDictionary(resources, "XObject", &xobjects), let xobjects else { return }
            CGPDFDictionaryApplyBlock(xobjects, { _, object, _ in
                var stream: CGPDFStreamRef?
                guard CGPDFObjectGetValue(object, .stream, &stream), let stream,
                      let dictionary = CGPDFStreamGetDictionary(stream)
                else { return true }

                var subtype: UnsafePointer<CChar>?
                guard CGPDFDictionaryGetName(dictionary, "Subtype", &subtype), let subtype else { return true }
                switch String(cString: subtype) {
                case "Image":
                    var width: CGPDFInteger = 0
                    if CGPDFDictionaryGetInteger(dictionary, "Width", &width) { widths.append(Int(width)) }
                case "Form":
                    var inner: CGPDFDictionaryRef?
                    if CGPDFDictionaryGetDictionary(dictionary, "Resources", &inner), let inner { scan(inner) }
                default:
                    break
                }
                return true
            }, nil)
        }

        for index in 1...max(1, document.numberOfPages) {
            guard let page = document.page(at: index), let pageDictionary = page.dictionary else { continue }
            var resources: CGPDFDictionaryRef?
            if CGPDFDictionaryGetDictionary(pageDictionary, "Resources", &resources), let resources {
                scan(resources)
            }
        }
        return widths
    }
}
