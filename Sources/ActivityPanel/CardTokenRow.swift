import ActivityPanelStyle
import SwiftUI
import ActivityCore

struct CardTokenRow: View {
    enum Value: Equatable {
        case count(Int64), waiting, unavailable

        init(_ count: Int64?, waiting: Bool) {
            if let count { self = .count(count) }
            else { self = waiting ? .waiting : .unavailable }
        }

        var detail: String {
            switch self {
            case .count(let count): return count.formatted(.number.locale(CardTokenRow.locale))
            case .waiting: return "ожидаются данные"
            case .unavailable: return "нет данных"
            }
        }
    }

    struct Values: Equatable {
        let turn: Value
        let chat: Value

        init(card: ActivityCard, now: Date) {
            let isStarting = card.state == .running &&
                card.turnStartedAt.map { (0..<60).contains(now.timeIntervalSince($0)) } == true
            turn = Value(card.tokenUsage?.turn, waiting:isStarting && card.hostID == "local")
            chat = Value(card.tokenUsage?.chat, waiting:isStarting)
        }

        var isWaiting: Bool { turn == .waiting || chat == .waiting }
        var details: String { "токены\nза ход: \(turn.detail)\nза чат: \(chat.detail)" }
    }

    let values: Values
    let visible: Bool
    let hovered: Bool
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var waitingSince = Date.now
    private static let locale = Locale(identifier: "ru_RU")
    private var turnColor: Color { hovered ? PanelPalette.muted(scheme) : PanelPalette.project(scheme) }
    private var totalColor: Color { hovered ? PanelPalette.project(scheme) : PanelPalette.tokenTotal(scheme) }

    var body: some View {
        Group {
            if values.isWaiting && visible && !reduceMotion {
                TimelineView(.animation(minimumInterval:1.0 / 30)) { context in
                    fittedLine(elapsed:context.date.timeIntervalSince(waitingSince))
                }
            } else {
                fittedLine(elapsed:nil)
            }
        }
        .onChange(of:values.isWaiting,initial:true) { _, waiting in
            if waiting { waitingSince = .now }
        }
    }

    private func fittedLine(elapsed: TimeInterval?) -> some View {
        ViewThatFits(in: .horizontal) {
            line(turnDigits:1,chatDigits:1,elapsed:elapsed).fixedSize()
            line(turnDigits:0,chatDigits:1,elapsed:elapsed).fixedSize()
            line(turnDigits:0,chatDigits:0,elapsed:elapsed).fixedSize()
            line(turnDigits:0,chatDigits:0,elapsed:elapsed,icon:false)
        }
        .font(.system(size: 10))
        .monospacedDigit()
        .foregroundStyle(totalColor)
        .lineLimit(1)
    }

    private func line(turnDigits: Int, chatDigits: Int, elapsed: TimeInterval?, icon: Bool = true) -> some View {
        HStack(spacing: icon ? 3 : 1) {
            HStack(spacing: values.turn == .waiting ? 5 : metadataIconGap) {
                if icon {
                    Image(systemName: "square.3.layers.3d")
                        .symbolRenderingMode(.monochrome)
                        .frame(width: 11)
                }
                value(values.turn,digits:turnDigits,color:turnColor,elapsed:elapsed)
            }
            Text("/")
            value(values.chat,digits:chatDigits,color:totalColor,elapsed:elapsed)
        }
    }

    @ViewBuilder private func value(_ value: Value, digits: Int, color: Color, elapsed: TimeInterval?) -> some View {
        switch value {
        case .count(let count): Text(Self.compact(count,digits:digits)).foregroundStyle(color)
        case .waiting: TokenPixels(color:color,elapsed:elapsed)
        case .unavailable: Text("—").foregroundStyle(color)
        }
    }

    static func compact(_ count: Int64?, digits: Int) -> String {
        guard let count, count >= 0 else { return "—" }
        let units: [(scale: Int64, suffix: String)] = [(1_000, "тыс"), (1_000_000, "млн"), (1_000_000_000, "млрд")]
        guard let index = units.lastIndex(where: { count >= $0.scale }) else { return String(count) }
        let unit = units[index]
        let value = Double(count) / Double(unit.scale)
        let decimals = value < 100 ? digits : 0
        let factor = decimals == 0 ? 1.0 : 10.0
        let rounded = (value * factor).rounded() / factor
        if rounded >= 1_000, index + 1 < units.count { return "1\u{00A0}\(units[index + 1].suffix)" }
        return rounded.formatted(.number.grouping(.never).precision(.fractionLength(0...decimals)).locale(locale))
            + "\u{00A0}" + unit.suffix
    }
}

private struct TokenPixels: View {
    let color: Color
    let elapsed: TimeInterval?

    // The dimmed square moves between neighbors, including on the return to the first square.
    private static let steps = [0,1,2,3, 11,8,7,4, 10,9,6,5]
    private static let side: CGFloat = 1.5

    var body: some View {
        Canvas { context, _ in
            let dimmed = elapsed.flatMap { time in
                time >= 0.55 ? Int((time - 0.55) / 0.18) % Self.steps.count : nil
            }
            for (index, step) in Self.steps.enumerated() {
                let progress = elapsed.map { min(1,max(0,($0 - Double(step) * 0.018) / 0.34)) } ?? 1
                let spread = CGFloat(1 - progress * progress * (3 - 2 * progress))
                let column = index % 4
                let row = index / 4
                let horizontalShift: CGFloat = switch column {
                case 0: -1.5
                case 3: 1.5
                default: 0
                }
                let x = CGFloat(column) * 3 + horizontalShift * spread
                let y = CGFloat(row) * 2.5 + CGFloat(row - 1) * 1.5 * spread
                let opacity: Double
                if dimmed == step { opacity = 0.15 }
                else if elapsed == nil && index == Self.steps.count - 1 { opacity = 0.45 }
                else { opacity = progress }
                let rect = CGRect(x:x,y:y,width:Self.side,height:Self.side)
                context.fill(Path(rect),with:.color(color.opacity(opacity)))
            }
        }
        .frame(width:10.5,height:6.5)
    }
}

/// Snapshot geometry is shared by SwiftUI placement and AppKit scrolling.
