//
//  ClaudeTranscriptReader.swift
//  NotchNerd — expanded-row transcript detail
//
//  Off-main reader for a session's ~/.claude/projects transcript, powering the expanded row's
//  activity timeline / edited files / stats (and the plan-text + last-message fallbacks). Field
//  shapes were validated against real Claude Code v2.1.198 transcripts on 2026-06-30:
//  `assistant.message.usage.output_tokens`, `message.content[]` text/tool_use blocks,
//  `file-history-snapshot.snapshot.trackedFileBackups` {path: {backupFileName, version,
//  backupTime}}, ISO-8601 `timestamp`. Files ≤ 12 MB are parsed whole (stats need the full
//  stream); larger ones fall back to a 512 KB tail read with `truncated = true`.
//  NEVER call from a SwiftUI body — run via Task.detached (the spotlightWorktreeBranch
//  99%-CPU lesson).
//

import Foundation

struct ClaudeTranscriptDetail: Equatable {
    struct ActivityEntry: Equatable, Identifiable {
        let id: String
        let toolName: String
        let preview: String?
        let timestamp: Date?
        let isSidechain: Bool
    }

    struct EditedFile: Equatable, Identifiable {
        var id: String { path }
        let path: String
        /// Backup version — a rough "times edited" counter.
        let version: Int
    }

    var fullLastAssistantMessage: String?
    var planText: String?
    var recentActivity: [ActivityEntry] = []   // newest last, capped
    var editedFiles: [EditedFile] = []         // from the latest file-history-snapshot
    var turnCount: Int = 0                     // real user prompts (tool_result records excluded)
    var outputTokens: Int = 0
    var truncated: Bool = false
}

enum ClaudeTranscriptReader {
    private static let fullScanByteLimit: UInt64 = 12 * 1024 * 1024
    private static let tailByteLimit: UInt64 = 512 * 1024
    private static let activityCap = 8

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func read(transcriptPath: String) -> ClaudeTranscriptDetail? {
        guard let handle = FileHandle(forReadingAtPath: transcriptPath) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size > 0 else { return nil }

        let truncated = size > fullScanByteLimit
        let start = truncated ? size - tailByteLimit : 0
        do { try handle.seek(toOffset: start) } catch { return nil }
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return nil }

        var lines = data.split(separator: UInt8(ascii: "\n"))
        if start > 0, !lines.isEmpty { lines.removeFirst() } // partial first line

        var detail = ClaudeTranscriptDetail(truncated: truncated)
        var activity: [ClaudeTranscriptDetail.ActivityEntry] = []

        for line in lines {
            guard let record = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let type = record["type"] as? String else { continue }
            switch type {
            case "assistant":
                guard let message = record["message"] as? [String: Any] else { continue }
                if let usage = message["usage"] as? [String: Any],
                   let out = usage["output_tokens"] as? Int {
                    detail.outputTokens += out
                }
                let timestamp = (record["timestamp"] as? String).flatMap(isoFormatter.date(from:))
                let isSidechain = record["isSidechain"] as? Bool ?? false
                var texts: [String] = []
                for block in message["content"] as? [[String: Any]] ?? [] {
                    switch block["type"] as? String {
                    case "text":
                        if let text = block["text"] as? String, !text.isEmpty { texts.append(text) }
                    case "tool_use":
                        let name = block["name"] as? String ?? "Tool"
                        activity.append(.init(
                            id: block["id"] as? String ?? UUID().uuidString,
                            toolName: name,
                            preview: toolInputPreview(block["input"] as? [String: Any]),
                            timestamp: timestamp,
                            isSidechain: isSidechain
                        ))
                        if name == "ExitPlanMode",
                           let input = block["input"] as? [String: Any],
                           let plan = input["plan"] as? String, !plan.isEmpty {
                            detail.planText = plan
                        }
                    default:
                        break
                    }
                }
                if !isSidechain, !texts.isEmpty {
                    detail.fullLastAssistantMessage = texts.joined(separator: "\n\n")
                }
            case "user":
                // Real prompts only — tool results also arrive as type "user".
                guard record["isSidechain"] as? Bool != true,
                      let message = record["message"] as? [String: Any] else { continue }
                if message["content"] is String {
                    detail.turnCount += 1
                } else if let blocks = message["content"] as? [[String: Any]],
                          blocks.contains(where: { ($0["type"] as? String) == "text" }),
                          !blocks.contains(where: { ($0["type"] as? String) == "tool_result" }) {
                    detail.turnCount += 1
                }
            case "file-history-snapshot":
                guard let snapshot = record["snapshot"] as? [String: Any],
                      let backups = snapshot["trackedFileBackups"] as? [String: Any] else { continue }
                detail.editedFiles = backups.map { path, value in
                    ClaudeTranscriptDetail.EditedFile(
                        path: path,
                        version: (value as? [String: Any])?["version"] as? Int ?? 1
                    )
                }
                .sorted { $0.path < $1.path }
            default:
                break
            }
        }

        detail.recentActivity = Array(activity.suffix(activityCap))
        return detail
    }

    /// Best-effort one-line preview of a tool call, mirroring the engine's key priority.
    private static func toolInputPreview(_ input: [String: Any]?) -> String? {
        guard let input else { return nil }
        for key in ["command", "file_path", "pattern", "query", "prompt", "description", "skill", "url"] {
            if let value = input[key] as? String, !value.isEmpty {
                let collapsed = value.split(whereSeparator: \.isNewline).joined(separator: " ")
                return collapsed.count > 90 ? String(collapsed.prefix(90)) + "…" : collapsed
            }
        }
        return nil
    }
}
