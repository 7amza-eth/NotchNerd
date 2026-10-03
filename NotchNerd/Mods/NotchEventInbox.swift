//
//  NotchEventInbox.swift
//  NotchNerd
//
//  The event inbox: how Claude Code mods (or any local process) put something in the notch.
//  A writer drops one JSON request per file into
//
//    ~/Library/Application Support/NotchNerd/Events/inbox/<ms>-<rand>.json
//
//  and NotchNerd applies it and deletes the file. Requests share `{ "version": 1, "type": … }`;
//  the only type so far is "toast":
//
//    { "version": 1, "type": "toast", "message": "Deploy is live",
//      "title": "deploy-watch", "style": "success", "icon": "checkmark.seal.fill",
//      "duration": 4, "sound": false, "createdAt": 1759450000000 }
//
//  `message` is required; `style` is info | success | warning | error; `icon` is an SF Symbol name
//  (falls back to the style's); `duration` is clamped to 2–10s; `createdAt` (ms) lets a toast queued
//  while NotchNerd wasn't running be dropped instead of shown late.
//
//  "timer" runs one focus countdown in the closed notch, ending with a toast and sound:
//
//    { "version": 1, "type": "timer", "op": "start", "minutes": 25, "label": "Write tests" }
//    { "version": 1, "type": "timer", "op": "stop" }
//
//  `minutes` is clamped to 1–240; starting replaces any running timer. While one runs, the app keeps
//  Events/timer.json = { endsAt (ms), minutes, label } so readers (the mod's /focus) can show it, and
//  so it survives a relaunch. Unknown types are discarded, so
//  new types can be added without breaking older apps. Writers can't rename atomically, so a file
//  that won't decode is retried for 10s, then moved to inbox/rejected/ (same as the notepad inbox).
//

import AppKit
import Defaults
import SwiftUI

/// A short message shown in the closed notch.
struct NotchToast: Equatable, Identifiable {
    enum Style: String {
        case info, success, warning, error

        var symbol: String {
            switch self {
            case .info: return "sparkles"
            case .success: return "checkmark.circle.fill"
            case .warning: return "exclamationmark.triangle.fill"
            case .error: return "xmark.octagon.fill"
            }
        }

        var tint: Color {
            switch self {
            case .info: return .white
            case .success: return .green
            case .warning: return .orange
            case .error: return .red
            }
        }
    }

    let id = UUID()
    let title: String
    let message: String
    let style: Style
    let symbol: String
    let duration: TimeInterval
    /// Overrides the style's icon color (a notch mod's `tint`).
    var tint: Color? = nil
}

/// A focus countdown shown in the closed notch.
struct FocusTimer: Equatable, Codable {
    /// Milliseconds since the epoch, like `createdAt`.
    let endsAt: Double
    let minutes: Double
    let label: String

    var endDate: Date { Date(timeIntervalSince1970: endsAt / 1000) }
}

@MainActor
final class NotchEventInbox: ObservableObject {
    static let shared = NotchEventInbox()

    /// The toast on screen, if any.
    @Published private(set) var toast: NotchToast?
    /// The running focus timer, if any.
    @Published private(set) var timer: FocusTimer?

    static let rootDirectory: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("NotchNerd/Events", isDirectory: true)
    private var inboxDir: URL { Self.rootDirectory.appendingPathComponent("inbox", isDirectory: true) }
    private var timerStateURL: URL { Self.rootDirectory.appendingPathComponent("timer.json") }

    /// Toasts older than this when read (queued while the app was down) are dropped.
    private static let maxAge: TimeInterval = 60
    /// More than this many waiting and the oldest are dropped, so a chatty mod can't back up the notch.
    private static let maxQueued = 5
    private static let unreadableGrace: TimeInterval = 10

    private struct Request: Decodable {
        let version: Int
        let type: String
        let message: String?
        let title: String?
        let style: String?
        let icon: String?
        let duration: Double?
        let sound: Bool?
        let createdAt: Double?
        let op: String?
        let minutes: Double?
        let label: String?
    }

    private let fm = FileManager.default
    private var source: DispatchSourceFileSystemObject?
    private var scanWork: DispatchWorkItem?
    private var unreadableSince: [String: Date] = [:]
    private var queue: [NotchToast] = []
    private var hideTask: Task<Void, Never>?
    private var timerTask: Task<Void, Never>?

    private init() {}

    /// Call once at launch: applies anything still fresh in the inbox, then watches it.
    func start() {
        guard source == nil else { return }
        try? fm.createDirectory(at: inboxDir, withIntermediateDirectories: true)
        let fd = open(inboxDir.path, O_EVTONLY)
        if fd >= 0 {
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
            source.setEventHandler { [weak self] in
                Task { @MainActor in self?.scheduleScan() }
            }
            source.setCancelHandler { close(fd) }
            source.resume()
            self.source = source
        }
        restoreTimer()
        scheduleScan()
    }

    /// Shows a toast now (or after the ones already waiting). Also the entry point for in-app callers.
    /// `always` skips the "Let mods show messages" switch, for alerts the user asked for (a timer ending).
    func show(_ toast: NotchToast, sound: Bool = false, always: Bool = false) {
        guard always || Defaults[.modToastsEnabled] else { return }
        if sound, !Defaults[.agentSoundMuted] {
            let name = Defaults[.agentSoundName]
            AgentNotificationSound.play(name.isEmpty ? AgentNotificationSound.fallbackSoundName : name)
        }
        queue.append(toast)
        if queue.count > Self.maxQueued { queue.removeFirst(queue.count - Self.maxQueued) }
        if self.toast == nil { advance() }
    }

    private func advance() {
        hideTask?.cancel()
        guard !queue.isEmpty else {
            toast = nil
            return
        }
        let next = queue.removeFirst()
        withAnimation(.smooth(duration: 0.3)) { toast = next }
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(next.duration))
            guard let self, !Task.isCancelled else { return }
            withAnimation(.smooth(duration: 0.3)) { self.toast = nil }
            // A beat between toasts so back-to-back ones read as separate.
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            self.advance()
        }
    }

    // MARK: Inbox

    private func scheduleScan(after delay: TimeInterval = 0.1) {
        scanWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.processInbox() }
        }
        scanWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func processInbox() {
        guard let files = try? fm.contentsOfDirectory(at: inboxDir, includingPropertiesForKeys: nil) else { return }
        var needsRetry = false
        // Names start with a millisecond timestamp, so name order is arrival order.
        for url in files.filter({ $0.pathExtension == "json" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let name = url.lastPathComponent
            guard let data = try? Data(contentsOf: url),
                  let request = try? JSONDecoder().decode(Request.self, from: data) else {
                let since = unreadableSince[name] ?? Date()
                unreadableSince[name] = since
                if Date().timeIntervalSince(since) < Self.unreadableGrace {
                    needsRetry = true
                } else {
                    let rejected = inboxDir.appendingPathComponent("rejected", isDirectory: true)
                    try? fm.createDirectory(at: rejected, withIntermediateDirectories: true)
                    try? fm.removeItem(at: rejected.appendingPathComponent(name))
                    try? fm.moveItem(at: url, to: rejected.appendingPathComponent(name))
                    unreadableSince[name] = nil
                }
                continue
            }
            try? fm.removeItem(at: url)
            unreadableSince[name] = nil
            apply(request)
        }
        if needsRetry { scheduleScan(after: 1) }
    }

    private func apply(_ request: Request) {
        guard request.version == 1 else { return }
        switch request.type {
        case "toast":
            if let createdAt = request.createdAt,
               Date().timeIntervalSince1970 - createdAt / 1000 > Self.maxAge { return }
            guard let toast = Self.toast(from: request) else { return }
            show(toast, sound: request.sound ?? false)
        case "timer":
            if request.op == "stop" {
                stopTimer()
            } else if request.op == "start", let minutes = request.minutes {
                startTimer(minutes: minutes, label: Self.clean(request.label, limit: 32))
            }
        default:
            break   // Unknown type: from a newer mod. Dropped (the file is already gone).
        }
    }

    // MARK: Focus timer

    func startTimer(minutes: Double, label: String) {
        let minutes = min(max(minutes, 1), 240)
        let endsAt = (Date().timeIntervalSince1970 + minutes * 60) * 1000
        setTimer(FocusTimer(endsAt: endsAt, minutes: minutes, label: label.isEmpty ? "Focus" : label))
    }

    func stopTimer() {
        setTimer(nil)
    }

    private func setTimer(_ new: FocusTimer?) {
        timerTask?.cancel()
        withAnimation(.smooth(duration: 0.3)) { timer = new }
        if let new, let data = try? JSONEncoder().encode(new) {
            try? data.write(to: timerStateURL, options: .atomic)
        } else {
            try? fm.removeItem(at: timerStateURL)
        }
        guard let new else { return }
        timerTask = Task { [weak self] in
            let wait = new.endDate.timeIntervalSinceNow
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            guard let self, !Task.isCancelled else { return }
            self.setTimer(nil)
            self.show(NotchToast(title: new.label, message: "Done. \(Self.minutesText(new.minutes)) up", style: .success,
                                 symbol: "timer", duration: 8), sound: true, always: true)
        }
    }

    /// Picks a timer back up after a relaunch. One that ended while the app was down is just cleared.
    private func restoreTimer() {
        guard let data = try? Data(contentsOf: timerStateURL),
              let saved = try? JSONDecoder().decode(FocusTimer.self, from: data) else { return }
        setTimer(saved.endDate > Date() ? saved : nil)
    }

    private static func minutesText(_ minutes: Double) -> String {
        let whole = Int(minutes.rounded())
        return whole == 1 ? "1 minute" : "\(whole) minutes"
    }

    private static func toast(from request: Request) -> NotchToast? {
        let message = clean(request.message, limit: 120)
        guard !message.isEmpty else { return nil }
        let style = request.style.flatMap(NotchToast.Style.init(rawValue:)) ?? .info
        let symbol = request.icon.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil ? $0 : nil }
            ?? style.symbol
        let title = clean(request.title, limit: 32)
        return NotchToast(title: title.isEmpty ? "Claude Code" : title, message: message, style: style,
                          symbol: symbol, duration: min(max(request.duration ?? 4, 2), 10))
    }

    /// One line, trimmed and capped: the notch has room for a short phrase, not a paragraph.
    private static func clean(_ text: String?, limit: Int) -> String {
        let line = (text ?? "").components(separatedBy: .newlines).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return line.count > limit ? String(line.prefix(limit - 1)) + "…" : line
    }
}

/// The toast as drawn in the closed notch: icon + source on the left wing, the message on the right,
/// with a black bridge over the hardware cutout between them (the battery notification's layout).
struct NotchToastView: View {
    let toast: NotchToast
    let notchWidth: CGFloat
    let leftWing: CGFloat
    let rightWing: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: toast.symbol)
                    .foregroundStyle(toast.tint ?? toast.style.tint)
                    .symbolEffect(.bounce, value: toast.id)
                Text(toast.title)
                    .foregroundStyle(.gray)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .font(.subheadline)
            .padding(.leading, 12)
            .frame(width: leftWing, alignment: .leading)

            Rectangle()
                .fill(.black)
                .frame(width: notchWidth)

            Text(toast.message)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, 10)
                .frame(width: rightWing, alignment: .leading)
                .help(toast.message)
        }
        .id(toast.id)
        .transition(.opacity)
    }
}

/// The focus timer in the closed notch: icon + label on the left wing, the countdown on the right.
struct NotchTimerView: View {
    let timer: FocusTimer
    let notchWidth: CGFloat
    let leftWing: CGFloat
    let rightWing: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "timer")
                    .foregroundStyle(.orange)
                Text(timer.label)
                    .foregroundStyle(.gray)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .font(.subheadline)
            .padding(.leading, 12)
            .frame(width: leftWing, alignment: .leading)

            Rectangle()
                .fill(.black)
                .frame(width: notchWidth)

            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(Self.remaining(until: timer.endDate, now: context.date))
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .contentTransition(.numericText(countsDown: true))
            }
            .padding(.trailing, 12)
            .frame(width: rightWing, alignment: .trailing)
        }
        .transition(.opacity)
    }

    static func remaining(until end: Date, now: Date) -> String {
        let seconds = max(0, Int(end.timeIntervalSince(now).rounded(.up)))
        let (h, m, s) = (seconds / 3600, seconds / 60 % 60, seconds % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
