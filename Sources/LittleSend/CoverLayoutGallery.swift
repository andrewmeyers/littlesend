import SwiftUI
import LittleSendCore

/// The cover layouts shown as actual covers, so the choice is made by looking
/// rather than by reading four descriptions.
///
/// The thumbnails come from the production renderer at a small canvas, not from
/// a separate mock-up — a hand-drawn preview is one that can quietly stop
/// matching what gets sent. They also follow the chosen font and the e-ink
/// toggle, so what is on screen is what will arrive.
struct CoverLayoutGallery: View {
    @Binding var selection: CoverLayout
    var fontFamily: String
    var eInk: Bool

    /// Rendered generously and scaled down by SwiftUI, because the on-screen
    /// width now depends on the window rather than being a fixed number here.
    private let renderHeight: CGFloat = 600

    @State private var previews: [CoverLayout: NSImage] = [:]

    private struct RenderKey: Equatable {
        let fontFamily: String
        let eInk: Bool
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ForEach(CoverLayout.allCases, id: \.self) { layout in
                Button {
                    selection = layout
                } label: {
                    VStack(spacing: 7) {
                        thumbnail(for: layout)
                        radio(for: layout)
                    }
                    // Equal shares of whatever width the window gives us.
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(layout.summary)
                .accessibilityLabel("\(layout.displayName). \(layout.summary)")
                .accessibilityAddTraits(selection == layout ? [.isSelected] : [])
            }
        }
        .frame(maxWidth: .infinity)
        .task(id: RenderKey(fontFamily: fontFamily, eInk: eInk)) {
            renderPreviews()
        }
    }

    @ViewBuilder
    private func thumbnail(for layout: CoverLayout) -> some View {
        Group {
            if let image = previews[layout] {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
            } else {
                // Same footprint before the render lands, so the row does not
                // jump when the images appear.
                Rectangle().fill(Color.secondary.opacity(0.12))
            }
        }
        // The cover's own proportion, so the thumbnail grows with the column
        // instead of being pinned to a hardcoded size.
        .aspectRatio(1 / 1.6, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .overlay {
            RoundedRectangle(cornerRadius: 3)
                .strokeBorder(
                    selection == layout ? Color.accentColor : Color.secondary.opacity(0.35),
                    lineWidth: selection == layout ? 3 : 1
                )
        }
    }

    /// A radio button under each cover rather than one group below them all, so
    /// the control sits with the thing it selects.
    ///
    /// Drawn from the system symbols because AppKit's real radio is only
    /// reachable through `Picker`'s radio-group style, which lays its own
    /// options out and cannot be split across four columns. The symbols are the
    /// system's, and the tint is the accent colour, so it matches the genuine
    /// control it stands in for.
    @ViewBuilder
    private func radio(for layout: CoverLayout) -> some View {
        let isSelected = selection == layout
        HStack(spacing: 5) {
            Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                .imageScale(.medium)
            Text(layout.displayName)
                .font(.caption)
                .foregroundStyle(isSelected ? Color.primary : .secondary)
        }
        .accessibilityHidden(true)
    }

    private func renderPreviews() {
        var rendered: [CoverLayout: NSImage] = [:]
        for layout in CoverLayout.allCases {
            guard let image = CoverGenerator.previewImage(
                article: CoverGenerator.sampleArticle,
                fontFamily: fontFamily,
                layout: layout,
                optimizeForEInk: eInk,
                height: renderHeight
            ) else { continue }
            rendered[layout] = NSImage(
                cgImage: image,
                size: NSSize(width: image.width, height: image.height)
            )
        }
        previews = rendered
    }
}
