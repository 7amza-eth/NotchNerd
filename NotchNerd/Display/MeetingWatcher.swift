//
//  MeetingWatcher.swift
//  NotchNerd
//
//  The next-meeting countdown in the closed notch ("Sales · in 20m", "Sales · 12m left"), so the
//  notch can stand in for a meeting app's menu-bar item (Granola, etc.). Reads the calendar through
//  EventKit (the same permission the Calendar feature uses) and drives the native chip slot in
//  NotchModChipCenter. At start time it shows one toast; "Open notes app" in Settings → Calendar
//  names the app to bring forward (default Granola).
//

import AppKit
import Defaults
import EventKit
import Foundation

@MainActor
final class MeetingWatcher {
    static let shared = MeetingWatcher()

    private let store = EKEventStore()
    private var timer: Timer?
    private var announced: Set<String> = []

    private init() {}

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            Task { @MainActor in MeetingWatcher.shared.tick() }
        }
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { _ in
            Task { @MainActor in MeetingWatcher.shared.tick() }
        }
        tick()
    }

    func tick() {
        guard Defaults[.meetingChipEnabled], EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            NotchModChipCenter.shared.setNative(nil)
            return
        }
        let now = Date()
        let lead = TimeInterval(Defaults[.meetingChipLeadMinutes] * 60)
        let predicate = store.predicateForEvents(withStart: now.addingTimeInterval(-6 * 3600), end: now.addingTimeInterval(lead), calendars: nil)
        let events = store.events(matching: predicate).filter { e in
            !e.isAllDay && e.endDate > now && e.startDate < now.addingTimeInterval(lead)
                && e.status != .canceled
                && e.attendees?.first(where: \.isCurrentUser)?.participantStatus != .declined
                // A meeting is something with other people or a call link; skip solo blocks.
                && ((e.attendees?.count ?? 0) > 1 || e.url != nil || (e.notes ?? "").contains("http"))
        }
        // Prefer one that's on now, else the soonest.
        let live = events.filter { $0.startDate <= now }.min { $0.endDate < $1.endDate }
        let next = events.filter { $0.startDate > now }.min { $0.startDate < $1.startDate }

        guard let event = live ?? next else {
            NotchModChipCenter.shared.setNative(nil)
            return
        }
        let isLive = event.startDate <= now
        let minutes = max(1, Int(((isLive ? event.endDate : event.startDate).timeIntervalSince(now) / 60).rounded(.up)))
        let title = Self.short(event.title ?? "Meeting")
        let text = isLive ? "\(title) · \(Self.span(minutes)) left" : "\(title) · in \(Self.span(minutes))"
        NotchModChipCenter.shared.setNative(NotchModChip(
            icon: isLive ? "record.circle" : "calendar",
            text: text,
            tint: isLive ? "red" : nil))

        // One heads-up as it starts.
        let key = event.eventIdentifier ?? "\(event.startDate)"
        if isLive, now.timeIntervalSince(event.startDate) < 120, !announced.contains(key) {
            announced.insert(key)
            NotchEventInbox.shared.show(NotchToast(
                title: event.title ?? "Meeting", message: "Starting now",
                style: .info, symbol: "calendar", duration: 6))
            if Defaults[.meetingOpenNotesApp], let app = Self.notesAppURL() {
                NSWorkspace.shared.openApplication(at: app, configuration: .init())
            }
        }
    }

    static func notesAppURL() -> URL? {
        let name = Defaults[.meetingNotesApp]
        guard !name.isEmpty else { return nil }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: name)
            ?? ["/Applications/\(name).app"].map(URL.init(fileURLWithPath:)).first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private static func span(_ minutes: Int) -> String {
        minutes < 60 ? "\(minutes)m" : "\(minutes / 60)h\(minutes % 60 == 0 ? "" : " \(minutes % 60)m")"
    }

    /// Keeps the chip short: the first word or two of the title.
    private static func short(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 10 else { return trimmed }
        return String(trimmed.prefix(9)).trimmingCharacters(in: .whitespaces) + "…"
    }
}
