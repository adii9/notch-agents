import Foundation

/// Installs/removes Notch Agents' Claude Code hooks in ~/.claude/settings.json.
/// Always writes a timestamped backup first and only touches entries that point at our own script.
enum HookInstaller {
    static let dir = NSString(string: "~/.notch-agents").expandingTildeInPath
    static let hookPath = dir + "/hook.sh"
    static let settingsPath = NSString(string: "~/.claude/settings.json").expandingTildeInPath
    /// Pre-rename location; entries pointing here are cleaned up on install/uninstall.
    private static let legacyDir = NSString(string: "~/.claude-island").expandingTildeInPath
    private static let legacyHook = legacyDir + "/hook.sh"

    static let events = ["SessionStart", "PreToolUse", "PostToolUse", "SubagentStart",
                         "SubagentStop", "Stop", "Notification"]

    /// Forwards the hook payload to the app's socket; never blocks or fails Claude.
    static let script = """
    #!/bin/bash
    SOCK="$HOME/.notch-agents/sock"
    [ -S "$SOCK" ] || exit 0
    /usr/bin/nc -U -w 1 "$SOCK" 2>/dev/null
    exit 0

    """

    static var isInstalled: Bool {
        guard let hooks = (try? loadSettings())?["hooks"] as? [String: Any] else { return false }
        return events.allSatisfy { ev in
            (hooks[ev] as? [[String: Any]])?.contains(where: { contains($0, hookPath) }) ?? false
        }
    }

    static func install() throws {
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try script.write(toFile: hookPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hookPath)
        try modify(add: true)
        try? FileManager.default.removeItem(atPath: legacyDir)
    }

    static func uninstall() throws {
        try modify(add: false)
    }

    private static func contains(_ group: [String: Any], _ command: String) -> Bool {
        (group["hooks"] as? [[String: Any]])?.contains { $0["command"] as? String == command } ?? false
    }

    private static func loadSettings() throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: settingsPath) else { return [:] }
        let data = try Data(contentsOf: URL(fileURLWithPath: settingsPath))
        guard !data.isEmpty else { return [:] }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "HookInstaller", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "settings.json is not a JSON object; not modifying it."])
        }
        return obj
    }

    private static func modify(add: Bool) throws {
        var settings = try loadSettings()
        let fm = FileManager.default
        try fm.createDirectory(atPath: (settingsPath as NSString).deletingLastPathComponent,
                               withIntermediateDirectories: true)
        if fm.fileExists(atPath: settingsPath) {
            let stamp = Int(Date().timeIntervalSince1970)
            try fm.copyItem(atPath: settingsPath, toPath: "\(settingsPath).bak.\(stamp)")
        }
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        for ev in events {
            var groups = hooks[ev] as? [[String: Any]] ?? []
            groups.removeAll { contains($0, hookPath) || contains($0, legacyHook) }
            if add { groups.append(["hooks": [["type": "command", "command": hookPath]]]) }
            if groups.isEmpty { hooks.removeValue(forKey: ev) } else { hooks[ev] = groups }
        }
        if hooks.isEmpty { settings.removeValue(forKey: "hooks") } else { settings["hooks"] = hooks }
        let out = try JSONSerialization.data(withJSONObject: settings,
                                             options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try out.write(to: URL(fileURLWithPath: settingsPath), options: .atomic)
    }
}
