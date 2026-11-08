import AppKit
import ServiceManagement

/// Menu bar icon: install/remove hooks, launch at login, quit.
@MainActor
final class MenuController: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()

    override init() {
        super.init()
        item.button?.image = NSImage(systemSymbolName: "capsule.fill", accessibilityDescription: "Notch Agents")
        menu.delegate = self
        item.menu = menu
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

    @objc private func quit() { NSApp.terminate(nil) }

    private func run(_ body: () throws -> Void) {
        do { try body() } catch {
            let a = NSAlert(error: error)
            NSApp.activate()
            a.runModal()
        }
    }
}
