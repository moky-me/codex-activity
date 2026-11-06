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
