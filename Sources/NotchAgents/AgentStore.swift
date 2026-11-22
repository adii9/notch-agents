import Foundation
import Observation

struct HookEvent: Decodable {
    let session_id: String?
    let hook_event_name: String?
    let agent_id: String?
    let agent_type: String?
    let tool_name: String?
    let tool_use_id: String?
    let tool_input: [String: JSONValue]?
    let message: String?
    let cwd: String?
    let session_title: String?
    /// Added by our hook script: the process that ran the hook (Claude Code, or a shell under it).
    let notch_pid: Int32?
    /// Added by our hook script in the Claude desktop app: the chat's id ("local_…").
    let notch_host_session: String?
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

/// One tool call in an agent's live trace.
struct Step: Identifiable {
    let id = UUID()
    let toolUseID: String?
    let tool: String
    let label: String
    let startedAt = Date()
    var endedAt: Date?
}

/// One item of Claude's own task list (TodoWrite in the CLI, update_plan in the desktop app).
struct TaskItem: Identifiable {
    let id = UUID()
    var content: String
    var activeForm: String?
    var status: String  // "pending" | "in_progress" | "completed"
}

struct AgentInfo: Identifiable {
    let id: String
    var type: String
    var project: String
    var currentTool: String?
    var state: AgentState
    let startedAt: Date
    var endedAt: Date?
    /// Most recent tool calls, oldest first, capped at `AgentStore.maxSteps`.
    var steps: [Step] = []
    var tasks: [TaskItem] = []
}

/// A Claude Code permission request waiting for an answer from the island.
struct PermissionPrompt: Identifiable {
    let id = UUID()
    let session: String
    let agentKey: String
    let title: String
    let tool: String
    let detail: String
    /// Working directory the tool will run in, shown in full so a path can't hide in the summary.
    let cwd: String?
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
    /// Agent whose live trace the island shows; nil (or gone) means the first running one.
    var tracedAgent: String?
    /// Where each session runs, keyed by session id, for "jump to terminal".
    private(set) var terminals: [String: TerminalTarget] = [:]

    /// After this, the prompt is dropped and Claude falls back to its own terminal prompt.
    /// Must stay below the hook's `nc -w` (30s) and the hook timeout in settings (40s).
    static let promptTimeout: TimeInterval = 25
    /// Question cards are only a heads-up; they clear when answered (PostToolUse) or after this.
    static let questionTimeout: TimeInterval = 600
    static let maxSteps = 5

    var running: [AgentInfo] { agents.filter { $0.state == .running } }
    /// The Allow/Deny card the island shows (approvals before question heads-ups).
    var currentApproval: PermissionPrompt? { pending.first { !$0.isQuestion } }
    var isVisible: Bool { !agents.isEmpty || !pending.isEmpty }

    func handle(_ e: HookEvent, responder: Responder? = nil, terminal: TerminalTarget? = nil) {
        let name = e.hook_event_name ?? ""
        // Key per session so several chats don't collapse into one row.
        let session = e.session_id ?? "?"
        if let terminal { terminals[session] = terminal }
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
            guard let i = index(key) else { break }
            if let tasks = taskList(e, current: agents[i].tasks) {
                // Task-list updates feed the checklist, not the step log.
                agents[i].tasks = tasks
            } else {
                agents[i].currentTool = describe(e)
                agents[i].steps.append(Step(toolUseID: e.tool_use_id, tool: e.tool_name ?? "tool", label: describe(e)))
                if agents[i].steps.count > Self.maxSteps { agents[i].steps.removeFirst(agents[i].steps.count - Self.maxSteps) }
            }
        case "PostToolUse":
            if let i = index(key) {
                agents[i].currentTool = nil
                // Match by tool_use_id; fall back to the oldest open call of the same tool.
                let open = agents[i].steps.indices.filter { agents[i].steps[$0].endedAt == nil }
                let s = open.first { e.tool_use_id != nil && agents[i].steps[$0].toolUseID == e.tool_use_id }
                    ?? open.first { agents[i].steps[$0].tool == e.tool_name }
                if let s { agents[i].steps[s].endedAt = Date() }
            }
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
                                          cwd: e.cwd, isQuestion: isQuestion, responder: responder)
            pending.append(prompt)
            Chime.needsYou()
            let wait = isQuestion ? Self.questionTimeout : Self.promptTimeout
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                self.dropPending { $0.id == prompt.id }
            }
        case "Stop":
            // This session's main agent finished its turn.
            if finish(session + ":main") { Chime.finished() }
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

    /// Answers the card on screen from a keyboard shortcut. Ignored while the card is still arming,
    /// so a shortcut pressed for something else can't approve a card that just appeared.
    func decideCurrent(allow: Bool) {
        guard let p = currentApproval, Date().timeIntervalSince(p.createdAt) >= ApprovalCard.armDelay else { return }
        decide(p.id, allow: allow)
    }

    /// The session's terminal (or app) for an agent row or prompt.
    func terminal(forAgent key: String) -> TerminalTarget? {
        guard let colon = key.lastIndex(of: ":") else { return nil }
        return terminals[String(key[..<colon])]
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
            if agents[i].state == .done {
                // A new turn: start a fresh trace. The task list carries over until Claude replaces it.
                agents[i].state = .running; agents[i].endedAt = nil; agents[i].steps = []
            }
        } else {
            agents.append(AgentInfo(id: key, type: type, project: project, currentTool: nil,
                                    state: .running, startedAt: Date()))
        }
    }

    /// True when the agent was running and is now done.
    @discardableResult
    private func finish(_ key: String) -> Bool {
        guard let i = index(key), agents[i].state == .running else { return false }
        agents[i].state = .done
        agents[i].currentTool = nil
        agents[i].endedAt = Date()
        // Calls that never reported back (failed or interrupted) stop spinning when the turn ends.
        for s in agents[i].steps.indices where agents[i].steps[s].endedAt == nil { agents[i].steps[s].endedAt = Date() }
        scheduleCleanup()
        return true
    }

    private func scheduleCleanup() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            let cutoff = Date().addingTimeInterval(-7.5)
            agents.removeAll { $0.state == .done && ($0.endedAt ?? .distantPast) < cutoff }
            terminals = terminals.filter { session, _ in agents.contains { $0.id.hasPrefix(session + ":") } }
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

    /// The task list after this call, or nil when the call isn't a task-list update.
    /// TodoWrite always sends the whole list; the desktop app's update_plan may send only a change.
    private func taskList(_ e: HookEvent, current: [TaskItem]) -> [TaskItem]? {
        let input = e.tool_input ?? [:]
        func items(_ v: JSONValue?, text: String) -> [TaskItem] {
            (v?.array ?? []).compactMap { $0.object }.map {
                TaskItem(content: $0[text]?.string ?? "", activeForm: $0["activeForm"]?.string,
                         status: $0["status"]?.string ?? "pending")
            }
        }
        switch e.tool_name ?? "" {
        case "TodoWrite":
            return items(input["todos"], text: "content")
        case let t where t.hasSuffix("__update_plan"):
            if input["items"] != nil { return items(input["items"], text: "content") }
            var list = current
            let isTrue: (JSONValue?) -> Bool = { if case .bool(true)? = $0 { return true } else { return false } }
            if isTrue(input["advance"]) {
                if let i = list.firstIndex(where: { $0.status == "in_progress" }) { list[i].status = "completed" }
                if let i = list.firstIndex(where: { $0.status == "pending" }) { list[i].status = "in_progress" }
            }
            for d in input["done"]?.array ?? [] {
                if case .number(let n) = d, list.indices.contains(Int(n) - 1) { list[Int(n) - 1].status = "completed" }
            }
            if case .number(let n)? = input["start"], list.indices.contains(Int(n) - 1) {
                for i in list.indices where list[i].status == "in_progress" { list[i].status = "pending" }
                list[Int(n) - 1].status = "in_progress"
            }
            return list
        default:
            return nil
        }
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
