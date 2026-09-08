import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

/// Renders a typographic cover image for the Kindle library.
///
/// Kindle shows covers in a dense grid, so the design leans on one large title
/// and strong contrast rather than detail. The field is tinted deterministically
/// from the source domain, which keeps articles from the same site visually
/// grouped without needing any artwork.
public enum CoverGenerator {

    public static let size = CGSize(width: 1600, height: 2560)

    /// Used only when a named family turns out not to be installed.
    public static let fallbackFontName = CoverFont.fallbackFaceName

    public struct Cover: Sendable {
        public let data: Data
        public let mediaType: String
        public let fileName: String
        /// True when `displayFontName` could not be resolved and the fallback ran.
        public let usedFallbackFont: Bool
    }

    public static func makeCover(
        article: ParsedArticle,
        fontFamily: String = "",
        layout: CoverLayout = .classic,
        size dimensions: CoverSize = .standard,
        optimizeForEInk: Bool = true
    ) -> Cover? {
        guard let rendered = renderImage(
            article: article, fontFamily: fontFamily, layout: layout,
            canvas: dimensions.pixelSize, optimizeForEInk: optimizeForEInk
        ) else { return nil }

        // JPEG is the wrong container for flat grey art. It is lossy, so the
        // levels chosen to land exactly on the panel's own 16 come back off by
        // a few and edged with ringing — measured at 243 distinct greys and a
        // near-black title arriving as 21 rather than 17. PNG is lossless and,
        // on artwork this flat, also smaller.
        guard let encoded = optimizeForEInk
            ? encodePNG(rendered.image)
            : encodeJPEG(rendered.image)
        else { return nil }

        return Cover(
            data: encoded,
            mediaType: optimizeForEInk ? "image/png" : "image/jpeg",
            fileName: optimizeForEInk ? "cover.png" : "cover.jpg",
            usedFallbackFont: rendered.usedFallbackFont
        )
    }

    /// A small rendering of the same cover, for showing the layouts in Settings.
    ///
    /// Deliberately the production renderer at a smaller canvas rather than a
    /// mock-up drawn separately: a preview that is a different piece of code is
    /// a preview that can quietly stop matching what gets sent. Every
    /// measurement scales off the canvas, so this is the real layout, small.
    public static func previewImage(
        article: ParsedArticle,
        fontFamily: String = "",
        layout: CoverLayout = .classic,
        optimizeForEInk: Bool = true,
        height: CGFloat = 320
    ) -> CGImage? {
        // Same 1.6:1 shape every CoverSize uses, so the preview is the real
        // proportion and not just the real arrangement.
        let canvas = CGSize(width: (height / 1.6).rounded(), height: height.rounded())
        return renderImage(
            article: article, fontFamily: fontFamily, layout: layout,
            canvas: canvas, optimizeForEInk: optimizeForEInk
        )?.image
    }

    /// A representative article for the Settings previews, so every layout has
    /// a title, byline, source and date to arrange.
    public static let sampleArticle = ParsedArticle(
        url: "https://example.com/the-quiet-part",
        title: "The Quiet Part of a Long Headline",
        siteName: "example.com",
        author: "A Writer",
        description: nil,
        html: "<p>x</p>",
        publishedDate: Date(timeIntervalSince1970: 1_757_000_000)
    )

    private static func renderImage(
        article: ParsedArticle,
        fontFamily: String,
        layout: CoverLayout,
        canvas: CGSize,
        optimizeForEInk: Bool
    ) -> (image: CGImage, usedFallbackFont: Bool)? {
        // An e-ink cover is drawn in greyscale from the start rather than
        // rendered in colour and converted afterwards, so the exact device
        // levels reach the encoder intact.
        guard canvas.width >= 1, canvas.height >= 1, let context = CGContext(
            data: nil,
            width: Int(canvas.width),
            height: Int(canvas.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: optimizeForEInk ? CGColorSpaceCreateDeviceGray() : CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: optimizeForEInk
                ? CGImageAlphaInfo.none.rawValue
                : CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }

        let resolved = CoverFont.resolveFace(preferredFamily: fontFamily)
        let accent = accentColor(for: article, eInk: optimizeForEInk)
        let geometry = Geometry(canvas: canvas)

        context.setFillColor(accent.background)
        context.fill(CGRect(origin: .zero, size: canvas))

        let plan = Plan(
            article: article, face: resolved.face,
            accent: accent, geometry: geometry, context: context,
            eInk: optimizeForEInk
        )

        switch layout {
        case .classic: drawClassic(plan, aligned: .left)
        case .centered: drawClassic(plan, aligned: .center)
        case .banded: drawBanded(plan)
        case .minimal: drawMinimal(plan)
        }

        guard let image = context.makeImage() else { return nil }
        return (image, resolved.usedFallback)
    }

    /// Every measurement in the layouts was chosen against the original
    /// 1600×2560 canvas, so a different size scales them rather than needing
    /// each one re-tuned by hand. Scaling on height alone is safe because every
    /// `CoverSize` keeps the same 1.6:1 ratio.
    struct Geometry {
        let canvas: CGSize

        var scale: CGFloat { canvas.height / 2560 }
        func scaled(_ value: CGFloat) -> CGFloat { value * scale }

        var margin: CGFloat { scaled(140) }
        var contentWidth: CGFloat { canvas.width - margin * 2 }
    }

    /// The arguments every layout needs, gathered so each one reads as layout
    /// rather than as parameter passing.
    private struct Plan {
        let article: ParsedArticle
        let face: CoverFont.Face
        let accent: Accent
        let geometry: Geometry
        let context: CGContext
        let eInk: Bool

        /// Preferred byline: the author, or the site when there is no author.
        var byline: String? { article.author ?? article.siteName }

        /// The site is a kicker only when it is not already the byline.
        var kicker: String? {
            guard let site = article.siteName,
                  site.caseInsensitiveCompare(byline ?? "") != .orderedSame
            else { return nil }
            return site
        }
    }

    /// Whether the historical display family is installed. The default is now
    /// the system font, which always is, so this only reports on Possibility.
    public static var isDisplayFontAvailable: Bool {
        CoverFont.boldFaceName(inFamily: "Possibility") != nil
    }

    // MARK: - Drawing

    private static func drawInsetRule(_ plan: Plan) {
        let geometry = plan.geometry
        let inset = geometry.scaled(50)
        plan.context.setStrokeColor(plan.accent.hairline)
        // A hairline that reads as a faint tint over a dark ground would be
        // nearly invisible as light grey on paper, so it gains weight there.
        plan.context.setLineWidth(geometry.scaled(plan.eInk ? 7 : 4))
        plan.context.stroke(CGRect(
            x: inset, y: inset,
            width: geometry.canvas.width - inset * 2,
            height: geometry.canvas.height - inset * 2
        ))
    }

    /// The original layout, and its centred twin. The two differ only in
    /// alignment and in where the rule sits, so they share one implementation
    /// rather than drifting apart as two near-copies.
    private static func drawClassic(_ plan: Plan, aligned alignment: CTTextAlignment) {
        let geometry = plan.geometry
        let canvas = geometry.canvas
        let context = plan.context
        drawInsetRule(plan)

        // Built bottom-up: date, byline, rule, then the title fills the rest.
        var cursorY = geometry.scaled(190)

        if let published = plan.article.publishedDate {
            drawText(
                dateFormatter.string(from: published).uppercased(),
                in: CGRect(x: geometry.margin, y: cursorY,
                           width: geometry.contentWidth, height: geometry.scaled(80)),
                face: plan.face, pointSize: geometry.scaled(38),
                color: plan.accent.secondaryText, tracking: geometry.scaled(6),
                lineLimit: 1, alignment: alignment, context: context
            )
        }
        cursorY += geometry.scaled(120)

        if let byline = plan.byline {
            drawText(
                byline.uppercased(),
                in: CGRect(x: geometry.margin, y: cursorY,
                           width: geometry.contentWidth, height: geometry.scaled(170)),
                face: plan.face, pointSize: geometry.scaled(50),
                color: plan.accent.accentText, tracking: geometry.scaled(4),
                lineLimit: 2, alignment: alignment, context: context
            )
            cursorY += geometry.scaled(190)
        }

        let ruleWidth = geometry.scaled(200)
        let ruleX = alignment == .center ? (canvas.width - ruleWidth) / 2 : geometry.margin
        context.setFillColor(plan.accent.accentText)
        context.fill(CGRect(x: ruleX, y: cursorY, width: ruleWidth, height: geometry.scaled(9)))
        cursorY += geometry.scaled(110)

        var titleCeiling = canvas.height - geometry.scaled(200)
        if let kicker = plan.kicker {
            drawText(
                kicker.uppercased(),
                in: CGRect(x: geometry.margin, y: canvas.height - geometry.scaled(300),
                           width: geometry.contentWidth, height: geometry.scaled(100)),
                face: plan.face, pointSize: geometry.scaled(44),
                color: plan.accent.secondaryText, tracking: geometry.scaled(8),
                lineLimit: 1, alignment: alignment, context: context
            )
            titleCeiling = canvas.height - geometry.scaled(380)
        }

        let available = max(geometry.scaled(300), titleCeiling - cursorY)
        let fitted = fitTitle(plan, width: geometry.contentWidth, height: available)

        // Centred wants the title in the middle of what is left; classic keeps
        // it low, so a short title leaves its gap up top where the kicker
        // balances it rather than as a hole through the middle.
        let titleY = alignment == .center
            ? cursorY + (available - fitted.height) / 2
            : cursorY

        drawText(
            plan.article.title,
            in: CGRect(x: geometry.margin, y: titleY,
                       width: geometry.contentWidth, height: fitted.height),
            face: plan.face, pointSize: fitted.pointSize,
            color: plan.accent.primaryText, tracking: -geometry.scale,
            lineLimit: 0, alignment: alignment, context: context
        )
    }

    /// Title reversed out of a solid band. The band is sized to the title, so
    /// it grows with a long one instead of clipping it.
    private static func drawBanded(_ plan: Plan) {
        let geometry = plan.geometry
        let canvas = geometry.canvas
        let context = plan.context

        let padding = geometry.scaled(110)
        let available = canvas.height * 0.52
        let fitted = fitTitle(plan, width: geometry.contentWidth, height: available)

        let bandHeight = fitted.height + padding * 2
        let bandY = (canvas.height - bandHeight) / 2

        context.setFillColor(plan.accent.accentText)
        context.fill(CGRect(x: 0, y: bandY, width: canvas.width, height: bandHeight))

        // Reversed out: the page colour becomes the ink.
        drawText(
            plan.article.title,
            in: CGRect(x: geometry.margin, y: bandY + padding,
                       width: geometry.contentWidth, height: fitted.height),
            face: plan.face, pointSize: fitted.pointSize,
            color: plan.accent.background, tracking: -geometry.scale,
            lineLimit: 0, alignment: .left, context: context
        )

        if let kicker = plan.kicker {
            drawText(
                kicker.uppercased(),
                in: CGRect(x: geometry.margin, y: bandY + bandHeight + geometry.scaled(90),
                           width: geometry.contentWidth, height: geometry.scaled(100)),
                face: plan.face, pointSize: geometry.scaled(44),
                color: plan.accent.secondaryText, tracking: geometry.scaled(8),
                lineLimit: 1, alignment: .left, context: context
            )
        }

        var cursorY = geometry.scaled(190)
        if let published = plan.article.publishedDate {
            drawText(
                dateFormatter.string(from: published).uppercased(),
                in: CGRect(x: geometry.margin, y: cursorY,
                           width: geometry.contentWidth, height: geometry.scaled(80)),
                face: plan.face, pointSize: geometry.scaled(38),
                color: plan.accent.secondaryText, tracking: geometry.scaled(6),
                lineLimit: 1, alignment: .left, context: context
            )
        }
        cursorY += geometry.scaled(120)

        if let byline = plan.byline {
            drawText(
                byline.uppercased(),
                in: CGRect(x: geometry.margin, y: cursorY,
                           width: geometry.contentWidth, height: geometry.scaled(170)),
                face: plan.face, pointSize: geometry.scaled(50),
                color: plan.accent.primaryText, tracking: geometry.scaled(4),
                lineLimit: 2, alignment: .left, context: context
            )
        }
    }

    /// Title alone, centred on the page. No border, no furniture.
    private static func drawMinimal(_ plan: Plan) {
        let geometry = plan.geometry
        let canvas = geometry.canvas

        let available = canvas.height * 0.62
        let fitted = fitTitle(plan, width: geometry.contentWidth, height: available)

        drawText(
            plan.article.title,
            in: CGRect(x: geometry.margin, y: (canvas.height - fitted.height) / 2,
                       width: geometry.contentWidth, height: fitted.height),
            face: plan.face, pointSize: fitted.pointSize,
            color: plan.accent.primaryText, tracking: -geometry.scale,
            lineLimit: 0, alignment: .center, context: plan.context
        )
    }

    /// Largest point size at which the title fits the space, with the height it
    /// then occupies. Separated from drawing so a layout can size a band or
    /// centre a block before committing to it.
    private static func fitTitle(
        _ plan: Plan, width: CGFloat, height: CGFloat
    ) -> (pointSize: CGFloat, height: CGFloat) {
        let geometry = plan.geometry
        var pointSize = geometry.scaled(152)
        let minimumSize = geometry.scaled(58)
        let step = geometry.scaled(6)
        let tracking = -geometry.scale

        while pointSize > minimumSize {
            let measured = measure(
                plan.article.title, face: plan.face,
                pointSize: pointSize, width: width, tracking: tracking
            )
            if measured <= height { break }
            pointSize -= step
        }

        let measured = measure(
            plan.article.title, face: plan.face,
            pointSize: pointSize, width: width, tracking: tracking
        )
        return (pointSize, min(measured, height))
    }

    private static func attributed(
        _ string: String,
        face: CoverFont.Face,
        pointSize: CGFloat,
        color: CGColor,
        tracking: CGFloat,
        alignment: CTTextAlignment = .left
    ) -> NSAttributedString {
        let spacing = pointSize * 0.16
        let paragraphStyle = withUnsafePointer(to: spacing) { spacingPointer in
            withUnsafePointer(to: alignment) { alignmentPointer in
                let settings = [
                    CTParagraphStyleSetting(
                        spec: .lineSpacingAdjustment,
                        valueSize: MemoryLayout<CGFloat>.size,
                        value: spacingPointer
                    ),
                    CTParagraphStyleSetting(
                        spec: .alignment,
                        valueSize: MemoryLayout<CTTextAlignment>.size,
                        value: alignmentPointer
                    ),
                ]
                return CTParagraphStyleCreate(settings, settings.count)
            }
        }
        let font = face.ctFont(size: pointSize)

        return NSAttributedString(string: string, attributes: [
            .init(kCTFontAttributeName as String): font,
            .init(kCTForegroundColorAttributeName as String): color,
            .init(kCTKernAttributeName as String): tracking,
            .init(kCTParagraphStyleAttributeName as String): paragraphStyle,
        ])
    }

    private static func measure(
        _ string: String,
        face: CoverFont.Face,
        pointSize: CGFloat,
        width: CGFloat,
        tracking: CGFloat,
        alignment: CTTextAlignment = .left
    ) -> CGFloat {
        let attributedString = attributed(
            string, face: face, pointSize: pointSize,
            color: CGColor(gray: 1, alpha: 1), tracking: tracking, alignment: alignment
        )
        let framesetter = CTFramesetterCreateWithAttributedString(attributedString)
        let suggested = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter,
            CFRange(location: 0, length: 0),
            nil,
            CGSize(width: width, height: .greatestFiniteMagnitude),
            nil
        )
        return ceil(suggested.height)
    }

    private static func drawText(
        _ string: String,
        in rect: CGRect,
        face: CoverFont.Face,
        pointSize: CGFloat,
        color: CGColor,
        tracking: CGFloat,
        lineLimit: Int,
        alignment: CTTextAlignment = .left,
        context: CGContext
    ) {
        guard !string.isEmpty, rect.height > 0, rect.width > 0 else { return }
        let attributedString = attributed(
            string, face: face, pointSize: pointSize,
            color: color, tracking: tracking, alignment: alignment
        )
        let framesetter = CTFramesetterCreateWithAttributedString(attributedString)
        let frame = CTFramesetterCreateFrame(
            framesetter, CFRange(location: 0, length: 0), CGPath(rect: rect, transform: nil), nil
        )

        guard lineLimit > 0 else {
            CTFrameDraw(frame, context)
            return
        }

        guard let lines = CTFrameGetLines(frame) as? [CTLine], !lines.isEmpty else { return }
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)
        for index in 0..<min(lineLimit, lines.count) {
            context.textPosition = CGPoint(x: rect.minX + origins[index].x, y: rect.minY + origins[index].y)
            CTLineDraw(lines[index], context)
        }
    }

    // MARK: - Colour

    struct Accent {
        let background: CGColor
        let primaryText: CGColor
        let secondaryText: CGColor
        let accentText: CGColor
        let hairline: CGColor
    }

    /// Deterministic per-domain palette, so one site always looks the same.
    ///
    /// Two palettes, because the destination decides what "looks good" means.
    /// The colour one assumes a backlit screen. The e-ink one is built for a
    /// reflective 16-level grey panel, where three things about the colour
    /// palette break down:
    ///
    /// 1. Hue carries no information. Every domain's background sat at the same
    ///    0.19 brightness, so converting to grey collapsed the whole range onto
    ///    2 of the 16 available levels — every site looked identical.
    /// 2. A large dark field is e-ink's weakest case. The panel reflects
    ///    ambient light rather than emitting it, so "black" is really dark
    ///    grey; a mostly-dark cover reads as muddy where paper-white reads
    ///    crisp.
    /// 3. Anything drawn with alpha over a dark ground disappears once the
    ///    ground becomes paper.
    ///
    /// The e-ink palette therefore inverts to dark-on-paper, moves the
    /// per-domain identity from hue onto grey level where it survives, and
    /// snaps every value onto the panel's own 16 levels so nothing is left for
    /// the device to dither.
    static func accentColor(for article: ParsedArticle, eInk: Bool = false) -> Accent {
        let key = URL(string: article.url)?.host ?? article.siteName ?? article.url
        var hash: UInt64 = 5381
        for byte in Array(key.utf8) { hash = (hash &* 33) &+ UInt64(byte) }

        guard eInk else {
            let hue = CGFloat(hash % 360) / 360
            return Accent(
                background: color(hue: hue, saturation: 0.44, brightness: 0.19),
                primaryText: CGColor(red: 1, green: 1, blue: 1, alpha: 1),
                secondaryText: CGColor(red: 1, green: 1, blue: 1, alpha: 0.60),
                accentText: color(hue: hue, saturation: 0.58, brightness: 0.85),
                hairline: CGColor(red: 1, green: 1, blue: 1, alpha: 0.22)
            )
        }

        // Levels 3 through 7 of 15. Dark enough that paper-white reverses out
        // of them legibly in the banded layout, light enough to stay clearly
        // separate from the near-black title.
        let accentLevel = 3 + Int(hash % 5)

        return Accent(
            background: eInkLevel(15),
            primaryText: eInkLevel(1),
            secondaryText: eInkLevel(8),
            accentText: eInkLevel(accentLevel),
            hairline: eInkLevel(11)
        )
    }

    /// One of the 16 grey levels a 4-bit e-ink panel can actually display.
    ///
    /// Rendering straight onto these means the device displays the file as
    /// authored. An arbitrary grey in between gets dithered instead, which on a
    /// large flat area is visible as texture.
    static func eInkLevel(_ level: Int) -> CGColor {
        let clamped = min(max(level, 0), 15)
        // Built in DeviceGray explicitly. `CGColor(gray:)` produces a *generic*
        // grey with a 2.2 gamma, and drawing that into the DeviceGray canvas
        // converts it — level 1 was landing in the file as 21 rather than 17,
        // which is exactly the off-level value this whole palette exists to
        // avoid. Naming the space keeps the number that was chosen.
        let value = CGFloat(clamped) * 17 / 255
        return CGColor(
            colorSpace: CGColorSpaceCreateDeviceGray(), components: [value, 1]
        ) ?? CGColor(gray: value, alpha: 1)
    }

    private static func color(hue: CGFloat, saturation: CGFloat, brightness: CGFloat) -> CGColor {
        let sector = hue * 6
        let index = Int(sector) % 6
        let fraction = sector - CGFloat(Int(sector))
        let p = brightness * (1 - saturation)
        let q = brightness * (1 - saturation * fraction)
        let t = brightness * (1 - saturation * (1 - fraction))

        let rgb: (CGFloat, CGFloat, CGFloat)
        switch index {
        case 0: rgb = (brightness, t, p)
        case 1: rgb = (q, brightness, p)
        case 2: rgb = (p, brightness, t)
        case 3: rgb = (p, q, brightness)
        case 4: rgb = (t, p, brightness)
        default: rgb = (brightness, p, q)
        }
        return CGColor(red: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
    }

    // MARK: - Encoding

    private static func encodePNG(_ image: CGImage) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.png.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    private static func encodeJPEG(_ image: CGImage) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(
            destination, image, [kCGImageDestinationLossyCompressionQuality: 0.88] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMMM yyyy"
        return formatter
    }()
}
