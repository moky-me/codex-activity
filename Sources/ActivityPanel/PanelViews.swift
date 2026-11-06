import AppKit
import SwiftUI
import ActivityCore
import ServiceManagement

private let metadataIconGap: CGFloat = 4

struct PanelView: View {
    private enum ContentState { case loading, empty, list }

    @ObservedObject var model: PanelModel
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var menuHovered = false
    @State private var menuOpen = false
    private let headerTop: CGFloat = 9
    private let menuSize = CGSize(width: 28, height: 26)
    var body: some View {
        GeometryReader { geometry in
            panelBody(spacing:PanelSpacing(width:geometry.size.width))
        }
    }

    private func panelBody(spacing: PanelSpacing) -> some View {
        let headerInset = spacing.contentInset
        return VStack(spacing:0) {
            ZStack(alignment:.topTrailing) {
                VStack(alignment:.leading,spacing:3) {
                    HStack(spacing:4) {
                        Text("codex").foregroundStyle(PanelPalette.ink(scheme)).font(.system(size:14,weight:.semibold))
                            .accessibilityAddTraits(.isHeader)
                        headerDot
                    }.frame(height:menuSize.height)
                    ViewThatFits(in:.horizontal) {
                        Text("наблюдение · \(periodValue)").fixedSize(horizontal:true,vertical:false)
                        Text("период · \(periodValue)")
                    }.font(.system(size:11,weight:.medium)).foregroundStyle(PanelPalette.muted(scheme))
                        .lineLimit(1)
                        .accessibilityLabel("наблюдение: \(model.period.label.lowercased())")
                }.frame(maxWidth:.infinity,alignment:.leading)
                    .padding(.horizontal,headerInset).padding(.top,headerTop).padding(.bottom,8)
                    .overlay { HeaderDrag().accessibilityHidden(true) }
                PanelMenu(model: model, isOpen: $menuOpen, showAbout: showAbout)
                    .frame(width: menuSize.width, height: menuSize.height)
                    .background { HoverArea { menuHovered = $0 } }
                    .background { HoverFill(active: menuHovered || menuOpen, pressed: menuOpen).padding(1) }
                    .padding(.trailing,8).padding(.top,headerTop)
            }
            Rectangle().fill(PanelPalette.divider(scheme)).frame(height:1).padding(.horizontal,headerInset)
                .accessibilityHidden(true)
            ZStack { content(spacing:spacing) }
                .animation(PanelMotion.feedback.animation(reduceMotion:reduceMotion),value:contentState)
            VStack(spacing:0) {
                if let notice {
                    Button {
                        let alert = NSAlert()
                        alert.messageText = "codex activity community"
                        alert.informativeText = notice
                        alert.addButton(withTitle: "закрыть")
                        alert.runModal()
                    } label: {
                        Label("есть уведомление",systemImage:"exclamationmark.circle").font(.system(size:9)).foregroundStyle(PanelPalette.statusText(.needsInput,scheme)).lineLimit(1)
                    }.buttonStyle(.plain).padding(.horizontal,8).padding(.vertical,7).help(notice)
                        .accessibilityHint("показать подробности")
                        .transition(.opacity)
                }
            }.animation(PanelMotion.feedback.animation(reduceMotion:reduceMotion),value:notice != nil)
        }
        .background(PanelPalette.panel(scheme),in:RoundedRectangle(cornerRadius:14,style:.continuous))
        .overlay(RoundedRectangle(cornerRadius:14,style:.continuous).strokeBorder(.primary.opacity(0.09),lineWidth:0.5))
        .clipShape(RoundedRectangle(cornerRadius:14,style:.continuous))
    }

    private var headerDot: some View {
        let dot = Circle().fill(PanelPalette.headerAccent(scheme))
        return Group {
            if !reduceMotion && model.displayedCards.contains(where: { $0.state == .running }) {
                dot.phaseAnimator([1.0, 0.5]) { content, opacity in
                    content.opacity(opacity)
                } animation: { _ in
                    .easeInOut(duration:2.5)
                }
            } else {
                dot
            }
        }
        .frame(width:4.5,height:4.5)
        .offset(y:1)
        .accessibilityHidden(true)
    }

    private var notice: String? { model.noticeDetails }
    private var periodValue: String { model.period == .unlimited ? "∞" : "\(model.period.rawValue) ч." }

    private var contentState: ContentState {
        if model.loading { return .loading }
        return model.displayedCards.isEmpty ? .empty : .list
    }

    @ViewBuilder private func content(spacing: PanelSpacing) -> some View {
        switch contentState {
        case .loading:
            VStack(spacing:10) { ProgressView().controlSize(.small); Text("читаю чаты…").font(.system(size:10)).foregroundStyle(PanelPalette.muted(scheme)) }
                .frame(maxWidth:.infinity,maxHeight:.infinity)
                .transition(.opacity)
        case .empty:
            VStack(spacing:10) {
                Image(systemName:model.notice == nil ? "moon.zzz" : "exclamationmark.icloud").font(.system(size:20,weight:.ultraLight)).foregroundStyle(PanelPalette.muted(scheme))
                    .accessibilityHidden(true)
                Text(model.notice == nil ? "сейчас тихо" : "данные недоступны").foregroundStyle(PanelPalette.ink(scheme)).font(.system(size:11,weight:.medium))
                Text(model.notice == nil ? emptyDescription : "не удалось прочитать\nчаты codex. повторим\nавтоматически.").font(.system(size:10)).foregroundStyle(PanelPalette.muted(scheme)).multilineTextAlignment(.center)
            }.frame(maxWidth:.infinity,maxHeight:.infinity)
                .transition(.opacity)
        case .list:
            NativeCardScroll(model:model,spacing:spacing).transition(.opacity)
        }
    }

    private var emptyDescription: String {
        model.period == .unlimited
            ? "здесь появятся ваши\nнеархивированные чаты."
            : "здесь появятся чаты\nза последние \(model.period.label)\nи ожидающие ответа."
    }
    private func showAbout() {
        let alert = NSAlert()
        alert.messageText = "codex activity community"
        let version = Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey:"CFBundleVersion") as? String
        let versionInfo = version.map { "версия \($0)" + (build.map { " · сборка \($0)" } ?? "") }
        alert.informativeText = [
            "панель чатов codex · \(model.period.label)",
            "нажмите карточку, чтобы открыть чат codex или локального work. перетаскивайте окно за шапку. двойной щелчок разворачивает или восстанавливает окно.",
            "запросы, ожидающие ответа, видны независимо от периода. удалённые статусы появляются, когда codex передаёт состояние чата.",
            versionInfo
        ].compactMap { $0 }.joined(separator:"\n\n")
        alert.addButton(withTitle: "закрыть")
        alert.runModal()
    }
}

/// An AppKit button owns the full hit area and opens a native menu.
private struct PanelMenu: NSViewRepresentable {
    let model: PanelModel
    @Binding var isOpen: Bool
    let showAbout: () -> Void

    final class Coordinator: NSObject {
        enum Action {
            case period(ActivityPeriod), toggleCloudChats, toggleTokens, toggleAutostart, loginSettings, about, close
        }

        var model: PanelModel
        var isOpen: Binding<Bool>
        var showAbout: () -> Void

        init(model: PanelModel, isOpen: Binding<Bool>, showAbout: @escaping () -> Void) {
            self.model = model
            self.isOpen = isOpen
            self.showAbout = showAbout
        }

        @objc func showMenu(_ sender: NSButton) {
            let menu = NSMenu()
            menu.autoenablesItems = false
            let periods = NSMenu(title: "период отслеживания")
            periods.autoenablesItems = false
            for period in ActivityPeriod.allCases {
                let option = item(period.label, action: .period(period))
                option.state = period == model.period ? .on : .off
                periods.addItem(option)
            }
            let periodMenu = NSMenuItem(title: periods.title, action: nil, keyEquivalent: "")
            periodMenu.submenu = periods
            menu.addItem(periodMenu)
            menu.addItem(.separator())
            let cloudChats = item("показывать облачные чаты", action: .toggleCloudChats)
            cloudChats.state = model.showsCloudChats ? .on : .off
            menu.addItem(cloudChats)
            let tokens = item("показать токены", action: .toggleTokens)
            tokens.state = model.showsTokens ? .on : .off
            menu.addItem(tokens)
            if let panel = sender.window as? ActivityWindow {
                menu.addItem(panel.allSpacesMenuItem())
            }
            let autostart = item("запускать вместе с codex", action: .toggleAutostart)
            autostart.state = model.launchEnabled ? .on : .off
            autostart.isEnabled = !model.launchChanging
            menu.addItem(autostart)
            if model.launchNeedsApproval {
                menu.addItem(item("разрешить в настройках macos…", action: .loginSettings))
            }
            menu.addItem(.separator())
            menu.addItem(item("о панели…", action: .about))
            let close = item("закрыть панель", action: .close)
            close.keyEquivalent = "q"
            menu.addItem(close)
            let y = sender.isFlipped ? sender.bounds.maxY : sender.bounds.minY
            isOpen.wrappedValue = true
            defer { isOpen.wrappedValue = false }
            menu.popUp(positioning: nil, at: NSPoint(x: sender.bounds.minX, y: y), in: sender)
        }

        private func item(_ title: String, action: Action) -> NSMenuItem {
            let result = NSMenuItem(title: title, action: #selector(performAction(_:)), keyEquivalent: "")
            result.target = self
            result.representedObject = action
            return result
        }

        @objc private func performAction(_ sender: NSMenuItem) {
            guard let action = sender.representedObject as? Action else { return }
            switch action {
            case .period(let period):
                model.setPeriod(period)
            case .toggleCloudChats:
                model.setShowsCloudChats(!model.showsCloudChats)
            case .toggleTokens:
                model.setShowsTokens(!model.showsTokens)
            case .toggleAutostart:
                let enable = !model.launchEnabled
                Task { @MainActor in await model.configureLoginItem(enable: enable) }
            case .loginSettings:
                SMAppService.openSystemSettingsLoginItems()
            case .about:
                showAbout()
            case .close:
                NSApp.terminate(nil)
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(model: model, isOpen: $isOpen, showAbout: showAbout) }

    func makeNSView(context: Context) -> NSView {
        // NSButton's alignment rectangle differs from its clickable frame.
        // Size the container in SwiftUI and give the button its exact bounds.
        let container = NSView()
        let button = NSButton()
        button.isBordered = false
        button.imagePosition = .imageOnly
        let configuration = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        button.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        button.toolTip = "настройки панели"
        button.setAccessibilityLabel("настройки панели")
        button.target = context.coordinator
        button.action = #selector(Coordinator.showMenu(_:))
        button.frame = container.bounds
        button.autoresizingMask = [.width, .height]
        container.addSubview(button)
        return container
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.model = model
        context.coordinator.isOpen = $isOpen
        context.coordinator.showAbout = showAbout
    }
}

private struct HeaderDrag: NSViewRepresentable {
    final class DragView: NSView {
        private var mouseDownEvent: NSEvent?

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            mouseDownEvent = event
        }

        override func mouseDragged(with event: NSEvent) {
            guard let start = mouseDownEvent else { return }
            let dx = event.locationInWindow.x - start.locationInWindow.x
            let dy = event.locationInWindow.y - start.locationInWindow.y
            guard hypot(dx, dy) >= 3 else { return }
            // Hand the original press to AppKit only after a real drag begins.
            mouseDownEvent = nil
            window?.performDrag(with: start)
        }

        override func mouseUp(with event: NSEvent) {
            let clickCount = mouseDownEvent?.clickCount
            mouseDownEvent = nil
            if clickCount == 2 { window?.zoom(nil) }
        }
    }
    func makeNSView(context:Context) -> DragView { DragView() }
    func updateNSView(_ view:DragView,context:Context) {}
}

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

private struct HoverArea: NSViewRepresentable {
    let changed: (Bool) -> Void

    final class TrackingView: NSView {
        var changed: ((Bool) -> Void)?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func mouseEntered(with event: NSEvent) { changed?(true) }
        override func mouseExited(with event: NSEvent) { changed?(false) }
    }

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.addTrackingArea(NSTrackingArea(rect:.zero,
            options:[.mouseEnteredAndExited,.activeAlways,.inVisibleRect],owner:view,userInfo:nil))
        return view
    }

    func updateNSView(_ view: TrackingView, context: Context) {
        view.changed = changed
    }
}

private struct HoverFill: View {
    let active: Bool
    var pressed = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        RoundedRectangle(cornerRadius:5,style:.continuous)
            .fill(pressed ? PanelPalette.controlPressed(scheme) : PanelPalette.controlHover(scheme))
            .opacity(active ? 1 : 0)
            .animation(PanelMotion.feedback.animation(reduceMotion:reduceMotion),value:active)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

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
        .help([card.title, "\(sourceLabel) · \(card.project) · \(status)", details, tokens, card.summary, canOpen ? Self.openHint : ""]
            .filter { !$0.isEmpty }.joined(separator:"\n"))
        .accessibilityLabel([card.title, sourceLabel, card.project, status, details, tokens, card.summary]
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
                VStack(alignment:.leading,spacing:2) {
                    Text(card.title).font(.system(size:11.5,weight:.semibold))
                        .foregroundStyle(PanelPalette.ink(scheme)).lineLimit(2)
                        .fixedSize(horizontal:false,vertical:true)
                        .frame(maxWidth:.infinity,alignment:.leading)
                    HStack(spacing:5) {
                        Text(card.source.badge)
                            .font(.system(size:9,weight:.semibold))
                            .frame(width:14,height:14)
                            .background(PanelPalette.sourceBadge(scheme),in:RoundedRectangle(cornerRadius:3))
                            .accessibilityHidden(true)
                        Text(card.project).font(.system(size:10)).lineLimit(1)
                    }.foregroundStyle(PanelPalette.project(scheme))
                }
                Text(card.summary).font(.system(size:10.5))
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
