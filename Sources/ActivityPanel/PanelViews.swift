import ActivityPanelStyle
import AppKit
import SwiftUI
import ActivityCore
import ServiceManagement

struct PanelView: View {
    private enum ContentState { case loading, empty, list }

    @ObservedObject var model: PanelModel
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var menuHovered = false
    @State private var menuOpen = false
    @State private var periodHovered = false
    @State private var periodOpen = false
    private let headerTop: CGFloat = 8
    private let titleRowHeight: CGFloat = 22
    private let menuSize = CGSize(width: 28, height: 26)

    var body: some View {
        GeometryReader { geometry in
            panelBody(spacing:PanelSpacing(width:geometry.size.width))
        }
    }

    private func panelBody(spacing: PanelSpacing) -> some View {
        let listInset = ActivityListLayout.horizontalInset
        return VStack(spacing:0) {
            ZStack(alignment:.topTrailing) {
                VStack(alignment:.leading,spacing:2) {
                    HStack(spacing:6) {
                        Text("панелька").foregroundStyle(PanelPalette.ink(scheme)).font(.system(size:14,weight:.semibold))
                            .accessibilityAddTraits(.isHeader)
                        headerDot
                    }
                    .frame(maxWidth:.infinity,alignment:.leading)
                    .frame(height:titleRowHeight)
                    .padding(.horizontal,listInset).padding(.top,headerTop)
                    .overlay { HeaderDrag().accessibilityHidden(true) }
                    periodControl.padding(.horizontal,listInset)
                }.frame(maxWidth:.infinity,alignment:.leading)
                    .padding(.bottom,7)
                PanelMenu(model: model, isOpen: $menuOpen, showAbout: showAbout)
                    .frame(width: menuSize.width, height: menuSize.height)
                    .background { HoverArea { menuHovered = $0 } }
                    .background { HoverFill(active: menuHovered || menuOpen, pressed: menuOpen).padding(1) }
                    .padding(.trailing,spacing.headerMenuInset)
                    .padding(.top,headerTop + (titleRowHeight - menuSize.height) / 2)
            }
            sectionDivider
                .padding(.horizontal,listInset)
            ZStack { content(spacing:spacing) }
                .animation(PanelMotion.feedback.animation(reduceMotion:reduceMotion),value:contentState)
            VStack(spacing:0) {
                if let notice {
                    Button {
                        let alert = NSAlert()
                        alert.messageText = "codex activity"
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

    private var sectionDivider: some View {
        Rectangle().fill(PanelPalette.divider(scheme)).frame(height: 1)
            .accessibilityHidden(true)
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

    private var periodControl: some View {
        ViewThatFits(in:.horizontal) {
            periodLabel("наблюдение")
            periodLabel("период")
        }
        .frame(height:20)
        .accessibilityHidden(true)
        .background { HoverFill(active:periodHovered || periodOpen, pressed:periodOpen).padding(.horizontal,-3) }
        .background { HoverArea { periodHovered = $0 } }
        .overlay { PeriodMenuButton(selection:model.period, isOpen:$periodOpen, select:model.setPeriod) }
    }

    private func periodLabel(_ title: String) -> some View {
        Text("\(title) · \(Text(periodValue).fontWeight(.medium).monospacedDigit())")
            .font(.system(size:11))
            .foregroundStyle(periodOpen ? PanelPalette.ink(scheme) : PanelPalette.muted(scheme))
            .lineLimit(1)
            .fixedSize(horizontal:true,vertical:false)
    }

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
        let alert=NSAlert(); alert.messageText="codex activity community"
        let version = Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey:"CFBundleVersion") as? String
        let versionInfo = version.map { "версия \($0)" + (build.map { " · сборка \($0)" } ?? "") }
        alert.informativeText = [
            "панель чатов codex · \(model.period.label)",
            "нажмите карточку, чтобы открыть чат. перетаскивайте окно за шапку. двойной щелчок по шапке разворачивает или восстанавливает окно.",
            "запросы, ожидающие ответа, видны независимо от периода. удалённые статусы появляются, когда codex передаёт состояние чата.",
            versionInfo
        ].compactMap { $0 }.joined(separator:"\n\n")
        alert.addButton(withTitle: "закрыть")
        alert.runModal()
    }
}

private struct PeriodMenuButton: NSViewRepresentable {
    let selection: ActivityPeriod
    @Binding var isOpen: Bool
    let select: (ActivityPeriod) -> Void

    final class Coordinator: NSObject {
        var control: PeriodMenuButton

        init(_ control: PeriodMenuButton) { self.control = control }

        @objc func showMenu(_ sender: NSButton) {
            let menu = NSMenu(title:"период наблюдения")
            menu.autoenablesItems = false
            for period in ActivityPeriod.allCases {
                let item = NSMenuItem(title:period.label, action:#selector(choose(_:)), keyEquivalent:"")
                item.target = self
                item.representedObject = period
                item.state = period == control.selection ? .on : .off
                menu.addItem(item)
            }
            control.isOpen = true
            defer { control.isOpen = false }
            let y = sender.isFlipped ? sender.bounds.maxY : sender.bounds.minY
            menu.popUp(positioning:nil, at:NSPoint(x:sender.bounds.minX,y:y), in:sender)
        }

        @objc private func choose(_ sender: NSMenuItem) {
            if let period = sender.representedObject as? ActivityPeriod { control.select(period) }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        let button = NSButton()
        button.title = ""
        button.isBordered = false
        button.target = context.coordinator
        button.action = #selector(Coordinator.showMenu(_:))
        button.toolTip = "изменить период наблюдения"
        button.setAccessibilityLabel("период наблюдения")
        button.frame = container.bounds
        button.autoresizingMask = [.width, .height]
        container.addSubview(button)
        return container
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.control = self
        (view.subviews.first as? NSButton)?.setAccessibilityValue(selection.label)
    }
}

/// An AppKit button owns the full hit area and opens a native menu.
private struct PanelMenu: NSViewRepresentable {
    let model: PanelModel
    @Binding var isOpen: Bool
    let showAbout: () -> Void

    final class Coordinator: NSObject {
        enum Action {
            case toggleCloudChats, toggleTokens
            case toggleAutostart, loginSettings, about, close
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
            let cloudChats = item("показывать облачные чаты", action: .toggleCloudChats)
            cloudChats.state = model.showsCloudChats ? .on : .off
            menu.addItem(cloudChats)
            let tokens = item("показать токены", action: .toggleTokens)
            tokens.state = model.showsTokens ? .on : .off
            menu.addItem(tokens)
            if let panel = sender.window as? ActivityWindow {
                menu.addItem(panel.aboveNormalWindowsMenuItem())
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
