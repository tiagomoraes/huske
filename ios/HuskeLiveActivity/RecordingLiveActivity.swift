// Lock Screen banner + Dynamic Island for a recording in progress.
//
// The same instrument as the app's recorder (DESIGN.md, "Quiet instrument"):
// state is a glyph and plain words, the elapsed time is the largest thing in
// light tabular numerals, and the controls are hardware — a hairline ring with
// a red square stops, a ring with a pause glyph pauses, an amber disc resumes.
//
// The elapsed time is a system timer (`Text(timerInterval:pauseTime:)`), so it
// ticks without app updates and freezes exactly when paused. In a widget that
// view is *flexible*: it takes all the width it is offered and must never get
// `.fixedSize()` (its ideal width is unbounded — that pushed the rest of the
// banner off-screen). Give it a frame and an alignment instead.

import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

struct RecordingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RecordingActivityAttributes.self) { context in
            LockScreenView(state: context.state, recordingID: context.attributes.recordingID)
                .activityBackgroundTint(Brand.Ink.bg)
                .activitySystemActionForegroundColor(Brand.Ink.fg)
        } dynamicIsland: { context in
            let state = context.state
            let id = context.attributes.recordingID
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    StateLine(state: state, size: 14)
                        .padding(.leading, 8)
                        .padding(.top, 6)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    ElapsedTime(state: state, size: 24, alignment: .trailing)
                        .padding(.trailing, 8)
                        .padding(.top, 2)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(state.title)
                                .font(.plexSans(16, .medium, relativeTo: .headline))
                                .foregroundStyle(Brand.Ink.fg)
                                .lineLimit(1)
                            DetailLine(state: state)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Controls(state: state, recordingID: id, diameter: 44)
                    }
                    .padding(.horizontal, 8)
                    .padding(.top, 10)
                    .padding(.bottom, 4)
                }
            } compactLeading: {
                PhaseGlyph(phase: state.phase, size: 10)
                    .padding(.leading, 4)
            } compactTrailing: {
                ElapsedTime(state: state, size: 14, weight: .medium, alignment: .trailing,
                            tint: state.phase == .recording ? Brand.Ink.recordRed : Brand.Ink.amber)
                    .frame(width: state.compactTimerWidth)
            } minimal: {
                PhaseGlyph(phase: state.phase, size: 10)
            }
            .keylineTint(state.phase == .recording ? Brand.Ink.recordRed : Brand.Ink.amber)
        }
    }
}

// MARK: - Lock Screen

private struct LockScreenView: View {
    let state: RecordingActivityAttributes.ContentState
    let recordingID: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                StateLine(state: state, size: 14)
                Spacer(minLength: 8)
                Text("huske")
                    .font(.plexSerifItalic(16, relativeTo: .subheadline))
                    .foregroundStyle(Brand.Ink.fgMuted)
                    .accessibilityHidden(true)
            }
            Text(state.title)
                .font(.plexSans(16, .medium, relativeTo: .headline))
                .foregroundStyle(Brand.Ink.fg)
                .lineLimit(1)
                .padding(.top, 8)
            HStack(alignment: .center, spacing: 12) {
                ElapsedTime(state: state, size: 40, alignment: .leading)
                if state.phase == .saved {
                    Text("Saved on this iPhone")
                        .font(.plexSans(13, relativeTo: .footnote))
                        .foregroundStyle(Brand.Ink.fgMuted)
                        .lineLimit(1)
                        .fixedSize()
                } else {
                    Controls(state: state, recordingID: recordingID, diameter: 46)
                }
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 14)
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
    }
}

// MARK: - pieces

/// The running time in light tabular numerals. Flexible by nature (see the
/// file header): it fills the frame it is given and aligns inside it.
private struct ElapsedTime: View {
    let state: RecordingActivityAttributes.ContentState
    let size: CGFloat
    var weight: Font.Weight = .light
    let alignment: Alignment
    var tint: Color?

    var body: some View {
        timer
            .font(.plexSans(size, weight, relativeTo: .title))
            .monospacedDigit()
            .foregroundStyle(tint ?? (state.phase == .recording ? Brand.Ink.fg : Brand.Ink.fgMuted))
            .multilineTextAlignment(alignment == .trailing ? .trailing : .leading)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(maxWidth: .infinity, alignment: alignment)
            .accessibilityLabel(state.phase == .recording ? "Elapsed" : "Recorded")
    }

    @ViewBuilder private var timer: some View {
        if state.phase == .saved {
            Text(Duration.seconds(max(0, state.elapsed)).formatted(.time(pattern: .minuteSecond)))
        } else {
            Text(timerInterval: state.timerRange, pauseTime: state.pausedAt, countsDown: false, showsHours: true)
        }
    }
}

/// Glyph + plain words: "● Recording", "Paused by a call", "✓ Saved".
private struct StateLine: View {
    let state: RecordingActivityAttributes.ContentState
    let size: CGFloat

    var body: some View {
        HStack(alignment: .center, spacing: 7) {
            PhaseGlyph(phase: state.phase, size: size * 0.6)
            Text(words)
                .font(.plexSans(size, .medium, relativeTo: .subheadline))
                .foregroundStyle(color)
                .lineLimit(1)
                .fixedSize()
        }
        .accessibilityElement(children: .combine)
    }

    private var words: String {
        switch state.phase {
        case .recording: return "Recording"
        case .paused: return state.pauseReason == nil ? "Paused" : "Paused by a call"
        case .saved: return "Saved"
        }
    }

    private var color: Color {
        switch state.phase {
        case .recording: return Brand.Ink.fg
        case .paused: return state.pauseReason == nil ? Brand.Ink.fg : Brand.Ink.warn
        case .saved: return Brand.Ink.fgMuted
        }
    }
}

/// Under the title in the expanded island: why it isn't recording, if it isn't.
/// There is no level meter anywhere in the Live Activity: the system redraws
/// it only now and then (especially on the Lock Screen), and a meter that
/// stands still reads as "not recording". The red dot and the running timer —
/// which the system ticks by itself — are the signs of life.
private struct DetailLine: View {
    let state: RecordingActivityAttributes.ContentState

    var body: some View {
        switch state.phase {
        case .recording:
            EmptyView()
        case .paused:
            Text("Tap resume to continue")
                .font(.plexSans(13, relativeTo: .footnote))
                .foregroundStyle(Brand.Ink.fgMuted)
                .lineLimit(1)
        case .saved:
            Text("Saved on this iPhone")
                .font(.plexSans(13, relativeTo: .footnote))
                .foregroundStyle(Brand.Ink.fgMuted)
                .lineLimit(1)
        }
    }
}

private struct PhaseGlyph: View {
    let phase: RecordingActivityAttributes.ContentState.Phase
    let size: CGFloat

    var body: some View {
        Group {
            switch phase {
            case .recording:
                Circle()
                    .fill(Brand.Ink.recordRed)
                    .frame(width: size, height: size)
            case .paused:
                Image(systemName: "pause.fill")
                    .font(.system(size: size, weight: .bold))
                    .foregroundStyle(Brand.Ink.amber)
            case .saved:
                Image(systemName: "checkmark")
                    .font(.system(size: size, weight: .bold))
                    .foregroundStyle(Brand.Ink.fgMuted)
            }
        }
        .accessibilityHidden(true)
    }
}

/// Pause/Resume + Stop, as round hardware controls.
private struct Controls: View {
    let state: RecordingActivityAttributes.ContentState
    let recordingID: String
    let diameter: CGFloat

    var body: some View {
        HStack(spacing: 12) {
            Button(intent: PauseResumeRecordingIntent(recordingID: recordingID)) {
                PauseResumeFace(paused: state.phase == .paused, diameter: diameter)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(state.phase == .paused ? "Resume recording" : "Pause recording")

            Button(intent: StopRecordingIntent(recordingID: recordingID)) {
                StopFace(diameter: diameter)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Stop and save recording")
        }
    }
}

private struct PauseResumeFace: View {
    let paused: Bool
    let diameter: CGFloat

    var body: some View {
        ZStack {
            if paused {
                Circle().fill(Brand.Ink.amber)
                Image(systemName: "play.fill")
                    .font(.system(size: diameter * 0.36, weight: .semibold))
                    .foregroundStyle(Brand.fgOnAmber)
                    .offset(x: diameter * 0.03)
            } else {
                Circle().strokeBorder(Brand.Ink.fg.opacity(0.35), lineWidth: 1.5)
                Image(systemName: "pause.fill")
                    .font(.system(size: diameter * 0.34, weight: .semibold))
                    .foregroundStyle(Brand.Ink.fg)
            }
        }
        .frame(width: diameter, height: diameter)
        .contentShape(Circle())
    }
}

/// The REC control while recording: a hairline ring around a red square.
private struct StopFace: View {
    let diameter: CGFloat

    var body: some View {
        ZStack {
            Circle().strokeBorder(Brand.Ink.fg.opacity(0.85), lineWidth: 1.5)
            RoundedRectangle(cornerRadius: diameter * 0.09, style: .continuous)
                .fill(Brand.Ink.recordRed)
                .frame(width: diameter * 0.38, height: diameter * 0.38)
        }
        .frame(width: diameter, height: diameter)
        .contentShape(Circle())
    }
}

// MARK: - previews

#if DEBUG
private extension RecordingActivityAttributes {
    static let preview = RecordingActivityAttributes(recordingID: "preview", startedAt: .now)
}

private extension RecordingActivityAttributes.ContentState {
    static let recording = Self(
        phase: .recording, title: "Supplier call — follow-up",
        timerStart: .now.addingTimeInterval(-754), pausedAt: nil, pauseReason: nil)
    static let paused = Self(
        phase: .paused, title: "Design review",
        timerStart: .now.addingTimeInterval(-1834), pausedAt: .now, pauseReason: "Phone call")
    static let saved = Self(
        phase: .saved, title: "Design review",
        timerStart: .now.addingTimeInterval(-1834), pausedAt: .now, pauseReason: nil)
}

#Preview("Lock Screen", as: .content, using: RecordingActivityAttributes.preview) {
    RecordingLiveActivity()
} contentStates: {
    RecordingActivityAttributes.ContentState.recording
    RecordingActivityAttributes.ContentState.paused
    RecordingActivityAttributes.ContentState.saved
}

#Preview("Island expanded", as: .dynamicIsland(.expanded), using: RecordingActivityAttributes.preview) {
    RecordingLiveActivity()
} contentStates: {
    RecordingActivityAttributes.ContentState.recording
    RecordingActivityAttributes.ContentState.paused
}

#Preview("Island compact", as: .dynamicIsland(.compact), using: RecordingActivityAttributes.preview) {
    RecordingLiveActivity()
} contentStates: {
    RecordingActivityAttributes.ContentState.recording
}
#endif
