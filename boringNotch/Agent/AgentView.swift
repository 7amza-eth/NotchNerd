//
//  AgentView.swift
//  NotchNerd — Phase 3 Agent panel UI
//
//  The expanded-notch "Agent" tab: live Claude Code sessions, with Allow/Deny on permission
//  prompts and answer buttons on questions. Binds to AgentBridgeManager.shared.
//

import Defaults
import SwiftUI
import OpenIslandCore

struct AgentView: View {
    @ObservedObject private var agent = AgentBridgeManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if agent.sessions.isEmpty {
                emptyState
            } else {
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
            statusChip
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

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle().fill(phaseColor).frame(width: 7, height: 7)
                Text(session.title.isEmpty ? "Claude Code" : session.title)
                    .font(.subheadline).lineLimit(1)
                Spacer(minLength: 4)
                if agent.canJump(session) {
                    Button { agent.jump(sessionID: session.id) } label: {
                        Image(systemName: "arrow.uturn.forward.square")
                    }
                    .buttonStyle(.plain)
                    .help("Jump to the Ghostty terminal")
                }
                Text(session.phase.displayName).font(.caption2).foregroundStyle(.secondary)
            }
            if !session.summary.isEmpty {
                Text(session.summary).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            }
            if let request = session.permissionRequest, session.phase == .waitingForApproval {
                permissionCard(request)
            } else if let question = session.questionPrompt, session.phase == .waitingForAnswer {
                questionCard(question)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.06)))
    }

    private var phaseColor: Color {
        switch session.phase {
        case .running: return .blue
        case .waitingForApproval: return .orange
        case .waitingForAnswer: return .yellow
        case .completed: return .gray
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
    @Default(.agentEnabled) var agentEnabled

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
        }
        .formStyle(.grouped)
        .navigationTitle("Agent")
        .onChange(of: agentEnabled) { _, enabled in
            if enabled { agent.start() } else { agent.stop() }
        }
        .onAppear { agent.refreshHookStatus() }
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
}
