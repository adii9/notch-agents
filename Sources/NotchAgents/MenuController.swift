import AppKit
import ServiceManagement
import Sparkle

/// Menu bar icon: install/remove hooks, launch at login, check for updates, quit.
@MainActor
final class MenuController: NSObject, NSMenuDelegate, SPUStandardUserDriverDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    /// Sparkle, only in a bundled build: `swift run` has no Info.plist with a feed and key.
    private lazy var updater: SPUStandardUpdaterController? =
        Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") == nil ? nil
            : SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self)

    override init() {
        super.init()
        item.button?.image = NSImage(systemSymbolName: "capsule.fill", accessibilityDescription: "Notch Agents")
        menu.delegate = self
        item.menu = menu
        _ = updater  // starts the daily background check
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let title = NSMenuItem(title: "Notch Agents", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        menu.addItem(.separator())

        if HookInstaller.isInstalled {
            menu.addItem(make("Remove Claude Code hooks", #selector(removeHooks)))
        } else {
            menu.addItem(make("Install Claude Code hooks…", #selector(installHooks)))
        }
        let login = make("Launch at login", #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        let sounds = make("Play sounds", #selector(toggleSounds))
        sounds.state = Chime.isEnabled ? .on : .off
        menu.addItem(sounds)
        let haptics = make("Haptic feedback", #selector(toggleHaptics))
        haptics.state = Haptics.isEnabled ? .on : .off
        menu.addItem(haptics)
        let steps = make("Show recent steps", #selector(toggleSteps))
        steps.state = UserDefaults.standard.bool(forKey: TraceView.showStepsKey) ? .on : .off
        menu.addItem(steps)
        if let updater {
            let check = NSMenuItem(title: "Check for Updates…",
                                   action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)), keyEquivalent: "")
            check.target = updater
            menu.addItem(check)
        }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let about = NSMenuItem(title: "Version \(version ?? "dev")", action: nil, keyEquivalent: "")
        about.isEnabled = false
        menu.addItem(about)
        menu.addItem(.separator())
        menu.addItem(make("Quit Notch Agents", #selector(quit), key: "q"))
    }

    private func make(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let m = NSMenuItem(title: title, action: action, keyEquivalent: key)
        m.target = self
        return m
    }

    @objc private func installHooks() {
        let alert = NSAlert()
        alert.messageText = "Install Claude Code hooks?"
        alert.informativeText = "This adds Notch Agents entries to ~/.claude/settings.json so Claude Code can report activity to the app. A timestamped backup is made first. Restart running Claude Code sessions afterwards."
        alert.addButton(withTitle: "Install")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        run { try HookInstaller.install() }
    }

    @objc private func removeHooks() { run { try HookInstaller.uninstall() } }

    @objc private func toggleLogin() {
        run {
            let s = SMAppService.mainApp
            if s.status == .enabled { try s.unregister() } else { try s.register() }
        }
    }

    @objc private func toggleSounds() { Chime.isEnabled.toggle() }

    @objc private func toggleHaptics() { Haptics.isEnabled.toggle() }

    @objc private func toggleSteps() {
        let d = UserDefaults.standard
        d.set(!d.bool(forKey: TraceView.showStepsKey), forKey: TraceView.showStepsKey)
    }

    @objc private func quit() { NSApp.terminate(nil) }

    // A menu bar app has no Dock icon or window, so an update found in the background must
    // bring the app forward or Sparkle's window would open behind whatever the user is doing.
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool,
                                                               forUpdate update: SUAppcastItem,
                                                               state: SPUUserUpdateState) {
        guard handleShowingUpdate, !state.userInitiated else { return }
        Task { @MainActor in NSApp.activate() }
    }

    private func run(_ body: () throws -> Void) {
        do { try body() } catch {
            let a = NSAlert(error: error)
            NSApp.activate()
            a.runModal()
        }
    }
}
