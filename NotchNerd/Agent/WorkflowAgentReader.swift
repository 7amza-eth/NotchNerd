//
//  WorkflowAgentReader.swift
//  NotchNerd — dynamic-workflow agent visibility
//
//  Surfaces the agents a session's "dynamic workflow" (the Workflow tool) is currently running.
//  These are NOT classic Task/Agent subagents — they don't fire SubagentStart/Stop hooks and don't
//  appear in the main transcript, so the engine's `activeSubagents` never sees them. Instead they
//  live on disk next to the session transcript:
//
//      <sessionDir>/subagents/workflows/wf_<runId>/
//          journal.jsonl                     # one {"type":"started"|"result", "agentId", ...} per agent
//          agent-<agentId>.jsonl             # that agent's live transcript
//          agent-<agentId>.meta.json         # {"agentType": "...", "spawnDepth": N}
//
//  where `<sessionDir>` is the transcript path minus its `.jsonl` extension. A running agent is one
//  with a `started` but no `result` in the journal AND a freshly-written transcript (the journal
//  goes quiet while long agents run, so per-agent mtime is the reliable liveness signal). This is
//  the only way to show workflow progress for a hookless/bridge session. Must run off the main actor.
//

import Foundation

struct WorkflowActivity: Equatable {
    /// Agents started-but-not-finished with a freshly-written transcript.
    var runningAgents: Int
    /// `agentType` of the running agents (best-effort, capped), for the expanded detail.
    var agentTypes: [String]
}

enum WorkflowAgentReader {
    /// Don't bother parsing a workflow whose journal hasn't moved in this long (done/abandoned).
    private static let journalStaleWindow: TimeInterval = 300
    /// A started-no-result agent counts as running only if its transcript moved this recently.
    private static let agentFreshWindow: TimeInterval = 120
    private static let agentTypeCap = 16

    /// Non-nil only when the session has ≥1 running workflow agent.
    static func read(transcriptPath: String, now: Date = Date()) -> WorkflowActivity? {
        let sessionDir = (transcriptPath as NSString).deletingPathExtension
        let workflowsDir = sessionDir + "/subagents/workflows"
        let fm = FileManager.default
        guard let runDirs = try? fm.contentsOfDirectory(atPath: workflowsDir) else { return nil }

        var runningCount = 0
        var agentTypes: [String] = []

        for run in runDirs where run.hasPrefix("wf_") {
            let runDir = workflowsDir + "/" + run
            let journalPath = runDir + "/journal.jsonl"
            guard let journalMTime = mtime(journalPath, fm), now.timeIntervalSince(journalMTime) < journalStaleWindow,
                  let data = fm.contents(atPath: journalPath),
                  let text = String(data: data, encoding: .utf8) else { continue }

            var started: [String] = []
            var finished = Set<String>()
            for line in text.split(separator: "\n") {
                guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      let type = obj["type"] as? String,
                      let agentID = obj["agentId"] as? String else { continue }
                if type == "started" { started.append(agentID) }
                else if type == "result" { finished.insert(agentID) }
            }

            for agentID in started where !finished.contains(agentID) {
                let agentPath = runDir + "/agent-\(agentID).jsonl"
                guard let agentMTime = mtime(agentPath, fm),
                      now.timeIntervalSince(agentMTime) < agentFreshWindow else { continue }
                runningCount += 1
                if agentTypes.count < agentTypeCap,
                   let metaData = fm.contents(atPath: runDir + "/agent-\(agentID).meta.json"),
                   let meta = try? JSONSerialization.jsonObject(with: metaData) as? [String: Any],
                   let type = meta["agentType"] as? String {
                    agentTypes.append(type)
                }
            }
        }

        guard runningCount > 0 else { return nil }
        return WorkflowActivity(runningAgents: runningCount, agentTypes: agentTypes)
    }

    private static func mtime(_ path: String, _ fm: FileManager) -> Date? {
        (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }
}
