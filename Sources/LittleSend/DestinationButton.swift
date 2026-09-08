import SwiftUI

/// The shared look for every "send to X" control in the popover: fills solid
/// with the system accent color when on (inverting to a light label on top of
/// it, the way any native prominent button does) and sits as a plain outline
/// when off.
///
/// Kept as one modifier rather than repeated modifiers per destination so the
/// chips cannot drift apart in styling as more are added.
///
/// A plain `Button` takes the accent correctly, so Kindle and Desktop use the
/// native prominent style untouched.
///
/// A `Menu` does not. `.menuStyle(.button)` gets it to present as a button —
/// which is what puts the chevron inside the chip — but `buttonStyle`'s
/// prominent *tint* still does not reach it: the fill is drawn in a default
/// colour, which is the "solid black", then "no accent", seen across three
/// attempts. Native gives the chevron inside or the accent fill, not both.
///
/// So the split chip paints its own filled state, matching the native metrics
/// beside it. The unfilled state stays native, since that one was never wrong.
struct DestinationChipStyle: ViewModifier {
    var isOn: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        let base = content
            .controlSize(.small)
            .tint(.accentColor)
            .buttonBorderShape(.roundedRectangle)

        if isOn {
            base.buttonStyle(.borderedProminent)
        } else {
            base.buttonStyle(.bordered)
        }
    }
}

/// The filled look for the split chip, drawn rather than inherited.
///
/// Values chosen to match `.controlSize(.small)` + `.buttonBorderShape(
/// .roundedRectangle)` as rendered by the plain chips next to it, so Kindle and
/// Email still read as one family.
struct DestinationMenuChipStyle: ViewModifier {
    var isOn: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        let base = content
            .controlSize(.small)
            .menuStyle(.button)

        if isOn {
            base
                .buttonStyle(.plain)
                .foregroundStyle(Color.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 5))
        } else {
            base
                .tint(.accentColor)
                .buttonBorderShape(.roundedRectangle)
                .buttonStyle(.bordered)
        }
    }
}

extension View {
    func destinationChip(isOn: Bool) -> some View {
        modifier(DestinationChipStyle(isOn: isOn))
    }

    func destinationMenuChip(isOn: Bool) -> some View {
        modifier(DestinationMenuChipStyle(isOn: isOn))
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
/// One control rather than a button with a separate chevron beside it: the
/// chevron belongs to the thing it configures. Clicking the label toggles the
/// destination; clicking the chevron opens the menu.
struct DestinationMenuButton<Content: View>: View {
    var title: String
    var onSymbol: String
    var offSymbol: String
    var isOn: Bool
    var enabled: Bool
    var help: String
    var action: () -> Void
    @ViewBuilder var content: () -> Content

    var body: some View {
        Menu {
            content()
        } label: {
            DestinationLabel(title: title, symbol: isOn ? onSymbol : offSymbol, isOn: isOn)
        } primaryAction: {
            action()
        }
        .menuIndicator(.visible)
        .destinationMenuChip(isOn: isOn)
        .fixedSize()
        .disabled(!enabled)
        .help(help)
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
    }
}
