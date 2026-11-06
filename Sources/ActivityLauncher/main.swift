import AppKit
import ActivityCore

final class Launcher: NSObject, NSApplicationDelegate {
    let codexID="com.openai.codex"
    let panelID="io.github.moky-me.CodexActivity"
    var observers:[NSObjectProtocol]=[]
    var launching=false
    func applicationDidFinishLaunching(_ notification:Notification) {
        NSApp.setActivationPolicy(.prohibited)
        let center=NSWorkspace.shared.notificationCenter
        for event in [NSWorkspace.didLaunchApplicationNotification,NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName:event,object:nil,queue:.main) { [weak self] note in
                guard let self, let application=note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      application.bundleIdentifier == self.codexID else { return }
                self.reconcile()
            })
        }
        reconcile()
    }
    func reconcile() {
        let codexRunning = !NSRunningApplication.runningApplications(withBundleIdentifier:codexID).isEmpty
        let panels=NSRunningApplication.runningApplications(withBundleIdentifier:panelID)
        switch LifecyclePolicy.action(codexRunning:codexRunning,panelRunning:!panels.isEmpty || launching) {
        case .none: break
        case .stopPanel: panels.forEach { $0.terminate() }
        case .launchPanel:
            // Main.app/Contents/Library/LoginItems/Helper.app → Main.app
            let main=Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            guard Bundle(url:main)?.bundleIdentifier == panelID else { return }
            launching=true
            let config=NSWorkspace.OpenConfiguration(); config.activates=false
            NSWorkspace.shared.openApplication(at:main,configuration:config) { [weak self] _,_ in
                DispatchQueue.main.async { self?.launching=false }
            }
        }
    }
}
let app=NSApplication.shared
let delegate=Launcher()
app.delegate=delegate
app.run()
