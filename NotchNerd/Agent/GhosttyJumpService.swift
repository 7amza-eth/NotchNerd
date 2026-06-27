//
//  GhosttyJumpService.swift
//  NotchNerd — terminal jump-back (Ghostty only)
//
//  Brings the Ghostty window/tab/split running a Claude Code session to the foreground.
//  Ported from Open Island's TerminalJumpService Ghostty path (the only terminal in scope).
//  Requires the Automation (Apple Events) TCC grant for Ghostty — macOS prompts on first use.
//  The frontmost short-circuit, live re-resolution, and jump all send Apple Events to the same
//  bundle id, so they share that single grant.
//
//  The session's JumpTarget is enriched at hook time (ClaudeHooks reads GHOSTTY_RESOURCES_DIR +
//  runs an osascript locator), but for non-SessionStart hooks Ghostty only reports the *focused*
//  surface, so terminalSessionID is frequently stale/nil by jump time — hence the pre-jump
//  re-resolution against the live Ghostty surface list (cwd is the most reliable anchor).
//

import AppKit
import Foundation
import OpenIslandCore

enum GhosttyJumpService {
    static let bundleIdentifier = "com.mitchellh.ghostty"
    private static let windowActivationDelay = 0.04
    private static let focusSettleDelay = 0.08
    private static let focusAttempts = 3

    /// Full jump: no-op if the session is already the focused Ghostty surface, otherwise
    /// re-resolve the live surface (recovering a stale/nil id from cwd/title) and focus it.
    /// Safe to call off the main thread.
    @discardableResult
    static func jumpResolving(to target: JumpTarget) -> Bool {
        if isAlreadyFocused(target) { return true }
        return jump(to: reresolve(target))
    }

    /// Raw jump against the given target (no re-resolution / frontmost check).
    @discardableResult
    static func jump(to target: JumpTarget) -> Bool {
        runOsascript(script(for: target)) == "matched"
    }

    /// Whether this target looks like a Ghostty session we can jump to.
    static func canJump(to target: JumpTarget?) -> Bool {
        guard let target else { return false }
        let app = target.terminalApp.lowercased()
        let hasLocator = (target.terminalSessionID?.isEmpty == false)
            || (target.workingDirectory?.isEmpty == false)
            || !target.paneTitle.isEmpty
        return (app.contains("ghostty") || app.contains("mitchellh")) && hasLocator
    }

    // MARK: - Already-focused short-circuit

    /// Cheap probe: is the target's surface already the focused Ghostty terminal?
    /// Returns false (i.e. do the jump) unless we can positively confirm a match.
    private static func isAlreadyFocused(_ target: JumpTarget) -> Bool {
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleIdentifier else {
            return false
        }
        guard let id = target.terminalSessionID, !id.isEmpty else { return false }
        let focused = runOsascript("""
        tell application "Ghostty"
            if not (it is running) then return ""
            try
                return id of focused terminal of selected tab of front window as text
            end try
            return ""
        end tell
        """)
        return !focused.isEmpty && focused == id
    }

    // MARK: - Pre-jump re-resolution

    private struct GhosttySnapshot {
        let sessionID: String
        let workingDirectory: String
        let title: String
    }

    /// Enumerate every live Ghostty terminal once (id ␟ cwd ␟ title, RS-joined).
    private static func liveSnapshots() -> [GhosttySnapshot] {
        let fs = "\u{1F}", rs = "\u{1E}"
        let out = runOsascript("""
        set fieldSeparator to ASCII character 31
        set recordSeparator to ASCII character 30
        tell application "Ghostty"
            if not (it is running) then return ""
            set outputLines to {}
            repeat with aTerminal in terminals
                set tID to ""
                set tDir to ""
                set tTitle to ""
                try
                    set tID to (id of aTerminal as text)
                end try
                try
                    set tDir to (working directory of aTerminal as text)
                end try
                try
                    set tTitle to (name of aTerminal as text)
                end try
                set end of outputLines to tID & fieldSeparator & tDir & fieldSeparator & tTitle
            end repeat
            set AppleScript's text item delimiters to recordSeparator
            set joinedOutput to outputLines as string
            set AppleScript's text item delimiters to ""
            return joinedOutput
        end tell
        """)
        return out.split(separator: Character(rs), omittingEmptySubsequences: true).compactMap { rec in
            let v = rec.components(separatedBy: fs)
            guard v.count == 3 else { return nil }
            return GhosttySnapshot(sessionID: v[0], workingDirectory: v[1], title: v[2])
        }
    }

    /// Correct the target's terminalSessionID against a live surface (by cwd, then title),
    /// or return the original target unchanged if no better match is found.
    private static func reresolve(_ target: JumpTarget) -> JumpTarget {
        let snaps = liveSnapshots()
        guard !snaps.isEmpty else { return target }

        let wantID = target.terminalSessionID?.trimmingCharacters(in: .whitespaces) ?? ""
        if !wantID.isEmpty, snaps.contains(where: { $0.sessionID == wantID }) {
            return target   // id still valid
        }

        let wantCWD = normalizedCWD(target.workingDirectory)
        if !wantCWD.isEmpty,
           let match = snaps.first(where: { normalizedCWD($0.workingDirectory) == wantCWD }) {
            var t = target
            t.terminalSessionID = match.sessionID
            if !match.title.isEmpty { t.paneTitle = match.title }
            return t
        }

        if !target.paneTitle.isEmpty,
           let match = snaps.first(where: { $0.title.contains(target.paneTitle) }) {
            var t = target
            t.terminalSessionID = match.sessionID
            return t
        }

        return target   // fall back; the jump script still tries cwd/title
    }

    /// Standardize a path and drop a single trailing slash (no lowercasing — APFS can be
    /// case-sensitive). Used on both sides of the cwd comparison.
    private static func normalizedCWD(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "" }
        var p = URL(fileURLWithPath: value).standardizedFileURL.path
        if p.count > 1, p.hasSuffix("/") { p.removeLast() }
        return p
    }

    // MARK: - Jump script

    private static func escape(_ value: String?) -> String {
        guard let value else { return "" }
        return value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func script(for target: JumpTarget) -> String {
        let terminalSessionID = escape(target.terminalSessionID)
        let workingDirectory = escape(normalizedCWD(target.workingDirectory))
        let paneTitle = escape(target.paneTitle)
        return """
        on normalizePath(p)
            set t to p as text
            if t ends with "/" and (length of t) > 1 then set t to text 1 thru -2 of t
            return t
        end normalizePath

        tell application "Ghostty"
            if not (it is running) then return ""
            activate

            set targetWindow to missing value
            set targetTab to missing value
            set targetTerminal to missing value

            repeat with aWindow in windows
                repeat with aTab in tabs of aWindow
                    repeat with aTerminal in terminals of aTab
                        if "\(terminalSessionID)" is not "" and (id of aTerminal as text) is "\(terminalSessionID)" then
                            set targetWindow to aWindow
                            set targetTab to aTab
                            set targetTerminal to aTerminal
                            exit repeat
                        end if
                    end repeat
                    if targetTerminal is not missing value then exit repeat
                end repeat
                if targetTerminal is not missing value then exit repeat
            end repeat

            if targetTerminal is missing value and "\(workingDirectory)" is not "" then
                repeat with aWindow in windows
                    repeat with aTab in tabs of aWindow
                        repeat with aTerminal in terminals of aTab
                            if my normalizePath(working directory of aTerminal as text) is "\(workingDirectory)" then
                                set targetWindow to aWindow
                                set targetTab to aTab
                                set targetTerminal to aTerminal
                                exit repeat
                            end if
                        end repeat
                        if targetTerminal is not missing value then exit repeat
                    end repeat
                    if targetTerminal is not missing value then exit repeat
                end repeat
            end if

            if targetTerminal is missing value and "\(paneTitle)" is not "" then
                repeat with aWindow in windows
                    repeat with aTab in tabs of aWindow
                        repeat with aTerminal in terminals of aTab
                            if (name of aTerminal as text) contains "\(paneTitle)" then
                                set targetWindow to aWindow
                                set targetTab to aTab
                                set targetTerminal to aTerminal
                                exit repeat
                            end if
                        end repeat
                        if targetTerminal is not missing value then exit repeat
                    end repeat
                    if targetTerminal is not missing value then exit repeat
                end repeat
            end if

            if targetTerminal is missing value then return ""

            if "\(terminalSessionID)" is "" then
                if targetWindow is not missing value then
                    activate window targetWindow
                    delay \(windowActivationDelay)
                end if
                if targetTab is not missing value then
                    select tab targetTab
                    delay \(windowActivationDelay)
                end if
                focus targetTerminal
                delay \(focusSettleDelay)
                return "matched"
            end if

            repeat \(focusAttempts) times
                if targetWindow is not missing value then
                    activate window targetWindow
                    delay \(windowActivationDelay)
                end if
                if targetTab is not missing value then
                    select tab targetTab
                    delay \(windowActivationDelay)
                end if
                focus targetTerminal
                delay \(focusSettleDelay)
                try
                    if (id of focused terminal of selected tab of front window as text) is "\(terminalSessionID)" then
                        return "matched"
                    end if
                end try
            end repeat
        end tell
        return ""
        """
    }

    /// Run an AppleScript via osascript with a bounded wait so a hung Apple Event can't
    /// block the detached jump task indefinitely.
    private static func runOsascript(_ script: String, timeout: TimeInterval = 3) -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", script]
        let outputPipe = Pipe()
        task.standardOutput = outputPipe
        task.standardError = Pipe()
        do { try task.run() } catch { return "" }

        // Drain stdout on a background queue: the read returns EOF when osascript closes its stdout
        // (i.e. exits), which doubles as our completion signal — so there is no terminationHandler
        // ordering race, and a large write can't deadlock the child against an undrained pipe.
        let group = DispatchGroup()
        group.enter()
        var output = Data()
        DispatchQueue.global(qos: .utility).async {
            output = outputPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        if group.wait(timeout: .now() + timeout) == .timedOut {
            task.terminate()                       // closes stdout → the read above returns EOF
            _ = group.wait(timeout: .now() + 0.5)
        }
        task.waitUntilExit()
        return String(data: output, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
