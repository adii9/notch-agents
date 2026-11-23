import AppKit

/// A light tap on the Force Touch trackpad when the island opens.
/// Only felt with a finger on a Force Touch trackpad; a mouse gets nothing.
@MainActor
enum Haptics {
    private static let key = "playHaptics"
    /// On unless the user turned it off from the menu.
    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
    private static var lastPlayed = Date.distantPast

    static func islandOpened() {
        // The pointer jittering on the island's edge shouldn't buzz repeatedly.
        guard isEnabled, Date().timeIntervalSince(lastPlayed) > 0.3 else { return }
        lastPlayed = Date()
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
    }
}
