import AppKit
import SwiftUI
import ActivityCore

struct CardStatusTransition {
    let previous: ActivityCard
    let phaseTarget: CGFloat
    private let boundary: CGFloat?

    init(previous: ActivityCard, phaseTarget: CGFloat, boundary: CGFloat?) {
        self.previous = previous
        self.phaseTarget = phaseTarget
        self.boundary = boundary
    }

    func progress(at phase: CGFloat) -> Double {
        let fraction = phase - (phaseTarget - 1)
        // Without a heading crossing, the status uses the whole transition.
        guard let boundary else { return min(1, max(0, Double(fraction))) }
        let delta = fraction - boundary
        let span = delta < 0 ? min(0.4,boundary) : min(0.4,1 - boundary)
        return min(1, max(0, Double(0.5 + delta / (2 * span))))
    }
}

private struct PositionedCard: View, Animatable {
    let card: ActivityCard
    let visible: Bool
    let action: () -> Void
    let spacing: PanelSpacing
    let showsTokens: Bool
    var position: CGFloat
    var statusPhase: CGFloat
    let statusTransition: CardStatusTransition?
    let runningVerb: String

    var animatableData: AnimatablePair<CGFloat,CGFloat> {
        get { AnimatablePair(position,statusPhase) }
        set { position = newValue.first; statusPhase = newValue.second }
    }

    var body: some View {
        CardView(card:card, visible:visible, action:action,
                 spacing:spacing, showsTokens:showsTokens,
                 statusProgress:statusTransition?.progress(at:statusPhase) ?? 1,
                 previousStatus:statusTransition?.previous, runningVerb:runningVerb)
            .offset(y:position)
            .transaction(value:animatableData) {
                // The outer animation already interpolates position and status opacity.
                $0.animation = nil
                $0.disablesAnimations = true
            }
    }
}

final class CardListPresentation: ObservableObject {
    struct Snapshot {
        let cards: [ActivityCard]
        let layout: ActivityListLayout
        let animateMoves: Bool
        let groupMoves: Set<ActivityCard.ID>
        let animationOrigin: CGFloat
        var statusTransitions: [ActivityCard.ID: CardStatusTransition] = [:]
    }

    @Published var snapshot = Snapshot(
        cards: [], layout: ActivityListLayout(cards: [], now: Date()), animateMoves: false,
        groupMoves: [], animationOrigin: 0
    )
    @Published var visible: CGRect = .zero
    @Published var spacing = PanelSpacing(width:150)
}

/// One AppKit scroll view, with one persistent SwiftUI host for the lifetime of the list.
struct NativeCardScroll: NSViewRepresentable {
    @ObservedObject var model: PanelModel
    var spacing = PanelSpacing(width:150)

    final class Coordinator {
        let presentation = CardListPresentation()
        weak var scroll: NSScrollView?
        var observation: NSObjectProtocol?

        deinit {
            if let observation { NotificationCenter.default.removeObserver(observation) }
        }

        func updateVisibility() {
            guard let bounds = scroll?.contentView.bounds, bounds != presentation.visible else { return }
            presentation.visible = bounds
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.verticalScrollElasticity = .automatic
        scroll.horizontalScrollElasticity = .none

        let coordinator = context.coordinator
        coordinator.presentation.spacing = spacing
        let host = NSHostingView(rootView: CardList(presentation:coordinator.presentation, open:model.open,
                                                   runningVerb:model.runningVerb))
        host.sizingOptions = []
        host.autoresizingMask = [.width]
        scroll.documentView = host
        scroll.contentView.postsBoundsChangedNotifications = true
        coordinator.scroll = scroll
        coordinator.observation = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main
        ) { [weak coordinator] _ in coordinator?.updateVisibility() }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        if coordinator.presentation.spacing != spacing { coordinator.presentation.spacing = spacing }
        let previous = coordinator.presentation.snapshot
        let old = previous.layout
        let cards = model.displayedCards
        let next = ActivityListLayout(cards:cards,now:Date(),showsTokens:model.showsTokens)
        let oldY = scroll.contentView.bounds.minY
        let viewport = scroll.contentSize
        let structureChanged = next.ids != old.ids || next.headers != old.headers
        let layoutChanged = structureChanged || next.positions != old.positions || next.height != old.height
        let sameCards = structureChanged && Set(next.ids) == Set(old.ids)
        let oldIndices = Dictionary(uniqueKeysWithValues:old.ids.enumerated().map { ($0.element, $0.offset) })
        var groupMoves = Set<ActivityCard.ID>()
        if structureChanged {
            for card in cards {
                if let index = oldIndices[card.id], previous.cards[index].state.group != card.state.group {
                    groupMoves.insert(card.id)
                }
            }
        }
        let anchor = old.positions.lastIndex { $0 <= oldY }.map { old.ids[$0] }
        let keepViewport = sameCards || anchor.map(groupMoves.contains) == true
        let restoredY = keepViewport
            ? min(max(0, oldY), max(0, next.height - viewport.height))
            : next.restore(from: old, offset: oldY, viewport: viewport.height)

        scroll.documentView?.frame = NSRect(
            x: 0, y: 0, width: viewport.width, height: max(viewport.height, next.height)
        )
        if layoutChanged {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: restoredY))
        }
        if cards != previous.cards || next.showsTokens != old.showsTokens {
            let scrollDelta = scroll.contentView.bounds.minY - oldY
            let animateMoves = layoutChanged && !old.ids.isEmpty
            // Keep the starting position in viewport coordinates when AppKit clamps or restores scrolling.
            // Apply the origin immediately to the container and animate each row relative to that origin.
            let animationOrigin = cards.isEmpty ? 0 : previous.animationOrigin + (animateMoves ? scrollDelta : 0)
            var statusTransitions = previous.statusTransitions
            if structureChanged && !sameCards {
                let survivingIDs = Set(next.ids)
                statusTransitions = statusTransitions.filter { survivingIDs.contains($0.key) }
            }
            for (index, card) in cards.enumerated() {
                guard let oldIndex = oldIndices[card.id], previous.cards[oldIndex].state != card.state else { continue }
                let boundary = groupMoves.contains(card.id)
                    ? crossingBoundary(from:oldIndex, in:previous, to:index, layout:next, cards:cards, origin:animationOrigin)
                    : nil
                let phaseTarget = (statusTransitions[card.id]?.phaseTarget ?? 0) + 1
                statusTransitions[card.id] = CardStatusTransition(previous:previous.cards[oldIndex],
                    phaseTarget:phaseTarget, boundary:boundary)
            }
            coordinator.presentation.snapshot = .init(cards: cards, layout: next, animateMoves: animateMoves,
                groupMoves:structureChanged ? groupMoves : previous.groupMoves,
                animationOrigin:animationOrigin, statusTransitions:statusTransitions)
        }
        coordinator.updateVisibility()
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    private func crossingBoundary(from oldIndex: Int, in previous: CardListPresentation.Snapshot,
                                  to index: Int, layout: ActivityListLayout,
                                  cards: [ActivityCard], origin: CGFloat) -> CGFloat? {
        let old = previous.layout
        let start = CGFloat(old.cardTop(at:oldIndex)) - previous.animationOrigin
        let end = CGFloat(layout.cardTop(at:index)) - origin
        guard abs(end - start) > 0.5 else { return nil }
        let heading = end > start
            ? layout.headers.prefix(index + 1).lastIndex { $0 != nil }
            : layout.headers.dropFirst(index + 1).firstIndex { $0 != nil }
        guard let heading else { return nil }
        let group = cards[heading].state.group
        let oldHeading = old.headers.indices.first {
            old.headers[$0] != nil && previous.cards[$0].state.group == group
        }
        let endEdge = CGFloat(layout.positions[heading]) - origin - layout.height(for:cards[index]) / 2
        let startEdge = oldHeading.map {
            CGFloat(old.positions[$0]) - previous.animationOrigin - old.height(for:previous.cards[oldIndex]) / 2
        } ?? endEdge
        // Intersect the card center's path with the heading's path in the viewport.
        let startGap = start - startEdge
        let endGap = end - endEdge
        return startGap * endGap < 0 ? startGap / (startGap - endGap) : nil
    }
}

struct CardList: View {
    private struct Row: Identifiable {
        enum ID: Hashable { case heading(ActivityGroup), card(String) }
        enum Content { case heading(ActivityGroup, String), card(ActivityCard) }

        let content: Content
        let top: CGFloat

        var cardID: ActivityCard.ID? {
            guard case .card(let card) = content else { return nil }
            return card.id
        }

        func stackingOrder(groupMoves: Set<ActivityCard.ID>, animating: Bool) -> Double {
            guard case .card(let card) = content else { return 0 }
            return animating && groupMoves.contains(card.id) ? 2 : 1
        }

        var id: ID {
            switch content {
            case .heading(let group, _): return .heading(group)
            case .card(let card): return .card(card.id)
            }
        }
    }

    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var presentation: CardListPresentation
    let open: (ActivityCard) -> Void
    let runningVerb: (ActivityCard) -> String

    var body: some View {
        let snapshot = presentation.snapshot
        let rows = makeRows(snapshot)
        let motion = PanelMotion.layout.animation(reduceMotion:reduceMotion)
        let spacing = presentation.spacing

        ZStack(alignment: .topLeading) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                let position = row.top - snapshot.animationOrigin
                let transition = row.cardID.flatMap { snapshot.statusTransitions[$0] }
                let phase = transition?.phaseTarget ?? 0
                rowView(row, position:position, transition:transition, spacing:spacing)
                    .padding(.horizontal, ActivityListLayout.horizontalInset)
                    .animation(motion,value:AnimatablePair(position,phase))
                    .transition(.opacity)
                    .zIndex(row.stackingOrder(groupMoves:snapshot.groupMoves, animating:!reduceMotion))
                    .accessibilitySortPriority(Double(rows.count - index))
            }
        }
        .animation(snapshot.animateMoves ? motion : nil,value:rows.map(\.id))
        .offset(y:snapshot.animationOrigin)
        // The document can be taller than its contents. Keep rows anchored to its top.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func makeRows(_ snapshot: CardListPresentation.Snapshot) -> [Row] {
        var rows: [Row] = []
        for (index, card) in snapshot.cards.enumerated() {
            if let heading = snapshot.layout.headers[index] {
                rows.append(Row(content: .heading(card.state.group, heading), top:snapshot.layout.positions[index]))
            }
            rows.append(Row(content: .card(card), top:snapshot.layout.cardTop(at:index)))
        }
        return rows
    }

    @ViewBuilder private func rowView(_ row: Row, position: CGFloat,
                                      transition: CardStatusTransition?, spacing: PanelSpacing) -> some View {
        switch row.content {
        case .heading(_, let title):
            Text(title).font(.system(size:11,weight:.medium)).foregroundStyle(PanelPalette.muted(scheme))
                .padding(.horizontal,spacing.cardInset)
                .frame(maxWidth:.infinity,alignment:.leading)
                .frame(height:ActivityListLayout.headingHeight)
                .accessibilityAddTraits(.isHeader)
                .offset(y:position)
        case .card(let card):
            let layout = presentation.snapshot.layout
            let captionCard = card.state == .running ? card : transition?.previous ?? card
            PositionedCard(card:card,
                           visible:row.top < presentation.visible.maxY &&
                               row.top + layout.height(for:card) > presentation.visible.minY,
                           action:{ open(card) }, spacing:spacing, showsTokens:layout.showsTokens, position:position,
                           statusPhase:transition?.phaseTarget ?? 0,
                           statusTransition:reduceMotion ? nil : transition, runningVerb:runningVerb(captionCard))
        }
    }
}
