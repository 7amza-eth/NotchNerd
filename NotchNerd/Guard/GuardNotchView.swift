//
//  GuardNotchView.swift
//  NotchNerd
//
//  Guard's notch surfaces: the Face ID HUD (looking / welcome back / not a real face) and the
//  Face ID-style enrollment ring. PresenceKit drives them through `GuardNotchModel`; NotchNerd's
//  own notch window shows them as the `.guardian` view, on the lock screen too.
//

import AVFoundation
import Combine
import Defaults
import PresenceKit
import SwiftUI

/// PresenceKit's presenter: Guard's HUD and face setup draw here instead of in PresenceKit's own panel.
@MainActor
final class GuardNotchModel: ObservableObject, GuardPresenter {
    static let shared = GuardNotchModel()

    enum Presentation: Equatable { case hud, enroll }

    @Published private(set) var presentation: Presentation?
    @Published private(set) var hud: HUDState = .scanning("")
    /// Bumped on every HUD change so the glyph's bounce/shake replays.
    @Published private(set) var hudTick = 0

    // Enrollment
    @Published private(set) var session: AVCaptureSession?
    @Published private(set) var prompt = "Look straight at the camera"
    /// Eight directions, 0 = up, clockwise; each 0...1.
    @Published private(set) var sectorFill = [Double](repeating: 0, count: 8)
    /// The straight-on samples taken before the head tilts, 0...1.
    @Published private(set) var centerProgress: Double = 0
    @Published private(set) var enrollDone = false

    private var hideWork: DispatchWorkItem?

    static let hudSize = CGSize(width: 300, height: 190)
    static let enrollSize = CGSize(width: 640, height: 300)
    var size: CGSize { presentation == .enroll ? Self.enrollSize : Self.hudSize }

    /// With a notch window per display, only the one at the camera shows Guard.
    static func hostsOnScreen(_ uuid: String?) -> Bool {
        guard Defaults[.showOnAllDisplays], let uuid else { return true }
        let camera = NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main
        return camera?.displayUUID == uuid
    }

    // MARK: HUD

    func showHUD(_ state: HUDState) {
        hideWork?.cancel()
        hud = state
        hudTick += 1
        if presentation != .enroll { presentation = .hud }
    }

    func hideHUD(after delay: Double) {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, presentation == .hud else { return }
            presentation = nil
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: enrollment

    func enrollmentBegan(session: AVCaptureSession) {
        hideWork?.cancel()
        self.session = session
        prompt = "Look straight at the camera"
        sectorFill = .init(repeating: 0, count: 8)
        centerProgress = 0
        enrollDone = false
        presentation = .enroll
    }

    func enrollmentUpdated(prompt: String, sectorFill: [Double], centerProgress: Double) {
        self.prompt = prompt
        if sectorFill.count == 8 { self.sectorFill = sectorFill }
        self.centerProgress = centerProgress
    }

    func enrollmentEnded(ok: Bool, message: String) {
        prompt = message
        enrollDone = ok
        if ok { sectorFill = .init(repeating: 1, count: 8); centerProgress = 1 }
        DispatchQueue.main.asyncAfter(deadline: .now() + (ok ? 1.6 : 2.4)) { [weak self] in
            guard let self, presentation == .enroll else { return }
            presentation = nil
            session = nil
        }
    }

    func cancelEnrollment() {
        PresenceGuard.shared.cancelEnrollment()
        presentation = nil
        session = nil
    }
}

struct GuardNotchView: View {
    @ObservedObject var model = GuardNotchModel.shared

    var body: some View {
        switch model.presentation {
        case .enroll: GuardEnrollView(model: model)
        default: GuardHUDView(model: model)
        }
    }
}

private struct GuardHUDView: View {
    @ObservedObject var model: GuardNotchModel
    @State private var shake: CGFloat = 0

    private var text: String {
        switch model.hud { case .scanning(let t), .success(let t), .failure(let t): return t }
    }
    private var tint: Color {
        switch model.hud { case .scanning: return .white; case .success: return .green; case .failure: return .red }
    }
    /// The live check asks for a random head turn ("Turn your head left", "Look up"); point the way.
    private var challengeArrow: String? {
        guard case .scanning(let t) = model.hud else { return nil }
        let words = Set(t.lowercased().split(separator: " ").map(String.init))
        for (word, arrow) in [("left", "arrow.left"), ("right", "arrow.right"), ("up", "arrow.up"), ("down", "arrow.down")] where words.contains(word) {
            return arrow
        }
        return nil
    }

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 14) {
                glyph
                    .font(.system(size: 58, weight: .light))
                    .foregroundStyle(tint)
                    .offset(x: shake)
                    .frame(width: 76, height: 76)
                if let arrow = challengeArrow {
                    Image(systemName: arrow)
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(.white)
                        .symbolEffect(.pulse, options: .repeating)
                        .transition(.opacity.combined(with: .scale))
                }
            }
            .animation(.smooth(duration: 0.25), value: challengeArrow)
            Text(text)
                .font(.system(size: challengeArrow == nil ? 13 : 16, weight: challengeArrow == nil ? .medium : .semibold))
                .foregroundStyle(.white.opacity(challengeArrow == nil ? 0.75 : 1))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(width: GuardNotchModel.hudSize.width - 40)
        .padding(.top, 4)
        .onChange(of: model.hudTick) { _, _ in
            if case .failure = model.hud { shakeGlyph() }
        }
    }

    @ViewBuilder
    private var glyph: some View {
        switch model.hud {
        case .scanning: Image(systemName: "faceid").symbolEffect(.pulse, options: .repeating)
        case .success: Image(systemName: "faceid").symbolEffect(.bounce, value: model.hudTick)
        case .failure: Image(systemName: "faceid")
        }
    }

    private func shakeGlyph() {
        let steps: [CGFloat] = [-10, 10, -8, 8, -4, 4, 0]
        for (i, x) in steps.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.06) {
                withAnimation(.linear(duration: 0.06)) { shake = x }
            }
        }
    }
}

private struct GuardEnrollView: View {
    @ObservedObject var model: GuardNotchModel
    private let diameter: CGFloat = 170
    private let tickCount = 64

    var body: some View {
        HStack(spacing: 28) {
            ZStack {
                if let session = model.session {
                    GuardCameraPreview(session: session)
                        .frame(width: diameter, height: diameter)
                        .clipShape(Circle())
                } else {
                    Circle().fill(Color.white.opacity(0.08)).frame(width: diameter, height: diameter)
                }
                ForEach(0..<tickCount, id: \.self) { i in
                    Capsule()
                        .fill(lit(i) ? Color.green : Color.white.opacity(0.25))
                        .frame(width: 3, height: 12)
                        .offset(y: -(diameter / 2 + 16))
                        .rotationEffect(.degrees(Double(i) / Double(tickCount) * 360))
                        .animation(.easeOut(duration: 0.2), value: model.sectorFill)
                }
            }
            .frame(width: diameter + 44, height: diameter + 44)

            VStack(alignment: .leading, spacing: 10) {
                Text("Set up Guard").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
                Text(model.prompt)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: 280, alignment: .leading)
                if model.centerProgress < 1 && !model.enrollDone {
                    ProgressView(value: model.centerProgress)
                        .tint(.green)
                        .frame(width: 180)
                }
                if !model.enrollDone {
                    Button("Cancel") { model.cancelEnrollment() }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
        }
        .frame(width: GuardNotchModel.enrollSize.width - 40, height: GuardNotchModel.enrollSize.height - 50)
    }

    /// Ticks fill in clockwise within each direction's sector as that direction gets samples.
    private func lit(_ i: Int) -> Bool {
        let sector = Int((Double(i) + Double(tickCount) / 16) / Double(tickCount) * 8) % 8
        let mine = (0..<tickCount).filter { Int((Double($0) + Double(tickCount) / 16) / Double(tickCount) * 8) % 8 == sector }
        guard let k = mine.firstIndex(of: i) else { return false }
        return Double(k + 1) / Double(mine.count) <= model.sectorFill[sector] + 0.01
    }
}

/// Mirrored live camera layer for the enrollment circle (same idea as the webcam mirror's preview).
private struct GuardCameraPreview: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        v.wantsLayer = true
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.setAffineTransform(CGAffineTransform(scaleX: -1, y: 1))
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        v.layer = CALayer()
        v.layer?.addSublayer(layer)
        return v
    }

    func updateNSView(_ v: NSView, context: Context) {
        guard let preview = v.layer?.sublayers?.first as? AVCaptureVideoPreviewLayer else { return }
        if preview.session !== session { preview.session = session }
        preview.frame = v.bounds
    }
}

