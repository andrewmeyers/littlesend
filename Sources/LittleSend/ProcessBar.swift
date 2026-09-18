import SwiftUI

/// The two steps of a send: what you are sending, then where it goes. Sending
/// itself is the button at the end of the second step, not a step of its own.
///
/// The labels are fixed — they name the step, not its current contents. Steps
/// at or before `highestSelectable` are clickable, so a decision can be
/// revisited but one that has not been made yet cannot be skipped.
struct ProcessBar: View {
    enum Step: Int, Comparable, CaseIterable {
        case source, destination

        var title: String {
            switch self {
            case .source: return "Source"
            case .destination: return "Destination"
            }
        }

        static func < (a: Step, b: Step) -> Bool { a.rawValue < b.rawValue }
    }

    var current: Step
    var highestSelectable: Step
    var isSending: Bool
    var onSelect: (Step) -> Void = { _ in }

    var body: some View {
        HStack(spacing: 5) {
            step(.source)
            separator
            step(.destination)
        }
        .font(.appLabel)
        .lineLimit(1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Step \(current.rawValue + 1) of 2: \(current.title)")
    }

    private var separator: some View {
        Image(systemName: "chevron.right")
            .font(.appHint)
            .foregroundStyle(.tertiary)
    }

    @ViewBuilder
    private func step(_ step: Step) -> some View {
        // Done steps stay readable but recede; the one you are on is the only
        // thing wearing the accent colour.
        let done = step < current
        let reachable = step <= highestSelectable && step != current && !isSending

        Button { onSelect(step) } label: {
            Text(step.title)
                .fontWeight(step == current ? .semibold : .regular)
                .foregroundStyle(
                    step == current ? AnyShapeStyle(Color.accentColor)
                        : done ? AnyShapeStyle(HierarchicalShapeStyle.secondary)
                        : AnyShapeStyle(HierarchicalShapeStyle.tertiary)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!reachable)
        .help(reachable ? "Go to \(step.title)" : "")
    }
}
