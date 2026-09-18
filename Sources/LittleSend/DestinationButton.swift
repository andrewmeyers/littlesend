import SwiftUI

/// The shared look for every "send to X" control in the popover: fills solid
/// with the system accent color when on (inverting to a light label on top of
/// it, the way any native prominent button does) and sits as a plain outline
/// when off.
///
/// Kept as one modifier rather than repeated modifiers per destination so the
/// chips cannot drift apart in styling as more are added.
///
/// Every chip is a plain `Button` with this style, including Email's. A `Menu`
/// was tried for Email and does not take the prominent tint — it drew
/// unaccented, then solid black — which is why Email's options live in a
/// popover instead; see `DestinationMenuButton`.
struct DestinationChipStyle: ViewModifier {
    var isOn: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        let base = content
            .controlSize(.regular)
            .tint(.accentColor)
            .buttonBorderShape(.roundedRectangle)

        if isOn {
            base.buttonStyle(.borderedProminent)
        } else {
            base.buttonStyle(.bordered)
        }
    }
}

extension View {
    func destinationChip(isOn: Bool) -> some View {
        modifier(DestinationChipStyle(isOn: isOn))
    }

}

/// A destination that is simply on or off — Kindle, Desktop.
struct DestinationButton: View {
    var title: String
    var onSymbol: String
    var offSymbol: String
    var isOn: Bool
    var enabled: Bool
    var help: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            DestinationLabel(title: title, symbol: isOn ? onSymbol : offSymbol, isOn: isOn)
        }
        .destinationChip(isOn: isOn)
        .disabled(!enabled)
        .help(help)
    }
}

/// A destination that is on or off *and* carries its own options — Email, whose
/// recipient list lives behind the chevron.
///
/// Not a `Menu`, despite the appearance. A macOS menu is an AppKit menu built
/// once and cached: its items never re-read the bindings behind them, so an
/// address unticked a moment ago keeps its checkmark while the chip's own
/// count — which SwiftUI does draw — says otherwise. Neither dismissing the
/// menu on action nor swapping `Toggle` for a `Button` fixed that; the second
/// lost the checkmarks entirely, because macOS drops a menu item's icon.
///
/// So the options live in a popover, which is an ordinary SwiftUI view and
/// re-renders like one. The chevron is drawn inside the chip's own label, so it
/// sits within the fill and inverts with it, and a clear button is laid over
/// that corner to catch clicks on it. The chip keeps the native button styling
/// shared with Kindle and Desktop, which is what makes the accent colour work.
struct DestinationMenuButton<Content: View>: View {
    var title: String
    var onSymbol: String
    var offSymbol: String
    var isOn: Bool
    var enabled: Bool
    var help: String
    var action: () -> Void
    /// Tooltip for the chevron, which opens whatever this chip's options are.
    var optionsHelp: String = "More options"
    @ViewBuilder var content: () -> Content

    /// Width of the chevron's hit target at the trailing edge.
    private let chevronWidth: CGFloat = 22

    @State private var showingOptions = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: isOn ? onSymbol : offSymbol)
                    .symbolEffect(.bounce, value: isOn)
                Text(title)
                    .fontWeight(isOn ? .semibold : .regular)
                    // Full width always; the row wraps rather than truncating.
                    .fixedSize(horizontal: true, vertical: false)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .opacity(0.8)
                    .padding(.leading, 1)
            }
        }
        .destinationChip(isOn: isOn)
        .disabled(!enabled)
        .help(help)
        .overlay(alignment: .trailing) {
            Button {
                showingOptions.toggle()
            } label: {
                // Invisible but hit-testable. Fully clear content is not
                // reliably hit-tested, hence the all-but-invisible fill.
                Rectangle()
                    .fill(Color.white.opacity(0.001))
                    .frame(width: chevronWidth)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!enabled)
            .help(optionsHelp)
            .popover(isPresented: $showingOptions, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    content()
                }
                .padding(14)
            }
        }
    }
}

/// Shared so the plain and split chips are laid out identically.
private struct DestinationLabel: View {
    var title: String
    var symbol: String
    var isOn: Bool

    var body: some View {
        Label(title, systemImage: symbol)
            .fontWeight(isOn ? .semibold : .regular)
            // Full width always; the row wraps rather than truncating.
            .fixedSize(horizontal: true, vertical: false)
            // A small hop when a destination is switched — the system's own
            // symbol animation, so it matches the rest of macOS. The panel
            // removes symbol effects under Reduce Motion.
            .symbolEffect(.bounce, value: isOn)
    }
}
