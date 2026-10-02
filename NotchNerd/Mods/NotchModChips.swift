//
//  NotchModChips.swift
//  NotchNerd
//
//  The closed-notch chip a notch mod can show: an SF Symbol on the left of the hardware notch and a
//  short text on the right, drawn natively (mods describe it; they never draw it). Set with
//  `notch.closed.set({ icon, text, tint })`; `notch.notify(...)` shows a chip for a few seconds over
//  everything else a mod shows.
//
//  Placement (ContentView.NotchLayout + computedChinWidth): below "needs you", battery, HUDs, music
//  and Claude "working" (a notice shows over "working" too); above Claude "active" and the idle face.
//  One chip at a time: the one picked in Settings → Mods, else the first enabled mod that has one.
//

import AppKit
import Defaults
import SwiftUI

struct NotchModChip: Equatable {
    let icon: String
    let text: String
    let tint: String?
}

@MainActor
final class NotchModChipCenter: ObservableObject {
    static let shared = NotchModChipCenter()

    @Published private(set) var chips: [String: NotchModChip] = [:]
    @Published private(set) var notice: (modID: String, chip: NotchModChip)?
    private var noticeTask: Task<Void, Never>?
    private var lastNotice: [String: Date] = [:]

    static let maxText = 24
    static let noticeInterval: TimeInterval = 10

    private init() {}

    /// The chip to draw now, and the width of its text side.
    var visible: (chip: NotchModChip, textWidth: CGFloat)? {
        if let notice, let mod = NotchModStore.shared.mod(id: notice.modID) {
            return (notice.chip, mod.manifest.chipWidth)
        }
        let enabled = Defaults[.notchModsEnabled]
        let preferred = Defaults[.notchModChipID]
        let order = preferred.isEmpty ? enabled : [preferred]
        for id in order {
            if let chip = chips[id], let mod = NotchModStore.shared.mod(id: id) {
                return (chip, mod.manifest.chipWidth)
            }
        }
        return nil
    }

    func set(_ chip: NotchModChip, for modID: String) {
        if chips[modID] != chip { chips[modID] = chip }
    }

    func clear(_ modID: String) {
        if chips[modID] != nil { chips[modID] = nil }
        if notice?.modID == modID { endNotice() }
    }

    /// Shows a chip briefly. At most one notice per mod every 10 seconds; returns false when skipped.
    func notify(_ chip: NotchModChip, for modID: String, seconds: Double) -> Bool {
        let now = Date()
        if let last = lastNotice[modID], now.timeIntervalSince(last) < Self.noticeInterval { return false }
        lastNotice[modID] = now
        notice = (modID, chip)
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(min(max(seconds, 2), 8)))
            guard !Task.isCancelled else { return }
            self?.endNotice()
        }
        return true
    }

    private func endNotice() {
        noticeTask?.cancel()
        noticeTask = nil
        notice = nil
    }

    /// Builds a chip from what a mod passed in, or throws a message for the mod.
    static func chip(from args: [String: Any]) throws -> NotchModChip {
        let rawText = (args["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let iconName = (args["icon"] as? String) ?? "circle.fill"
        guard NSImage(systemSymbolName: iconName, accessibilityDescription: nil) != nil else {
            throw NotchModBridge.Failure(message: "\"\(iconName)\" isn't an SF Symbol name.")
        }
        guard !rawText.isEmpty || args["icon"] != nil else {
            throw NotchModBridge.Failure(message: "A chip needs text or an icon.")
        }
        return NotchModChip(icon: iconName, text: String(rawText.prefix(maxText)), tint: args["tint"] as? String)
    }

    static func color(_ tint: String?) -> Color {
        switch tint?.lowercased() {
        case nil, "": return .white
        case "purple": return .purple
        case "green": return .green
        case "orange": return .orange
        case "red": return .red
        case "blue": return .blue
        case "yellow": return .yellow
        case "pink": return .pink
        case "teal": return .teal
        case "gray", "grey": return .gray
        case "white": return .white
        case let hex?:
            var value: UInt64 = 0
            let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
            guard digits.count == 6, Scanner(string: digits).scanHexInt64(&value) else { return .white }
            return Color(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255,
                         blue: Double(value & 0xFF) / 255)
        }
    }
}

/// Same notch-flanking layout as `AgentClosedIndicator`: a small icon wing (left), a notch-width
/// black spacer, and the text wing (right). ContentView shifts the notch by
/// `(textWidth - iconSlot) / 2` so the shape grows only on the text side.
struct NotchModClosedChip: View {
    let chip: NotchModChip
    let notchWidth: CGFloat
    let textWidth: CGFloat
    static let iconSlot: CGFloat = 22

    var body: some View {
        HStack(spacing: 0) {
            Image(systemName: chip.icon)
                .font(.system(size: 12))
                .foregroundStyle(NotchModChipCenter.color(chip.tint))
                .frame(width: Self.iconSlot, alignment: .trailing)
                .padding(.trailing, 6)

            Rectangle().fill(.black).frame(width: notchWidth)

            Text(chip.text)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(width: textWidth, alignment: .leading)
                .padding(.leading, 6)
        }
    }
}
