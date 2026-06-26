//
//  NotesStore.swift
//  boringNotch (NotchNerd)
//
//  Multi-note model + on-disk persistence + debounced autosave for the always-
//  open notepad. Pure Foundation + Combine, no host-app coupling, so it can be
//  unit-tested in isolation.
//
//  On-disk format (reachable once the app is unsandboxed, per PLAN §3b):
//
//      ~/Library/Application Support/NotchNerd/Notepad/
//        ├── index.json          ← ordered metadata + selectedID (the source of truth for ORDER)
//        └── notes/
//            ├── <uuid>.md        ← one plain-text/markdown body per note
//            └── <uuid>.md
//
//  Body and metadata are split on purpose: the body file is a plain .md the
//  user could open in any editor, while index.json holds order, titles and
//  timestamps. A note's title is derived from its first non-empty line unless
//  the user has set an explicit title.
//

import Combine
import Foundation

// MARK: - Model

struct Note: Identifiable, Codable, Equatable {
    let id: UUID
    var explicitTitle: String?      // nil ⇒ derive from body
    var createdAt: Date
    var modifiedAt: Date

    /// Body is NOT in index.json; loaded/saved alongside via NotesStore.
    var body: String = ""

    init(id: UUID = UUID(), body: String = "", explicitTitle: String? = nil) {
        self.id = id
        self.body = body
        self.explicitTitle = explicitTitle
        let now = Date()
        self.createdAt = now
        self.modifiedAt = now
    }

    /// Tab / list label.
    var displayTitle: String {
        if let t = explicitTitle, !t.isEmpty { return t }
        let firstLine = body
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        return firstLine.isEmpty ? "Untitled" : String(firstLine.prefix(40))
    }

    // index.json only persists metadata; `body` is excluded.
    enum CodingKeys: String, CodingKey {
        case id, explicitTitle, createdAt, modifiedAt
    }
}

// MARK: - Store

@MainActor
final class NotesStore: ObservableObject {
    static let shared = NotesStore()

    @Published private(set) var notes: [Note] = []
    @Published var selectedNoteID: UUID?

    var selectedNote: Note? {
        guard let id = selectedNoteID else { return nil }
        return notes.first { $0.id == id }
    }

    private let fm = FileManager.default
    private var pendingSaves: [UUID: DispatchWorkItem] = [:]
    private var indexSaveWork: DispatchWorkItem?
    private let autosaveDelay: TimeInterval = 0.6

    private init() {
        try? fm.createDirectory(at: notesDir, withIntermediateDirectories: true)
        load()
        if notes.isEmpty { _ = newNote() } // never present an empty notepad
    }

    // MARK: Directories

    private var rootDir: URL {
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("NotchNerd/Notepad", isDirectory: true)
    }
    private var notesDir: URL { rootDir.appendingPathComponent("notes", isDirectory: true) }
    private var indexURL: URL { rootDir.appendingPathComponent("index.json") }
    private func bodyURL(for id: UUID) -> URL {
        notesDir.appendingPathComponent("\(id.uuidString).md")
    }

    // MARK: Load

    private struct Index: Codable {
        var order: [Note]      // metadata only (CodingKeys exclude body)
        var selectedID: UUID?
    }

    func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let index = try? JSONDecoder.iso.decode(Index.self, from: data) else {
            notes = []
            selectedNoteID = nil
            return
        }
        notes = index.order.map { meta in
            var note = meta
            note.body = (try? String(contentsOf: bodyURL(for: meta.id), encoding: .utf8)) ?? ""
            return note
        }
        selectedNoteID = index.selectedID ?? notes.first?.id
    }

    // MARK: Mutations (each schedules the right autosave)

    @discardableResult
    func newNote() -> Note {
        let note = Note(body: "")
        notes.insert(note, at: 0)
        selectedNoteID = note.id
        scheduleBodySave(for: note.id)
        scheduleIndexSave()
        return note
    }

    func deleteNote(_ id: UUID) {
        guard let idx = notes.firstIndex(where: { $0.id == id }) else { return }
        notes.remove(at: idx)
        try? fm.removeItem(at: bodyURL(for: id))
        pendingSaves[id]?.cancel()
        pendingSaves[id] = nil
        if selectedNoteID == id {
            selectedNoteID = notes[safe: idx]?.id ?? notes.last?.id
        }
        if notes.isEmpty { _ = newNote() }
        scheduleIndexSave()
    }

    func updateBody(_ body: String, for id: UUID) {
        guard let idx = notes.firstIndex(where: { $0.id == id }) else { return }
        guard notes[idx].body != body else { return }
        notes[idx].body = body
        notes[idx].modifiedAt = Date()
        scheduleBodySave(for: id)   // debounced per-note body write
        scheduleIndexSave()         // title/timestamp may have changed
    }

    func rename(_ id: UUID, to title: String?) {
        guard let idx = notes.firstIndex(where: { $0.id == id }) else { return }
        notes[idx].explicitTitle = title
        notes[idx].modifiedAt = Date()
        scheduleIndexSave()
    }

    func select(_ id: UUID) {
        selectedNoteID = id
        scheduleIndexSave()
    }

    /// Reorder support for drag-to-reorder tabs/list.
    func move(from source: IndexSet, to destination: Int) {
        notes.move(fromOffsets: source, toOffset: destination)
        scheduleIndexSave()
    }

    // MARK: Autosave (debounced; flush on quit)

    private func scheduleBodySave(for id: UUID) {
        pendingSaves[id]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            Task { @MainActor in self.writeBody(for: id) }
        }
        pendingSaves[id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + autosaveDelay, execute: work)
    }

    private func scheduleIndexSave() {
        indexSaveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            Task { @MainActor in self.writeIndex() }
        }
        indexSaveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + autosaveDelay, execute: work)
    }

    private func writeBody(for id: UUID) {
        guard let note = notes.first(where: { $0.id == id }) else { return }
        try? note.body.write(to: bodyURL(for: id), atomically: true, encoding: .utf8)
    }

    private func writeIndex() {
        let index = Index(order: notes, selectedID: selectedNoteID)
        if let data = try? JSONEncoder.iso.encode(index) {
            try? data.write(to: indexURL, options: .atomic)
        }
    }

    /// Call from applicationWillTerminate to flush any pending debounced writes.
    func flush() {
        pendingSaves.values.forEach { $0.cancel() }
        notes.forEach { writeBody(for: $0.id) }
        pendingSaves.removeAll()
        indexSaveWork?.cancel()
        writeIndex()
    }
}

// MARK: - Small helpers

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

private extension JSONDecoder {
    static let iso: JSONDecoder = {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }()
}
private extension JSONEncoder {
    static let iso: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted, .sortedKeys]; return e
    }()
}
