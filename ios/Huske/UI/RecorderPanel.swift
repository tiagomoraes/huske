// The bottom recorder, built like hardware: one REC control when idle; while
// recording it grows into the live panel — title, the elapsed time as the
// largest thing on screen, a tape-like level strip, Pause and Rename as
// plain controls either side of Stop.

import SwiftUI

struct RecorderPanel: View {
    let recorder: RecorderController
    let sync: SyncManager
    @State private var renaming = false
    @State private var draftTitle = ""

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Brand.divider).frame(height: 1)
            Group {
                if recorder.phase.isActive {
                    activeBody
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                } else {
                    idleBody
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, 20)
        }
        .frame(maxWidth: .infinity)
        .background(Brand.bg.ignoresSafeArea(edges: .bottom))
        .animation(Brand.easeSlow, value: recorder.phase.isActive)
        .sensoryFeedback(trigger: recorder.phase) { old, new in
            switch (old, new) {
            case (.idle, .recording): return .start
            case (_, .idle): return .stop
            case (.recording, .paused), (.paused, .recording): return .impact(weight: .light)
            default: return nil
            }
        }
        .alert("Rename recording", isPresented: $renaming) {
            TextField("Title", text: $draftTitle)
            Button("Cancel", role: .cancel) {}
            Button("Save") { recorder.renameCurrent(to: draftTitle) }
        }
    }

    // MARK: idle

    private var idleBody: some View {
        VStack(spacing: 10) {
            RecordButton(isRecording: false) {
                Task { await recorder.start() }
            }
            .disabled(recorder.isStarting)
            .opacity(recorder.isStarting ? 0.6 : 1)
            .padding(.top, 16)
            Text(idleCaption)
                .font(.plexSans(13, relativeTo: .caption))
                .foregroundStyle(Brand.fgMuted)
                .lineLimit(1)
                .padding(.bottom, 6)
        }
    }

    private var idleCaption: String {
        if recorder.isStarting { return "Starting…" }
        return sync.isPaired ? "Syncs to \(sync.macName)" : "Recordings stay on this iPhone"
    }

    // MARK: active

    private var activeBody: some View {
        VStack(spacing: 14) {
            Button {
                draftTitle = recorder.title
                renaming = true
            } label: {
                HStack(spacing: 6) {
                    Text(recorder.title)
                        .font(.plexSans(17, .medium, relativeTo: .headline))
                        .foregroundStyle(Brand.fg)
                        .lineLimit(1)
                    Image(systemName: "pencil")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Brand.fgMuted)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Title: \(recorder.title). Rename")
            .padding(.top, 18)

            ElapsedReadout(elapsed: recorder.elapsed, paused: recorder.phase != .recording)

            LevelHistoryView(levels: recorder.levels, active: recorder.phase == .recording)
                .frame(height: 56)
                .accessibilityElement()
                .accessibilityLabel("Input level")
                .accessibilityValue(levelDescription)

            statusLine

            controls
                .padding(.bottom, 10)
        }
    }

    private var levelDescription: String {
        recorder.phase == .recording ? "\(Int(recorder.power.rounded())) decibels" : "Paused"
    }

    private var statusLine: some View {
        HStack(spacing: 7) {
            switch recorder.phase {
            case .recording:
                StatusDot(color: Brand.recordRed, size: 7, pulsing: true)
                Text("Recording")
                    .foregroundStyle(Brand.fg)
            case .paused(.interruption):
                Text("Paused by a call")
                    .foregroundStyle(Brand.warn)
            case .paused:
                Text("Paused")
                    .foregroundStyle(Brand.fg)
            case .idle:
                EmptyView()
            }
            Text("·").foregroundStyle(Brand.fgFaint)
            Text(recorder.notice ?? recorder.inputName)
                .foregroundStyle(Brand.fgMuted)
                .lineLimit(1)
            if recorder.phase == .recording {
                Text("·").foregroundStyle(Brand.fgFaint)
                Text(dbText)
                    .foregroundStyle(Brand.fgMuted)
                    .monospacedDigit()
            }
        }
        .font(.plexSans(13, relativeTo: .caption))
        .animation(Brand.ease, value: recorder.notice)
    }

    private var dbText: String {
        recorder.power <= -159 ? "−∞ dB" : "\(Int(recorder.power.rounded())) dB"
            .replacingOccurrences(of: "-", with: "−")
    }

    private var controls: some View {
        HStack {
            pauseResumeButton
            Spacer()
            RecordButton(isRecording: true) { recorder.stop() }
            Spacer()
            Button {
                draftTitle = recorder.title
                renaming = true
            } label: {
                Text("Rename")
            }
            .buttonStyle(QuietControlStyle())
            .accessibilityLabel("Rename recording")
        }
    }

    @ViewBuilder
    private var pauseResumeButton: some View {
        let paused = recorder.phase != .recording
        Button {
            recorder.togglePause()
        } label: {
            Text(paused ? "Resume" : "Pause")
        }
        .buttonStyle(QuietControlStyle(tint: paused ? Brand.amber : Brand.fg))
        .accessibilityLabel(paused ? "Resume recording" : "Pause recording")
    }
}

/// A word, not a bubble: the secondary transport controls either side of the
/// REC control. 44 pt tall, fixed width so the REC control stays centred.
private struct QuietControlStyle: ButtonStyle {
    var tint: Color = Brand.fg

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.plexSans(16, .medium, relativeTo: .body))
            .foregroundStyle(tint)
            .frame(width: 84, height: 44)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.5 : 1)
            .animation(Brand.easeFast, value: configuration.isPressed)
    }
}

/// The elapsed time — the largest thing on screen, in light tabular numerals,
/// tenths in the faint ink.
struct ElapsedReadout: View {
    let elapsed: TimeInterval
    let paused: Bool

    var body: some View {
        let tenths = Int((elapsed * 10).rounded(.down)) % 10
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(Format.duration(elapsed))
                .font(.plexSans(64, .light, relativeTo: .largeTitle))
                .foregroundStyle(paused ? Brand.fgMuted : Brand.fg)
            Text(".\(tenths)")
                .font(.plexSans(30, .light, relativeTo: .title))
                .foregroundStyle(Brand.fgFaint)
        }
        .monospacedDigit()
        .kerning(-1)
        .contentTransition(.identity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(paused ? "Paused at" : "Elapsed")
        .accessibilityValue(Format.spokenDuration(elapsed))
    }
}

/// The REC control, like a recorder's: a hairline ring around a red disc. While
/// recording the disc becomes a rounded square (Stop).
struct RecordButton: View {
    let isRecording: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .strokeBorder(Brand.fg.opacity(0.85), lineWidth: 1.5)
                    .frame(width: 76, height: 76)
                RoundedRectangle(cornerRadius: isRecording ? 7 : 30, style: .continuous)
                    .fill(Brand.recordRed)
                    .frame(width: isRecording ? 28 : 60, height: isRecording ? 28 : 60)
            }
            .frame(width: 76, height: 76)
            .contentShape(Circle())
            .animation(Brand.ease, value: isRecording)
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityLabel(isRecording ? "Stop and save recording" : "Start recording")
        .accessibilityAddTraits(.isButton)
    }
}

private struct PressScaleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.93 : 1)
            .animation(Brand.easeFast, value: configuration.isPressed)
    }
}

/// Level history: one bar per sample, newest on the right. Data, not
/// decoration — heights are the measured input level; bars near full scale
/// turn amber as a quiet clipping hint.
struct LevelHistoryView: View {
    let levels: [Float]
    let active: Bool

    var body: some View {
        Canvas { context, size in
            let count = levels.count
            guard count > 0 else { return }
            let gap: CGFloat = 3
            let barWidth = max(2, (size.width - gap * CGFloat(count - 1)) / CGFloat(count))
            let mid = size.height / 2
            for (index, level) in levels.enumerated() {
                let height = max(3, CGFloat(level) * size.height)
                let x = CGFloat(index) * (barWidth + gap)
                let rect = CGRect(x: x, y: mid - height / 2, width: barWidth, height: height)
                let color: Color
                if !active {
                    color = Brand.fgFaint
                } else if level > 0.85 {
                    color = Brand.amber
                } else {
                    // Older samples fade slightly so "now" reads on the right.
                    let age = Double(count - index) / Double(count)
                    color = Brand.fg.opacity(0.9 - age * 0.45)
                }
                context.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2), with: .color(color))
            }
        }
    }
}
