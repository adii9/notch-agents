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
        let host = FirstClickHostingView(rootView: root)
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
        panel.ignoresMouseEvents = true  // click-through until the pointer is over the island
        positionPanel()
        panel.orderFrontRegardless()

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.positionPanel() }
        }

        server = EventServer { [weak self] ev, responder in
            Task { @MainActor in
                guard let self else { responder?.finish(nil); return }
                self.store.handle(ev, responder: responder)
            }
        }
        do { try server.start() } catch {
            NSLog("NotchAgents: socket failed or another instance is running: \(error)")
            NSApp.terminate(nil)
            return
        }
        menu = MenuController()

        // The panel is much bigger than the island and floats above other windows, so it must
        // only take clicks where the island actually is; everywhere else they go to what's below.
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateClickThrough() }
        }
        RunLoop.main.add(timer, forMode: .common)  // keep running while menus and dialogs are open
        mouseTimer = timer
    }

    var mouseTimer: Timer?

    private func updateClickThrough() {
        let size = hover.islandSize
        let f = panel.frame
        let island = NSRect(x: f.midX - size.width / 2, y: f.maxY - size.height,
                            width: size.width, height: size.height).insetBy(dx: -2, dy: -2)
        let inside = store.isVisible && size != .zero && island.contains(NSEvent.mouseLocation)
        if panel.ignoresMouseEvents == inside { panel.ignoresMouseEvents = !inside }
        // While click-through, SwiftUI gets no hover-exit event, so collapse here.
        if !inside && hover.hovering { hover.hovering = false }
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
final class HoverState {
    var hovering = false
    /// The island's current on-screen size, used to decide where the panel accepts clicks.
    var islandSize: CGSize = .zero
}

struct RootView: View {
    let store: AgentStore
    let hover: HoverState

    var body: some View {
        VStack {
            if store.isVisible {
                // A pending permission request keeps the island open until it's answered.
                IslandView(store: store, expanded: hover.hovering || !store.pending.isEmpty)
                    .onHover { hover.hovering = $0 }
                    .background(GeometryReader { g in
                        Color.clear
                            .onAppear { hover.islandSize = g.size }
                            .onChange(of: g.size) { _, new in hover.islandSize = new }
                    })
                    .onDisappear { hover.islandSize = .zero }
                    .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .top)))
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.easeInOut(duration: 0.25), value: store.isVisible)
    }
}

/// The panel never becomes key, so the first click must go straight to the buttons.
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
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
