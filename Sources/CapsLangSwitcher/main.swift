import Cocoa
import SwiftUI
import Carbon
import Darwin
import LangSwitchCore
import ServiceManagement

private let launchAtLoginConfiguredKey = "didConfigureLaunchAtLogin"
private let nativeIndicatorNoticeShownKey = "didShowNativeIndicatorNotice"

@available(macOS 13.0, *)
private func launchAtLoginStatusName(_ status: SMAppService.Status) -> String {
    switch status {
    case .notRegistered: return "not registered"
    case .enabled: return "enabled"
    case .requiresApproval: return "approval required"
    case .notFound: return "not found"
    @unknown default: return "unknown"
    }
}

/// Handles installer diagnostics without creating NSApplication or requesting Accessibility.
private func loginItemCommandExitCodeIfRequested(
    arguments: [String] = CommandLine.arguments
) -> Int32? {
    guard arguments.count == 2 else { return nil }
    let command = arguments[1]
    guard command == "--register-login-item" || command == "--login-item-status" else {
        return nil
    }

    guard #available(macOS 13.0, *) else {
        print("Launch at Login requires macOS 13 or later")
        return 2
    }

    let service = SMAppService.mainApp
    if command == "--register-login-item",
       service.status == .notRegistered || service.status == .notFound {
        do {
            try service.register()
            UserDefaults.standard.set(true, forKey: launchAtLoginConfiguredKey)
        } catch {
            fputs("Could not register Launch at Login: \(error.localizedDescription)\n", stderr)
            return 1
        }
    }

    print("Launch at Login: \(launchAtLoginStatusName(service.status))")
    return 0
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let tap = CapsLockTap()
    private let hud = LanguageIndicatorHUD()
    private var aboutWindow: NSWindow?
    private var instanceLock: SingleInstanceLock?
    private var signalHandler: TerminationSignalHandler?
    private weak var launchAtLoginItem: NSMenuItem?
    private weak var runtimeStatusItem: NSMenuItem?
    private var isTerminating = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let lock = SingleInstanceLock() else {
            let alert = NSAlert()
            alert.messageText = "LangSwitch is already running"
            alert.informativeText = "Only one instance can own the Caps Lock mapping at a time."
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        instanceLock = lock

        configureLaunchAtLoginIfNeeded()
        suppressNativeIndicator()

        signalHandler = TerminationSignalHandler { [weak self] in
            guard self?.isTerminating == false else { return }
            NSApp.terminate(nil)
        }

        buildMenu()
        setRuntimeStatus("Status: Waiting for Accessibility…", isActive: false)
        updateStatusTitle()

        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(inputSourceDidChange),
            name: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil
        )

        guard AXIsProcessTrustedWithOptions(
            [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        ) else {
            promptForAccessibility()
            return
        }

        startTap()
    }

    private func startTap() {
        tap.onTap = {
            InputSourceSwitcher.selectNext()
        }
        tap.onFailure = { [weak self] error in
            guard let self, !self.isTerminating else { return }
            self.setRuntimeStatus("Status: Stopped — mapping restored", isActive: false)
            let alert = NSAlert()
            alert.messageText = "Caps Lock capture stopped"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }

        do {
            try tap.start()
            updateStatusTitle()
        } catch {
            setRuntimeStatus("Status: Stopped — see error", isActive: false)
            let alert = NSAlert()
            alert.messageText = "Caps Lock capture did not start"
            alert.informativeText = "LangSwitch left your previous keyboard mapping unchanged.\n\n\(error.localizedDescription)"
            alert.runModal()
        }
    }

    private func promptForAccessibility() {
        guard !isTerminating else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, !self.isTerminating else { return }
            if AXIsProcessTrusted() {
                self.startTap()
            } else {
                self.promptForAccessibility()
            }
        }
    }

    @objc private func inputSourceDidChange() {
        updateStatusTitle()
        guard let source = InputSourceSwitcher.currentSource() else { return }
        // Defer the HUD off the current turn so a synchronously delivered TIS
        // notification cannot run Accessibility queries inside the event-tap callback.
        DispatchQueue.main.async { [weak self] in
            self?.hud.show(for: source)
        }
    }

    @objc private func updateStatusTitle() {
        guard let source = InputSourceSwitcher.currentSource() else { return }
        let sourceName = InputSourceSwitcher.localizedName(source)
        if tap.isRunning {
            setRuntimeStatus("Status: Active — \(sourceName)", isActive: true)
        } else {
            statusItem.button?.toolTip = "LangSwitch — Waiting for Accessibility"
        }
    }

    private func buildMenu() {
        let menu = NSMenu()
        menu.delegate = self

        let heading = menu.addItem(
            withTitle: "Status: Waiting for Accessibility…",
            action: nil,
            keyEquivalent: ""
        )
        heading.isEnabled = false
        runtimeStatusItem = heading
        menu.addItem(.separator())

        addItem(
            to: menu,
            "Open Accessibility Settings…",
            #selector(openAccessibilitySettings),
            symbol: "accessibility"
        )
        let launchAtLogin = NSMenuItem(
            title: "Launch at Login",
            action: #selector(toggleLaunchAtLogin),
            keyEquivalent: ""
        )
        launchAtLogin.target = self
        launchAtLogin.image = NSImage(
            systemSymbolName: "arrow.clockwise.circle",
            accessibilityDescription: nil
        )
        menu.addItem(launchAtLogin)
        launchAtLoginItem = launchAtLogin
        updateLaunchAtLoginItem()

        addItem(to: menu, "About LangSwitch", #selector(openAbout), symbol: "info.circle")
        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: "Quit & Restore Caps Lock",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quit.target = NSApp
        quit.image = NSImage(systemSymbolName: "power", accessibilityDescription: nil)
        menu.addItem(quit)

        statusItem.menu = menu
    }

    private func setRuntimeStatus(_ title: String, isActive: Bool) {
        runtimeStatusItem?.title = title
        let symbolName = isActive ? "capslock.fill" : "capslock"
        let icon = NSImage(systemSymbolName: symbolName, accessibilityDescription: "LangSwitch")
        icon?.isTemplate = true
        statusItem.button?.image = icon
        statusItem.button?.toolTip = isActive
            ? title.replacingOccurrences(of: "Status: ", with: "LangSwitch — ")
            : "LangSwitch — Waiting for Accessibility"
    }

    func menuWillOpen(_ menu: NSMenu) {
        updateLaunchAtLoginItem()
    }

    private func addItem(to menu: NSMenu, _ title: String, _ action: Selector, symbol: String) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        menu.addItem(item)
    }

    @objc private func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    private func configureLaunchAtLoginIfNeeded() {
        guard #available(macOS 13.0, *), isInstalledInApplicationsFolder else { return }
        guard !UserDefaults.standard.bool(forKey: launchAtLoginConfiguredKey) else { return }

        let service = SMAppService.mainApp
        guard service.status == .notRegistered || service.status == .notFound else {
            UserDefaults.standard.set(true, forKey: launchAtLoginConfiguredKey)
            return
        }

        if (try? service.register()) != nil {
            // Record only a successful registration attempt. A failure is retried on the
            // next manual launch and remains visible as an unchecked menu item.
            UserDefaults.standard.set(true, forKey: launchAtLoginConfiguredKey)
        }
    }

    /// Disables macOS's native near-cursor language indicator, which shows the *previous*
    /// source after a programmatic switch. LangSwitch shows its own correct HUD instead.
    ///
    /// `TSMLanguageIndicatorEnabled` is a global default macOS only re-reads at login, so it is
    /// left disabled *persistently* and is NOT restored on quit: restoring it would let the
    /// built-in badge win the next-login race (session agents read the pref before our login-item
    /// re-disables it) and reappear every session. Takes effect after the next logout/restart.
    /// Preference failures never throw or block startup.
    private func suppressNativeIndicator() {
        let key = "TSMLanguageIndicatorEnabled" as CFString
        let current = CFPreferencesCopyAppValue(key, kCFPreferencesAnyApplication) as? Bool
        if current != false {   // idempotent: only write when not already disabled
            CFPreferencesSetAppValue(key, kCFBooleanFalse, kCFPreferencesAnyApplication)
            CFPreferencesAppSynchronize(kCFPreferencesAnyApplication)
        }
        showNativeIndicatorNoticeIfNeeded()
    }

    private func showNativeIndicatorNoticeIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: nativeIndicatorNoticeShownKey) else { return }
        UserDefaults.standard.set(true, forKey: nativeIndicatorNoticeShownKey)

        let alert = NSAlert()
        alert.messageText = "LangSwitch replaces the macOS language indicator"
        alert.informativeText = """
        macOS's built-in near-cursor language indicator shows the previous language after a \
        switch, so LangSwitch disables it and shows its own indicator with the correct language. \
        Log out or restart once for the built-in badge to disappear.
        """
        alert.runModal()
    }

    private var isInstalledInApplicationsFolder: Bool {
        let bundlePath = Bundle.main.bundleURL.standardizedFileURL.path
        let userApplications = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true)
            .standardizedFileURL.path + "/"

        return bundlePath.hasPrefix(userApplications) || bundlePath.hasPrefix("/Applications/")
    }

    @objc private func toggleLaunchAtLogin() {
        guard #available(macOS 13.0, *) else { return }

        let service = SMAppService.mainApp
        do {
            switch service.status {
            case .enabled:
                try service.unregister()
            case .requiresApproval:
                SMAppService.openSystemSettingsLoginItems()
            case .notRegistered, .notFound:
                try service.register()
            @unknown default:
                throw NSError(
                    domain: "com.chayapats.langswitch",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Unknown Login Item status"]
                )
            }
            UserDefaults.standard.set(true, forKey: launchAtLoginConfiguredKey)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not change Launch at Login"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }

        updateLaunchAtLoginItem()
    }

    private func updateLaunchAtLoginItem() {
        guard let item = launchAtLoginItem else { return }
        guard #available(macOS 13.0, *) else {
            item.title = "Launch at Login — Requires macOS 13"
            item.state = .off
            item.isEnabled = false
            return
        }

        item.isEnabled = true
        switch SMAppService.mainApp.status {
        case .enabled:
            item.title = "Launch at Login"
            item.state = .on
        case .requiresApproval:
            item.title = "Launch at Login — Approval Required…"
            item.state = .mixed
        case .notRegistered, .notFound:
            item.title = "Launch at Login"
            item.state = .off
        @unknown default:
            item.title = "Launch at Login"
            item.state = .off
        }
    }

    @objc private func openAbout() {
        if aboutWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 340, height: 420),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "About LangSwitch"
            window.contentView = NSHostingView(rootView: AboutView())
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            aboutWindow = window
        }

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        aboutWindow?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        if (notification.object as? NSWindow) === aboutWindow {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        isTerminating = true
        DistributedNotificationCenter.default().removeObserver(self)
        tap.stop()
        signalHandler = nil
    }
}

if let watchdogExitCode = HIDMappingManager.watchdogExitCodeIfRequested() {
    exit(watchdogExitCode)
}

if let loginItemExitCode = loginItemCommandExitCodeIfRequested() {
    exit(loginItemExitCode)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
