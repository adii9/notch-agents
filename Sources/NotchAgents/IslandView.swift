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
        // Content stays clear of the outward-curving "ears" at the top corners.
        .padding(.horizontal, (expanded ? 14 : 10) + shape.topRadius)
        .padding(.bottom, expanded ? 14 : 0)
        .frame(width: expanded ? IslandLayout.expandedWidth : IslandLayout.collapsedWidth,
               height: expanded ? nil : IslandLayout.collapsedHeight)
        .background(Color.black)
        .clipShape(shape)
        .shadow(color: .black.opacity(expanded ? 0.5 : 0), radius: 12, y: 4)
        .animation(.spring(response: 0.38, dampingFraction: 0.78), value: expanded)
    }

    /// Flush with the top of the screen like the hardware notch, so the island reads as the notch growing.
    private var shape: NotchShape {
        expanded ? NotchShape(topRadius: 14, bottomRadius: 24) : NotchShape(topRadius: 6, bottomRadius: 12)
    }

    /// Compact live activity: status on the left of the camera housing, timer or count on the right.
    private var collapsedBody: some View {
        HStack(spacing: 0) {
            Group {
                if let prompt = store.pending.first {
                    Image(systemName: prompt.isQuestion ? "questionmark.bubble.fill" : "hand.raised.fill")
                        .foregroundStyle(prompt.isQuestion ? Color.blue : Color.orange)
                        .symbolEffect(.pulse)
                } else if store.running.isEmpty {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    ActivityRing()
                }
            }
            .font(.system(size: 13, weight: .semibold))
            .frame(width: 18, height: 18)
            Spacer(minLength: IslandLayout.notchWidth)
            trailingCompact
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                .lineLimit(1).fixedSize()
        }
        .frame(maxHeight: .infinity)
    }

    @ViewBuilder private var trailingCompact: some View {
        if store.running.count == 1, let agent = store.running.first {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                Text(format(ctx.date.timeIntervalSince(agent.startedAt)))
                    .font(.system(size: 12, weight: .semibold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(.orange)
            }
        } else if store.running.count > 1 {
            HStack(spacing: 4) {
                Image(systemName: "sparkles").foregroundStyle(.orange)
                Text("\(store.running.count)").monospacedDigit()
            }
        } else {
            Text("Done").foregroundStyle(.green)
        }
    }

    private var expandedBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            Color.clear.frame(height: IslandLayout.notchHeight)
            // Approvals first: they block Claude. Questions are only a heads-up.
            if let prompt = store.pending.first(where: { !$0.isQuestion }) ?? store.pending.first {
                let terminal = store.terminal(forAgent: prompt.agentKey)
                ApprovalCard(prompt: prompt, more: store.pending.count - 1,
                             decide: { allow in store.decide(prompt.id, allow: allow) },
                             dismiss: { store.dismiss(prompt.id) },
                             openTerminal: terminal.map { t in { TerminalLocator.focus(t) } })
            }
            ForEach(store.agents) { agent in
                let tint = agent.state == .running ? Color.orange : Color.green
                HStack(spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 9, style: .continuous).fill(tint.opacity(0.18))
                        Image(systemName: agent.state == .running ? "sparkle" : "checkmark")
                            .font(.system(size: 14, weight: .bold)).foregroundStyle(tint)
                            .symbolEffect(.pulse, isActive: agent.state == .running)
                    }
                    .frame(width: 32, height: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(agent.type).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                        Text("\(agent.project) · " + (agent.currentTool ?? (agent.state == .running ? "thinking…" : "finished")))
                            .font(.system(size: 11)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                    }
                    Spacer()
                    if let terminal = store.terminal(forAgent: agent.id) {
                        Button { TerminalLocator.focus(terminal) } label: {
                            Image(systemName: "arrow.up.forward.app")
                                .font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
                                .frame(width: 22, height: 22).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(terminal.desktopChat != nil ? "Open this chat in Claude"
                              : terminal.tty == nil ? "Open the app this session runs in" : "Jump to this session's terminal")
                    }
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        let end = agent.endedAt ?? ctx.date
                        Text(format(end.timeIntervalSince(agent.startedAt)))
                            .font(.system(size: 11, design: .monospaced)).foregroundStyle(.white.opacity(0.6))
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { store.tracedAgent = agent.id }
                if !agent.tasks.isEmpty && agent.id != traced {
                    TaskProgressBar(done: agent.tasks.filter { $0.status == "completed" }.count,
                                    total: agent.tasks.count, tint: tint)
                        .padding(.leading, 42)
                }
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
    /// UserDefaults key for the menu's "Show recent steps"; off unless the user turns it on.
    static let showStepsKey = "showRecentSteps"
    @AppStorage(TraceView.showStepsKey) private var showSteps = false

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
            if showSteps && !agent.steps.isEmpty {
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
        .padding(.leading, 42)
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
    /// Brings the session's terminal forward; nil when it couldn't be found.
    let openTerminal: (() -> Void)?
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
                // Full command stays readable: short ones take only their own height, long ones scroll
                // instead of being cut off.
                CappedHeight(max: 120) {
                    ViewThatFits(in: .vertical) {
                        detailText
                        ScrollView(.vertical) { detailText }
                    }
                }
            }
            if prompt.isQuestion {
                HStack {
                    if let openTerminal {
                        Button("Answer in terminal", action: openTerminal).buttonStyle(IslandButtonStyle(primary: true))
                    } else {
                        Text("Answer it in the terminal").font(.system(size: 10)).foregroundStyle(.white.opacity(0.45))
                        Spacer()
                    }
                    Button("Dismiss", action: dismiss).buttonStyle(IslandButtonStyle(primary: false)).frame(width: 90)
                }
            } else {
                TimelineView(.periodic(from: .now, by: 0.25)) { ctx in
                    let armed = ctx.date.timeIntervalSince(prompt.createdAt) >= Self.armDelay
                    HStack(spacing: 8) {
                        Button { decide(false) } label: { ButtonLabel(title: "Deny", key: ApprovalHotKeys.denyLabel) }
                            .buttonStyle(IslandButtonStyle(primary: false))
                        Button { decide(true) } label: { ButtonLabel(title: "Allow", key: ApprovalHotKeys.allowLabel) }
                            .buttonStyle(IslandButtonStyle(primary: true))
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

/// Offers its child at most `max` points of height but takes only what the child uses.
/// (`.frame(maxHeight:)` would always grow to `max` whenever more room is offered.)
struct CappedHeight: Layout {
    let max: CGFloat
    private func capped(_ p: ProposedViewSize) -> ProposedViewSize {
        ProposedViewSize(width: p.width, height: min(p.height ?? max, max))
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        subviews.first?.sizeThatFits(capped(proposal)) ?? .zero
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: capped(proposal))
    }
}

/// A button title with its keyboard shortcut beside it.
struct ButtonLabel: View {
    let title: String
    let key: String
    var body: some View {
        HStack(spacing: 6) {
            Text(title)
            Text(key).font(.system(size: 10, weight: .medium)).opacity(0.55)
        }
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

/// The hardware notch's silhouette: square top flush with the screen edge, concave curves flaring
/// into the menu bar at the top corners, rounded bottom corners. Both radii animate.
struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set { topRadius = newValue.first; bottomRadius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let t = topRadius, b = bottomRadius
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.minX + t, y: rect.minY + t), control: CGPoint(x: rect.minX + t, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX + t, y: rect.maxY - b))
        p.addQuadCurve(to: CGPoint(x: rect.minX + t + b, y: rect.maxY), control: CGPoint(x: rect.minX + t, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - t - b, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - t, y: rect.maxY - b), control: CGPoint(x: rect.maxX - t, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - t, y: rect.minY + t))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: rect.maxX - t, y: rect.minY))
        p.closeSubpath()
        return p
    }
}

/// Spinning arc for "working", in place of the stock spinner.
struct ActivityRing: View {
    var body: some View {
        TimelineView(.animation) { ctx in
            Circle()
                .trim(from: 0.15, to: 1)
                .stroke(AngularGradient(colors: [.orange.opacity(0), .orange], center: .center),
                        style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .frame(width: 14, height: 14)
                .rotationEffect(.degrees(ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1) * 360))
        }
    }
}

/// Slim progress bar for an agent's task list.
struct TaskProgressBar: View {
    let done: Int
    let total: Int
    let tint: Color
    var body: some View {
        HStack(spacing: 8) {
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.12))
                    Capsule().fill(tint).frame(width: g.size.width * CGFloat(done) / CGFloat(max(total, 1)))
                }
            }
            .frame(height: 4)
            Text("\(done)/\(total)").font(.system(size: 10, weight: .medium)).monospacedDigit()
                .foregroundStyle(.white.opacity(0.5))
        }
    }
}

enum IslandLayout {
    /// Set at launch from the screen's safe-area; 0 on displays without a notch.
    nonisolated(unsafe) static var notchWidth: CGFloat = 0
    nonisolated(unsafe) static var notchHeight: CGFloat = 0
    /// Room on each side of the camera housing for the compact live-activity content, plus the top ears.
    static var collapsedWidth: CGFloat { (notchWidth > 0 ? notchWidth : 120) + 2 * 60 + 12 }
    /// Exactly the hardware notch's height so the two blend into one shape.
    static var collapsedHeight: CGFloat { notchHeight > 0 ? notchHeight : 32 }
    static let expandedWidth: CGFloat = 360
    static let panelWidth: CGFloat = 400
    /// Tall enough for an approval card plus a full trace; clicks outside the island pass through.
    static let panelHeight: CGFloat = 720
}
