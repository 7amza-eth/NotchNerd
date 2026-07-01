//
//  AgentSessionDetails.swift
//  NotchNerd — expandable subagent / task detail for the Agent tab
//
//  A NotchNerd-authored view that renders a session's live subagents and
//  task checklist from the vendored `ClaudeSessionMetadata`. Visual logic
//  adapted from Open Island's IslandPanelView subagent/task rows (GPL v3),
//  retinted to NotchNerd's palette.
//

import AppKit
import SwiftUI
import OpenIslandCore

/// Per-phase status tints for the Agent tab (NotchNerd palette).
enum AgentStatusPalette {
    static let waiting = Color(red: 231 / 255, green: 167 / 255, blue: 98 / 255)   // approval (amber)
    static let answer = Color(red: 255 / 255, green: 213 / 255, blue: 138 / 255)   // question (yellow)
    static let running = Color(red: 110 / 255, green: 167 / 255, blue: 255 / 255)  // live (blue)
    static let completed = Color(red: 111 / 255, green: 185 / 255, blue: 130 / 255) // done (green)
    static let error = Color(red: 229 / 255, green: 112 / 255, blue: 79 / 255)      // failed (red-orange)
    static let idle = Color.white.opacity(0.35)

    static func tint(for phase: SessionPhase) -> Color {
        switch phase {
        case .running: return running
        case .waitingForApproval: return waiting
        case .waitingForAnswer: return answer
        case .completed: return completed
        }
    }

    /// Presence-based tint (folds stale-completed rows into idle).
    static func tint(for presence: IslandSessionPresence, phase: SessionPhase) -> Color {
        switch presence {
        case .running: return running
        case .active: return tint(for: phase)
        case .inactive: return idle
        }
    }
}

/// Renders a session's active subagents + task checklist (shown when a row is expanded).
struct AgentSessionDetailView: View {
    let session: AgentSession

    private var subagents: [ClaudeSubagentInfo] { session.claudeMetadata?.activeSubagents ?? [] }
    private var tasks: [ClaudeTaskInfo] { session.claudeMetadata?.activeTasks ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !subagents.isEmpty { subagentsSection }
            if !tasks.isEmpty { tasksSection }
        }
        .padding(.top, 2)
    }

    // MARK: Subagents

    private var subagentsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Subagents (\(subagents.count))", systemImage: "arrow.triangle.branch")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color.cyan.opacity(0.9))
            ForEach(subagents, id: \.agentID) { sub in
                subagentRow(sub)
            }
        }
    }

    private func subagentRow(_ sub: ClaudeSubagentInfo) -> some View {
        let isDone = sub.summary != nil
        return HStack(alignment: .top, spacing: 5) {
            Circle()
                .fill(isDone ? AgentStatusPalette.completed : AgentStatusPalette.running)
                .frame(width: 5, height: 5)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 1) {
                Text(sub.agentType ?? sub.agentID)
                    .font(.caption2).foregroundStyle(.white.opacity(0.9)).lineLimit(1)
                if let task = sub.taskDescription, !task.isEmpty {
                    Text(task).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if isDone {
                Text("done").font(.system(size: 9)).foregroundStyle(AgentStatusPalette.completed)
            } else if let started = sub.startedAt {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    Text(Self.elapsed(since: started, at: ctx.date))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Tasks

    private var tasksSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(Self.taskSummary(tasks))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white.opacity(0.7))
            ForEach(tasks) { task in
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Self.taskIcon(task.status)
                    Text(task.title)
                        .font(.caption2)
                        .foregroundStyle(task.status == .completed ? Color.secondary : Color.white.opacity(0.9))
                        .strikethrough(task.status == .completed)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    // MARK: Helpers

    @ViewBuilder
    static func taskIcon(_ status: ClaudeTaskInfo.Status) -> some View {
        switch status {
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 10)).foregroundStyle(AgentStatusPalette.completed)
        case .inProgress:
            Image(systemName: "circle.dotted")
                .font(.system(size: 10)).foregroundStyle(AgentStatusPalette.running)
        case .pending:
            Image(systemName: "circle")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }

    static func taskSummary(_ tasks: [ClaudeTaskInfo]) -> String {
        let done = tasks.filter { $0.status == .completed }.count
        return "Tasks · \(done)/\(tasks.count)"
    }

    static func elapsed(since start: Date, at now: Date) -> String {
        let secs = max(0, Int(now.timeIntervalSince(start)))
        if secs < 60 { return "\(secs)s" }
        if secs < 3_600 { return "\(secs / 60)m \(secs % 60)s" }
        return "\(secs / 3_600)h \((secs % 3_600) / 60)m"
    }
}

/// Expanded content for any session row (expansion state is manager-owned —
/// `AgentBridgeManager.expandedSessionIDs` — so it survives row-view teardown).
/// Shows Claude's full last message (the metadata stores the raw, un-truncated
/// `last_assistant_message` hook field — the 140-char cap is view-layer), the
/// session's full goal, and live subagents + tasks when present.
struct AgentSessionExpandedView: View {
    let session: AgentSession
    let hasDetail: Bool

    /// Collapsed-by-default clamp for long messages. Per-view state: losing it on
    /// remount just re-clamps, which is the safe default anyway.
    @State private var showFullMessage = false
    @State private var justCopied = false

    private var lastMessage: String? {
        guard let text = session.lastAssistantMessageText?
            .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    /// Worth a Show-more toggle only when the clamp plausibly bites.
    private func isLong(_ text: String) -> Bool {
        text.count > 350 || text.filter(\.isNewline).count >= 8
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let message = lastMessage {
                lastMessageSection(message)
            }
            // Full goal (initial prompt), un-truncated — the collapsed row clips it to one line.
            if let goal = session.initialUserPromptText?.trimmingCharacters(in: .whitespacesAndNewlines),
               !goal.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Goal").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                    Text(goal)
                        .font(.caption2).foregroundStyle(.secondary)
                        .lineLimit(showFullMessage ? nil : 4)
                        .textSelection(.enabled)
                }
            }
            if hasDetail {
                AgentSessionDetailView(session: session)
            } else if lastMessage == nil && session.initialUserPromptText == nil {
                Text("No details yet").font(.system(size: 9)).foregroundStyle(.tertiary)
            }
        }
        .padding(.top, 2)
    }

    private func lastMessageSection(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text("Last message").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                Spacer(minLength: 4)
                // Explicit copy button — textSelection drag is fiddly on the non-key notch panel.
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(message, forType: .string)
                    justCopied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { justCopied = false }
                } label: {
                    Label(justCopied ? "Copied" : "Copy",
                          systemImage: justCopied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 9))
                        .foregroundStyle(justCopied ? AgentStatusPalette.completed : .secondary)
                }
                .buttonStyle(.plain)
                .help("Copy Claude's full last message")
            }
            Text(message)
                .font(.caption2).foregroundStyle(.white.opacity(0.85))
                .lineLimit(showFullMessage ? nil : 8)
                .textSelection(.enabled)
            if isLong(message) {
                Button(showFullMessage ? "Show less" : "Show more") {
                    withAnimation(.easeInOut(duration: 0.15)) { showFullMessage.toggle() }
                }
                .buttonStyle(.plain)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.blue)
            }
        }
    }
}

/// A small status dot that pulses while a session is running or needs attention.
struct AnimatedStatusDot: View {
    let color: Color
    let pulsing: Bool
    @State private var animate = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .opacity(pulsing ? (animate ? 0.4 : 1.0) : 1.0)
            .animation(pulsing ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true) : .default,
                       value: animate)
            .onAppear { animate = pulsing }
            .onChange(of: pulsing) { _, newValue in animate = newValue }
    }
}

/// Session counts for the Agent tab overview row. `done`/`idle` split is
/// time-relative, so build it inside a `TimelineView`.
struct AgentSessionOverview {
    let total: Int
    let waiting: Int
    let running: Int
    let done: Int
    let idle: Int

    init(sessions: [AgentSession], at date: Date) {
        total = sessions.count
        waiting = sessions.filter { $0.phase.requiresAttention }.count
        running = sessions.filter { $0.phase == .running }.count
        let completed = sessions.filter { $0.phase == .completed }
        let idleCount = completed.filter {
            $0.isStaleCompletedForIsland(at: date) || $0.islandPresence(at: date) == .inactive
        }.count
        idle = idleCount
        done = completed.count - idleCount
    }
}
