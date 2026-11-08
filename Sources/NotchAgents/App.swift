import AppKit
import SwiftUI

/// Fixed-size transparent panel at top-center; the SwiftUI pill is drawn at its top edge.
/// Mouse events pass through transparent areas, and hover over the pill toggles expansion.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = AgentStore()
    var panel: NSPanel!
    var server: EventServer!
    let hover = HoverState()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let root = RootView(store: store, hover: hover)
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(x: 0, y: 0, width: IslandLayout.panelWidth, height: IslandLayout.panelHeight)

        panel = NSPanel(contentRect: host.frame,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.contentView = host
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.ignoresMouseEvents = false
        positionPanel()
        panel.orderFrontRegardless()

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.positionPanel() }
        }

        server = EventServer { [weak self] ev in
            Task { @MainActor in self?.store.handle(ev) }
        }
        do { try server.start() } catch {
            NSLog("NotchAgents: socket failed or another instance is running: \(error)")
            NSApp.terminate(nil)
            return
        }
        menu = MenuController()
    }

    var menu: MenuController?

    private func positionPanel() {
        // Prefer the built-in display (the one with a notch).
        let screen = NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens[0]
        let f = screen.frame
        if let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea {
            IslandLayout.notchWidth = f.width - l.width - r.width
            IslandLayout.notchHeight = screen.safeAreaInsets.top
        }
        panel.setFrame(NSRect(x: f.midX - IslandLayout.panelWidth / 2,
                              y: f.maxY - IslandLayout.panelHeight,
                              width: IslandLayout.panelWidth, height: IslandLayout.panelHeight),
                       display: true)
    }
}

@MainActor @Observable
final class HoverState { var hovering = false }

struct RootView: View {
    let store: AgentStore
    let hover: HoverState

    var body: some View {
        VStack {
            if store.isVisible {
                IslandView(store: store, expanded: hover.hovering)
                    .onHover { hover.hovering = $0 }
                    .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .top)))
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.easeInOut(duration: 0.25), value: store.isVisible)
    }
}

@main
struct NotchAgentsApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
