//
//  AgentView.swift
//  NotchNerd — Agent panel UI
//
//  The expanded-notch "Agent" tab: live Claude Code sessions with an overview
//  row, expandable subagent/task detail, Allow/Deny on permission prompts,
//  answer buttons on questions, usage chips, and a Ghostty jump button.
//  Binds to AgentBridgeManager.shared + AgentUsageManager.shared.
//

import Defaults
import SwiftUI
import OpenIslandCore

struct AgentView: View {
    @ObservedObject private var agent = AgentBridgeManager.shared
    @ObservedObject private var usage = AgentUsageManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if agent.sessions.isEmpty {
                emptyState
            } else {
                overviewRow
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 6) {
                        ForEach(agent.sessions) { session in
                            AgentSessionRow(session: session)
                        }
                    }
                    .padding(.bottom, 4)
                }
            }
        }
        .padding(.horizontal, 6)
        .foregroundStyle(.white)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles").foregroundStyle(.purple)
            Text("Claude Code").font(.headline)
            Spacer()
            if Defaults[.agentUsageEnabled], let snap = usage.snapshot {
                if let fiveHour = snap.fiveHour { UsageChip(label: "5h", window: fiveHour) }
                if let sevenDay = snap.sevenDay { UsageChip(label: "7d", window: sevenDay) }
            }
            statusChip
        }
    }

    /// Total / waiting / running / done / idle, recomputed every 30s so the
    /// time-relative done/idle split stays current.
    private var overviewRow: some View {
        TimelineView(.periodic(from: .now, by: 30)) { ctx in
            let counts = AgentSessionOverview(sessions: agent.sessions, at: ctx.date)
            HStack(spacing: 10) {
                overviewMetric(counts.total, "total", .white.opacity(0.55))
                if counts.waiting > 0 { overviewMetric(counts.waiting, "waiting", AgentStatusPalette.waiting) }
                if counts.running > 0 { overviewMetric(counts.running, "running", AgentStatusPalette.running) }
                if counts.done > 0 { overviewMetric(counts.done, "done", AgentStatusPalette.completed) }
                if counts.idle > 0 { overviewMetric(counts.idle, "idle", AgentStatusPalette.idle) }
                Spacer(minLength: 0)
            }
        }
    }

    private func overviewMetric(_ count: Int, _ label: String, _ tint: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(tint).frame(width: 5.5, height: 5.5)
            Text("\(count) \(label)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var statusChip: some View {
        switch agent.hookInstallState {
        case .installed:
            Label("Hooks on", systemImage: "checkmark.seal.fill")
                .labelStyle(.titleAndIcon).font(.caption2).foregroundStyle(.green)
        case .notInstalled, .unknown:
            Button { agent.installHooks() } label: {
                Label("Install hooks", systemImage: "bolt.fill").font(.caption2)
            }
            .buttonStyle(.borderless).tint(.purple)
        case let .failed(message):
            Label("Hook error", systemImage: "exclamationmark.triangle.fill")
                .font(.caption2).foregroundStyle(.orange).help(message)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 4) {
            Spacer(minLength: 0)
            Image(systemName: "moon.zzz").font(.title3).foregroundStyle(.secondary)
            Text("No active Claude Code sessions").font(.caption).foregroundStyle(.secondary)
            if !agent.isBridgeReady && !agent.lastStatusMessage.isEmpty {
                Text(agent.lastStatusMessage).font(.caption2).foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct AgentSessionRow: View {
    let session: AgentSession
    @ObservedObject private var agent = AgentBridgeManager.shared
    @State private var isExpanded = false

    private var hasDetail: Bool {
        !(session.claudeMetadata?.activeSubagents.isEmpty ?? true)
            || !(session.claudeMetadata?.activeTasks.isEmpty ?? true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                AnimatedStatusDot(
                    color: AgentStatusPalette.tint(for: session.phase),
                    pulsing: session.phase == .running || session.phase.requiresAttention
                )
                Text(session.title.isEmpty ? "Claude Code" : session.title)
                    .font(.subheadline).lineLimit(1)
                Spacer(minLength: 4)
                Text(session.spotlightAgeBadge)
                    .font(.system(size: 9, design: .monospaced)).foregroundStyle(.tertiary)
                if hasDetail {
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            isExpanded.toggle()
                            if isExpanded {
                                AgentRowExpansion.userCollapsed.remove(session.id)
                            } else {
                                AgentRowExpansion.userCollapsed.insert(session.id)
                            }
                        }
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(isExpanded ? "Hide subagents and tasks" : "Show subagents and tasks")
                }
                if agent.canJump(session) {
                    Button { agent.jump(sessionID: session.id) } label: {
                        Image(systemName: "arrow.uturn.forward.square")
                    }
                    .buttonStyle(.plain)
                    .help("Jump to the Ghostty terminal")
                }
                Text(session.phase.displayName).font(.caption2).foregroundStyle(.secondary)
            }
            if let activity = session.spotlightActivityLineText, !activity.isEmpty {
                Text(activity).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            } else if !session.summary.isEmpty {
                Text(session.summary).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            }
            if let promptLine = session.spotlightPromptLineText {
                Text(promptLine).font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1)
            }
            if isExpanded && hasDetail {
                AgentSessionDetailView(session: session)
            }
            if let request = session.permissionRequest, session.phase == .waitingForApproval {
                permissionCard(request)
            } else if let question = session.questionPrompt, session.phase == .waitingForAnswer {
                questionCard(question)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.06)))
        .onAppear {
            isExpanded = hasDetail && session.phase.requiresAttention
                && !AgentRowExpansion.userCollapsed.contains(session.id)
        }
    }

    private func permissionCard(_ request: PermissionRequest) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(request.title).font(.caption).bold()
            if !request.summary.isEmpty {
                Text(request.summary).font(.caption2).foregroundStyle(.secondary).lineLimit(3)
            }
            HStack(spacing: 8) {
                Button(request.secondaryActionTitle.isEmpty ? "Deny" : request.secondaryActionTitle) {
                    agent.deny(sessionID: session.id)
                }
                .buttonStyle(.bordered).tint(.red).controlSize(.small)
                Button(request.primaryActionTitle.isEmpty ? "Allow" : request.primaryActionTitle) {
                    agent.approve(sessionID: session.id)
                }
                .buttonStyle(.borderedProminent).tint(.green).controlSize(.small)
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.14)))
    }

    private func questionCard(_ question: QuestionPrompt) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(question.title).font(.caption).bold()
            if question.options.isEmpty {
                Text("Waiting for your answer in the terminal.")
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                ForEach(question.options, id: \.self) { option in
                    Button(option) {
                        agent.answer(sessionID: session.id,
                                     response: QuestionPromptResponse(rawAnswer: option))
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                }
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.yellow.opacity(0.12)))
    }
}

/// Persistent closed-notch attention indicator (shown when a session needs the user).
struct AgentClosedIndicator: View {
    let count: Int
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "sparkles").foregroundStyle(.purple)
            Text("\(count)").font(.caption).bold().foregroundStyle(.white)
            Text(count == 1 ? "needs you" : "need you")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
    }
}

// MARK: - Settings pane

struct AgentSettings: View {
    @ObservedObject private var agent = AgentBridgeManager.shared
    @ObservedObject private var usage = AgentUsageManager.shared
    @Default(.agentEnabled) var agentEnabled
    @Default(.agentSoundEnabled) var agentSoundEnabled
    @Default(.agentSoundName) var agentSoundName
    @Default(.agentUsageEnabled) var agentUsageEnabled
    @Default(.agentNotificationsEnabled) var agentNotificationsEnabled

    var body: some View {
        Form {
            Section {
                Defaults.Toggle(key: .agentEnabled) { Text("Monitor Claude Code sessions") }
                Defaults.Toggle(key: .agentPanelEnabled) { Text("Show the Agent tab in the notch") }
            } header: {
                Text("Agent")
            } footer: {
                Text("Watches Claude Code through its hooks. Local-only — NotchNerd never calls the Anthropic API and stores no credentials.")
            }

            Section {
                HStack {
                    Text("Status")
                    Spacer()
                    hookStatusLabel
                }
                Defaults.Toggle(key: .agentAutoInstallHooks) { Text("Install hooks automatically on launch") }
                HStack {
                    Button("Install hooks") { agent.installHooks() }
                    Button("Remove hooks") { agent.uninstallHooks() }
                    Spacer()
                    Button("Refresh") { agent.refreshHookStatus() }
                }
            } header: {
                Text("Claude Code hooks")
            } footer: {
                Text("Adds managed entries to ~/.claude/settings.json so NotchNerd can show live session status and let you approve/deny permission prompts from the notch. Your settings are backed up first; fully reversible.")
            }

            Section {
                Defaults.Toggle(key: .agentNotificationsEnabled) { Text("Pop the notch on agent events") }
                Defaults.Toggle(key: .agentAutoOpenNotch) { Text("Auto-open the notch (off = sound + indicator only)") }
                Defaults.Toggle(key: .agentNotifyOnCompletion) { Text("Notify when a session finishes") }
                Defaults.Toggle(key: .agentSuppressWhenFrontmost) { Text("Don't pop if the session's terminal is already focused") }
            } header: {
                Text("Notifications")
            } footer: {
                Text("Permission and question prompts stay until you answer them; completion notices auto-dismiss after 10 seconds.")
            }
            .disabled(!agentNotificationsEnabled)

            Section {
                Defaults.Toggle(key: .agentSoundEnabled) { Text("Play a sound when a session needs you") }
                Defaults.Toggle(key: .agentSoundMuted) { Text("Mute") }
                Picker("Sound", selection: $agentSoundName) {
                    ForEach(AgentNotificationSound.availableSounds(), id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                .onChange(of: agentSoundName) { _, name in AgentNotificationSound.play(name) }
                Button("Preview") { AgentNotificationSound.play(agentSoundName) }
            } header: {
                Text("Sound")
            } footer: {
                Text("Uses a macOS system sound from /System/Library/Sounds.")
            }
            .disabled(!agentSoundEnabled)

            Section {
                Defaults.Toggle(key: .agentUsageEnabled) { Text("Show Claude usage (5h / 7d quotas)") }
                HStack {
                    Text("Statusline")
                    Spacer()
                    usageStatusLabel
                }
                HStack {
                    Button("Install") { usage.installIfNeeded() }
                    Button("Remove") { usage.uninstall() }
                    Spacer()
                    Button("Refresh") { usage.refreshStatus() }
                }
            } header: {
                Text("Usage")
            } footer: {
                Text("Adds a managed statusLine entry to Claude Code's settings.json that records your remaining quota. If you already have a custom statusline, NotchNerd wraps it so it keeps working. Reversible.")
            }
            .disabled(!agentUsageEnabled)
        }
        .formStyle(.grouped)
        .navigationTitle("Agent")
        .onChange(of: agentEnabled) { _, enabled in
            if enabled { agent.start() } else { agent.stop() }
        }
        .onChange(of: agentUsageEnabled) { _, enabled in
            if enabled { usage.start() } else { usage.uninstall(); usage.stop() }
        }
        .onAppear {
            agent.refreshHookStatus()
            usage.refreshStatus()
        }
    }

    @ViewBuilder private var hookStatusLabel: some View {
        switch agent.hookInstallState {
        case .installed:
            Label("Installed", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
        case .notInstalled:
            Label("Not installed", systemImage: "circle").foregroundStyle(.secondary)
        case .unknown:
            Text("—").foregroundStyle(.secondary)
        case let .failed(message):
            Label("Error", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange).help(message)
        }
    }

    @ViewBuilder private var usageStatusLabel: some View {
        switch usage.installState {
        case .installed:
            Label("Installed", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
        case .notInstalled:
            Label("Not installed", systemImage: "circle").foregroundStyle(.secondary)
        case .unknown:
            Text("—").foregroundStyle(.secondary)
        case let .failed(message):
            Label("Error", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange).help(message)
        }
    }
}
