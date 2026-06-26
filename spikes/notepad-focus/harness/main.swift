//
//  main.swift
//  notepad-focus harness
//
//  A SELF-CONTAINED AppKit validation harness for the single riskiest unknown
//  in NotchNerd's always-open notepad: can a key-capable text panel take
//  *keyboard focus* while living in boring.notch's max-level private CGS Space,
//  WITHOUT stealing foreground activation from the user's frontmost app
//  (the app runs as .accessory / LSUIElement)?
//
//  Build (Command Line Tools only, NO Xcode project needed):
//      swiftc -O main.swift -o harness && ./harness
//  Optionally start directly in CGS-space mode:
//      ./harness B
//
//  Two modes, switchable live with the on-panel buttons:
//    Mode A  — plain high-level floating NSPanel (level .mainMenu+2),
//              .canJoinAllSpaces. This is the *fallback* design.
//    Mode B  — the panel is inserted into a self-created max-level CGS Space
//              that replicates boringNotch/private/CGSSpace.swift +
//              NotchSpaceManager (level 2147483647). This is the *GO* design.
//
//  This file is pure AppKit so it compiles with `swiftc` alone. The shipping
//  app hosts a SwiftUI TextEditor via NSHostingView; here we use a plain
//  NSTextView so the harness needs no SwiftUI App scene.
//

import AppKit

// MARK: - Minimal CGS Spaces API
//
// These declarations are copied 1:1 (minimal subset) from the real
// boringNotch/private/CGSSpace.swift so Mode B exercises the *exact* code path
// the shipping app would use. Symbols replicated:
//   _CGSDefaultConnection, CGSSpaceCreate, CGSSpaceDestroy,
//   CGSSpaceSetAbsoluteLevel, CGSAddWindowsToSpaces,
//   CGSRemoveWindowsFromSpaces, CGSShowSpaces, CGSHideSpaces

private typealias CGSConnectionID = UInt
private typealias CGSSpaceID = UInt64

@_silgen_name("_CGSDefaultConnection")
private func _CGSDefaultConnection() -> CGSConnectionID
@_silgen_name("CGSSpaceCreate")
private func CGSSpaceCreate(_ cid: CGSConnectionID, _ unknown: Int, _ options: NSDictionary?) -> CGSSpaceID
@_silgen_name("CGSSpaceDestroy")
private func CGSSpaceDestroy(_ cid: CGSConnectionID, _ space: CGSSpaceID)
@_silgen_name("CGSSpaceSetAbsoluteLevel")
private func CGSSpaceSetAbsoluteLevel(_ cid: CGSConnectionID, _ space: CGSSpaceID, _ level: Int)
@_silgen_name("CGSAddWindowsToSpaces")
private func CGSAddWindowsToSpaces(_ cid: CGSConnectionID, _ windows: NSArray, _ spaces: NSArray)
@_silgen_name("CGSRemoveWindowsFromSpaces")
private func CGSRemoveWindowsFromSpaces(_ cid: CGSConnectionID, _ windows: NSArray, _ spaces: NSArray)
@_silgen_name("CGSShowSpaces")
private func CGSShowSpaces(_ cid: CGSConnectionID, _ spaces: NSArray)
@_silgen_name("CGSHideSpaces")
private func CGSHideSpaces(_ cid: CGSConnectionID, _ spaces: NSArray)

/// Replica of `CGSSpace` (boringNotch/private/CGSSpace.swift) + the max-level
/// choice made in NotchSpaceManager.shared.notchSpace.
final class HarnessCGSSpace {
    private let identifier: CGSSpaceID
    private let cid = _CGSDefaultConnection()

    var windows: Set<NSWindow> = [] {
        didSet {
            let remove = oldValue.subtracting(windows)
            let add = windows.subtracting(oldValue)
            if !remove.isEmpty {
                CGSRemoveWindowsFromSpaces(cid, remove.map { $0.windowNumber } as NSArray, [identifier])
            }
            if !add.isEmpty {
                CGSAddWindowsToSpaces(cid, add.map { $0.windowNumber } as NSArray, [identifier])
            }
        }
    }

    init(level: Int = 2147483647) { // 2147483647 == Int32.max, matches NotchSpaceManager
        let flag = 0x1 // MUST be 1, otherwise Finder draws desktop icons (per CGSSpace.swift)
        identifier = CGSSpaceCreate(cid, flag, nil)
        CGSSpaceSetAbsoluteLevel(cid, identifier, level)
        CGSShowSpaces(cid, [identifier])
    }

    deinit {
        CGSHideSpaces(cid, [identifier])
        CGSSpaceDestroy(cid, identifier)
    }
}

// MARK: - The key-capable, non-activating panel
//
// This is the heart of the spike. .nonactivatingPanel means clicking it does
// NOT activate our app (the user's frontmost app stays frontmost). Overriding
// canBecomeKey = true lets it still become the *key window* so the NSTextView
// receives keystrokes. The shipping notch panels hard-code canBecomeKey=false
// for click-through; here we flip it.

final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - Harness controller

enum Mode: String {
    case floating = "A: plain floating panel"
    case cgsSpace = "B: max-level CGS space"
}

final class HarnessController: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var panel: KeyPanel!
    private var textView: NSTextView!
    private var statusLabel: NSTextField!
    private var modeButtonA: NSButton!
    private var modeButtonB: NSButton!
    private var cgsSpace: HarnessCGSSpace?
    private var timer: Timer?
    private var mode: Mode = .floating

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildPanel()
        positionNearTop()
        panel.orderFrontRegardless() // NOTE: never NSApp.activate — that would steal foreground

        let initial: Mode = CommandLine.arguments.contains("B") ? .cgsSpace : .floating
        apply(mode: initial)

        timer = Timer.scheduledTimer(timeInterval: 0.5, target: self,
                                     selector: #selector(tick), userInfo: nil, repeats: true)
        printInstructions()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // MARK: Build

    private func buildPanel() {
        let contentSize = NSSize(width: 470, height: 430)
        let style: NSWindow.StyleMask = [.titled, .closable, .resizable, .nonactivatingPanel, .utilityWindow]
        panel = KeyPanel(contentRect: NSRect(origin: .zero, size: contentSize),
                         styleMask: style, backing: .buffered, defer: false)
        panel.title = "NotchNerd Notepad — focus spike"
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let container = NSView(frame: NSRect(origin: .zero, size: contentSize))
        container.autoresizingMask = [.width, .height]

        // Status line (live): which app is frontmost, is our app active, is the panel key.
        statusLabel = NSTextField(labelWithString: "…")
        statusLabel.frame = NSRect(x: 12, y: contentSize.height - 30, width: contentSize.width - 24, height: 20)
        statusLabel.autoresizingMask = [.width, .minYMargin]
        statusLabel.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        statusLabel.lineBreakMode = .byTruncatingTail
        container.addSubview(statusLabel)

        // Mode buttons
        modeButtonA = NSButton(title: "Mode A: floating", target: self, action: #selector(chooseA))
        modeButtonA.frame = NSRect(x: 12, y: contentSize.height - 64, width: 215, height: 26)
        modeButtonA.autoresizingMask = [.minYMargin]
        modeButtonA.bezelStyle = .rounded
        container.addSubview(modeButtonA)

        modeButtonB = NSButton(title: "Mode B: CGS space", target: self, action: #selector(chooseB))
        modeButtonB.frame = NSRect(x: 235, y: contentSize.height - 64, width: 223, height: 26)
        modeButtonB.autoresizingMask = [.minYMargin, .minXMargin]
        modeButtonB.bezelStyle = .rounded
        container.addSubview(modeButtonB)

        let hint = NSTextField(labelWithString: "Click below and type. Watch the status line — Frontmost should stay your OTHER app.")
        hint.frame = NSRect(x: 12, y: contentSize.height - 86, width: contentSize.width - 24, height: 18)
        hint.autoresizingMask = [.width, .minYMargin]
        hint.font = .systemFont(ofSize: 10)
        hint.textColor = .secondaryLabelColor
        container.addSubview(hint)

        // Scrollable NSTextView
        let scrollFrame = NSRect(x: 12, y: 12, width: contentSize.width - 24, height: contentSize.height - 106)
        let scroll = NSScrollView(frame: scrollFrame)
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        textView = NSTextView(frame: NSRect(origin: .zero, size: scrollFrame.size))
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(width: scrollFrame.width, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.isEditable = true
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.string = "Type here. If letters appear AND the status line below still shows your other app as Frontmost, the focus model works.\n\n"
        scroll.documentView = textView
        container.addSubview(scroll)

        panel.contentView = container
    }

    private func positionNearTop() {
        guard let screen = NSScreen.main else { return }
        let f = screen.visibleFrame
        let size = panel.frame.size
        let origin = NSPoint(x: f.midX - size.width / 2,
                             y: f.maxY - size.height - 8)
        panel.setFrameOrigin(origin)
    }

    // MARK: Mode switching

    @objc private func chooseA() { apply(mode: .floating) }
    @objc private func chooseB() { apply(mode: .cgsSpace) }

    private func apply(mode newMode: Mode) {
        mode = newMode
        panel.level = .mainMenu + 2 // CGS absolute level dominates in mode B; this is the fallback level for A
        switch newMode {
        case .floating:
            // Remove from CGS space if we ever joined one.
            cgsSpace?.windows = []
        case .cgsSpace:
            let space = ensureSpace()
            space.windows = [panel]
        }
        panel.orderFrontRegardless()
        modeButtonA.state = (newMode == .floating) ? .on : .off
        modeButtonB.state = (newMode == .cgsSpace) ? .on : .off
        print("[harness] switched to Mode \(newMode.rawValue)")
    }

    private func ensureSpace() -> HarnessCGSSpace {
        if let s = cgsSpace { return s }
        let s = HarnessCGSSpace() // creates max-level space, mirrors NotchSpaceManager
        cgsSpace = s
        print("[harness] created max-level CGS space (level 2147483647)")
        return s
    }

    // MARK: Live status

    @objc private func tick() {
        let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
        let appActive = NSApp.isActive
        let isKey = panel.isKeyWindow
        statusLabel.stringValue = String(
            format: "Mode %@  |  Frontmost: %@  |  ourApp.isActive: %@  |  notepad.isKey: %@",
            mode == .floating ? "A" : "B", front,
            appActive ? "YES(!)" : "no", isKey ? "YES" : "no")
        statusLabel.textColor = appActive ? .systemRed : .labelColor
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        NSApp.terminate(nil)
    }

    private func printInstructions() {
        print("""

        ============================================================
         NotchNerd notepad focus spike — RUNNING
        ============================================================
        The panel is .accessory + .nonactivatingPanel + canBecomeKey=true.
        We NEVER call NSApp.activate, so your other app should stay frontmost.

        DO THIS:
          1. Bring Safari or Notes to the front (click it). It is now the
             visibly-active app (its menu bar shows, its Dock dot is lit).
          2. WITHOUT cmd-tabbing, click into this notepad and type.
          3. Watch the in-panel status line:
               - 'Frontmost' should stay Safari/Notes (NOT this harness).
               - 'ourApp.isActive' should stay 'no' (red 'YES' = activation leak).
               - 'notepad.isKey' should be 'YES' while you type.
          4. Click 'Mode B: CGS space' and repeat 1–3. THIS is the load-bearing
             test (text focus inside the max-level CGS space).
          5. Put any app into native fullscreen (green button). Does the notepad
             still float above it? (Mode B should; Mode A may or may not.)

        PASS for GO (use CGS space):
            In Mode B you can type, caret blinks, AND Frontmost stays your
            other app AND ourApp.isActive stays 'no' AND it floats over
            fullscreen.
        FAIL -> NO-GO (use fallback Mode A):
            In Mode B you cannot type / no caret, OR Frontmost flips to the
            harness, OR ourApp.isActive turns red 'YES'. Then ship Mode A.

        Close the panel (red dot) or Ctrl+C in this terminal to quit.
        ============================================================

        """)
    }
}

// MARK: - Entry point (main.swift top-level code)

let app = NSApplication.shared
app.setActivationPolicy(.accessory) // LSUIElement-equivalent: no Dock icon, no menu bar
let controller = HarnessController()
app.delegate = controller
app.run()
