import SwiftUI

/// Content with a square action button beside it, the square's side equal to
/// the content's height so the two read as a single row — Send beside the
/// address and destination chips. Next keeps Send's width but stretches to the
/// full height of the URL field and file well beside it.
///
/// The square is drawn rather than a stock bordered button because macOS push
/// buttons keep a fixed height: a native button asked to be 70 points tall
/// stays a short pill. It still takes the accent colour, dims when disabled,
/// and darkens when pressed, like the native control it stands in for.
struct SquareButtonRow<Content: View>: View {
    let title: String
    let systemImage: String
    var isEnabled = true
    /// Shows a spinner in place of the icon — Send while a send is running.
    var isBusy = false
    var shortcut: KeyboardShortcut?
    var help = ""
    /// Use this side instead of the content's height — so Next can be the same
    /// square as Send even though a text field is much shorter than Send's rows.
    var fixedSide: CGFloat? = nil
    /// Receives the measured side, for another row to match.
    var reportsSide: Binding<CGFloat>? = nil
    /// Keeps the fixed width but takes the content's full height, so the
    /// button runs from the top of its column to the bottom — Next beside both
    /// the URL field and the file well, as wide as Send but taller.
    var stretchesToContentHeight = false
    let action: () -> Void
    @ViewBuilder var content: () -> Content

    private let spacing: CGFloat = 8
    @State private var side: CGFloat = 28

    var body: some View {
        HStack(alignment: .center, spacing: spacing) {
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(key: ContentHeightKey.self, value: proxy.size.height)
                    }
                )

            Button(action: action) {
                SquareLabel(title: title, systemImage: systemImage, isBusy: isBusy, width: width, height: height)
            }
            .buttonStyle(SquareButtonStyle(shortestSide: min(width, height)))
            .disabled(!isEnabled || isBusy)
            .keyboardShortcut(shortcut)
            .help(help)
            .accessibilityLabel(title)
        }
        .onPreferenceChange(ContentHeightKey.self) { height in
            // Never smaller than a comfortable click target.
            let measured = max(24, height.rounded())
            side = measured
            if let reportsSide, reportsSide.wrappedValue != measured {
                reportsSide.wrappedValue = measured
            }
        }
    }

    private var width: CGFloat { fixedSide ?? side }
    private var height: CGFloat { stretchesToContentHeight ? side : width }
}

/// Icon alone when the square is small; icon over its title once there is room.
private struct SquareLabel: View {
    let title: String
    let systemImage: String
    let isBusy: Bool
    let width: CGFloat
    let height: CGFloat

    private var roomy: Bool { min(width, height) >= 56 }

    var body: some View {
        VStack(spacing: 3) {
            if isBusy {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
            } else {
                Image(systemName: systemImage)
                    .font(roomy ? .title3.weight(.semibold) : .body.weight(.semibold))
            }
            if roomy {
                Text(title)
                    .font(.appLabel.weight(.semibold))
            }
        }
        .frame(width: width, height: height)
    }
}

private struct SquareButtonStyle: ButtonStyle {
    let shortestSide: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        SquareButtonBody(configuration: configuration, shortestSide: shortestSide)
    }
}

private struct SquareButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let shortestSide: CGFloat
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: min(10, shortestSide * 0.2), style: .continuous)
        configuration.label
            .foregroundStyle(isEnabled ? AnyShapeStyle(Color.white) : AnyShapeStyle(HierarchicalShapeStyle.tertiary))
            .background(
                shape.fill(isEnabled ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.secondary.opacity(0.14)))
            )
            .overlay(shape.fill(Color.black.opacity(configuration.isPressed ? 0.18 : 0)))
            .contentShape(shape)
    }
}

private struct ContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
