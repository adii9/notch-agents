import SwiftUI

struct IslandView: View {
    let store: AgentStore
    let expanded: Bool

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
            }
        }
    }

    private func format(_ t: TimeInterval) -> String {
        let s = Int(t)
        return s < 60 ? "\(s)s" : "\(s / 60)m \(s % 60)s"
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
    static let panelHeight: CGFloat = 320
}
