//
//  AgentActivity.swift
//  NotchNerd — derived session-activity vocabulary
//
//  A pure, body-safe (no IO, no clocks) descriptor of what a session is doing
//  right now, finer-grained than the engine's 4 SessionPhases: it buckets the
//  current tool, surfaces waiting-on-subagents, and distinguishes plan review
//  from generic approval. Drives the recap line's icon/tint (and, in P7, the
//  failed/compacting states). The status dot deliberately keeps the coarse
//  per-phase color — activity is conveyed by icon + label, not a second color
//  system to learn.
//

import SwiftUI
import OpenIslandCore

enum AgentActivity: Equatable {
    case thinking
    case bash
    case editing
    case searching
    case reading
    case tool(String)
    case researching(Int)
    case planReview
    case permission
    case question
    case done

    struct Descriptor {
        let symbol: String
        let tint: Color
        let label: String
        let pulses: Bool
    }

    /// `ignoringSubagents` lets the recap line show the underlying tool state when the
    /// "N agents researching" chip already conveys the subagent count on its own line.
    static func resolve(for session: AgentSession, ignoringSubagents: Bool = false) -> AgentActivity {
        switch session.phase {
        case .waitingForApproval:
            return session.permissionRequest?.toolName == "ExitPlanMode" ? .planReview : .permission
        case .waitingForAnswer:
            return .question
        case .completed:
            return .done
        case .running:
            if !ignoringSubagents {
                let active = session.claudeMetadata?.activeSubagents.filter { $0.summary == nil }.count ?? 0
                if active > 0 { return .researching(active) }
            }
            guard let tool = session.currentToolName, !tool.isEmpty else { return .thinking }
            switch tool {
            case "Bash", "BashOutput", "KillShell": return .bash
            case "Edit", "Write", "MultiEdit", "NotebookEdit": return .editing
            case "Grep", "Glob", "WebSearch": return .searching
            case "Read", "WebFetch": return .reading
            default: return .tool(tool)
            }
        }
    }

    var descriptor: Descriptor {
        switch self {
        case .thinking:
            Descriptor(symbol: "brain", tint: AgentStatusPalette.running, label: "Thinking…", pulses: true)
        case .bash:
            Descriptor(symbol: "terminal", tint: AgentStatusPalette.running, label: "Running a command", pulses: true)
        case .editing:
            Descriptor(symbol: "pencil.and.outline", tint: AgentStatusPalette.running, label: "Editing files", pulses: true)
        case .searching:
            Descriptor(symbol: "magnifyingglass", tint: AgentStatusPalette.running, label: "Searching", pulses: true)
        case .reading:
            Descriptor(symbol: "doc.text.magnifyingglass", tint: AgentStatusPalette.running, label: "Reading", pulses: true)
        case let .tool(name):
            Descriptor(symbol: "wrench.and.screwdriver", tint: AgentStatusPalette.running, label: "Running \(name)", pulses: true)
        case let .researching(count):
            Descriptor(symbol: "arrow.triangle.branch", tint: .cyan,
                       label: count == 1 ? "1 agent researching" : "\(count) agents researching", pulses: true)
        case .planReview:
            Descriptor(symbol: "list.clipboard", tint: AgentStatusPalette.waiting, label: "Plan ready for review", pulses: true)
        case .permission:
            Descriptor(symbol: "lock.shield", tint: AgentStatusPalette.waiting, label: "Needs approval", pulses: true)
        case .question:
            Descriptor(symbol: "questionmark.bubble", tint: AgentStatusPalette.answer, label: "Needs an answer", pulses: true)
        case .done:
            Descriptor(symbol: "checkmark.circle.fill", tint: AgentStatusPalette.completed, label: "Done", pulses: false)
        }
    }
}
