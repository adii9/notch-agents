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

@MainActor
@Observable
final class AgentStore {
    var agents: [AgentInfo] = []
    var lastMessage: String?

    var running: [AgentInfo] { agents.filter { $0.state == .running } }
    var isVisible: Bool { !agents.isEmpty }

    func handle(_ e: HookEvent) {
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
        case "Stop":
            // This session's main agent finished its turn.
            finish(session + ":main")
        case "SessionStart":
            break
        case "Notification":
            lastMessage = e.message
        default:
            break
        }
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
}
