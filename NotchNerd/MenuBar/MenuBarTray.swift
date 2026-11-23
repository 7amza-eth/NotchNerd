//
//  MenuBarTray.swift
//  NotchNerd
//
//  A hidden section for the menu bar, like Ice's: NotchNerd adds a thin divider status item. You
//  ⌘-drag the icons you don't need to see all the time to the LEFT of it. Collapsed, the divider
//  stretches to `collapsedLength`, which pushes everything left of it off the screen; expanded, it
//  shrinks back to a small chevron so they show again. The notch's right side has a button that
//  shows them, and they hide again after `menuBarTrayAutoHideSeconds`.
//
//  No Screen Recording or Accessibility permission: it only changes the length of its own item.
//  macOS remembers the divider's position (autosaveName), so the arrangement survives relaunches.
//

import AppKit
import Defaults
import SwiftUI

@MainActor
final class MenuBarTray: ObservableObject {
    static let shared = MenuBarTray()

    @Published private(set) var expanded = false
    @Published private(set) var active = false

    private var divider: NSStatusItem?
    private var hideTask: DispatchWorkItem?
    private var observer: Any?

    private static let collapsedLength: CGFloat = 10_000
    private static let expandedLength: CGFloat = 14

    private init() {}

    func start() {
        apply()
        observer = Defaults.observe(.menuBarTrayEnabled) { _ in
            Task { @MainActor in MenuBarTray.shared.apply() }
        }
    }

    private func apply() {
        if Defaults[.menuBarTrayEnabled] {
            guard divider == nil else { return }
            let item = NSStatusBar.system.statusItem(withLength: Self.expandedLength)
            item.autosaveName = "NotchNerdMenuBarDivider"
            item.behavior = []   // can't be removed by dragging it out
            if let button = item.button {
                button.target = self
                button.action = #selector(dividerClicked)
                button.toolTip = "NotchNerd: icons to the left of this are hidden. ⌘-drag icons across it."
            }
            divider = item
            active = true
            // Start collapsed once the bar has laid out.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.collapse() }
        } else {
            if let divider { NSStatusBar.system.removeStatusItem(divider) }
            divider = nil
            active = false
            expanded = false
        }
    }

    @objc private func dividerClicked() { toggle() }

    func toggle() { expanded ? collapse() : expand() }

    func expand() {
        guard let divider else { return }
        hideTask?.cancel()
        divider.length = Self.expandedLength
        setImage("chevron.compact.right")
        expanded = true
        let seconds = Defaults[.menuBarTrayAutoHideSeconds]
        guard seconds > 0 else { return }
        let task = DispatchWorkItem { [weak self] in self?.collapse() }
        hideTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(seconds), execute: task)
    }

    func collapse() {
        guard let divider else { return }
        hideTask?.cancel()
        // While collapsed the divider itself sits off to the left, so it needs no image.
        divider.button?.image = nil
        divider.length = Self.collapsedLength
        expanded = false
    }

    private func setImage(_ symbol: String) {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Hidden menu bar icons")
        image?.isTemplate = true
        divider?.button?.image = image
    }
}

/// The notch's right-side button for the hidden menu bar icons.
struct MenuBarTrayButton: View {
    @ObservedObject private var tray = MenuBarTray.shared

    var body: some View {
        if tray.active {
            Button {
                tray.toggle()
            } label: {
                Capsule()
                    .fill(tray.expanded ? Color(nsColor: .secondarySystemFill) : .black)
                    .frame(width: 30, height: 30)
                    .overlay {
                        Image(systemName: tray.expanded ? "menubar.arrow.up.rectangle" : "menubar.rectangle")
                            .foregroundColor(tray.expanded ? .white : .gray)
                            .imageScale(.medium)
                    }
            }
            .buttonStyle(PlainButtonStyle())
            .help(tray.expanded ? "Hide the extra menu bar icons" : "Show the hidden menu bar icons")
        }
    }
}

// MARK: - Settings → Menu Bar

struct MenuBarTraySettings: View {
    @Default(.menuBarTrayAutoHideSeconds) var autoHide

    var body: some View {
        Form {
            Section {
                Defaults.Toggle(key: .menuBarTrayEnabled) { Text("Hide menu bar icons behind a divider") }
                Picker("Hide them again after", selection: $autoHide) {
                    Text("10 seconds").tag(10)
                    Text("30 seconds").tag(30)
                    Text("1 minute").tag(60)
                    Text("Never").tag(0)
                }
            } header: {
                Text("Hidden menu bar icons")
            } footer: {
                Text("Turning this on adds a small divider to the menu bar. Hold ⌘ and drag the icons you rarely need to the left of it. They stay hidden until you press the menu bar button on the right of the open notch (or click the divider). On a MacBook with a notch this also keeps icons from disappearing behind it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
