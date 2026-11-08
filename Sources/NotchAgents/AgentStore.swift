import Foundation
import Observation

struct HookEvent: Decodable {
    let session_id: String?
    let hook_event_name: String?
    let agent_id: String?
    let agent_type: String?
    let tool_name: String?
    let tool_input: [String: JSONValue]?
    let message: String?
    let cwd: String?
    let session_title: String?
}

/// Minimal JSON value so tool_input of any shape decodes.
enum JSONValue: Decodable {
    case string(String), number(Double), bool(Bool), null, array([JSONValue]), object([String: JSONValue])
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else if let v = try? c.decode([String: JSONValue].self) { self = .object(v) }
        else { self = .null }
    }
    var string: String? { if case .string(let s) = self { return s } else { return nil } }
    var array: [JSONValue]? { if case .array(let a) = self { return a } else { return nil } }
    var object: [String: JSONValue]? { if case .object(let o) = self { return o } else { return nil } }

    /// Readable text for any shape, so nested tool input is never hidden from the user.
    func text(indent: String = "") -> String {
        switch self {
        case .string(let s): return s
        case .number(let n): return n == n.rounded() ? String(Int(n)) : String(n)
        case .bool(let b): return b ? "true" : "false"
        case .null: return "null"
        case .array(let a): return a.map { indent + "• " + $0.text(indent: indent + "  ") }.joined(separator: "\n")
        case .object(let o):
            return o.keys.sorted().map { k in
                let v = o[k]!
                switch v {
                case .array, .object: return "\(indent)\(k):\n" + v.text(indent: indent + "  ")
                default: return "\(indent)\(k): \(v.text())"
                }
            }.joined(separator: "\n")
        }
    }
}

enum AgentState { case running, done }

struct AgentInfo: Identifiable {
    let id: String
    var type: String
    var project: String
    var currentTool: String?
    var state: AgentState
    let startedAt: Date
    var endedAt: Date?
}

/// A Claude Code permission request waiting for an answer from the island.
struct PermissionPrompt: Identifiable {
    let id = UUID()
    let session: String
    let agentKey: String
    let title: String
    let tool: String
    let detail: String
    /// Claude asking the user a question (AskUserQuestion): shown for information only and answered
    /// in the terminal, because Allow/Deny can't pick an option.
    let isQuestion: Bool
    let createdAt = Date()
    let responder: Responder
}

@MainActor
@Observable
final class AgentStore {
    var agents: [AgentInfo] = []
    var pending: [PermissionPrompt] = []
    var lastMessage: String?

    /// After this, the prompt is dropped and Claude falls back to its own terminal prompt.
    /// Must stay below the hook's `nc -w` (30s) and the hook timeout in settings (40s).
    static let promptTimeout: TimeInterval = 25
    /// Question cards are only a heads-up; they clear when answered (PostToolUse) or after this.
    static let questionTimeout: TimeInterval = 600

    var running: [AgentInfo] { agents.filter { $0.state == .running } }
    var isVisible: Bool { !agents.isEmpty || !pending.isEmpty }

    func handle(_ e: HookEvent, responder: Responder? = nil) {
        let name = e.hook_event_name ?? ""
        // Key per session so several chats don't collapse into one row.
        let session = e.session_id ?? "?"
        let key = session + ":" + (e.agent_id ?? "main")
        let project = e.cwd.map { ($0 as NSString).lastPathComponent } ?? "session"
        let mainTitle = e.session_title ?? project
        let isMain = e.agent_id == nil
        let type = isMain ? mainTitle : (e.agent_type ?? "agent")
        switch name {
        case "SubagentStart":
            upsert(key, type: type, project: project)
        case "SubagentStop":
            finish(key)
        case "PreToolUse":
            upsert(key, type: type, project: project)
            if let i = index(key) { agents[i].currentTool = describe(e) }
        case "PostToolUse":
            if let i = index(key) { agents[i].currentTool = nil }
            // The tool ran, so any island prompt for it was answered elsewhere (e.g. in the terminal).
            dropPending { $0.agentKey == key && $0.tool == (e.tool_name ?? "") }
        case "PermissionRequest":
            guard let responder else { break }
            upsert(key, type: type, project: project)
            let isQuestion = e.tool_name == "AskUserQuestion"
            // Questions are released at once so Claude shows them in the terminal without delay.
            if isQuestion { responder.finish(nil) }
            if let i = index(key) { agents[i].currentTool = isQuestion ? "Asking you a question" : "Waiting for approval" }
            let prompt = PermissionPrompt(session: session, agentKey: key, title: type,
                                          tool: e.tool_name ?? "tool",
                                          detail: isQuestion ? questionDetail(e) : fullDetail(e),
                                          isQuestion: isQuestion, responder: responder)
            pending.append(prompt)
            let wait = isQuestion ? Self.questionTimeout : Self.promptTimeout
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                self.dropPending { $0.id == prompt.id }
            }
        case "Stop":
            // This session's main agent finished its turn.
            finish(session + ":main")
            dropPending { $0.session == session }
        case "SessionStart":
            break
        case "Notification":
            lastMessage = e.message
        default:
            break
        }
    }

    /// Answers a prompt from the island.
    func decide(_ id: UUID, allow: Bool) {
        guard let i = pending.firstIndex(where: { $0.id == id }) else { return }
        let p = pending.remove(at: i)
        p.responder.finish(Self.decisionJSON(allow: allow))
        if let a = index(p.agentKey) { agents[a].currentTool = allow ? "Approved \(p.tool)" : "Denied \(p.tool)" }
    }

    /// Hook output understood by Claude Code's PermissionRequest event.
    nonisolated static func decisionJSON(allow: Bool) -> String {
        var decision: [String: Any] = ["behavior": allow ? "allow" : "deny"]
        if !allow { decision["message"] = "The user denied this from Notch Agents." }
        let out: [String: Any] = ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": decision]]
        let data = try! JSONSerialization.data(withJSONObject: out, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    /// Hides a card without answering it (question cards only need dismissing).
    func dismiss(_ id: UUID) { dropPending { $0.id == id } }

    /// Removes matching prompts without a decision, so Claude shows its own prompt (or has moved on).
    private func dropPending(where match: (PermissionPrompt) -> Bool) {
        for p in pending where match(p) { p.responder.finish(nil) }
        pending.removeAll(where: match)
    }

    private func index(_ key: String) -> Int? { agents.firstIndex { $0.id == key } }

    private func upsert(_ key: String, type: String, project: String) {
        if let i = index(key) {
            agents[i].type = type
            if agents[i].state == .done { agents[i].state = .running; agents[i].endedAt = nil }
        } else {
            agents.append(AgentInfo(id: key, type: type, project: project, currentTool: nil,
                                    state: .running, startedAt: Date()))
        }
    }

    private func finish(_ key: String) {
        guard let i = index(key), agents[i].state == .running else { return }
        agents[i].state = .done
        agents[i].currentTool = nil
        agents[i].endedAt = Date()
        scheduleCleanup()
    }

    private func scheduleCleanup() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            let cutoff = Date().addingTimeInterval(-7.5)
            agents.removeAll { $0.state == .done && ($0.endedAt ?? .distantPast) < cutoff }
        }
    }

    private func describe(_ e: HookEvent) -> String {
        let tool = e.tool_name ?? "tool"
        let input = e.tool_input
        let detail = input?["file_path"]?.string
            ?? input?["command"]?.string
            ?? input?["pattern"]?.string
            ?? input?["description"]?.string
        guard var d = detail else { return tool }
        if d.hasPrefix("/") { d = (d as NSString).lastPathComponent }
        if d.count > 40 { d = String(d.prefix(40)) + "…" }
        return "\(tool) \(d)"
    }

    /// Everything the user needs to judge a permission request: never truncated to a file name.
    private func fullDetail(_ e: HookEvent) -> String {
        let input = e.tool_input ?? [:]
        for k in ["command", "file_path", "url", "pattern", "path", "query", "prompt"] {
            if let s = input[k]?.string { return s }
        }
        return input.isEmpty ? (e.tool_name ?? "tool") : JSONValue.object(input).text()
    }

    /// "Question?" followed by its options, for every question in an AskUserQuestion call.
    private func questionDetail(_ e: HookEvent) -> String {
        let input = e.tool_input ?? [:]
        guard let questions = input["questions"]?.array, !questions.isEmpty else { return fullDetail(e) }
        return questions.map { q -> String in
            guard let o = q.object else { return q.text() }
            var lines = [o["question"]?.string ?? o["header"]?.string ?? "Question"]
            for opt in o["options"]?.array ?? [] {
                let label = opt.object?["label"]?.string ?? opt.string ?? opt.text()
                lines.append("• " + label)
            }
            return lines.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }
}
