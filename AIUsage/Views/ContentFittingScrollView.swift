import SwiftUI

/// Uses the content's natural height until scrolling is needed.
struct ContentFittingScrollView<Content: View>: View {
    let maximumHeight: CGFloat
    @ViewBuilder let content: () -> Content
    var body: some View {
        NaturalScrollLayout(maximumHeight: maximumHeight) {
            content().fixedSize(horizontal: false, vertical: true)
                .hidden().accessibilityHidden(true)
            ScrollView(.vertical) {
                content().fixedSize(horizontal: false, vertical: true)
            }
            .scrollIndicators(.hidden)
            .clipped()
        }
    }
}

private struct NaturalScrollLayout: Layout {
    let maximumHeight: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let natural = subviews[0].sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: proposal.width ?? natural.width, height: min(natural.height, maximumHeight))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews[0].place(at: bounds.origin, anchor: .topLeading,
                          proposal: ProposedViewSize(width: bounds.width, height: nil))
        subviews[1].place(at: bounds.origin, anchor: .topLeading,
                          proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}

/// Places each card in the shortest column without reserving row-height gaps.
struct ProviderCardLayout: Layout {
    var columns: Int
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        placements(width: proposal.width ?? 372, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = placements(width: bounds.width, subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y),
                                  anchor: .topLeading,
                                  proposal: ProposedViewSize(width: result.cardWidth, height: nil))
        }
    }

    private func placements(width: CGFloat, subviews: Subviews) -> (size: CGSize, positions: [CGPoint], cardWidth: CGFloat) {
        let count = max(1, columns)
        let cardWidth = max(0, (width - CGFloat(count - 1) * spacing) / CGFloat(count))
        var heights = Array(repeating: CGFloat.zero, count: count)
        var positions: [CGPoint] = []
        for view in subviews {
            let column = heights.indices.min(by: { heights[$0] < heights[$1] }) ?? 0
            positions.append(CGPoint(x: CGFloat(column) * (cardWidth + spacing), y: heights[column]))
            heights[column] += view.sizeThatFits(ProposedViewSize(width: cardWidth, height: nil)).height + spacing
        }
        return (CGSize(width: width, height: max(0, (heights.max() ?? 0) - spacing)), positions, cardWidth)
    }
}
