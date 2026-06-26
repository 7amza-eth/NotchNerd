//
//  GhosttyJumpService.swift
//  NotchNerd — Phase 4 terminal jump-back (Ghostty only)
//
//  Brings the Ghostty window/tab/split running a Claude Code session to the foreground.
//  Ported from Open Island's TerminalJumpService Ghostty path (the only terminal in scope).
//  Requires the Automation (Apple Events) TCC grant for Ghostty — macOS prompts on first use.
//
//  The session's JumpTarget is enriched at hook time (ClaudeHooks reads GHOSTTY_RESOURCES_DIR +
//  runs an osascript locator), so a session started in Ghostty carries terminalSessionID etc.
//

import Foundation
import OpenIslandCore

enum GhosttyJumpService {
    static let bundleIdentifier = "com.mitchellh.ghostty"
    private static let windowActivationDelay = 0.04
    private static let focusSettleDelay = 0.08
    private static let focusAttempts = 3

    /// True if the matching terminal was focused. Safe to call off the main thread.
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

    private static func escape(_ value: String?) -> String {
        guard let value else { return "" }
        return value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func script(for target: JumpTarget) -> String {
        let terminalSessionID = escape(target.terminalSessionID)
        let workingDirectory = escape(target.workingDirectory)
        let paneTitle = escape(target.paneTitle)
        return """
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
                            if (working directory of aTerminal as text) is "\(workingDirectory)" then
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

    private static func runOsascript(_ script: String) -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", script]
        let outputPipe = Pipe()
        task.standardOutput = outputPipe
        task.standardError = Pipe()
        do { try task.run() } catch { return "" }
        task.waitUntilExit()
        return String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
