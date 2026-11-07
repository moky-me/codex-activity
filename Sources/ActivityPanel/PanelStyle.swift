import AppKit
import SwiftUI
import ActivityCore

struct PanelSpacing: Equatable {
    let cardInset: CGFloat

    init(width: CGFloat) {
        let compact = width > 0 && width < 140
        cardInset = compact ? 6 : 8
    }

    var headerMenuInset: CGFloat { ActivityListLayout.horizontalInset + cardInset - 10 }
}
