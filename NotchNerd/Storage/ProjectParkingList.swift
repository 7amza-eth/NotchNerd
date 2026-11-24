//
//  ProjectParkingList.swift
//  NotchNerd
//
//  The Storage tab's "Idle projects" review list: idle projects with a Park button each (two taps,
//  like Clean), then the parked ones with Wake. Engine: ProjectParking.swift.
//

import SwiftUI

struct ProjectParkingList: View {
    let onBack: () -> Void
    @ObservedObject private var parking = ProjectParking.shared
    @State private var confirming: String?

    private var parkable: [IdleProject] { parking.idle.filter { !$0.inUse } }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 2) {
                    if parking.scanning && parking.idle.isEmpty {
                        HStack { ProgressView().controlSize(.small); Text("Looking for idle projects…").font(.caption).foregroundStyle(.secondary) }
                            .padding(.vertical, 20)
                    } else if parking.idle.isEmpty && parking.parked.isEmpty {
                        Text("Nothing idle right now").font(.caption).foregroundStyle(.secondary).padding(.vertical, 20)
                    }
                    ForEach(parking.idle) { idleRow($0) }
                    if !parking.parked.isEmpty {
                        Text("Parked")
                            .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 8).padding(.leading, 8)
                        ForEach(parking.parked) { parkedRow($0) }
                    }
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button(action: onBack) {
                Image(systemName: "chevron.left").font(.caption.weight(.semibold))
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Color.white.opacity(0.1)))
            }
            .buttonStyle(.plain)
            Text("Idle projects").font(.callout.weight(.medium))
            if parking.scanning { ProgressView().controlSize(.mini) }
            Spacer()
            if parkable.count > 1 {
                let armed = confirming == "*all*"
                Button(action: { tap("*all*") { parking.parkAll() } }) {
                    Text(armed ? "Confirm" : "Park all · \(StorageManager.format(parking.idleBytes))")
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Capsule().fill(armed ? Color.red.opacity(0.8) : Color.white.opacity(0.12)))
                }
                .buttonStyle(.plain)
                .disabled(!parking.busy.isEmpty)
            }
        }
        .padding(.horizontal, 4)
    }

    private func idleRow(_ p: IdleProject) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "folder").frame(width: 20).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(p.name).font(.callout).lineLimit(1).layoutPriority(1)
                    if !p.rootLabel.isEmpty {
                        Text(p.rootLabel).font(.caption2).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                    }
                }
                Text(p.inUse ? "In use right now" : subtitle(p))
                    .font(.caption2)
                    .foregroundStyle(p.inUse ? Color.orange : .secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            Text(StorageManager.format(p.bytes))
                .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: 70, alignment: .trailing)
            if parking.busy.contains(p.path) {
                ProgressView().controlSize(.small).frame(width: 66)
            } else {
                pill(confirming == p.path ? "Confirm" : "Park", armed: confirming == p.path, disabled: p.inUse) {
                    tap(p.path) { parking.park(p) }
                }
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(confirming == p.path ? 0.08 : 0.03)))
        .contextMenu { Button("Show in Finder") { parking.reveal(p.path) } }
        .help(p.path + "\nRemoves: " + p.removable.map { String($0.dropFirst(p.path.count + 1)) }.joined(separator: ", "))
    }

    private func parkedRow(_ e: ParkedProject) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "parkingsign.circle").frame(width: 20).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(e.name).font(.callout).lineLimit(1)
                Text("Parked \(relative(e.parkedAt)) · \(e.restore.isEmpty ? "rebuilds on next build" : e.restore.joined(separator: ", "))")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 6)
            Text(StorageManager.format(e.bytes))
                .font(.callout.monospacedDigit()).foregroundStyle(.tertiary)
                .frame(width: 70, alignment: .trailing)
            if parking.busy.contains(e.path) {
                ProgressView().controlSize(.small).frame(width: 66)
            } else {
                pill("Wake", armed: false, disabled: false) { parking.wake(e) }
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.03)))
        .contextMenu { Button("Show in Finder") { parking.reveal(e.path) } }
        .help(e.path + "\nRemoved: " + e.removed.joined(separator: ", "))
    }

    private func subtitle(_ p: IdleProject) -> String {
        var parts: [String] = []
        if let d = p.lastTouched { parts.append(relative(d)) }
        let kinds = Set(p.removable.map { ($0 as NSString).lastPathComponent }).sorted()
        parts.append(kinds.joined(separator: ", "))
        return parts.joined(separator: " · ")
    }

    private func relative(_ d: Date) -> String {
        RelativeDateTimeFormatter().localizedString(for: d, relativeTo: Date())
    }

    private func pill(_ title: String, armed: Bool, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(.medium))
                .frame(width: 58)
                .padding(.vertical, 4)
                .background(Capsule().fill(armed ? Color.red.opacity(0.8) : Color.white.opacity(0.12)))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.35 : 1)
    }

    /// Two-tap confirm, same as the Clean buttons: first tap arms for 4 s, second runs.
    private func tap(_ key: String, run: @escaping () -> Void) {
        if confirming == key {
            confirming = nil
            run()
        } else {
            withAnimation(.smooth(duration: 0.2)) { confirming = key }
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                if confirming == key { withAnimation { confirming = nil } }
            }
        }
    }
}
