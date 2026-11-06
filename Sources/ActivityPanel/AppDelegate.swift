import AppKit
import SwiftUI
import CoreGraphics
import ServiceManagement

final class ActivityWindow: NSPanel {
    private static let allSpacesPreference = "showOnAllSpaces"

    override init(contentRect: NSRect, styleMask: NSWindow.StyleMask,
                  backing: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect:contentRect, styleMask:styleMask, backing:backing, defer:flag)
        allowsToolTipsWhenApplicationIsInactive = true
        level = .normal
        applySpaces(UserDefaults.standard.object(forKey: Self.allSpacesPreference) as? Bool ?? true)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func allSpacesMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "на всех рабочих столах", action: #selector(toggleAllSpaces(_:)), keyEquivalent: "")
        item.target = self
        item.state = collectionBehavior.contains(.canJoinAllSpaces) ? .on : .off
        return item
    }

    @objc private func toggleAllSpaces(_ sender: NSMenuItem) {
        let enabled = !collectionBehavior.contains(.canJoinAllSpaces)
        applySpaces(enabled)
        UserDefaults.standard.set(enabled, forKey: Self.allSpacesPreference)
        sender.state = enabled ? .on : .off
    }

    private func applySpaces(_ allSpaces: Bool) {
        collectionBehavior = [.fullScreenAuxiliary, allSpaces ? .canJoinAllSpaces : .managed]
    }

    static func width(screenWidth: CGFloat, physicalWidth: CGFloat, targetMM: CGFloat) -> CGFloat {
        // Use the same share of a narrower display, with a readable minimum in AppKit points.
        let referenceWidthMM: CGFloat = 344
        let target: CGFloat
        if physicalWidth.isFinite && physicalWidth > 0 {
            target = screenWidth / max(physicalWidth, referenceWidthMM) * targetMM
        } else {
            target = min(150, screenWidth / referenceWidthMM * targetMM)
        }
        return max(124, floor(target))
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let screenMargin: CGFloat = 10
    let model=PanelModel()
    var panel: ActivityWindow!
    var observers: [NSObjectProtocol] = []
    var placing=false
    func applicationDidFinishLaunching(_ notification:Notification) {
        if CommandLine.arguments.contains("--login-status") {
            print("Login item status: \(SMAppService.loginItem(identifier:AppIdentity.launcher).status.rawValue)")
            NSApp.terminate(nil); return
        }
        if CommandLine.arguments.contains("--unregister") || CommandLine.arguments.contains("--register") {
            Task { @MainActor in
                await model.configureLoginItem(enable:CommandLine.arguments.contains("--register"))
                print("Login item status: \(SMAppService.loginItem(identifier:AppIdentity.launcher).status.rawValue)")
                if let notice=model.launchNotice { print(notice) }
                NSApp.terminate(nil)
            }
            return
        }
        guard !NSRunningApplication.runningApplications(withBundleIdentifier:AppIdentity.codex).isEmpty else { NSApp.terminate(nil); return }
        NSApp.setActivationPolicy(.accessory)
        panel=ActivityWindow(contentRect:NSRect(x:0,y:0,width:140,height:620),styleMask:[.borderless,.nonactivatingPanel,.resizable],backing:.buffered,defer:false)
        panel.title="codex activity community"; panel.identifier=NSUserInterfaceItemIdentifier("CodexActivityPanel")
        panel.isOpaque=false; panel.backgroundColor = .clear; panel.hasShadow=true
        panel.hidesOnDeactivate=false
        panel.isMovableByWindowBackground=false; panel.delegate=self
        panel.becomesKeyOnlyIfNeeded = true
        let host=NSHostingView(rootView:PanelView(model:model)); host.sizingOptions=[]
        panel.contentView=host
        placePanel(restoreFrame:true); panel.orderFrontRegardless()
        model.start()
        let wanted=UserDefaults.standard.object(forKey:"autostartWanted") as? Bool ?? true
        if !CommandLine.arguments.contains("--no-register") { Task { @MainActor in await model.configureLoginItem(enable:wanted) } }
        observers.append(NotificationCenter.default.addObserver(forName:NSApplication.didBecomeActiveNotification,object:nil,queue:.main) { [weak self] _ in self?.model.updateLoginStatus() })
        let workspace=NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(forName:NSWorkspace.didTerminateApplicationNotification,object:nil,queue:.main) { note in
            guard let app=note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication, app.bundleIdentifier == AppIdentity.codex else { return }
            if NSRunningApplication.runningApplications(withBundleIdentifier:AppIdentity.codex).isEmpty { NSApp.terminate(nil) }
        })
        observers.append(NotificationCenter.default.addObserver(forName:NSApplication.didChangeScreenParametersNotification,object:nil,queue:.main) { [weak self] _ in self?.placePanel() })
        observers.append(workspace.addObserver(forName:NSWorkspace.didWakeNotification,object:nil,queue:.main) { [weak self] _ in self?.model.refresh(force:true) })
    }
    func placePanel(restoreFrame: Bool = false) {
        guard let panel else { return }
        let saved = restoreFrame ? UserDefaults.standard.string(forKey:"frame").map(NSRectFromString) : nil
        let savedScreen = saved.flatMap { frame in
            NSScreen.screens.first { $0.frame.contains(NSPoint(x:frame.midX,y:frame.midY)) }
        }
        guard let screen = savedScreen ?? panel.screen ?? NSScreen.main else { return }
        placing=true; defer { placing=false }
        let screenID=(screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
        let mm=CGDisplayScreenSize(screenID).width
        let width=ActivityWindow.width(screenWidth:screen.frame.width,physicalWidth:mm,targetMM:model.widthMM)
        let visible = screen.visibleFrame
        panel.minSize = NSSize(width: width, height: min(260, visible.height))
        panel.maxSize = NSSize(width: width, height: visible.height)
        var frame=saved ?? panel.frame
        frame.size.width=width; frame.size.height=min(visible.height,max(260,frame.height))
        if restoreFrame && saved == nil {
            frame.origin.x=visible.maxX-width-screenMargin
            frame.origin.y=visible.midY-frame.height/2
        }
        frame.origin.x=min(max(frame.minX,visible.minX),visible.maxX-width)
        frame.origin.y=min(max(frame.minY,visible.minY),visible.maxY-frame.height)
        panel.setFrame(frame,display:true)
    }
    func windowWillUseStandardFrame(_ window: NSWindow, defaultFrame: NSRect) -> NSRect {
        let visible = window.screen?.visibleFrame ?? defaultFrame
        return NSRect(x: window.frame.minX, y: visible.minY, width: window.frame.width, height: visible.height)
    }

    func windowDidMove(_ notification:Notification) { saveFrame() }
    func windowDidResize(_ notification:Notification) { saveFrame() }
    func windowDidChangeScreen(_ notification:Notification) { if !placing { placePanel() } }
    func saveFrame() { if !placing, let panel { UserDefaults.standard.set(NSStringFromRect(panel.frame),forKey:"frame") } }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication) -> Bool { false }
}
