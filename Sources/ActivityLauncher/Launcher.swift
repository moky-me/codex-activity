import AppKit
import ActivityCore

protocol LauncherService {
    var codexRunning: Bool { get }
    var panelRunning: Bool { get }
    func openPanel(completion: @escaping (NSRunningApplication?) -> Void)
    func stopPanels(including opened: NSRunningApplication?)
}

struct NativeLauncherService: LauncherService {
    private let panelID = "io.github.moky-me.CodexActivity"

    var codexRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex").isEmpty
    }
    var panelRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: panelID).isEmpty
    }

    func openPanel(completion: @escaping (NSRunningApplication?) -> Void) {
        // Main.app/Contents/Library/LoginItems/Helper.app → Main.app
        let main = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        guard Bundle(url: main)?.bundleIdentifier == panelID else { completion(nil); return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.openApplication(at: main, configuration: configuration) { application, error in
            completion(error == nil ? application : nil)
        }
    }

    func stopPanels(including opened: NSRunningApplication?) {
        let panels = NSRunningApplication.runningApplications(withBundleIdentifier: panelID)
        panels.forEach { $0.terminate() }
        if let opened, !panels.contains(where: { $0.processIdentifier == opened.processIdentifier }) {
            opened.terminate()
        }
    }
}

/// Workspace notifications, launch completions and retries are handled on the main queue.
final class Launcher: NSObject, NSApplicationDelegate {
    private static let maxAttempts = 3
    private let service: LauncherService
    private let retryDelay: TimeInterval
    private var observers: [NSObjectProtocol] = []
    private var launching = false
    private var attempts = 0
    private var retry: DispatchWorkItem?

    init(service: LauncherService = NativeLauncherService(), retryDelay: TimeInterval = 2) {
        self.service = service
        self.retryDelay = retryDelay
        super.init()
    }

    deinit { retry?.cancel() }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.prohibited)
        let center = NSWorkspace.shared.notificationCenter
        for event in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: event, object: nil, queue: .main) { [weak self] note in
                guard let application = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      application.bundleIdentifier == "com.openai.codex" else { return }
                self?.reconcile()
            })
        }
        reconcile()
    }

    func reconcile() {
        let codexRunning = service.codexRunning
        let panelRunning = service.panelRunning
        if !codexRunning || panelRunning {
            cancelRetry()
            attempts = 0
        }
        switch LifecyclePolicy.action(codexRunning: codexRunning, panelRunning: panelRunning || launching) {
        case .none:
            break
        case .stopPanel:
            service.stopPanels(including: nil)
        case .launchPanel:
            guard retry == nil, attempts < Self.maxAttempts else { return }
            launching = true
            attempts += 1
            service.openPanel { [weak self] application in
                DispatchQueue.main.async {
                    self?.opened(application)
                }
            }
        }
    }

    private func opened(_ application: NSRunningApplication?) {
        launching = false
        guard service.codexRunning else {
            cancelRetry()
            attempts = 0
            service.stopPanels(including: application)
            return
        }
        if service.panelRunning || application?.isTerminated == false {
            cancelRetry()
            attempts = 0
            return
        }
        guard attempts < Self.maxAttempts else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.retry = nil
            self?.reconcile()
        }
        retry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + retryDelay, execute: work)
    }

    private func cancelRetry() {
        retry?.cancel()
        retry = nil
    }
}
