import AppKit

/// A short system sound when an agent needs you or a session finishes its turn.
@MainActor
enum Chime {
    private static let key = "playSounds"
    /// On unless the user turned it off from the menu.
    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
    private static var lastPlayed = Date.distantPast

    static func needsYou() { play("Ping") }
    static func finished() { play("Glass") }

    private static func play(_ name: String) {
        // Several sessions stopping together should make one sound, not a burst.
        guard isEnabled, Date().timeIntervalSince(lastPlayed) > 1 else { return }
        lastPlayed = Date()
        NSSound(named: name)?.play()
    }
}
