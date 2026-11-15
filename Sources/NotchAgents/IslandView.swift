import SwiftUI

struct IslandView: View {
    let store: AgentStore
    let expanded: Bool
    private var traced: String? {
        if let selected = store.tracedAgent, store.agents.contains(where: { $0.id == selected }) { return selected }
        return (store.running.first ?? store.agents.first)?.id
    }

    var body: some View {
        VStack(spacing: 0) {
            if expanded { expandedBody } else { collapsedBody }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, expanded ? 12 : 0)
        .frame(width: expanded ? IslandLayout.expandedWidth : IslandLayout.collapsedWidth,
               height: expanded ? nil : IslandLayout.collapsedHeight)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: expanded ? 24 : 18, style: .continuous))
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: expanded)
    }

    private var collapsedBody: some View {
        // Spinner and count sit either side of the physical notch.
        HStack(spacing: 0) {
            if store.running.isEmpty {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                ProgressView().controlSize(.small).tint(.orange)
            }
            Spacer(minLength: IslandLayout.notchWidth)
            Text(store.running.isEmpty ? "Done" : "\(store.running.count) active")
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                .lineLimit(1).fixedSize()
        }
        .frame(maxHeight: .infinity)
    }

    private var expandedBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            Color.clear.frame(height: IslandLayout.notchHeight)
            // Approvals first: they block Claude. Questions are only a heads-up.
            if let prompt = store.pending.first(where: { !$0.isQuestion }) ?? store.pending.first {
                ApprovalCard(prompt: prompt, more: store.pending.count - 1,
                             decide: { allow in store.decide(prompt.id, allow: allow) },
                             dismiss: { store.dismiss(prompt.id) })
            }
            ForEach(store.agents) { agent in
                HStack(spacing: 10) {
                    Circle().fill(agent.state == .running ? Color.orange : Color.green).frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(agent.type).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                        Text("\(agent.project) · " + (agent.currentTool ?? (agent.state == .running ? "thinking…" : "finished")))
                            .font(.system(size: 11)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                    }
                    Spacer()
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        let end = agent.endedAt ?? ctx.date
                        Text(format(end.timeIntervalSince(agent.startedAt)))
                            .font(.system(size: 11, design: .monospaced)).foregroundStyle(.white.opacity(0.6))
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { store.tracedAgent = agent.id }
                if agent.id == traced { TraceView(agent: agent) }
            }
        }
    }

    private func format(_ t: TimeInterval) -> String {
        let s = Int(t)
        return s < 60 ? "\(s)s" : "\(s / 60)m \(s % 60)s"
    }
}

/// Live trace for one agent: Claude's task list, then its most recent tool calls.
struct TraceView: View {
    let agent: AgentInfo
    /// Long task lists show this many, centred on the active item, so the notch stays on screen.
    static let maxTasks = 7

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !agent.tasks.isEmpty {
                let done = agent.tasks.filter { $0.status == "completed" }.count
                Text("Tasks \(done)/\(agent.tasks.count)").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.45))
                ForEach(visibleTasks) { task in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        icon(task.status).frame(width: 12)
                        Text(task.status == "in_progress" ? (task.activeForm ?? task.content) : task.content)
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(task.status == "pending" ? 0.5 : 0.85))
                            .strikethrough(task.status == "completed", color: .white.opacity(0.4))
                            .lineLimit(1)
                    }
                }
            }
            if !agent.steps.isEmpty {
                Text("Recent steps").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.45)).padding(.top, agent.tasks.isEmpty ? 0 : 4)
                ForEach(agent.steps) { step in
                    HStack(spacing: 6) {
                        icon(step.endedAt == nil ? "in_progress" : "completed").frame(width: 12)
                        Text(step.label).font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.8)).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 4)
                        TimelineView(.periodic(from: .now, by: 1)) { ctx in
                            let t = (step.endedAt ?? ctx.date).timeIntervalSince(step.startedAt)
                            Text(t < 1 ? "<1s" : t < 60 ? "\(Int(t))s" : "\(Int(t) / 60)m \(Int(t) % 60)s")
                                .font(.system(size: 10, design: .monospaced)).foregroundStyle(.white.opacity(0.45))
                        }
                    }
                }
            }
        }
        .padding(.leading, 18)
    }

    private var visibleTasks: ArraySlice<TaskItem> {
        let all = agent.tasks
        guard all.count > Self.maxTasks else { return all[...] }
        let focus = all.firstIndex { $0.status == "in_progress" } ?? all.firstIndex { $0.status == "pending" } ?? all.count - 1
        let start = min(max(0, focus - Self.maxTasks / 2), all.count - Self.maxTasks)
        return all[start..<start + Self.maxTasks]
    }

    @ViewBuilder private func icon(_ status: String) -> some View {
        switch status {
        case "completed": Image(systemName: "checkmark.circle.fill").font(.system(size: 10)).foregroundStyle(.green)
        case "in_progress": Image(systemName: "circle.lefthalf.filled").font(.system(size: 10)).foregroundStyle(.orange)
        default: Image(systemName: "circle").font(.system(size: 10)).foregroundStyle(.white.opacity(0.35))
        }
    }
}

/// Allow / Deny for a pending Claude Code permission request.
struct ApprovalCard: View {
    let prompt: PermissionPrompt
    let more: Int
    let decide: (Bool) -> Void
    let dismiss: () -> Void
    /// Buttons stay inert briefly so a click already in flight can't approve a card that just popped up.
    static let armDelay: TimeInterval = 0.7

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: prompt.isQuestion ? "questionmark.bubble.fill" : "hand.raised.fill")
                    .foregroundStyle(prompt.isQuestion ? Color.blue : Color.orange)
                Text(prompt.isQuestion ? "Claude has a question" : "Permission needed")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                Spacer()
                if !prompt.isQuestion {
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        let left = max(0, Int(AgentStore.promptTimeout - ctx.date.timeIntervalSince(prompt.createdAt)))
                        Text("\(left)s").font(.system(size: 11, design: .monospaced)).foregroundStyle(.white.opacity(0.5))
                    }
                }
            }
            Text(prompt.isQuestion ? prompt.title : "\(prompt.title) · \(prompt.tool)")
                .font(.system(size: 11)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
            if !prompt.isQuestion, let cwd = prompt.cwd {
                Text("in \(cwd)")
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(.white.opacity(0.6))
                    .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
            }
            let detailText = Text(prompt.detail)
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(.white)
                .lineLimit(prompt.isQuestion ? 12 : nil).frame(maxWidth: .infinity, alignment: .leading)
                .padding(8).background(Color.white.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            if prompt.isQuestion {
                detailText
            } else {
                // Full command stays readable: long ones scroll instead of being cut off.
                ScrollView(.vertical) { detailText }.frame(maxHeight: 120)
            }
            if prompt.isQuestion {
                HStack {
                    Text("Answer it in the terminal").font(.system(size: 10)).foregroundStyle(.white.opacity(0.45))
                    Spacer()
                    Button("Dismiss", action: dismiss).buttonStyle(IslandButtonStyle(primary: false)).frame(width: 90)
                }
            } else {
                TimelineView(.periodic(from: .now, by: 0.25)) { ctx in
                    let armed = ctx.date.timeIntervalSince(prompt.createdAt) >= Self.armDelay
                    HStack(spacing: 8) {
                        Button("Deny") { decide(false) }.buttonStyle(IslandButtonStyle(primary: false))
                        Button("Allow") { decide(true) }.buttonStyle(IslandButtonStyle(primary: true))
                    }
                    .disabled(!armed).opacity(armed ? 1 : 0.5)
                }
                Text(more > 0 ? "+\(more) more waiting · no answer = ask in terminal"
                              : "No answer = Claude asks in the terminal")
                    .font(.system(size: 10)).foregroundStyle(.white.opacity(0.45))
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

struct IslandButtonStyle: ButtonStyle {
    let primary: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(primary ? Color.black : Color.white)
            .frame(maxWidth: .infinity, minHeight: 28)
            .background(primary ? Color.white : Color.white.opacity(0.14))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Rectangle())
    }
}

enum IslandLayout {
    /// Set at launch from the screen's safe-area; 0 on displays without a notch.
    nonisolated(unsafe) static var notchWidth: CGFloat = 0
    nonisolated(unsafe) static var notchHeight: CGFloat = 0
    static var collapsedWidth: CGFloat { notchWidth > 0 ? notchWidth + 150 : 170 }
    static var collapsedHeight: CGFloat { max(notchHeight, 34) }
    static let expandedWidth: CGFloat = 340
    static let panelWidth: CGFloat = 360
    /// Tall enough for an approval card plus a full trace; clicks outside the island pass through.
    static let panelHeight: CGFloat = 720
}
