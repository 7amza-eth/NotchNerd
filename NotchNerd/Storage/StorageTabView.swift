//
//  StorageTabView.swift
//  NotchNerd
//
//  The Storage tab: a disk bar with free space on the left, reclaimable categories on the right.
//  Cleaning is two taps (Clean → Confirm) because the notch panel can't host a modal dialog.
//  Engine: StorageManager.swift. Settings: StorageSettings below.
//

import Defaults
import SwiftUI

let storageNotchSize: CGSize = .init(width: openNotchSize.width, height: 300)

struct StorageTabView: View {
    @ObservedObject private var storage = StorageManager.shared
    @State private var confirming: StorageCategory.ID?
    @State private var showingProjects = false
    @ObservedObject private var parking = ProjectParking.shared

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            summary
                .frame(width: 180)
            Divider().overlay(Color.white.opacity(0.08))
            if showingProjects {
                ProjectParkingList(onBack: { withAnimation(.smooth(duration: 0.2)) { showingProjects = false } })
            } else {
                list
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 10)
        .foregroundStyle(.white)
        .onAppear {
            #if DEBUG
            if UserDefaults.standard.string(forKey: "debugOpenTab") == "storage-projects", !showingProjects {
                showingProjects = true
                parking.scan()
            }
            #endif
            storage.refreshFreeSpace()
            // Rescan when the numbers are missing or more than 10 minutes old.
            if storage.lastScan.map({ Date().timeIntervalSince($0) > 600 }) ?? true { storage.scan() }
        }
    }

    // MARK: Left: the disk

    private var summary: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "internaldrive").foregroundStyle(.secondary)
                Text("Macintosh HD").font(.caption).foregroundStyle(.secondary)
            }
            Text(StorageManager.format(storage.freeBytes))
                .font(.system(size: 28, weight: .semibold, design: .rounded))
                .foregroundStyle(storage.isLow ? .orange : .white)
                .contentTransition(.numericText())
            Text("free of \(StorageManager.format(storage.totalBytes))")
                .font(.caption).foregroundStyle(.secondary)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.1))
                    Capsule()
                        .fill(storage.isLow ? Color.orange : Color.white.opacity(0.75))
                        .frame(width: geo.size.width * storage.usedFraction)
                }
            }
            .frame(height: 6)
            .animation(.smooth, value: storage.usedFraction)

            Spacer(minLength: 4)

            if storage.reclaimableBytes > 0 {
                Text("\(StorageManager.format(storage.reclaimableBytes)) can be cleaned")
                    .font(.caption).foregroundStyle(.green.opacity(0.9))
            }
            if let result = (showingProjects ? parking.lastResult : nil) ?? storage.lastResult {
                Text(result).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            }
            Button(action: { storage.scan() }) {
                HStack(spacing: 4) {
                    if storage.scanning { ProgressView().controlSize(.mini) } else { Image(systemName: "arrow.clockwise") }
                    Text(storage.scanning ? "Measuring…" : "Rescan")
                }
                .font(.caption)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Capsule().fill(Color.white.opacity(0.1)))
            }
            .buttonStyle(.plain)
            .disabled(storage.scanning)
        }
    }

    // MARK: Right: what can go

    private var list: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 2) {
                ForEach(storage.categories) { cat in
                    row(cat)
                }
            }
        }
    }

    private func row(_ cat: StorageCategory) -> some View {
        HStack(spacing: 10) {
            Image(systemName: cat.symbol)
                .frame(width: 20)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(cat.title).font(.callout)
                    if !cat.detail.isEmpty {
                        Text(cat.detail).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Text(cat.unavailable ?? cat.explainer)
                    .font(.caption2)
                    .foregroundStyle(cat.unavailable == nil ? .secondary : Color.orange)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            Group {
                if let bytes = cat.bytes {
                    Text(bytes == 0 ? "—" : StorageManager.format(bytes))
                } else if storage.scanning {
                    ProgressView().controlSize(.mini)
                } else {
                    Text("—")
                }
            }
            .font(.callout.monospacedDigit())
            .foregroundStyle(.secondary)
            .frame(width: 70, alignment: .trailing)

            cleanButton(cat)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(confirming == cat.id ? 0.08 : 0.03)))
        .help(cat.title + ": " + cat.explainer)
    }

    @ViewBuilder
    private func cleanButton(_ cat: StorageCategory) -> some View {
        if cat.id == .nodeModules {
            reviewButton(cat)
        } else {
            plainCleanButton(cat)
        }
    }

    /// Idle projects are picked one by one, so this row opens a list instead of cleaning.
    private func reviewButton(_ cat: StorageCategory) -> some View {
        let disabled = (cat.bytes ?? 0) == 0 && parking.parked.isEmpty
        return Button(action: {
            withAnimation(.smooth(duration: 0.2)) { showingProjects = true }
            parking.scan()
        }) {
            Text("Review")
                .font(.caption.weight(.medium))
                .frame(width: 58)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.white.opacity(0.12)))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.35 : 1)
    }

    @ViewBuilder
    private func plainCleanButton(_ cat: StorageCategory) -> some View {
        let disabled = cat.unavailable != nil || (cat.bytes ?? 0) == 0 || storage.cleaning != nil
        if storage.cleaning == cat.id {
            ProgressView().controlSize(.small).frame(width: 66)
        } else {
            Button(action: { tap(cat.id) }) {
                Text(confirming == cat.id ? "Confirm" : "Clean")
                    .font(.caption.weight(.medium))
                    .frame(width: 58)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(confirming == cat.id ? Color.red.opacity(0.8) : Color.white.opacity(0.12)))
            }
            .buttonStyle(.plain)
            .disabled(disabled)
            .opacity(disabled ? 0.35 : 1)
        }
    }

    private func tap(_ id: StorageCategory.ID) {
        if confirming == id {
            confirming = nil
            storage.clean(id)
        } else {
            withAnimation(.smooth(duration: 0.2)) { confirming = id }
            // Drop the armed state if they don't confirm.
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                if confirming == id { withAnimation { confirming = nil } }
            }
        }
    }
}

// MARK: - Settings → Storage

struct StorageSettings: View {
    @Default(.storageLowSpaceGB) var lowSpaceGB
    @Default(.storageIdleDays) var idleDays
    @Default(.storageProjectRoots) var roots
    @Default(.storageAutoCleanLastRun) var lastRun
    @Default(.storageAutoCleanLastFreed) var lastFreed
    @ObservedObject private var storage = StorageManager.shared

    private var lastRunText: String {
        if storage.cleaning != nil { return "Cleaning…" }
        guard lastRun > 0 else { return "Hasn't run yet" }
        let when = RelativeDateTimeFormatter().localizedString(for: Date(timeIntervalSince1970: lastRun), relativeTo: Date())
        return "Last run \(when), freed \(StorageManager.format(Int64(lastFreed)))"
    }

    var body: some View {
        Form {
            Section {
                Defaults.Toggle(key: .storageTabEnabled) { Text("Show the Storage tab in the notch") }
                Defaults.Toggle(key: .storageLowSpaceAlerts) { Text("Warn in the notch when the disk is almost full") }
                Stepper("Warn below \(lowSpaceGB) GB free", value: $lowSpaceGB, in: 5...200, step: 5)
            } header: {
                Text("Storage")
            } footer: {
                Text("Shows free space and the caches that are safe to clear. The warning shows at most once an hour.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Defaults.Toggle(key: .storageAutoCleanEnabled) { Text("Clear rebuildable caches once a week") }
                HStack {
                    Text(lastRunText).foregroundStyle(.secondary)
                    Spacer()
                    Button("Run now") { StorageManager.shared.runAutoClean() }
                        .disabled(storage.cleaning != nil)
                }
            } header: {
                Text("Weekly clean")
            } footer: {
                Text("Clears the Xcode build cache, package caches (npm, pnpm, uv, Homebrew and others) and simulators for iOS versions you no longer have. All of it rebuilds itself when needed. Your simulators, node_modules and app data are left alone.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Stepper("Idle after \(idleDays) days", value: $idleDays, in: 3...180)
                ForEach(roots, id: \.self) { root in
                    HStack {
                        Text(root).font(.callout.monospaced())
                        Spacer()
                        Button(role: .destructive) { roots.removeAll { $0 == root } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.plain)
                    }
                }
                Button("Add folder…") { addRoot() }
            } header: {
                Text("Idle projects")
            } footer: {
                Text("Projects in these folders (and any ~/.…worktrees folder) with no file changed for this many days, and nothing running inside them, count as idle. Parking one deletes node_modules, Pods and build caches but never source, .git, env files or .wrangler state. Wake reinstalls them.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func addRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let path = url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        if !roots.contains(path) { roots.append(path) }
    }
}
