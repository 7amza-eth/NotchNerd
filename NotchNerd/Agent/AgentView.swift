//
//  AgentView.swift
//  NotchNerd — Agent panel UI
//
//  The expanded-notch "Agent" tab: live Claude Code sessions with an overview
//  row, expandable subagent/task detail, Allow/Deny on permission prompts,
//  answer buttons on questions, usage chips, and a Ghostty jump button.
//  Binds to AgentBridgeManager.shared + AgentUsageManager.shared.
//

import AppKit
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

    /// Manager-owned so expansion survives row-view teardown (notch reopen / tab switch).
    private var isExpanded: Bool { agent.expandedSessionIDs.contains(session.id) }

    private var hasDetail: Bool {
        !(session.claudeMetadata?.activeSubagents.isEmpty ?? true)
            || !(session.claudeMetadata?.activeTasks.isEmpty ?? true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                AnimatedStatusDot(
                    color: AgentStatusPalette.tint(for: session.phase),
                    pulsing: session.phase == .running || session.phase.requiresAttention
                )
                Text(session.title.isEmpty ? "Claude Code" : session.title)
                    .font(.subheadline).lineLimit(1)
                Spacer(minLength: 4)
                if let progress = session.taskProgress {
                    Label("\(progress.done)/\(progress.total)", systemImage: "checklist")
                        .labelStyle(.titleAndIcon)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .help("\(progress.done) of \(progress.total) tasks done")
                }
                Text(session.spotlightAgeBadge)
                    .font(.system(size: 9, design: .monospaced)).foregroundStyle(.tertiary)
                    .help("Time since last activity")
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .foregroundStyle(.secondary)
                if agent.canJump(session) {
                    Button { agent.jump(sessionID: session.id) } label: {
                        Image(systemName: "arrow.uturn.forward.square")
                    }
                    .buttonStyle(.plain)
                    .help("Jump to the terminal")
                }
            }
            // The whole header row is the expand/collapse affordance ("click the session box").
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.18)) {
                    agent.toggleExpansion(session.id)
                }
            }
            .help(isExpanded ? "Hide details" : "Show details")
            // Identity context — branch · terminal · model · mode — so same-repo sessions are distinct.
            if !session.identityChips.isEmpty {
                Text(session.identityChips.joined(separator: "  ·  "))
                    .font(.system(size: 9)).foregroundStyle(.tertiary).lineLimit(1)
            }
            // Waiting-on-subagents chip — on the activity line, not the crowded header row.
            if session.phase == .running, let researching = session.subagentSummary {
                Label(researching, systemImage: "arrow.triangle.branch")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Color.cyan.opacity(0.9))
            }
            // Recap (the outcome / current activity) instead of a raw transcript line. Running
            // sessions get a per-activity icon (thinking/bash/edit/search/…) so different kinds of
            // "running" are tellable apart at a glance; the subagent chip above already carries the
            // researching state, so the icon resolves the underlying tool instead.
            if let recap = session.recapLineText, !recap.isEmpty {
                if session.phase == .running {
                    let descriptor = AgentActivity.resolve(for: session, ignoringSubagents: true).descriptor
                    Label {
                        Text(recap).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                    } icon: {
                        Image(systemName: descriptor.symbol)
                            .font(.system(size: 9))
                            .foregroundStyle(descriptor.tint)
                    }
                } else {
                    Text(recap).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            // The session's goal (its initial prompt), so a long/drifted session still shows its purpose.
            if let goal = session.recapGoalText, !goal.isEmpty {
                Text("↳ \(goal)").font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1)
            }
            if isExpanded {
                AgentSessionExpandedView(session: session, hasDetail: hasDetail)
            }
            if let request = session.permissionRequest, session.phase == .waitingForApproval {
                if request.toolName == "ExitPlanMode" {
                    PlanReviewCard(session: session, request: request)
                } else {
                    permissionCard(request)
                }
            } else if let question = session.questionPrompt, session.phase == .waitingForAnswer {
                QuestionCard(prompt: question) { response in
                    agent.answer(sessionID: session.id, response: response)
                }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.06)))
    }

    private func permissionCard(_ request: PermissionRequest) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(request.title).font(.caption).bold()
            if !request.summary.isEmpty {
                Text(request.summary).font(.caption2).foregroundStyle(.secondary).lineLimit(3)
            }
            // Claude's structured one-tap options ("Yes, always allow Bash …", mode changes) — these
            // allow AND persist the rule/mode, vs. the generic allow-once below. Round-trips through
            // resolve(.allowWithUpdates) → the engine's allowOnce(updatedPermissions:).
            if !request.suggestedUpdates.isEmpty {
                ForEach(Array(request.suggestedUpdates.enumerated()), id: \.offset) { _, update in
                    Button {
                        agent.resolve(sessionID: session.id, action: .allowWithUpdates([update]))
                    } label: {
                        Label(update.displayLabel, systemImage: "checkmark.circle")
                            .font(.caption2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.bordered).tint(.green).controlSize(.small)
                }
            }
            HStack(spacing: 8) {
                Button(request.secondaryActionTitle.isEmpty ? "Deny" : request.secondaryActionTitle) {
                    agent.deny(sessionID: session.id)
                }
                .buttonStyle(.bordered).tint(.red).controlSize(.small)
                Button(allowButtonTitle(for: request)) {
                    agent.approve(sessionID: session.id)
                }
                .buttonStyle(.borderedProminent).tint(.green).controlSize(.small)
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.14)))
    }

    private func allowButtonTitle(for request: PermissionRequest) -> String {
        // When Claude offers persistent "always allow" options above, the generic button is allow-once.
        if !request.suggestedUpdates.isEmpty { return "Allow once" }
        return request.primaryActionTitle.isEmpty ? "Allow" : request.primaryActionTitle
    }

}

/// Plan-mode review card, shown instead of the generic permission card when Claude calls
/// `ExitPlanMode`. Mirrors the real CLI plan-approval menu (labels/values verified against the
/// Claude Code v2.1.198 binary — see spec.md v0.3): the leading "yes" option depends on the
/// session's mode ("Yes, and use auto mode" for auto sessions, else "Yes, auto-accept edits"),
/// then "Yes, manually approve edits", an Ultraplan jump-to-terminal escape hatch, and
/// "No, keep planning" with a first-class feedback field. Each "yes" round-trips
/// allow + setMode(.session, mode) — the CLI provably applies updatedPermissions from
/// PermissionRequest hooks. Do NOT use ClaudePermissionUpdate.displayLabel here (its mapping is
/// inverted vs. the real menu).
struct PlanReviewCard: View {
    let session: AgentSession
    let request: PermissionRequest
    @ObservedObject private var agent = AgentBridgeManager.shared

    @State private var planText: String?
    @State private var planLoaded = false
    @State private var resolving = false
    @State private var showFeedback = false
    @State private var feedback = ""
    @FocusState private var feedbackFocused: Bool

    private struct PlanChoice {
        let label: String
        let mode: ClaudePermissionMode
        let prominent: Bool
    }

    /// CLI-mirrored "yes" options: the first (prominent) entry matches what the terminal shows
    /// first for this session's current mode; mutually exclusive auto variants, like the CLI.
    private var choices: [PlanChoice] {
        let first: PlanChoice = session.claudeMetadata?.permissionMode == .auto
            ? PlanChoice(label: "Yes, and use auto mode", mode: .auto, prominent: true)
            : PlanChoice(label: "Yes, auto-accept edits", mode: .acceptEdits, prominent: true)
        return [first, PlanChoice(label: "Yes, manually approve edits", mode: .default, prominent: false)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "list.clipboard").font(.caption).foregroundStyle(.purple)
                Text("Claude finished planning").font(.caption).bold()
            }

            planBody

            if resolving {
                Text("Sent — waiting for Claude…").font(.system(size: 9)).foregroundStyle(.tertiary)
            }

            ForEach(Array(choices.enumerated()), id: \.offset) { _, choice in
                planButton(choice)
            }

            if agent.canJump(session) {
                Button {
                    agent.jump(sessionID: session.id)
                } label: {
                    Label("Refine with Ultraplan — continue in terminal", systemImage: "arrow.uturn.forward.square")
                        .font(.system(size: 9))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderless).tint(.secondary).controlSize(.small)
                .help("Ultraplan runs in the terminal/cloud — it can't be started from a hook")
            }

            keepPlanningSection
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.14)))
        .disabled(resolving)
        .task(id: request.id) {
            guard let path = session.claudeMetadata?.transcriptPath else { planLoaded = true; return }
            let toolUseID = request.toolUseID
            planText = await Task.detached(priority: .userInitiated) {
                PlanTextLoader.loadPlan(transcriptPath: path, toolUseID: toolUseID)
            }.value
            planLoaded = true
        }
        // Same non-key-panel dance as QuestionCard: the feedback field needs the notch to be key.
        .background { if showFeedback { NotchFreeformKeyMaker() } }
        .onChange(of: showFeedback) { _, active in
            NotepadNotchFocus.allowsNotchKey = active
            SharingStateManager.shared.preventNotchClose = active
            if active { feedbackFocused = true }
        }
        .onDisappear {
            if showFeedback {
                NotepadNotchFocus.allowsNotchKey = false
                SharingStateManager.shared.preventNotchClose = false
            }
        }
    }

    @ViewBuilder private var planBody: some View {
        if let plan = planText {
            ScrollView(.vertical) {
                Text(plan)
                    .font(.system(size: 10))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(maxHeight: 160)
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(0.4)))
        } else if !planLoaded {
            Text("Loading plan…").font(.caption2).foregroundStyle(.tertiary)
        } else if !request.summary.isEmpty {
            // Transcript unavailable — fall back to the engine's summary line.
            Text(request.summary).font(.caption2).foregroundStyle(.secondary).lineLimit(3)
        }
    }

    private func planButton(_ choice: PlanChoice) -> some View {
        Button {
            resolving = true
            agent.resolve(
                sessionID: session.id,
                action: .allowWithUpdates([.setMode(destination: .session, mode: choice.mode)])
            )
        } label: {
            Text(choice.label)
                .font(.caption2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.bordered)
        .tint(choice.prominent ? .green : .blue)
        .controlSize(.small)
    }

    @ViewBuilder private var keepPlanningSection: some View {
        if showFeedback {
            VStack(alignment: .leading, spacing: 4) {
                TextField("Tell Claude what to change", text: $feedback)
                    .textFieldStyle(.roundedBorder).controlSize(.small)
                    .focused($feedbackFocused)
                    .onSubmit { sendKeepPlanning() }
                HStack(spacing: 8) {
                    Button("Send & keep planning") { sendKeepPlanning() }
                        .buttonStyle(.borderedProminent).tint(.orange).controlSize(.small)
                    Button("Cancel") {
                        showFeedback = false
                        feedback = ""
                    }
                    .buttonStyle(.borderless).controlSize(.small)
                }
            }
        } else {
            Button {
                showFeedback = true
            } label: {
                Text("No, keep planning…")
                    .font(.caption2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.bordered).tint(.red).controlSize(.small)
            .help("Claude stays in plan mode; optionally tell it what to change")
        }
    }

    private func sendKeepPlanning() {
        resolving = true
        showFeedback = false
        agent.keepPlanning(sessionID: session.id, feedback: feedback)
    }
}

/// Interactive answer card for Claude's AskUserQuestion. Renders EVERY question (not just the first),
/// supports multi-select (toggle, no auto-submit), per-option ASCII/code previews, and a freeform
/// "Other" answer, then submits all answers together via a single Submit. Mirrors the engine
/// round-trip's per-question `answers` dict + preview annotations.
struct QuestionCard: View {
    let prompt: QuestionPrompt
    let onSubmit: (QuestionPromptResponse) -> Void

    @State private var selected: [Int: Set<String>] = [:]   // question index → selected option labels
    @State private var freeform: [Int: String] = [:]        // question index → typed "Other" text
    @State private var expandedPreviews: Set<UUID> = []     // option ids whose preview is expanded
    @FocusState private var focusedQuestion: Int?           // which freeform field holds keyboard focus

    /// Any question currently shows its freeform ("Other") field.
    private var hasActiveFreeform: Bool {
        prompt.questions.indices.contains { isFreeformActive(index: $0, question: prompt.questions[$0]) }
    }
    private var firstFreeformIndex: Int? {
        prompt.questions.indices.first { isFreeformActive(index: $0, question: prompt.questions[$0]) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if prompt.questions.isEmpty {
                Text(prompt.title).font(.caption).bold()
                Text("Waiting for your answer in the terminal.")
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                if prompt.questions.count > 1 {
                    Text(prompt.title).font(.caption).bold()
                }
                ForEach(Array(prompt.questions.enumerated()), id: \.offset) { index, question in
                    questionSection(index: index, question: question)
                }
                Button("Submit") { submit() }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                    .disabled(!allAnswered)
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.yellow.opacity(0.12)))
        .background {
            // The notch panel is non-key (click-through) by default, so a TextField can't get keyboard
            // input. While a freeform ("Other") field is showing, flip the shared gate + make the notch
            // window key — the same trick the in-notch Notes tab uses — and keep the notch open.
            if hasActiveFreeform { NotchFreeformKeyMaker() }
        }
        .onChange(of: hasActiveFreeform) { _, active in
            NotepadNotchFocus.allowsNotchKey = active
            SharingStateManager.shared.preventNotchClose = active
            if active { focusedQuestion = firstFreeformIndex }
        }
        .onDisappear {
            NotepadNotchFocus.allowsNotchKey = false
            SharingStateManager.shared.preventNotchClose = false
        }
    }

    @ViewBuilder
    private func questionSection(index: Int, question: QuestionPromptItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(question.question).font(.caption).bold()
            if question.multiSelect {
                Text("Select all that apply").font(.system(size: 9)).foregroundStyle(.tertiary)
            }
            ForEach(question.options) { option in
                optionRow(index: index, question: question, option: option)
            }
            if isFreeformActive(index: index, question: question) {
                TextField("Type your answer", text: freeformBinding(index))
                    .textFieldStyle(.roundedBorder).controlSize(.small)
                    .focused($focusedQuestion, equals: index)
            }
        }
    }

    @ViewBuilder
    private func optionRow(index: Int, question: QuestionPromptItem, option: QuestionOption) -> some View {
        let isSelected = selected[index, default: []].contains(option.label)
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .top, spacing: 6) {
                Button {
                    toggle(index: index, question: question, label: option.label)
                } label: {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: selectionSymbol(multiSelect: question.multiSelect, isSelected: isSelected))
                            .foregroundStyle(isSelected ? .green : .secondary)
                            .font(.system(size: 11))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(option.label).font(.caption2)
                            if !option.description.isEmpty {
                                Text(option.description).font(.system(size: 9)).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .buttonStyle(.plain)
                Spacer(minLength: 4)
                if option.preview != nil {
                    Button {
                        if expandedPreviews.contains(option.id) {
                            expandedPreviews.remove(option.id)
                        } else {
                            expandedPreviews.insert(option.id)
                        }
                    } label: {
                        Image(systemName: expandedPreviews.contains(option.id) ? "eye.slash" : "eye")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.plain)
                    .help("Show preview")
                }
            }
            if let preview = option.preview, expandedPreviews.contains(option.id) {
                ScrollView([.horizontal, .vertical]) {
                    Text(preview)
                        .font(.system(size: 9, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: true, vertical: true)
                }
                .frame(maxWidth: .infinity, maxHeight: 160, alignment: .topLeading)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(0.4)))
            }
        }
    }

    private func selectionSymbol(multiSelect: Bool, isSelected: Bool) -> String {
        if multiSelect { return isSelected ? "checkmark.square.fill" : "square" }
        return isSelected ? "largecircle.fill.circle" : "circle"
    }

    private func toggle(index: Int, question: QuestionPromptItem, label: String) {
        var set = selected[index, default: []]
        if question.multiSelect {
            if set.contains(label) { set.remove(label) } else { set.insert(label) }
        } else {
            set = set.contains(label) ? [] : [label]
        }
        selected[index] = set
    }

    private func isFreeformActive(index: Int, question: QuestionPromptItem) -> Bool {
        let set = selected[index, default: []]
        return question.options.contains { $0.allowsFreeform && set.contains($0.label) }
    }

    private func freeformBinding(_ index: Int) -> Binding<String> {
        Binding(get: { freeform[index] ?? "" }, set: { freeform[index] = $0 })
    }

    private var allAnswered: Bool {
        for (index, question) in prompt.questions.enumerated() {
            let set = selected[index, default: []]
            if set.isEmpty { return false }
            if question.options.contains(where: { $0.allowsFreeform && set.contains($0.label) }),
               (freeform[index] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return false
            }
        }
        return true
    }

    private func submit() {
        var answers: [String: String] = [:]
        var annotations: [String: QuestionAnswerAnnotation] = [:]
        for (index, question) in prompt.questions.enumerated() {
            let set = selected[index, default: []]
            let typed = (freeform[index] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            var parts = question.options.filter { set.contains($0.label) && !$0.allowsFreeform }.map(\.label)
            if question.options.contains(where: { $0.allowsFreeform && set.contains($0.label) }), !typed.isEmpty {
                parts.append(typed)
            }
            let answer = parts.joined(separator: ", ")
            guard !answer.isEmpty else { continue }
            answers[question.question] = answer
            if let preview = question.options.first(where: { set.contains($0.label) })?.preview, !preview.isEmpty {
                annotations[question.question] = QuestionAnswerAnnotation(preview: preview)
            }
        }
        onSubmit(QuestionPromptResponse(answers: answers, annotations: annotations))
    }
}

/// Makes the hosting notch window key while a freeform answer field is shown, so it can take keyboard
/// input (the notch panel is otherwise non-key / click-through). Mirrors the Notes tab's NotchKeyMaker.
private struct NotchFreeformKeyMaker: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak view] in
            NotepadNotchFocus.allowsNotchKey = true
            view?.window?.makeKey()
        }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - NotchNerd recap / identity presentation
//
// Glanceable recap + session-identity helpers, kept OUT of the verbatim AgentSessionPresentation.swift
// (which mirrors upstream for clean re-sync). Built only from already-captured hook metadata — no
// transcript reads, no API.
extension AgentSession {
    /// The session's goal — its initial prompt — so a long / drifted session still shows what it's about.
    var recapGoalText: String? {
        guard spotlightShowsDetailLines,
              let goal = initialUserPromptText?.condensedForRecap, !goal.isEmpty else {
            return nil
        }
        return goal
    }

    /// A glanceable recap of the last exchange instead of a raw transcript: running → current
    /// tool/activity; completed → "Claude: <last message>"; waiting → the pending ask.
    var recapLineText: String? {
        guard spotlightShowsDetailLines else { return nil }
        switch phase {
        case .waitingForApproval:
            return permissionRequest?.summary.condensedForRecap
        case .waitingForAnswer:
            return questionPrompt?.title.condensedForRecap
        case .running:
            return spotlightActivityLineText
        case .completed:
            if let message = lastAssistantMessageText?.condensedForRecap, !message.isEmpty {
                return "\(completionReplyRecipientName): \(message)"
            }
            return jumpTarget != nil ? "Idle" : "Completed"
        }
    }

    /// Compact identity context: branch · terminal · friendly model · non-default permission mode.
    var identityChips: [String] {
        var chips: [String] = []
        if let branch = spotlightWorktreeBranch { chips.append(branch) }
        if let terminal = spotlightTerminalBadge { chips.append(terminal) }
        if let model = claudeMetadata?.model, !model.isEmpty { chips.append(Self.friendlyModelName(model)) }
        if let mode = claudeMetadata?.permissionMode, let label = Self.permissionModeLabel(mode) {
            chips.append(label)
        }
        return chips
    }

    /// (done, total) of the session's task checklist, when it has one.
    var taskProgress: (done: Int, total: Int)? {
        let tasks = claudeMetadata?.activeTasks ?? []
        guard !tasks.isEmpty else { return nil }
        return (tasks.filter { $0.status == .completed }.count, tasks.count)
    }

    /// "N agents researching" — subagents currently running (no summary yet). Glance chip so a
    /// session blocked on research/workflow subagents doesn't read as frozen.
    var subagentSummary: String? {
        let active = claudeMetadata?.activeSubagents.filter { $0.summary == nil }.count ?? 0
        guard active > 0 else { return nil }
        return active == 1 ? "1 agent researching" : "\(active) agents researching"
    }

    static func friendlyModelName(_ raw: String) -> String {
        let lowered = raw.lowercased()
        if lowered.contains("opus") { return "Opus" }
        if lowered.contains("sonnet") { return "Sonnet" }
        if lowered.contains("haiku") { return "Haiku" }
        if lowered.contains("fable") { return "Fable" }
        return raw
    }

    static func permissionModeLabel(_ mode: ClaudePermissionMode) -> String? {
        switch mode {
        case .default: return nil          // the norm — not worth a chip
        case .acceptEdits: return "Accept Edits"
        case .plan: return "Plan"
        case .dontAsk: return "Don't Ask"
        case .bypassPermissions: return "Bypass"
        case .auto: return "Auto"
        }
    }
}

private extension String {
    /// One line, whitespace-collapsed, length-capped — for a compact recap surface.
    var condensedForRecap: String {
        let collapsed = split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return collapsed.count > 140 ? String(collapsed.prefix(140)) + "…" : collapsed
    }
}

/// Persistent closed-notch attention indicator (shown when a session needs the user).
///
/// Laid out to **flank the hardware notch** — a sparkle hugging its left edge, the "needs you" label
/// hugging its right edge, with a notch-width black spacer between. A plain centered pill would be
/// narrower than the physical notch and render *behind* the cutout (invisible). The chin widens to
/// match via `ContentView.computedChinWidth`.
struct AgentClosedIndicator: View {
    let count: Int
    /// Width of the physical notch cutout (`vm.closedNotchSize.width`).
    let notchWidth: CGFloat
    /// Small left wing for the sparkle (`ContentView.agentAttentionSparkleSlot`).
    let sparkleSlot: CGFloat
    /// Wider right wing for the "N need you" text (`ContentView.agentAttentionFlankWidth`). The notch is
    /// shifted by `closedNotchHOffset` so only this side expands past the cutout.
    let textFlank: CGFloat
    var body: some View {
        HStack(spacing: 0) {
            Image(systemName: "sparkles")
                .foregroundStyle(.purple)
                .symbolEffect(.pulse, options: .repeating)
                .frame(width: sparkleSlot, alignment: .trailing)
                .padding(.trailing, 6)

            Rectangle().fill(.black).frame(width: notchWidth)

            HStack(spacing: 4) {
                Text("\(count)").font(.caption).bold().foregroundStyle(.white)
                Text(count == 1 ? "needs you" : "need you")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .fixedSize()
            .frame(width: textFlank, alignment: .leading)
            .padding(.leading, 6)
        }
    }
}

/// Closed-notch Claude status, shown when no music is playing. Pulses + "working" while Claude is
/// actively cooking; otherwise a calm "active" presence for the live sessions. Distinct from
/// AgentClosedIndicator ("needs you").
///
/// Same notch-flanking layout as `AgentClosedIndicator` so it isn't occluded by the physical notch.
struct AgentActiveIndicator: View {
    let working: Int
    let live: Int
    let notchWidth: CGFloat
    let side: CGFloat

    private var isWorking: Bool { working > 0 }
    private var count: Int { isWorking ? working : live }

    var body: some View {
        HStack(spacing: 0) {
            // Left flank: pulsing sparkle hugging the notch — purple while working, green when idle/active.
            Image(systemName: "sparkles")
                .font(.system(size: 12))
                .foregroundStyle(isWorking ? .purple : .green)
                .symbolEffect(.pulse, options: .repeating, isActive: isWorking)
                .frame(width: side, alignment: .center)
                .padding(.trailing, 3)

            Rectangle().fill(.black).frame(width: notchWidth)

            // Right flank: status dot (+ count when more than one session). No word label keeps it tight.
            HStack(spacing: 3) {
                AnimatedStatusDot(
                    color: isWorking ? AgentStatusPalette.running : AgentStatusPalette.completed,
                    pulsing: isWorking
                )
                if count > 1 {
                    Text("\(count)")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: side, alignment: .center)
            .padding(.leading, 3)
        }
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
                if let health = agent.hookHealth, !health.isHealthy {
                    ForEach(Array(health.errors.enumerated()), id: \.offset) { _, issue in
                        Label(issue.description, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                    if !health.repairableIssues.isEmpty {
                        Button("Repair hooks") { agent.installHooks() }
                    }
                }
                if let health = agent.hookHealth, !health.notices.isEmpty {
                    ForEach(Array(health.notices.enumerated()), id: \.offset) { _, issue in
                        Label(issue.description, systemImage: "info.circle")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Claude Code hooks")
            } footer: {
                Text("Adds managed entries to ~/.claude/settings.json so NotchNerd can show live session status and let you approve/deny permission prompts from the notch. Your settings are backed up first; fully reversible.")
            }

            Section {
                Defaults.Toggle(key: .agentNotificationsEnabled) { Text("Open the notch on agent events") }
                Group {
                    Defaults.Toggle(key: .agentAutoOpenNotch) { Text("Auto-open the notch (off = sound + indicator only)") }
                    Defaults.Toggle(key: .agentNotifyOnCompletion) { Text("Notify when a session finishes") }
                    Defaults.Toggle(key: .agentSuppressWhenFrontmost) { Text("Don't pop if the session's terminal is already focused") }
                }
                .disabled(!agentNotificationsEnabled)
            } header: {
                Text("Notifications")
            } footer: {
                Text("Permission and question prompts stay until you answer them; completion notices auto-dismiss after 10 seconds.")
            }

            Section {
                Defaults.Toggle(key: .agentSoundEnabled) { Text("Play a sound when a session needs you") }
                Group {
                    Defaults.Toggle(key: .agentSoundMuted) { Text("Mute") }
                    Picker("Sound", selection: $agentSoundName) {
                        ForEach(AgentNotificationSound.availableSounds(), id: \.self) { name in
                            Text(name).tag(name)
                        }
                    }
                    .onChange(of: agentSoundName) { _, name in AgentNotificationSound.play(name) }
                    Button("Preview") { AgentNotificationSound.play(agentSoundName) }
                }
                .disabled(!agentSoundEnabled)
            } header: {
                Text("Sound")
            } footer: {
                Text("Uses a macOS system sound from /System/Library/Sounds.")
            }

            Section {
                Defaults.Toggle(key: .agentUsageEnabled) { Text("Show Claude usage (5h / 7d quotas)") }
                Group {
                    HStack {
                        Text("Statusline")
                        Spacer()
                        usageStatusLabel
                    }
                    HStack {
                        Button("Install statusline") { usage.installIfNeeded() }
                        Button("Remove statusline") { usage.uninstall() }
                        Spacer()
                        Button("Refresh") { usage.refreshStatus() }
                    }
                }
                .disabled(!agentUsageEnabled)
            } header: {
                Text("Usage")
            } footer: {
                Text("Adds a managed statusLine entry to Claude Code's settings.json that records your remaining quota. If you already have a custom statusline, NotchNerd wraps it so it keeps working. Reversible.")
            }
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
