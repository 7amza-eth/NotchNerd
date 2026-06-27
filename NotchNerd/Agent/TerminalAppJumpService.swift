//
//  TerminalAppJumpService.swift
//  NotchNerd — terminal jump-back for macOS Terminal.app
//
//  Brings the Terminal.app window/tab running a Claude Code session to the foreground,
//  matching by TTY (then custom title). Ported from Open Island's TerminalJumpService
//  Terminal.app path. Requires the Automation (Apple Events) TCC grant for Terminal —
//  macOS prompts on first use. The Claude hook labels these sessions terminalApp == "Terminal"
//  (from TERM_PROGRAM=Apple_Terminal) and stamps the controlling tty.
//

import AppKit
import Foundation
import OpenIslandCore

enum TerminalAppJumpService {
    static let bundleIdentifier = "com.apple.Terminal"

    /// Whether this target looks like a macOS Terminal.app session we can jump to.
    static func canJump(to target: JumpTarget?) -> Bool {
        guard let target else { return false }
        let app = target.terminalApp.lowercased()
        guard app == "terminal" || app.contains("apple_terminal") || app == "com.apple.terminal" else {
            return false
        }
        return (target.terminalTTY?.isEmpty == false) || !target.paneTitle.isEmpty
    }

    /// True if the matching tab was focused. Safe to call off the main thread.
    @discardableResult
    static func jump(to target: JumpTarget) -> Bool {
        runOsascript(script(for: target)) == "matched"
    }

    private static func escape(_ value: String?) -> String {
        guard let value else { return "" }
        return value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func script(for target: JumpTarget) -> String {
        let tty = escape(target.terminalTTY)
        let paneTitle = escape(target.paneTitle)
        return """
        tell application "Terminal"
            if not (it is running) then return ""
            activate
            repeat with aWindow in windows
                repeat with aTab in tabs of aWindow
                    if "\(tty)" is not "" and (tty of aTab as text) is "\(tty)" then
                        set selected of aTab to true
                        set frontmost of aWindow to true
                        return "matched"
                    end if
                    if "\(paneTitle)" is not "" and (custom title of aTab as text) contains "\(paneTitle)" then
                        set selected of aTab to true
                        set frontmost of aWindow to true
                        return "matched"
                    end if
                end repeat
            end repeat
        end tell
        return ""
        """
    }

    /// Bounded + concurrently-drained osascript runner (same hardening as GhosttyJumpService).
    private static func runOsascript(_ script: String, timeout: TimeInterval = 3) -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", script]
        let outputPipe = Pipe()
        task.standardOutput = outputPipe
        task.standardError = Pipe()
        do { try task.run() } catch { return "" }

        let group = DispatchGroup()
        group.enter()
        var output = Data()
        DispatchQueue.global(qos: .utility).async {
            output = outputPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        if group.wait(timeout: .now() + timeout) == .timedOut {
            task.terminate()
            _ = group.wait(timeout: .now() + 0.5)
        }
        task.waitUntilExit()
        return String(data: output, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

/// Routes an agent session's jump to the right terminal service. NotchNerd supports
/// Ghostty (precise, with live re-resolution) and macOS Terminal.app (TTY match).
enum AgentTerminalJump {
    static func canJump(to target: JumpTarget?) -> Bool {
        GhosttyJumpService.canJump(to: target) || TerminalAppJumpService.canJump(to: target)
    }

    /// Display name for the matched terminal (for status messages).
    static func appName(for target: JumpTarget?) -> String {
        if GhosttyJumpService.canJump(to: target) { return "Ghostty" }
        if TerminalAppJumpService.canJump(to: target) { return "Terminal" }
        return "terminal"
    }

    @discardableResult
    static func jump(to target: JumpTarget) -> Bool {
        if GhosttyJumpService.canJump(to: target) { return GhosttyJumpService.jumpResolving(to: target) }
        if TerminalAppJumpService.canJump(to: target) { return TerminalAppJumpService.jump(to: target) }
        return false
    }
}
