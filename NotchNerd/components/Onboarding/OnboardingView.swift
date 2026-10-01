//
//  OnboardingView.swift
//  NotchNerd
//
//  Created by Alexander on 2025-06-23.
//

import SwiftUI
import AVFoundation
import Defaults

enum OnboardingStep {
    case welcome
    case cameraPermission
    case calendarPermission
    case remindersPermission
    case accessibilityPermission
    case musicPermission
    case automationInfo
    case agentMonitor
    case finished
    /// Standalone, re-runnable feature tour. NOT part of the linear first-run chain — entered only
    /// from the finish screen's button, the menu-bar item, or Settings.
    case featureTour
}

private let calendarService = CalendarService()

struct OnboardingView: View {
    @State var step: OnboardingStep = .welcome
    let onFinish: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        ZStack {
            switch step {
            case .welcome:
                WelcomeView {
                    withAnimation(.easeInOut(duration: 0.6)) {
                        step = .cameraPermission
                    }
                }
                .transition(.opacity)

            case .cameraPermission:
                PermissionRequestView(
                    icon: Image(systemName: "camera.fill"),
                    title: "Enable Camera Access",
                    description: "NotchNerd includes a mirror feature that lets you quickly check your appearance using your camera, right from the notch. Camera access is required only to show this live preview. You can turn the mirror feature on or off at any time in the app.",
                    privacyNote: "Your camera is never used without your consent, and nothing is recorded or stored.",
                    onAllow: {
                        Task {
                            await requestCameraPermission()
                            withAnimation(.easeInOut(duration: 0.6)) {
                                step = .calendarPermission
                            }
                        }
                    },
                    onSkip: {
                        withAnimation(.easeInOut(duration: 0.6)) {
                            step = .calendarPermission
                        }
                    }
                )
                .transition(.opacity)

            case .calendarPermission:
                PermissionRequestView(
                    icon: Image(systemName: "calendar"),
                    title: "Enable Calendar Access",
                    description: "NotchNerd can show all your upcoming events in one place. Access to your calendar is needed to display your schedule.",
                    privacyNote: "Your calendar data is only used to show your events and is never shared.",
                    onAllow: {
                        Task {
                                await requestCalendarPermission()
                                withAnimation(.easeInOut(duration: 0.6)) {
                                    step = .remindersPermission
                                }
                        }
                    },
                    onSkip: {
                            withAnimation(.easeInOut(duration: 0.6)) {
                                step = .remindersPermission
                            }
                    }
                )
                .transition(.opacity)

                case .remindersPermission:
                    PermissionRequestView(
                        icon: Image(systemName: "checklist"),
                        title: "Enable Reminders Access",
                        description: "NotchNerd can show your scheduled reminders alongside your calendar events. Access to Reminders is needed to display your reminders.",
                        privacyNote: "Your reminders data is only used to show your reminders and is never shared.",
                        onAllow: {
                            Task {
                                await requestRemindersPermission()
                                withAnimation(.easeInOut(duration: 0.6)) {
                                    step = .accessibilityPermission
                                }
                            }
                        },
                        onSkip: {
                            withAnimation(.easeInOut(duration: 0.6)) {
                                step = .accessibilityPermission
                            }
                        }
                    )
                    .transition(.opacity)
                
            case .accessibilityPermission:
                PermissionRequestView(
                    icon: Image(systemName: "hand.raised.fill"),
                    title: "Enable Accessibility Access",
                    description: "Accessibility access is required to replace system notifications with the NotchNerd HUD. This allows the app to intercept media and brightness events to display custom HUD overlays.",
                    privacyNote: "Accessibility access is used only to improve media and brightness notifications. No data is collected or shared.",
                    onAllow: {
                        Task {
                            await requestAccessibilityPermission()
                            withAnimation(.easeInOut(duration: 0.6)) {
                                step = .musicPermission
                            }
                        }
                    },
                    onSkip: {
                        withAnimation(.easeInOut(duration: 0.6)) {
                            step = .musicPermission
                        }
                    }
                )
                .transition(.opacity)
                
            case .musicPermission:
                MusicControllerSelectionView(
                    onContinue: {
                        // Read firstLaunch BEFORE it flips (it now flips on entering .finished).
                        // Genuine first run continues into the new agent steps; the returning-user
                        // music re-prompt (firstLaunch already false) goes straight to finish.
                        let isFirstRun = NotchNerdViewCoordinator.shared.firstLaunch
                        withAnimation(.easeInOut(duration: 0.6)) {
                            step = isFirstRun ? .automationInfo : .finished
                        }
                    }
                )
                .transition(.opacity)

            case .automationInfo:
                AutomationInfoView(
                    onContinue: {
                        withAnimation(.easeInOut(duration: 0.6)) { step = .agentMonitor }
                    }
                )
                .transition(.opacity)

            case .agentMonitor:
                AgentMonitorOnboardingView(
                    onContinue: {
                        withAnimation(.easeInOut(duration: 0.6)) { step = .finished }
                    }
                )
                .transition(.opacity)

            case .finished:
                OnboardingFinishView(
                    onFinish: onFinish,
                    onOpenSettings: onOpenSettings,
                    onStartTour: {
                        withAnimation(.easeInOut(duration: 0.6)) { step = .featureTour }
                    }
                )
                .onAppear {
                    // Flip on entering .finished (not in the music step) so a quit/crash before this
                    // point re-surfaces onboarding. Covers every path that reaches finished; a no-op
                    // on the music re-prompt path where firstLaunch is already false.
                    NotchNerdViewCoordinator.shared.firstLaunch = false
                    // First-run users were offered the tour here, so don't auto-present it next launch.
                    Defaults[.hasSeenFeatureTour] = true
                }

            case .featureTour:
                FeatureTourView(onFinish: onFinish)
                    .transition(.opacity)
            }
        }
        .frame(width: 400, height: 600)
    }

    // MARK: - Permission Request Logic

    func requestCameraPermission() async {
        await AVCaptureDevice.requestAccess(for: .video)
    }

    func requestCalendarPermission() async {
        _ = try? await calendarService.requestAccess(to: .event)
    }

    func requestRemindersPermission() async {
        _ = try? await calendarService.requestAccess(to: .reminder)
    }
    
    func requestAccessibilityPermission() async {
        // Prompt the APP for Accessibility — the HUD event tap runs in-app, so the grant must
        // target the app, not the XPC helper (Phase 5.5 / c53ccfe).
        _ = await MediaKeyInterceptor.shared.ensureAccessibilityAuthorization(promptIfNeeded: true)
    }
}
