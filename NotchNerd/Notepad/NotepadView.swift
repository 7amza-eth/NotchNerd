//
//  NotepadView.swift
//  NotchNerd (NotchNerd)
//
//  SwiftUI content for the notepad panel: a notes list/tabs strip + a TextEditor
//  bound to the selected note. Hosted in NotepadPanel via NSHostingView.
//
//  Focus note: the TextEditor must be able to become first responder for the
//  .nonactivatingPanel+canBecomeKey trick to deliver text. We use @FocusState
//  and focus the editor when the selection changes / the panel is shown.
//

import SwiftUI

struct NotepadView: View {
    @ObservedObject var store: NotesStore
    @FocusState private var editorFocused: Bool

    // Bridges the selected note's body to the editor with autosave on every edit.
    private var bodyBinding: Binding<String> {
        Binding(
            get: { store.selectedNote?.body ?? "" },
            set: { newValue in
                if let id = store.selectedNoteID { store.updateBody(newValue, for: id) }
            }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            tabStrip
            Divider().opacity(0.4)
            editor
        }
        .frame(minWidth: 320, minHeight: 220)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.white.opacity(0.08), lineWidth: 1)
        )
        .onAppear { focusEditorSoon() }
        .onChange(of: store.selectedNoteID) { _, _ in focusEditorSoon() }
    }

    // MARK: Tabs / notes list (horizontal scrollable strip)

    private var tabStrip: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(store.notes) { note in
                        tab(for: note)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
            Spacer(minLength: 0)
            Button { store.newNote() } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.plain)
            .padding(.trailing, 10)
            .help("New note")
        }
        .frame(height: 34)
    }

    private func tab(for note: Note) -> some View {
        let isSelected = note.id == store.selectedNoteID
        return HStack(spacing: 4) {
            Text(note.displayTitle)
                .lineLimit(1)
                .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
            if isSelected {
                Button { store.deleteNote(note.id) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                }
                .buttonStyle(.plain)
                .help("Delete note")
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.25) : Color.white.opacity(0.06))
        )
        .contentShape(Rectangle())
        .onTapGesture { store.select(note.id) }
    }

    // MARK: Editor

    private var editor: some View {
        TextEditor(text: bodyBinding)
            .focused($editorFocused)
            .font(.system(size: 13, design: .monospaced))
            .scrollContentBackground(.hidden)
            .padding(8)
    }

    private func focusEditorSoon() {
        // Defer one runloop tick so the hosting view is in the window before we
        // try to take first responder.
        DispatchQueue.main.async { editorFocused = true }
    }
}
