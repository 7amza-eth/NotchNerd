//
//  PlanTextLoader.swift
//  NotchNerd — plan-mode support
//
//  Extracts the plan markdown Claude attached to its most recent `ExitPlanMode` call by
//  tail-reading the session transcript (`~/.claude/projects/**.jsonl`). The hook payload's
//  `tool_input` never reaches the app layer (`PermissionRequest` carries no toolInput, and the
//  engine's `toolInputPreview` key list omits `plan`), so the transcript is the only app-layer
//  source. The assistant's tool_use record is already on disk when the blocking PermissionRequest
//  hook fires, so a bounded tail read is sufficient. Must run off the main actor.
//

import Foundation

enum PlanTextLoader {
    /// The ExitPlanMode tool_use is the newest assistant record when the permission prompt fires,
    /// but plans can be long — scan a generous tail.
    private static let tailByteLimit: UInt64 = 256 * 1024

    /// Returns the plan text for `toolUseID` (falling back to the newest ExitPlanMode call when
    /// the exact id isn't found — e.g. transcript flush lag).
    static func loadPlan(transcriptPath: String, toolUseID: String?) -> String? {
        guard let handle = FileHandle(forReadingAtPath: transcriptPath) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size > 0 else { return nil }

        let start = size > tailByteLimit ? size - tailByteLimit : 0
        do { try handle.seek(toOffset: start) } catch { return nil }
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return nil }

        var lines = data.split(separator: UInt8(ascii: "\n"))
        // Started mid-file → the first line is (probably) partial; drop it.
        if start > 0, !lines.isEmpty { lines.removeFirst() }

        let needle = Data("ExitPlanMode".utf8)
        var newestPlan: String?
        for line in lines.reversed() {
            let lineData = Data(line)
            guard lineData.range(of: needle) != nil else { continue }
            guard let record = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let message = record["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else { continue }
            for block in content
                where (block["type"] as? String) == "tool_use" && (block["name"] as? String) == "ExitPlanMode" {
                guard let input = block["input"] as? [String: Any],
                      let plan = input["plan"] as? String, !plan.isEmpty else { continue }
                if let toolUseID, (block["id"] as? String) == toolUseID {
                    return plan // exact match for the pending request
                }
                if newestPlan == nil { newestPlan = plan } // newest-seen fallback
            }
        }
        return newestPlan
    }
}
