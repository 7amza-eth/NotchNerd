//
//  UsageChip.swift
//  NotchNerd — usage chip for the Agent tab header
//
//  Adapted from Open Island's IslandPanelView.compactUsageChip / usageColor /
//  remainingDurationString (GPL v3). Renders one Claude rate-limit window
//  ("5h 42%") color-coded by threshold, with a reset countdown in the tooltip.
//

import SwiftUI
import OpenIslandCore

struct UsageChip: View {
    let label: String                 // "5h" / "7d"
    let window: ClaudeUsageWindow

    var body: some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.45))
            Text("\(window.roundedUsedPercentage)%")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(Self.color(for: window.usedPercentage))
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(.white.opacity(0.06), in: Capsule())
        .help(helpText)
    }

    private var helpText: String {
        var parts = ["\(label) \(window.roundedUsedPercentage)% used"]
        if let resetsAt = window.resetsAt, let remaining = Self.remainingDurationString(until: resetsAt) {
            parts.append("resets in \(remaining)")
        }
        return parts.joined(separator: " · ")
    }

    static func color(for percentage: Double) -> Color {
        switch percentage {
        case 90...: return .red.opacity(0.95)
        case 70..<90: return .orange.opacity(0.95)
        default: return .green.opacity(0.95)
        }
    }

    static func remainingDurationString(until date: Date) -> String? {
        let interval = date.timeIntervalSinceNow
        guard interval > 0 else { return nil }
        let f = DateComponentsFormatter()
        f.unitsStyle = .abbreviated
        if interval >= 86_400 {
            f.allowedUnits = [.day]; f.maximumUnitCount = 1
        } else if interval >= 3_600 {
            f.allowedUnits = [.hour, .minute]; f.maximumUnitCount = 2
        } else {
            f.allowedUnits = [.minute]; f.maximumUnitCount = 1
        }
        return f.string(from: interval)
    }
}
