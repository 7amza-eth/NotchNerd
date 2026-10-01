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
                        snoozedFooter
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

    /// Total / waiting on you (split: blocked on a prompt vs. your turn to reply) / running.
    private var overviewRow: some View {
        let counts = AgentSessionOverview(sessions: agent.sessions)
        return HStack(spacing: 10) {
            overviewMetric(counts.total, "total", .white.opacity(0.55))
            if counts.waiting > 0 {
                overviewMetric(counts.waiting, "waiting", AgentStatusPalette.waiting)
                    .help("Waiting on you: blocked on an approval or question, or finished and waiting for your reply")
                Text(waitingBreakdown(counts))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            if counts.running > 0 { overviewMetric(counts.running, "running", AgentStatusPalette.running) }
            Spacer(minLength: 0)
        }
    }

    private func waitingBreakdown(_ counts: AgentSessionOverview) -> String {
        var parts: [String] = []
        if counts.needsYou > 0 { parts.append("\(counts.needsYou) need\(counts.needsYou == 1 ? "s" : "") you") }
        if counts.yourTurn > 0 { parts.append("\(counts.yourTurn) your turn") }
        return "(" + parts.joined(separator: " · ") + ")"
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

    @ViewBuilder private var snoozedFooter: some View {
        if agent.snoozedCount > 0 {
            Button { agent.unsnoozeAll() } label: {
                Label("\(agent.snoozedCount) snoozed · Show all", systemImage: "moon.zzz")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Snoozed chats come back on their own when they run again or ask you something")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 4) {
            Spacer(minLength: 0)
            Image(systemName: "moon.zzz").font(.title3).foregroundStyle(.secondary)
            Text("No active Claude Code sessions").font(.caption).foregroundStyle(.secondary)
            snoozedFooter
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
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                AnimatedStatusDot(
                    color: AgentStatusPalette.tint(for: session.phase),
                    pulsing: session.phase == .running || session.phase.requiresAttention
                )
                Text(session.title.isEmpty ? "Claude Code" : session.title)
                    .font(.subheadline).lineLimit(1)
                    .contentShape(Rectangle())
                    .onTapGesture { if agent.canJump(session) { agent.jump(sessionID: session.id) } }
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
                Button { agent.snooze(sessionID: session.id) } label: {
                    Image(systemName: "moon.zzz")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Snooze — hide until it runs again or asks you something")
                if agent.canJump(session) {
                    Button { agent.jump(sessionID: session.id) } label: {
                        Image(systemName: "arrow.uturn.forward.square")
                    }
                    .buttonStyle(.plain)
                    .help(agent.isDesktopSession(session.id) ? "Open the Claude app" : "Jump to the terminal")
                }
            }
            // Identity context — branch · terminal · model · mode — so same-repo sessions are distinct.
            if !session.identityChips.isEmpty {
                Text(session.identityChips.joined(separator: "  ·  "))
                    .font(.system(size: 9)).foregroundStyle(.tertiary).lineLimit(1)
            }
            // Recap (the outcome / current activity) instead of a raw transcript line.
            if let recap = session.recapLineText, !recap.isEmpty {
                Text(recap).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            }
            // The session's goal (its initial prompt), so a long/drifted session still shows its purpose.
            if let goal = session.recapGoalText, !goal.isEmpty {
                Text("↳ \(goal)").font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1)
            }
            if isExpanded && hasDetail {
                AgentSessionDetailView(session: session)
            }
            if let request = session.permissionRequest, session.phase == .waitingForApproval {
                permissionCard(request)
            } else if let question = session.questionPrompt, session.phase == .waitingForAnswer {
                QuestionCard(sessionID: session.id, prompt: question) { response in
                    agent.answer(sessionID: session.id, response: response)
                }
            }
            // Desktop chats get the same prompt in the Claude app too (the PermissionRequest hook races
            // the app's own UI) — whichever is answered first wins and the other one clears.
            if session.phase.requiresAttention, agent.isDesktopSession(session.id) {
                HStack(spacing: 4) {
                    Text("Also showing in the Claude app — answer in either place.")
                        .font(.system(size: 9)).foregroundStyle(.tertiary)
                    Button("Open Claude") { agent.jump(sessionID: session.id) }
                        .buttonStyle(.plain).font(.system(size: 9, weight: .semibold)).foregroundStyle(.purple)
                }
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

/// Interactive answer card for Claude's AskUserQuestion. Renders EVERY question (not just the first),
/// supports multi-select (toggle, no auto-submit), per-option ASCII/code previews, and a freeform
/// "Other" answer, then submits all answers together via a single Submit. Mirrors the engine
/// round-trip's per-question `answers` dict + preview annotations.
struct QuestionCard: View {
    let sessionID: String
    let prompt: QuestionPrompt
    let onSubmit: (QuestionPromptResponse) -> Void

    /// Draft key: this session + this exact set of questions (a new question set starts fresh).
    private var draftKey: String {
        ([sessionID, prompt.title] + prompt.questions.map(\.question)).joined(separator: "\u{1F}")
    }

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
        // Keep half-finished answers when the notch closes (or NotchNerd quits) — restored on reopen.
        .onAppear {
            guard let draft = QuestionDrafts.load(draftKey) else { return }
            selected = draft.selected
            freeform = draft.freeform
        }
        .onChange(of: selected) { _, _ in QuestionDrafts.save(draftKey, selected: selected, freeform: freeform) }
        .onChange(of: freeform) { _, _ in QuestionDrafts.save(draftKey, selected: selected, freeform: freeform) }
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
        QuestionDrafts.clear(draftKey)
        onSubmit(QuestionPromptResponse(answers: answers, annotations: annotations))
    }
}

/// Unsent AskUserQuestion answers, persisted in Defaults so they survive the notch closing and app
/// restarts. Keyed by `QuestionCard.draftKey`; capped to the most recent few.
enum QuestionDrafts {
    struct Draft: Codable {
        var selected: [Int: Set<String>]
        var freeform: [Int: String]
        var savedAt: Date
    }

    private static let maxDrafts = 20

    static func load(_ key: String) -> Draft? {
        all()[key]
    }

    static func save(_ key: String, selected: [Int: Set<String>], freeform: [Int: String]) {
        var drafts = all()
        if selected.values.allSatisfy(\.isEmpty) && freeform.values.allSatisfy(\.isEmpty) {
            drafts[key] = nil
        } else {
            drafts[key] = Draft(selected: selected, freeform: freeform, savedAt: .now)
        }
        if drafts.count > maxDrafts {
            let keep = drafts.sorted { $0.value.savedAt > $1.value.savedAt }.prefix(maxDrafts)
            drafts = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        Defaults[.agentQuestionDrafts] = (try? JSONEncoder().encode(drafts)) ?? Data()
    }

    static func clear(_ key: String) {
        var drafts = all()
        guard drafts.removeValue(forKey: key) != nil else { return }
        Defaults[.agentQuestionDrafts] = (try? JSONEncoder().encode(drafts)) ?? Data()
    }

    private static func all() -> [String: Draft] {
        (try? JSONDecoder().decode([String: Draft].self, from: Defaults[.agentQuestionDrafts])) ?? [:]
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
    /// Finished sessions waiting on your reply — shown as a green count on the right flank.
    var yourTurn: Int = 0
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

            // Right flank: "your turn" count (green) when any chat is waiting on your reply — the left
            // sparkle still says whether something is working. Otherwise the working/live dot + count.
            HStack(spacing: 3) {
                if yourTurn > 0 {
                    AnimatedStatusDot(color: AgentStatusPalette.completed, pulsing: false)
                    Text("\(yourTurn)")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                } else {
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
            }
            .help(yourTurn > 0 ? "\(yourTurn) waiting for your reply" : "")
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
    @Default(.agentCompletionSoundName) var agentCompletionSoundName
    @Default(.agentNudgeBlockedMinutes) var agentNudgeBlockedMinutes
    @Default(.agentNudgeRunningMinutes) var agentNudgeRunningMinutes

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
                Defaults.Toggle(key: .agentNotificationsEnabled) { Text("Pop the notch on agent events") }
                Defaults.Toggle(key: .agentAutoOpenNotch) { Text("Auto-open the notch (off = sound + indicator only)") }
                Defaults.Toggle(key: .agentNotifyOnCompletion) { Text("Notify when a session finishes") }
                Defaults.Toggle(key: .agentSuppressWhenFrontmost) { Text("Don't pop if the session's terminal or the Claude app is already focused") }
                Stepper(value: $agentNudgeBlockedMinutes, in: 0...120, step: 5) {
                    Text(agentNudgeBlockedMinutes == 0
                         ? "Nudge when blocked on you: off"
                         : "Nudge when blocked on you for \(agentNudgeBlockedMinutes) min")
                }
                Stepper(value: $agentNudgeRunningMinutes, in: 0...240, step: 15) {
                    Text(agentNudgeRunningMinutes == 0
                         ? "Nudge when a turn runs long: off"
                         : "Nudge when a turn runs longer than \(agentNudgeRunningMinutes) min")
                }
            } header: {
                Text("Notifications")
            } footer: {
                Text("Permission and question prompts stay until you answer them; completion notices and nudges auto-dismiss after 10 seconds. Each nudge fires once per wait. Snoozed chats never pop.")
            }
            .disabled(!agentNotificationsEnabled)

            Section {
                Defaults.Toggle(key: .agentSoundEnabled) { Text("Play a sound when a session needs you") }
                Defaults.Toggle(key: .agentSoundMuted) { Text("Mute") }
                Picker("Needs you", selection: $agentSoundName) {
                    ForEach(AgentNotificationSound.availableSounds(), id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                .onChange(of: agentSoundName) { _, name in AgentNotificationSound.play(name) }
                Picker("Finished (your turn)", selection: $agentCompletionSoundName) {
                    ForEach(AgentNotificationSound.availableSounds(), id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                .onChange(of: agentCompletionSoundName) { _, name in AgentNotificationSound.play(name) }
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
