import Foundation

/// Known row heights keep native scrolling and card animations in agreement.
public struct ActivityListLayout {
    public let ids:[String]
    public let positions:[Double]
    public let headers:[String?]
    public let height:Double
    public let showsTokens: Bool
    public static let cardHeight=122.0
    public static let tokenRowHeight=20.0
    public static let horizontalInset=9.0
    public static let headingHeight=29.0
    private static let topInset=8.0
    private static let bottomInset=9.0
    private static let cardGap=8.0
    private static let groupGap=12.0
    public init(cards:[ActivityCard],now:Date,showsTokens:Bool = true) {
        self.showsTokens = showsTokens
        ids=cards.map(\.id)
        let counts=Dictionary(grouping:cards,by:{ $0.state.group }).mapValues(\.count)
        var positions:[Double]=[]; var headings:[String?]=[]; var cursor=Self.topInset
        for index in cards.indices {
            let group=cards[index].state.group
            let title:String? = index == 0 || cards[index-1].state.group != group ? "\(group.title) · \(counts[group] ?? 0)" : nil
            if index > 0 { cursor += title == nil ? Self.cardGap : Self.groupGap }
            positions.append(cursor); headings.append(title)
            cursor += Self.cardHeight(for:cards[index],showsTokens:showsTokens)+(title == nil ? 0 : Self.headingHeight)
        }
        self.positions=positions; headers=headings; height=cursor+Self.bottomInset
    }
    public static func cardHeight(for card: ActivityCard, showsTokens: Bool) -> Double {
        cardHeight + (showsTokenRow(for:card,showsTokens:showsTokens) ? tokenRowHeight : 0)
    }

    public static func showsTokenRow(for card: ActivityCard, showsTokens: Bool) -> Bool {
        showsTokens && !card.isChatGPTHosted && (card.tokenUsage != nil || card.state == .running)
    }

    public func height(for card: ActivityCard) -> Double {
        Self.cardHeight(for:card,showsTokens:showsTokens)
    }
    public func cardTop(at index:Int) -> Double {
        positions[index] + (headers[index] == nil ? 0 : Self.headingHeight)
    }
    public func restore(from old:ActivityListLayout,offset:Double,viewport:Double) -> Double {
        guard offset > 1, !old.ids.isEmpty else { return 0 }
        let index=old.positions.lastIndex(where:{ $0 <= offset }) ?? 0
        let candidate=old.ids.indices.dropFirst(index).first(where:{ ids.contains(old.ids[$0]) })
            ?? old.ids.indices.prefix(index).reversed().first(where:{ ids.contains(old.ids[$0]) })
        guard let candidate, let next=ids.firstIndex(of:old.ids[candidate]) else { return min(offset,max(0,height-viewport)) }
        let displacement=offset-old.positions[index]
        return min(max(0,positions[next]+displacement),max(0,height-viewport))
    }
}
