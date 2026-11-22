import AppKit
import Darwin

/// The app (and, for terminals, the tty) a Claude Code session runs in.
struct TerminalTarget: Sendable {
    let appPID: pid_t?
    let bundleID: String?
    /// e.g. "/dev/ttys003"; nil when the session has no terminal (the Claude desktop app).
    let tty: String?
    /// The Claude desktop app's id for the chat ("local_…"), so the jump can open that chat.
    let desktopChat: String?
}

/// Finds a session's window from the process that ran its hook, and brings it to the front.
enum TerminalLocator {
    /// Walks up from `pid` to the first regular app (Terminal, iTerm2, VS Code, Ghostty, Claude…).
    /// Must run while the hook is still alive, since its parent shell may exit right after.
    static func locate(pid: pid_t?, desktopChat: String?) -> TerminalTarget? {
        let chat = desktopChat.flatMap { isChatID($0) ? $0 : nil }
        guard let pid, pid > 1, let first = info(pid) else {
            return chat.map { TerminalTarget(appPID: nil, bundleID: nil, tty: nil, desktopChat: $0) }
        }
        let dev = first.kp_eproc.e_tdev
        var tty: String?
        if dev != -1, let name = devname(dev, S_IFCHR), name.pointee != 0x3F /* "?" */ {
            tty = "/dev/" + String(cString: name)
        }
        var p = pid
        for _ in 0..<32 {
            if let app = NSRunningApplication(processIdentifier: p), app.activationPolicy == .regular {
                return TerminalTarget(appPID: p, bundleID: app.bundleIdentifier, tty: tty, desktopChat: chat)
            }
            guard let parent = info(p)?.kp_eproc.e_ppid, parent > 1 else { break }
            p = parent
        }
        return chat.map { TerminalTarget(appPID: nil, bundleID: nil, tty: nil, desktopChat: $0) }
    }

    /// The desktop app's chat ids, as its claude://code/continue link accepts them: local_ + 1–64 of [A-Za-z0-9-].
    private static func isChatID(_ s: String) -> Bool {
        let rest = s.utf8.dropFirst(6)
        return s.hasPrefix("local_") && (1...64).contains(rest.count)
            && rest.allSatisfy { (0x30...0x39).contains($0) || (0x41...0x5A).contains($0) || (0x61...0x7A).contains($0) || $0 == 0x2D }
    }

    /// Selects the session's tab in Terminal or iTerm2; other apps are brought to the front.
    static func focus(_ t: TerminalTarget) {
        // Claude desktop app: its own link opens the exact chat.
        if let chat = t.desktopChat, let url = URL(string: "claude://code/continue?session=\(chat)") {
            NSWorkspace.shared.open(url)
            return
        }
        queue.async {
            if let tty = t.tty, let source = tabScript(bundleID: t.bundleID, tty: tty) {
                var error: NSDictionary?
                let found = NSAppleScript(source: source)?.executeAndReturnError(&error).booleanValue ?? false
                if found { return }
            }
            DispatchQueue.main.async {
                guard let pid = t.appPID, let url = NSRunningApplication(processIdentifier: pid)?.bundleURL else { return }
                let config = NSWorkspace.OpenConfiguration()
                config.activates = true
                NSWorkspace.shared.openApplication(at: url, configuration: config)
            }
        }
    }

    /// AppleScript runs off the main thread so a slow app (or the first-use permission prompt)
    /// can't freeze the island.
    private static let queue = DispatchQueue(label: "TerminalLocator")

    private static func tabScript(bundleID: String?, tty: String) -> String? {
        // tty comes from devname(), so it is always "/dev/" plus letters and digits.
        guard tty.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "/" }) else { return nil }
        switch bundleID {
        case "com.apple.Terminal":
            return """
            tell application id "com.apple.Terminal"
              repeat with w in windows
                repeat with t in tabs of w
                  if tty of t is "\(tty)" then
                    -- By id: "w" means "window N", which shifts once windows reorder.
                    set win to window id (id of w)
                    set selected of t to true
                    set index of win to 1
                    activate
                    return true
                  end if
                end repeat
              end repeat
            end tell
            return false
            """
        case "com.googlecode.iterm2":
            return """
            tell application id "com.googlecode.iterm2"
              repeat with w in windows
                repeat with t in tabs of w
                  repeat with s in sessions of t
                    if tty of s is "\(tty)" then
                      set win to window id (id of w)
                      select t
                      select s
                      select win
                      activate
                      return true
                    end if
                  end repeat
                end repeat
              end repeat
            end tell
            return false
            """
        default:
            return nil
        }
    }

    private static func info(_ pid: pid_t) -> kinfo_proc? {
        var kp = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &kp, &size, nil, 0) == 0, size > 0 else { return nil }
        return kp
    }
}
