import AppKit
import SwiftUI
import ActivityCore

struct CardView: View {
    private static let statusTravel: CGFloat = 10
    let card: ActivityCard
    let visible: Bool
    let action: () -> Void
    var spacing = PanelSpacing(width:150)
    var showsTokens = true
    var statusProgress: Double = 1
    var previousStatus: ActivityCard? = nil
    var runningVerb = PanelModel.defaultRunningVerb

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme
    @State private var hover = false
    @State private var durationHovered = false
    @State private var tokensHovered = false
    @State private var pulse = false
    @State private var eventTask: Task<Void,Never>?
    @State private var elapsedClock = Date()
    private var runningCaption: String { runningVerb.lowercased() }
    private var title: String { card.title.lowercased() }
    private var project: String { card.project.lowercased() }
    private var summary: String { card.summary.lowercased() }
    private let shape = RoundedRectangle(cornerRadius:9,style:.continuous)
    private static let russian = Locale(identifier:"ru_RU")
    private var settledState: ActivityState {
        statusProgress < 1 ? previousStatus?.state ?? card.state : card.state
    }
    private var status: String { card.state.label }
    private var sourceLabel: String {
        card.source == .work && card.isChatGPTHosted ? "облачный work" : card.source.label
    }
    private static let openHint = "открыть чат в приложении"
    private var age: String { ActivityPolicy.age(card.updatedAt) }
    private var tokenValues: CardTokenRow.Values? {
        guard ActivityListLayout.showsTokenRow(for:card,showsTokens:showsTokens) else { return nil }
        return CardTokenRow.Values(card:card,now:elapsedClock)
    }
    private var cardHeight: CGFloat { ActivityListLayout.cardHeight(for:card,showsTokens:showsTokens) }
    private var timerStart: Date? {
        switch card.state {
        case .running: return card.turnStartedAt
        case .needsInput: return card.waitingSince
        default: return nil
        }
    }
    private func waitingAge(for card: ActivityCard) -> String {
        guard let date = card.waitingSince else { return "—" }
        return ActivityPolicy.age(date, now:elapsedClock, underMinute:"<1 мин")
    }
    private func elapsed(for card: ActivityCard) -> TimeInterval? {
        card.turnStartedAt.map { max(0, elapsedClock.timeIntervalSince($0)) }
    }
    private var timingDescription: String {
        switch card.state {
        case .running:
            return elapsed(for:card).map { "\(runningCaption) \(Self.spokenDuration($0))" } ?? runningCaption
        case .needsInput:
            return "время ожидания: \(waitingAge(for:card))"
        case .completed:
            let duration = card.turnDuration.map { "ход занял \(Self.spokenDuration($0))" }
            let finished = card.turnCompletedAt.map { "завершён \(Self.completionTimestamp($0))" }
            return [duration, finished].compactMap { $0 }.joined(separator:". ")
        default:
            return "последняя активность: \(age)"
        }
    }

    var body: some View {
        let details = timingDescription
        let tokenValues = tokenValues
        let tokens = tokenValues?.details ?? ""
        let canOpen = card.url != nil
        Group {
            if canOpen {
                Button(action:action) { surface(tokenValues:tokenValues) }
                    .buttonStyle(.plain)
                    .accessibilityHint(Self.openHint)
            } else {
                surface(tokenValues:tokenValues)
                    .accessibilityElement(children:.ignore)
                    .accessibilityAddTraits(.isStaticText)
            }
        }
        .onHover { value in
            withAnimation(PanelMotion.feedback.animation(reduceMotion:reduceMotion)) { hover=value && canOpen }
            if !value { durationHovered=false; tokensHovered=false }
        }
        .help([title, "\(sourceLabel) · \(project) · \(status)", details, tokens, summary, canOpen ? Self.openHint : ""]
            .filter { !$0.isEmpty }.joined(separator:"\n"))
        .accessibilityLabel([title, sourceLabel, project, status, details, tokens, summary]
            .filter { !$0.isEmpty }.joined(separator:". "))
        .task(id: visible ? timerStart : nil) {
            guard visible, let start = timerStart else { return }
            while !Task.isCancelled {
                elapsedClock = Date()
                let seconds = max(0, elapsedClock.timeIntervalSince(start))
                do {
                    try await Task.sleep(for:.seconds(60 - seconds.truncatingRemainder(dividingBy:60)))
                } catch {
                    return
                }
            }
        }
        .onChange(of:settledState) { _,state in
            eventTask?.cancel()
            if state != .completed { durationHovered=false }
            guard state == .needsInput, visible, !reduceMotion else { pulse=false; return }
            let motion = PanelMotion.layout.animation(reduceMotion:reduceMotion)
            eventTask=Task { @MainActor in
                withAnimation(motion) { pulse=true }
                try? await Task.sleep(for:.milliseconds(800))
                guard !Task.isCancelled else { return }
                withAnimation(motion) { pulse=false }
            }
        }.onChange(of:visible && !reduceMotion) { _,enabled in
            if !enabled { eventTask?.cancel(); pulse=false }
        }
        .onChange(of:visible) { _,shown in if !shown { durationHovered=false; tokensHovered=false } }
        .onChange(of:tokenValues == nil) { _,missing in if missing { tokensHovered=false } }
        .onDisappear { eventTask?.cancel(); hover=false; pulse=false; durationHovered=false; tokensHovered=false }
    }

    private func surface(tokenValues: CardTokenRow.Values?) -> some View {
        VStack(alignment:.leading,spacing:0) {
            VStack(alignment:.leading,spacing:7) {
                VStack(alignment:.leading,spacing:4) {
                    Text(title).font(.system(size:11.5,weight:.semibold))
                        .foregroundStyle(PanelPalette.ink(scheme)).lineLimit(2)
                        .fixedSize(horizontal:false,vertical:true)
                        .frame(maxWidth:.infinity,alignment:.leading)
                    HStack(spacing:5) {
                        Text(card.source.badge)
                            .font(.system(size:9,weight:.semibold))
                            .frame(width:14,height:14)
                            .background {
                                RoundedRectangle(cornerRadius:3)
                                    .fill(PanelPalette.sourceBadge(scheme))
                                    .shadow(color:.black.opacity(scheme == .dark ? 0.24 : 0.12), radius:1, y:1)
                            }
                            .accessibilityHidden(true)
                        Text(project).font(.system(size:10)).lineLimit(1)
                    }.foregroundStyle(PanelPalette.project(scheme))
                }
                Text(summary).font(.system(size:10.5))
                    .foregroundStyle(PanelPalette.ink(scheme)).lineLimit(2).lineSpacing(1)
                    .fixedSize(horizontal:false,vertical:true)
                    .frame(maxWidth:.infinity,alignment:.leading)
            }
            Spacer(minLength:6)
            statusLayers(travel:Self.statusTravel) { footer(for:$0) }.font(.system(size:10,weight:.medium))
                .accessibilityHidden(true)
            if let tokenValues {
                CardTokenRow(values:tokenValues,visible:visible,hovered:tokensHovered)
                    .frame(height:13)
                    .background { HoverArea { tokensHovered = $0 } }
                    .background { HoverFill(active:tokensHovered).padding(.horizontal,-3).padding(.vertical,-2) }
                    .padding(.top,ActivityListLayout.tokenRowHeight - 13)
                    .accessibilityHidden(true)
                    .transition(.identity)
            }
        }.padding(.horizontal,spacing.cardInset).padding(.vertical,11)
            .frame(height:cardHeight,alignment:.top)
            .frame(maxWidth:.infinity,alignment:.leading)
            .background {
                shape.fill(PanelPalette.card(scheme))
                    .overlay {
                        shape.fill(PanelPalette.cardHover(settledState.group,scheme))
                            .opacity(hover ? 1 : 0)
                    }
            }
            .overlay {
                statusLayers(switching:previousStatus?.state.group != card.state.group) { card in
                    RoundedRectangle(cornerRadius:1)
                        .fill(PanelPalette.statusStripe(card.state.group,scheme,pulsing:pulse))
                        .frame(width:2)
                        .padding(.vertical,9)
                        .frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.trailing)
                }.accessibilityHidden(true).allowsHitTesting(false)
            }
            .overlay(alignment:.bottomLeading) { hoverPreview }
            .contentShape(shape)
    }

    @ViewBuilder private var hoverPreview: some View {
        if tokensHovered, let tokenValues {
            preview(tokenValues.details, bottom:28)
        } else if durationHovered, settledState == .completed, let duration = card.turnDuration {
            let offset = cardHeight - ActivityListLayout.cardHeight
            preview(Self.previewDuration(duration), bottom:28 + offset)
        }
    }

    private func preview(_ text: String, bottom: CGFloat) -> some View {
        Text(text)
            .font(.system(size:10,weight:.medium))
            .foregroundStyle(PanelPalette.ink(scheme))
            .fixedSize(horizontal:false,vertical:true)
            .padding(.horizontal,6).padding(.vertical,4)
            .background(PanelPalette.panel(scheme),in:RoundedRectangle(cornerRadius:5))
            .overlay(RoundedRectangle(cornerRadius:5).strokeBorder(PanelPalette.divider(scheme),lineWidth:1))
            .padding(.horizontal,spacing.cardInset).padding(.bottom,bottom)
            .accessibilityHidden(true)
            .allowsHitTesting(false)
    }

    @ViewBuilder private func statusLayers<Content: View>(
        travel: CGFloat = 0,
        switching: Bool = true,
        @ViewBuilder _ content: (ActivityCard) -> Content
    ) -> some View {
        let progress = switching ? statusProgress : 1
        let outgoing = 1 - progress
        // Keep moving text legible through the middle of the roll.
        let outgoingOpacity = travel == 0 ? outgoing : outgoing.squareRoot()
        let incomingOpacity = travel == 0 ? progress : progress.squareRoot()
        ZStack(alignment:.leading) {
            if let previousStatus, progress < 1 {
                content(previousStatus)
                    .offset(y:-travel * progress)
                    .opacity(outgoingOpacity)
                    .transition(.identity)
            }
            content(card)
                .offset(y:travel * outgoing)
                .opacity(incomingOpacity)
                .transition(.identity)
        }
    }

    @ViewBuilder private func footer(for card: ActivityCard) -> some View {
        let status = card.state.label
        let statusColor = PanelPalette.statusText(card.state,scheme)
        switch card.state {
        case .running:
            ViewThatFits(in:.horizontal) {
                if let seconds = elapsed(for:card) {
                    Text("\(runningCaption) \(Self.compactDuration(seconds))").fixedSize()
                    Text("\(runningCaption) \(Self.shortRunningDuration(seconds))").fixedSize()
                }
                Text(runningCaption).lineLimit(1)
            }.foregroundStyle(statusColor)
        case .completed:
            if card.turnDuration != nil || card.turnCompletedAt != nil {
                ViewThatFits(in:.horizontal) {
                    completedTimes(for:card, shortDate:false)
                    completedTimes(for:card, shortDate:true)
                    completedTimes(for:card, shortDate:true, showSymbols:false)
                }
            } else {
                Text(status).foregroundStyle(statusColor).lineLimit(1)
            }
        default:
            HStack(spacing:0) {
                Text(status).foregroundStyle(statusColor).lineLimit(1)
                Spacer(minLength:6)
                Text(card.state == .needsInput ? waitingAge(for:card) : ActivityPolicy.age(card.updatedAt))
                    .foregroundStyle(PanelPalette.muted(scheme)).lineLimit(1)
                    .fixedSize(horizontal:true,vertical:false)
            }
        }
    }

    private func completedTimes(for card: ActivityCard, shortDate: Bool, showSymbols: Bool = true) -> some View {
        HStack(spacing:0) {
            if let duration = card.turnDuration {
                timeLabel(Self.completedDuration(duration), symbol:showSymbols ? "stopwatch" : nil)
                    .foregroundStyle(PanelPalette.statusText(.completed,scheme))
                    .background { HoverArea { durationHovered=$0 } }
                    .background { HoverFill(active:durationHovered).padding(.horizontal,-3).padding(.vertical,-2) }
            }
            if let date = card.turnCompletedAt {
                Spacer(minLength:card.turnDuration == nil ? 0 : 6)
                timeLabel(Self.completionLabel(date, short:shortDate), symbol:showSymbols ? "flag.checkered" : nil)
                    .foregroundStyle(PanelPalette.muted(scheme))
                    .layoutPriority(1)
                    .help("завершён \(Self.completionTimestamp(date))")
            }
        }
    }

    private func timeLabel(_ value: String, symbol: String?) -> some View {
        HStack(spacing:metadataIconGap) {
            if let symbol { Image(systemName:symbol).symbolRenderingMode(.monochrome).accessibilityHidden(true) }
            Text(value).lineLimit(1)
        }.fixedSize(horizontal:symbol != nil,vertical:false)
    }

    static func completedDuration(_ seconds: TimeInterval) -> String {
        guard seconds >= 3600 else { return compactDuration(seconds) }
        guard let hours = Int(exactly:(seconds / 3600).rounded(.down)) else { return "—" }
        return "\(hours) ч"
    }

    static func compactDuration(_ seconds: TimeInterval) -> String {
        guard let minutes = Int(exactly:(seconds / 60).rounded(.down)) else { return "—" }
        guard seconds >= 60 else { return "<1 мин" }
        let hours = minutes / 60
        let days = hours / 24
        if days > 0 {
            let remainder = hours % 24
            return remainder == 0 ? "\(days) д" : "\(days) д \(remainder) ч"
        }
        if hours > 0 {
            let remainder = minutes % 60
            return remainder == 0 ? "\(hours) ч" : "\(hours) ч \(remainder) мин"
        }
        return "\(minutes) мин"
    }

    static func shortRunningDuration(_ seconds: TimeInterval) -> String {
        let unit: TimeInterval = seconds >= 86_400 ? 86_400 : 3_600
        let shortened = seconds < unit ? seconds : (seconds / unit).rounded(.down) * unit
        return compactDuration(shortened)
    }

    static func completionLabel(_ date: Date, short: Bool = false, now: Date = Date(),
                                calendar: Calendar = .current) -> String {
        let style = Date.FormatStyle(date:.omitted, time:.omitted, locale:russian,
                                     calendar:calendar, timeZone:calendar.timeZone)
        if calendar.isDate(date, inSameDayAs:now) {
            return style.hour(.twoDigits(amPM:.omitted)).minute(.twoDigits).format(date)
        }
        let sameYear = calendar.isDate(date, equalTo:now, toGranularity:.year)
        let dateStyle = style.day(short || !sameYear ? .twoDigits : .defaultDigits)
            .month(short || !sameYear ? .twoDigits : .abbreviated)
        return (sameYear ? dateStyle : dateStyle.year(.twoDigits)).format(date)
    }

    private static func completionTimestamp(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.wide).year()
            .hour(.twoDigits(amPM:.omitted)).minute(.twoDigits).second(.twoDigits).locale(Self.russian))
    }

    static func spokenDuration(_ seconds: TimeInterval) -> String {
        formattedDuration(seconds,units:[.day,.hour,.minute,.second],style:.full)
    }

    private static func previewDuration(_ seconds: TimeInterval) -> String {
        guard seconds >= 60 else { return "<1 мин" }
        let wholeMinutes = (seconds / 60).rounded(.down)
        return formattedDuration(wholeMinutes * 60,units:[.day,.hour,.minute],style:.abbreviated)
    }

    private static func formattedDuration(_ seconds: TimeInterval, units: NSCalendar.Unit,
                                          style: DateComponentsFormatter.UnitsStyle) -> String {
        let formatter = DateComponentsFormatter()
        var calendar = Calendar.current
        calendar.locale = russian
        formatter.calendar = calendar
        formatter.allowedUnits = units
        formatter.unitsStyle = style
        formatter.zeroFormattingBehavior = .dropAll
        return formatter.string(from:seconds.rounded(.down)) ?? compactDuration(seconds)
    }
}
