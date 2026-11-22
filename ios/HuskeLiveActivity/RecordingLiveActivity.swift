// Lock Screen banner + Dynamic Island for a recording in progress.
//
// State is the interface: a red dot + "REC" while recording, an amber pause
// glyph + "PAUSED" when paused. The elapsed time is a system timer
// (`Text(timerInterval:pauseTime:)`), so it ticks without app updates and
// freezes exactly when paused. Widgets cannot animate continuously, so the
// "pulse" is the coarse level meter the app refreshes at most every ~2 s.

import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

struct RecordingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RecordingActivityAttributes.self) { context in
            LockScreenBanner(context: context)
                .activityBackgroundTint(Brand.Ink.bg)
                .activitySystemActionForegroundColor(Brand.Ink.fg)
        } dynamicIsland: { context in
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 8) {
                        PhaseLabel(state: state)
                        MiniLevelMeter(level: state.level, active: state.phase == .recording, barHeight: 16)
                    }
                    .padding(.leading, 6)
                    .padding(.top, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    ElapsedText(state: state)
                        .font(.plexMono(26, .semibold, relativeTo: .title2))
                        .foregroundStyle(Brand.Ink.fg)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 120, alignment: .trailing)
                        .padding(.trailing, 6)
                        .padding(.top, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(state.title)
                        .font(.plexSans(14, .semibold, relativeTo: .subheadline))
                        .foregroundStyle(Brand.Ink.fg)
                        .lineLimit(1)
                        .padding(.top, 2)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if state.phase == .saved {
                        SavedLine()
                            .padding(.top, 6)
                    } else {
                        HStack(spacing: 10) {
                            PauseResumeButton(recordingID: context.attributes.recordingID, state: state, wide: true)
                            StopButton(recordingID: context.attributes.recordingID, wide: true)
                        }
                        .padding(.top, 8)
                        .padding(.horizontal, 4)
                    }
                }
            } compactLeading: {
                HStack(spacing: 5) {
                    PhaseGlyph(state: state, size: 9)
                    MiniLevelMeter(level: state.level, active: state.phase == .recording, barHeight: 11, barCount: 3)
                }
                .padding(.leading, 2)
            } compactTrailing: {
                ElapsedText(state: state)
                    .font(.plexMono(13, .medium, relativeTo: .caption))
                    .foregroundStyle(state.phase == .recording ? Brand.Ink.recordRed : Brand.Ink.amber)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 46, alignment: .trailing)
            } minimal: {
                PhaseGlyph(state: state, size: 10)
            }
            .keylineTint(state.phase == .recording ? Brand.Ink.recordRed : Brand.Ink.amber)
        }
    }
}

// MARK: - Lock Screen

private struct LockScreenBanner: View {
    let context: ActivityViewContext<RecordingActivityAttributes>

    var body: some View {
        let state = context.state
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    PhaseLabel(state: state)
                    Text("·")
                        .font(.plexSans(13))
                        .foregroundStyle(Brand.Ink.fgFaint)
                    Text("huske")
                        .font(.plexSerifItalic(14))
                        .foregroundStyle(Brand.Ink.fgMuted)
                }
                Text(state.title)
                    .font(.plexSans(16, .semibold, relativeTo: .headline))
                    .foregroundStyle(Brand.Ink.fg)
                    .lineLimit(1)
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    ElapsedText(state: state)
                        .font(.plexMono(30, .semibold, relativeTo: .title))
                        .foregroundStyle(Brand.Ink.fg)
                        .fixedSize()
                    if state.phase == .saved {
                        SavedLine()
                    } else if let reason = state.pauseReason, state.phase == .paused {
                        Text(reason)
                            .font(.plexSans(13, .medium, relativeTo: .footnote))
                            .foregroundStyle(Brand.Ink.warn)
                            .lineLimit(1)
                    } else {
                        MiniLevelMeter(level: state.level, active: state.phase == .recording, barHeight: 16)
                    }
                }
            }
            Spacer(minLength: 0)
            if state.phase != .saved {
                HStack(spacing: 10) {
                    PauseResumeButton(recordingID: context.attributes.recordingID, state: state, wide: false)
                    StopButton(recordingID: context.attributes.recordingID, wide: false)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
    }
}

// MARK: - pieces

private struct ElapsedText: View {
    let state: RecordingActivityAttributes.ContentState

    var body: some View {
        if state.phase == .saved {
            Text(Duration.seconds(max(0, state.elapsed)).formatted(.time(pattern: .minuteSecond)))
                .monospacedDigit()
        } else {
            Text(timerInterval: state.timerRange, pauseTime: state.pausedAt, countsDown: false, showsHours: true)
                .monospacedDigit()
        }
    }
}

private struct PhaseGlyph: View {
    let state: RecordingActivityAttributes.ContentState
    let size: CGFloat

    var body: some View {
        switch state.phase {
        case .recording:
            Circle()
                .fill(Brand.Ink.recordRed)
                .frame(width: size, height: size)
                .accessibilityLabel("Recording")
        case .paused:
            Image(systemName: "pause.fill")
                .font(.system(size: size + 2, weight: .bold))
                .foregroundStyle(Brand.Ink.amber)
                .accessibilityLabel("Paused")
        case .saved:
            Image(systemName: "checkmark")
                .font(.system(size: size + 2, weight: .bold))
                .foregroundStyle(Brand.Ink.fg)
                .accessibilityLabel("Saved")
        }
    }
}

private struct PhaseLabel: View {
    let state: RecordingActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 6) {
            PhaseGlyph(state: state, size: 8)
            Text(label)
                .font(.plexSans(13, .medium))
                .foregroundStyle(color)
        }
    }

    private var label: String {
        switch state.phase {
        case .recording: return "Recording"
        case .paused: return "Paused"
        case .saved: return "Saved"
        }
    }

    private var color: Color {
        switch state.phase {
        case .recording: return Brand.Ink.recordRed
        case .paused: return Brand.Ink.amber
        case .saved: return Brand.Ink.fgMuted
        }
    }
}

/// A tiny 0…4 input-level meter: data, not decoration (DESIGN.md).
struct MiniLevelMeter: View {
    let level: Int
    let active: Bool
    var barHeight: CGFloat = 14
    var barCount: Int = 4

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<barCount, id: \.self) { index in
                let threshold = barCount == 4 ? index + 1 : index * 2 + 1
                RoundedRectangle(cornerRadius: 1)
                    .fill(active && level >= threshold ? Brand.Ink.fg : Brand.Ink.fgFaint)
                    .frame(width: 3, height: barHeight * CGFloat(index + 1) / CGFloat(barCount))
            }
        }
        .frame(height: barHeight, alignment: .bottom)
        .accessibilityElement()
        .accessibilityLabel("Input level \(level) of 4")
    }
}

private struct SavedLine: View {
    var body: some View {
        Text("Saved · syncing to your Mac")
            .font(.plexSans(13, .medium, relativeTo: .footnote))
            .foregroundStyle(Brand.Ink.fgMuted)
            .lineLimit(1)
    }
}

private struct PauseResumeButton: View {
    let recordingID: String
    let state: RecordingActivityAttributes.ContentState
    let wide: Bool

    var body: some View {
        let paused = state.phase == .paused
        Button(intent: PauseResumeRecordingIntent(recordingID: recordingID)) {
            if wide {
                Label(paused ? "Resume" : "Pause", systemImage: paused ? "play.fill" : "pause.fill")
                    .font(.plexSans(14, .semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 40)
                    .foregroundStyle(paused ? Brand.fgOnAmber : Brand.Ink.fg)
                    .background(Capsule().fill(paused ? Brand.Ink.amber : Brand.Ink.bgElevated))
                    .overlay(Capsule().strokeBorder(paused ? .clear : Brand.Ink.border, lineWidth: 1))
            } else {
                Image(systemName: paused ? "play.fill" : "pause.fill")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(paused ? Brand.fgOnAmber : Brand.Ink.fg)
                    .frame(width: 46, height: 46)
                    .background(Circle().fill(paused ? Brand.Ink.amber : Brand.Ink.bgElevated))
                    .overlay(Circle().strokeBorder(paused ? .clear : Brand.Ink.border, lineWidth: 1))
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(paused ? "Resume recording" : "Pause recording")
    }
}

private struct StopButton: View {
    let recordingID: String
    let wide: Bool

    var body: some View {
        Button(intent: StopRecordingIntent(recordingID: recordingID)) {
            if wide {
                Label("Stop", systemImage: "stop.fill")
                    .font(.plexSans(14, .semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 40)
                    .foregroundStyle(Brand.fgOnRed)
                    .background(Capsule().fill(Brand.Ink.recordRed))
            } else {
                Image(systemName: "stop.fill")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Brand.fgOnRed)
                    .frame(width: 46, height: 46)
                    .background(Circle().fill(Brand.Ink.recordRed))
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Stop and save recording")
    }
}

// MARK: - previews

#if DEBUG
private extension RecordingActivityAttributes {
    static let preview = RecordingActivityAttributes(recordingID: "preview", startedAt: .now)
}

private extension RecordingActivityAttributes.ContentState {
    static let recording = Self(
        phase: .recording, title: "Recording 14:03",
        timerStart: .now.addingTimeInterval(-754), pausedAt: nil, pauseReason: nil, level: 3)
    static let paused = Self(
        phase: .paused, title: "Design review",
        timerStart: .now.addingTimeInterval(-1834), pausedAt: .now, pauseReason: "Phone call", level: 0)
}

#Preview("Lock Screen", as: .content, using: RecordingActivityAttributes.preview) {
    RecordingLiveActivity()
} contentStates: {
    RecordingActivityAttributes.ContentState.recording
    RecordingActivityAttributes.ContentState.paused
}
#endif
