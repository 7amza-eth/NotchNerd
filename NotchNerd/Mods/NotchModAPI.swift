//
//  NotchModAPI.swift
//  NotchNerd
//
//  Everything `window.notch` can do, for both places a mod's code runs: its tab page (WKWebView,
//  NotchModBridge) and its logic (JavaScriptCore, NotchModRuntime). One dispatcher, so the two get
//  the same methods, the same permission checks and the same storage. Keep in step with
//  tooling/notch-mod-sample/notchnerd.d.ts.
//
//    notch.info()                         { id, version, appVersion, development, surface }
//    notch.log(...values)                 Console.app, category mod.<id>
//    notch.storage.get/set/remove/keys    1 MB of JSON per mod; fires "storage" { key } on change
//    notch.on(event, callback) → off()    events below, at most one per second each
//    notch.closed.set({ icon, text, tint }) / notch.closed.clear()   needs surfaces.closed
//    notch.notify({ icon, text, tint, seconds })                     needs "notify"
//    notch.media.get()            "media"     needs "media.read"
//    notch.calendar.events()      "calendar"  needs "calendar.read"
//    notch.agent.get()            "agent"     needs "agent.read"
//    notch.notes.list() / read(id) "notes"    needs "notes.read"
//    notch.notes.append(id, text) / create(text, title)  needs "notes.write"
//  Page only: notch.close(), notch.openURL(url) (both need a person in front of the page).
//

import AppKit
import Combine
import Defaults
import Foundation
import os

enum NotchModSurface: String {
    case page, logic
}

/// Something that receives a mod's events: an open tab page or a running logic script.
@MainActor
protocol NotchModEventSink: AnyObject {
    func deliver(event: String, json: String)
}

@MainActor
enum NotchModAPI {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static let storageLimit = 1_000_000

    /// Runs one call. Returns something JSONSerialization can encode (or NSNull).
    static func call(_ method: String, _ args: [String: Any], mod: NotchMod, surface: NotchModSurface,
                     sink: NotchModEventSink, closeNotch: (() -> Void)? = nil) throws -> Any {
        let manifest = mod.manifest
        func require(_ permission: NotchModManifest.Permission) throws {
            guard manifest.allows(permission) else {
                throw Failure(message: "notch.\(method) needs \"\(permission.rawValue)\" in the permissions of \(NotchModManifest.fileName).")
            }
        }

        switch method {
        case "info":
            return [
                "id": mod.id,
                "version": manifest.version,
                "appVersion": Bundle.main.releaseVersionNumber ?? "",
                "development": mod.isDevelopment,
                "surface": surface.rawValue,
            ] as [String: Any]

        case "log":
            let text = String((args["message"] as? String ?? "").prefix(2000))
            let level = args["level"] as? String ?? "log"
            let logger = Logger(subsystem: "eth.7amza.notchnerd", category: "mod.\(mod.id)")
            if level == "error" { logger.error("\(text, privacy: .public)") } else { logger.info("\(text, privacy: .public)") }
            if level == "error" { NotchModRuntimeManager.shared.reportError(text, for: mod.id) }
            return NSNull()

        case "close", "openURL":
            guard surface == .page else {
                throw Failure(message: "notch.\(method) only works from the tab page, where someone is looking.")
            }
            if method == "close" {
                closeNotch?()
            } else {
                guard let string = args["url"] as? String, let url = URL(string: string), NotchModBridge.isWebURL(url) else {
                    throw Failure(message: "notch.openURL takes an http or https URL.")
                }
                NSWorkspace.shared.open(url)
            }
            return NSNull()

        case "storage.get":
            return try NotchModStorage.for(mod.id).get(try key(args)) ?? NSNull()
        case "storage.set":
            guard let value = args["value"], JSONSerialization.isValidJSONObject([value]) else {
                throw Failure(message: "notch.storage.set takes a JSON value.")
            }
            let key = try key(args)
            try NotchModStorage.for(mod.id).set(key, value, limit: storageLimit)
            NotchModEvents.shared.emit("storage", ["key": key], to: mod.id)
            return NSNull()
        case "storage.remove":
            let key = try key(args)
            try NotchModStorage.for(mod.id).remove(key)
            NotchModEvents.shared.emit("storage", ["key": key], to: mod.id)
            return NSNull()
        case "storage.keys":
            return try NotchModStorage.for(mod.id).keys()

        case "subscribe", "unsubscribe":
            guard let event = args["event"] as? String, let kind = NotchModEvents.Kind(rawValue: event) else {
                throw Failure(message: "Unknown event. Events: \(NotchModEvents.Kind.allCases.map(\.rawValue).joined(separator: ", ")).")
            }
            if let permission = kind.permission { try require(permission) }
            if method == "subscribe" {
                NotchModEvents.shared.subscribe(sink, to: kind, mod: mod.id)
            } else {
                NotchModEvents.shared.unsubscribe(sink, from: kind, mod: mod.id)
            }
            return NSNull()

        case "closed.set":
            guard manifest.surfaces.closed != nil else {
                throw Failure(message: "notch.closed needs \"surfaces\": { \"closed\": {} } in \(NotchModManifest.fileName).")
            }
            NotchModChipCenter.shared.set(try NotchModChipCenter.chip(from: args), for: mod.id)
            return NSNull()
        case "closed.clear":
            NotchModChipCenter.shared.clear(mod.id)
            return NSNull()
        case "notify":
            try require(.notify)
            let seconds = (args["seconds"] as? Double) ?? 4
            return NotchModChipCenter.shared.notify(try NotchModChipCenter.chip(from: args), for: mod.id, seconds: seconds)

        case "media.get":
            try require(.mediaRead)
            return NotchModEvents.Kind.media.snapshot()
        case "calendar.events":
            try require(.calendarRead)
            return NotchModEvents.Kind.calendar.snapshot()
        case "agent.get":
            try require(.agentRead)
            return NotchModEvents.Kind.agent.snapshot()
        case "notes.list":
            try require(.notesRead)
            return NotchModEvents.Kind.notes.snapshot()
        case "notes.read":
            try require(.notesRead)
            guard let note = try note(args) else { return NSNull() }
            return ["id": note.id.uuidString, "title": note.displayTitle, "body": note.body]
        case "notes.append":
            try require(.notesWrite)
            let text = try text(args)
            guard let note = try note(args) else { throw Failure(message: "No note with that id.") }
            let body = note.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? text : note.body + (note.body.hasSuffix("\n") ? "" : "\n") + text
            NotesStore.shared.updateBody(body, for: note.id)
            return NSNull()
        case "notes.create":
            try require(.notesWrite)
            let text = try text(args)
            let store = NotesStore.shared
            let previous = store.selectedNoteID
            let note = store.newNote()
            store.updateBody(text, for: note.id)
            if let title = args["title"] as? String, !title.isEmpty { store.rename(note.id, to: String(title.prefix(80))) }
            if let previous { store.select(previous) }   // a mod never switches the note you're on
            return note.id.uuidString

        default:
            throw Failure(message: "notch.\(method) isn't available in this version of NotchNerd.")
        }
    }

    private static func key(_ args: [String: Any]) throws -> String {
        guard let key = args["key"] as? String, !key.isEmpty, key.count <= 200 else {
            throw Failure(message: "Storage keys are non-empty strings of up to 200 characters.")
        }
        return key
    }

    private static func note(_ args: [String: Any]) throws -> Note? {
        guard let string = args["id"] as? String, let id = UUID(uuidString: string) else {
            throw Failure(message: "Pass a note id from notch.notes.list().")
        }
        return NotesStore.shared.notes.first { $0.id == id }
    }

    private static func text(_ args: [String: Any]) throws -> String {
        guard let text = args["text"] as? String, !text.isEmpty else { throw Failure(message: "Pass some text.") }
        guard text.count <= 20_000 else { throw Failure(message: "That's too much text for one call.") }
        return text
    }

    /// JSON text for a value from `call`, for handing to JavaScript.
    static func json(_ value: Any) -> String {
        guard !(value is NSNull),
              let data = try? JSONSerialization.data(withJSONObject: [value], options: [.fragmentsAllowed]),
              let text = String(data: data, encoding: .utf8) else { return "null" }
        return String(text.dropFirst().dropLast())   // unwrap the [ ] used to allow fragments
    }
}

// MARK: - Events

/// Delivers app state to the mods that asked for it. Watches a source only while some mod is
/// subscribed to it, and sends each event at most once a second.
@MainActor
final class NotchModEvents {
    static let shared = NotchModEvents()

    enum Kind: String, CaseIterable {
        case storage, media, calendar, agent, notes

        var permission: NotchModManifest.Permission? {
            switch self {
            case .storage: return nil
            case .media: return .mediaRead
            case .calendar: return .calendarRead
            case .agent: return .agentRead
            case .notes: return .notesRead
            }
        }

        /// What the event (and its getter) carries.
        @MainActor func snapshot() -> Any {
            switch self {
            case .storage:
                return NSNull()
            case .media:
                let music = MusicManager.shared
                let idle = music.isPlayerIdle && !music.isPlaying
                return [
                    "playing": music.isPlaying,
                    "idle": idle,
                    "title": idle ? "" : music.songTitle,
                    "artist": idle ? "" : music.artistName,
                    "album": idle ? "" : music.album,
                    "duration": music.songDuration,
                    "elapsed": music.elapsedTime,
                    "app": music.bundleIdentifier ?? "",
                ] as [String: Any]
            case .calendar:
                let iso = ISO8601DateFormatter()
                return CalendarManager.shared.events.map { event in
                    [
                        "id": event.id,
                        "title": event.title,
                        "start": iso.string(from: event.start),
                        "end": iso.string(from: event.end),
                        "allDay": event.isAllDay,
                        "location": event.location ?? "",
                        "calendar": event.calendar.title,
                    ] as [String: Any]
                }
            case .agent:
                let agent = AgentBridgeManager.shared
                let iso = ISO8601DateFormatter()
                return [
                    "working": agent.workingCount,
                    "live": agent.liveSessionCount,
                    "needsYou": agent.attentionCount,
                    "yourTurn": agent.yourTurnCount,
                    // Titles and status only: no transcripts, prompts or paths.
                    "sessions": agent.sessions.map { session in
                        [
                            "id": session.id,
                            "title": session.title,
                            "tool": session.tool.rawValue,
                            "phase": session.phase.rawValue,
                            "updated": iso.string(from: session.updatedAt),
                        ] as [String: Any]
                    },
                ] as [String: Any]
            case .notes:
                let iso = ISO8601DateFormatter()
                return NotesStore.shared.notes.map { note in
                    ["id": note.id.uuidString, "title": note.displayTitle, "modified": iso.string(from: note.modifiedAt)]
                }
            }
        }

        @MainActor fileprivate func publisher() -> AnyPublisher<Void, Never>? {
            switch self {
            case .storage:
                return nil
            case .media:
                let music = MusicManager.shared
                return Publishers.MergeMany(
                    music.$songTitle.map { _ in () }.eraseToAnyPublisher(),
                    music.$artistName.map { _ in () }.eraseToAnyPublisher(),
                    music.$isPlaying.map { _ in () }.eraseToAnyPublisher(),
                    music.$isPlayerIdle.map { _ in () }.eraseToAnyPublisher(),
                    music.$songDuration.map { _ in () }.eraseToAnyPublisher()
                ).eraseToAnyPublisher()
            case .calendar:
                return CalendarManager.shared.$events.map { _ in () }.eraseToAnyPublisher()
            case .agent:
                return AgentBridgeManager.shared.objectWillChange.map { _ in () }.eraseToAnyPublisher()
            case .notes:
                return NotesStore.shared.$notes.map { _ in () }.eraseToAnyPublisher()
            }
        }
    }

    private struct Subscriber {
        weak var sink: NotchModEventSink?
        let mod: String
    }

    private var subscribers: [Kind: [Subscriber]] = [:]
    private var sources: [Kind: AnyCancellable] = [:]
    private var lastSent: [Kind: Date] = [:]
    private var pending: Set<Kind> = []

    private init() {}

    func subscribe(_ sink: NotchModEventSink, to kind: Kind, mod: String) {
        prune(kind)
        if !(subscribers[kind] ?? []).contains(where: { $0.sink === sink }) {
            subscribers[kind, default: []].append(Subscriber(sink: sink, mod: mod))
        }
        startSource(kind)
        // Send the current state right away so a subscriber never starts empty.
        if kind != .storage { deliver(kind, NotchModAPI.json(kind.snapshot()), to: [sink]) }
    }

    func unsubscribe(_ sink: NotchModEventSink, from kind: Kind? = nil, mod: String) {
        for each in kind.map({ [$0] }) ?? Kind.allCases {
            subscribers[each]?.removeAll { $0.sink === sink || $0.sink == nil }
            stopSourceIfUnused(each)
        }
    }

    /// For events a mod causes itself (storage), sent straight away to that mod's subscribers.
    func emit(_ event: String, _ payload: Any, to mod: String) {
        guard let kind = Kind(rawValue: event) else { return }
        let sinks = (subscribers[kind] ?? []).filter { $0.mod == mod }.compactMap(\.sink)
        deliver(kind, NotchModAPI.json(payload), to: sinks)
    }

    private func startSource(_ kind: Kind) {
        guard sources[kind] == nil, let publisher = kind.publisher() else { return }
        sources[kind] = publisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.changed(kind) }
    }

    private func stopSourceIfUnused(_ kind: Kind) {
        prune(kind)
        if (subscribers[kind] ?? []).isEmpty {
            sources[kind] = nil
            pending.remove(kind)
        }
    }

    private func prune(_ kind: Kind) {
        subscribers[kind]?.removeAll { $0.sink == nil }
    }

    /// Coalesces bursts: at most one send per second per event, always ending on the latest state.
    private func changed(_ kind: Kind) {
        guard !pending.contains(kind) else { return }
        let wait = max(0, 1 - Date().timeIntervalSince(lastSent[kind] ?? .distantPast))
        pending.insert(kind)
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            guard let self else { return }
            self.pending.remove(kind)
            self.lastSent[kind] = Date()
            self.prune(kind)
            let sinks = (self.subscribers[kind] ?? []).compactMap(\.sink)
            guard !sinks.isEmpty else { return self.stopSourceIfUnused(kind) }
            self.deliver(kind, NotchModAPI.json(kind.snapshot()), to: sinks)
        }
    }

    private func deliver(_ kind: Kind, _ json: String, to sinks: [NotchModEventSink]) {
        for sink in sinks { sink.deliver(event: kind.rawValue, json: json) }
    }
}
