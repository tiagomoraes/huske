// iPhone pane: pair a phone with a QR code, see paired phones, follow the
// recordings they sent from upload to transcript. The protocol lives in
// HuskeSync; the hand-off to the engine in PhoneSyncCoordinator.

import CoreImage
import CoreImage.CIFilterBuiltins
import HuskeKit
import HuskeSync
import SwiftUI

struct PhoneView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmingRemoval: PairedDevice?

    var body: some View {
        @Bindable var phone = model.phoneSync
        PaneScroll {
            VStack(alignment: .leading, spacing: 14) {
                PaneHeader(
                    "iPhone",
                    subtitle: "Record on your iPhone. Huske transcribes it here, on this Mac."
                ) {
                    Button {
                        phone.beginPairing()
                    } label: {
                        Label("Pair iPhone", systemImage: "qrcode")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(!phone.enabled || !phone.isListening)
                    .help(phone.isListening ? "Show a pairing code" : "Turn on receiving first")
                }
                .padding(.top, 30)

                receivingCard(phone)

                if !model.isDemo, model.engineReady, !phone.engineCanTakeRecordings {
                    engineNotice
                }

                devicesCard(phone)
                recordingsCard(phone)
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 24)
            .frame(maxWidth: 780)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.bg)
        .confirmationDialog(
            "Remove \(confirmingRemoval?.name ?? "this iPhone")?",
            isPresented: Binding(
                get: { confirmingRemoval != nil },
                set: { if !$0 { confirmingRemoval = nil } }),
            presenting: confirmingRemoval
        ) { device in
            Button("Remove", role: .destructive) {
                phone.removeDevice(device.deviceID)
            }
        } message: { _ in
            Text("It will stop sending recordings until you pair it again. Recordings already on this Mac stay.")
        }
    }

    // MARK: receiving

    private func receivingCard(_ phone: PhoneSyncCoordinator) -> some View {
        @Bindable var phone = phone
        return Card {
            VStack(alignment: .leading, spacing: 13) {
                Toggle(isOn: $phone.enabled) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Receive recordings from iPhone")
                            .font(.brandSans(12.5))
                            .foregroundStyle(Theme.fg)
                        Text("Huske listens on your local network, and over peer-to-peer Wi-Fi when you're away from it.")
                            .font(.brandSans(11))
                            .foregroundStyle(Theme.fgMuted)
                    }
                }
                .toggleStyle(.switch)
                .controlSize(.small)

                HStack(spacing: 8) {
                    Circle()
                        .fill(listenColor(phone))
                        .frame(width: 7, height: 7)
                    Text(listenText(phone))
                        .font(.brandSans(12))
                        .foregroundStyle(phone.listenerError == nil ? Theme.fgMuted : Theme.err)
                        .textSelection(.enabled)
                }

                Rectangle().fill(Theme.divider).frame(height: 1)

                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "lock.shield")
                        .foregroundStyle(Theme.ok)
                    Text(
                        "Recordings travel straight from your iPhone to this Mac, encrypted with a key only "
                            + "your paired iPhone holds. No cloud, no account."
                    )
                    .font(.brandSans(12))
                    .foregroundStyle(Theme.fgMuted)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func listenColor(_ phone: PhoneSyncCoordinator) -> Color {
        if phone.listenerError != nil { return Theme.err }
        return phone.enabled && phone.isListening ? Theme.ok : Theme.fgFaint
    }

    private func listenText(_ phone: PhoneSyncCoordinator) -> String {
        if let error = phone.listenerError { return error }
        if !phone.enabled { return "off" }
        return phone.isListening ? "Ready — your iPhone sees this Mac as “\(phone.macName)”" : "Starting…"
    }

    private var engineNotice: some View {
        Card {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.warn)
                VStack(alignment: .leading, spacing: 3) {
                    Text("This engine can't transcribe phone recordings yet")
                        .font(.brandSans(12.5, .semibold))
                        .foregroundStyle(Theme.fg)
                    // `.init` → LocalizedStringKey, so the code span renders as code.
                    Text(
                        .init(
                            "\(model.binaryVersion.map { "huske \($0)" } ?? "The engine in use") has no "
                                + "`inbox` command. Recordings from your iPhone are kept on this Mac and "
                                + "transcribed as soon as you upgrade the engine.")
                    )
                    .font(.brandSans(12))
                    .foregroundStyle(Theme.fgMuted)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: devices

    private func devicesCard(_ phone: PhoneSyncCoordinator) -> some View {
        let devices = phone.pairedDevices
        return Card(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    SectionLabel("Paired iPhones")
                    Spacer()
                    if !devices.isEmpty {
                        Text("\(devices.count)")
                            .font(.brandMono(11, .medium))
                            .foregroundStyle(Theme.fgFaint)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 8)
                if devices.isEmpty {
                    HStack(spacing: 12) {
                        Image(systemName: "iphone.slash")
                            .font(.system(size: 18))
                            .foregroundStyle(Theme.fgFaint)
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("No iPhone paired yet")
                                .font(.brandSans(13, .semibold))
                                .foregroundStyle(Theme.fg)
                            Text("Choose Pair iPhone and scan the code with your iPhone's Camera.")
                                .font(.brandSans(12))
                                .foregroundStyle(Theme.fgMuted)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                } else {
                    ForEach(Array(devices.enumerated()), id: \.element.id) { index, device in
                        if index > 0 {
                            Rectangle().fill(Theme.divider).frame(height: 1).padding(.leading, 50)
                        }
                        PairedDeviceRow(device: device) { confirmingRemoval = device }
                    }
                    .padding(.bottom, 6)
                }
            }
        }
    }

    // MARK: recordings

    private func recordingsCard(_ phone: PhoneSyncCoordinator) -> some View {
        Card(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    SectionLabel("Recent recordings")
                    Spacer()
                    if phone.inboxProcessRunning {
                        Text("transcribing…")
                            .font(.brandMono(11, .medium))
                            .foregroundStyle(Theme.info)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 8)
                if phone.recordings.isEmpty {
                    HStack(spacing: 12) {
                        Image(systemName: "waveform.badge.mic")
                            .font(.system(size: 18))
                            .foregroundStyle(Theme.fgFaint)
                            .frame(width: 22)
                        Text("Recordings you make on your iPhone show up here as they arrive, then as they're transcribed.")
                            .font(.brandSans(12))
                            .foregroundStyle(Theme.fgMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                } else {
                    ForEach(Array(phone.recordings.enumerated()), id: \.element.id) { index, recording in
                        if index > 0 {
                            Rectangle().fill(Theme.divider).frame(height: 1).padding(.leading, 50)
                        }
                        PhoneRecordingRow(recording: recording) {
                            phone.revealTranscript(recording)
                        }
                    }
                    .padding(.bottom, 6)
                }
            }
        }
    }
}

// MARK: - rows

struct PairedDeviceRow: View {
    let device: PairedDevice
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "iphone")
                .font(.system(size: 16))
                .foregroundStyle(Theme.fgMuted)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name ?? "iPhone")
                    .font(.brandSans(13, .semibold))
                    .foregroundStyle(Theme.fg)
                Text(device.model ?? "Paired")
                    .font(.brandSans(11.5))
                    .foregroundStyle(Theme.fgFaint)
            }
            Spacer(minLength: 12)
            Text(lastSeen)
                .font(.brandSans(11.5))
                .foregroundStyle(Theme.fgFaint)
            Button("Remove", action: onRemove)
                .buttonStyle(LinkButtonStyle(fontSize: 12, tint: Theme.fgMuted, hoverTint: Theme.err))
                .help("Forget this iPhone")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
    }

    private var lastSeen: String {
        guard let seen = device.lastSeenAt else { return "never connected" }
        if Date().timeIntervalSince(seen) < 60 { return "seen just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "seen " + formatter.localizedString(for: seen, relativeTo: Date())
    }
}

struct PhoneRecordingRow: View {
    let recording: PhoneSyncCoordinator.Recording
    let onReveal: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            StateRing(kind: ring, size: 11)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(recording.title.isEmpty ? "Untitled recording" : recording.title)
                        .font(.brandSans(13.5, .medium))
                        .foregroundStyle(Theme.fg)
                        .lineLimit(1)
                    Spacer(minLength: 12)
                    if recording.durationSeconds > 0 {
                        Text(Self.duration(recording.durationSeconds))
                            .font(.brandMono(11.5))
                            .foregroundStyle(Theme.fgMuted)
                    }
                }
                HStack(spacing: 0) {
                    Text(meta)
                        .foregroundStyle(Theme.fgFaint)
                    if let status {
                        Text("  ·  ").foregroundStyle(Theme.fgFaint)
                        Text(status)
                            .foregroundStyle(recording.state == .failed ? Theme.err : Theme.fgMuted)
                    }
                    Spacer(minLength: 12)
                    if recording.state == .transcribed, !recording.transcripts.isEmpty {
                        Button("Open transcript", action: onReveal)
                            .buttonStyle(LinkButtonStyle(fontSize: 12))
                    }
                }
                .font(.brandSans(12))
                .monospacedDigit()
                .lineLimit(1)
                if let detail = visibleDetail {
                    Text(detail)
                        .font(.brandSans(12))
                        .foregroundStyle(recording.state == .failed ? Theme.err : Theme.fgMuted)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .accessibilityElement(children: .combine)
    }

    private var meta: String {
        [recording.deviceName,
         recording.startedAt.formatted(.dateTime.month(.abbreviated).day().hour().minute())]
            .filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private var visibleDetail: String? {
        switch recording.state {
        case .failed, .received: return recording.detail
        case .queued: return recording.detail.flatMap { $0.hasPrefix("Will retry") ? $0 : nil }
        default: return nil
        }
    }

    /// Plain words; a finished recording needs none (its link speaks).
    private var status: String? {
        switch recording.state {
        case .receiving:
            if let progress = recording.progress { return "Receiving · \(Int(progress * 100))%" }
            return "Receiving"
        case .received: return "Received"
        case .queued: return "Queued"
        case .transcribing:
            if let progress = recording.progress { return "Transcribing · \(Int(progress * 100))%" }
            return "Transcribing"
        case .transcribed: return nil
        case .failed: return "Couldn't transcribe"
        case .unknown: return nil
        }
    }

    private var ring: StateRing.Kind {
        switch recording.state {
        case .receiving, .transcribing: return .progress(recording.progress)
        case .received, .queued: return .held
        case .transcribed: return .done
        case .failed: return .failed
        case .unknown: return .waiting
        }
    }

    static func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

/// A 4 pt capsule bar — custom-drawn so the offscreen renderer shows it
/// (ImageRenderer draws AppKit ProgressViews as placeholders). nil = an
/// indeterminate sliver.
struct ThinProgressBar: View {
    let value: Double?
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.bgSunken)
                Capsule()
                    .fill(color)
                    .frame(width: max(4, geo.size.width * min(1, max(0, value ?? 0.12))))
            }
        }
        .frame(height: 4)
        .accessibilityValue(value.map { "\(Int($0 * 100)) percent" } ?? "in progress")
    }
}

// MARK: - pairing sheet

struct PairPhoneSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.screenRendering) private var rendering
    @State private var copied = false

    var body: some View {
        let phone = model.phoneSync
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                Text("Pair your iPhone")
                    .font(.brandSans(20, .semibold))
                    .kerning(-0.2)
                    .foregroundStyle(Theme.fg)
                Text("Open the Camera on your iPhone and point it at this code.")
                    .font(.brandSans(13))
                    .foregroundStyle(Theme.fgMuted)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 26)
            .padding(.bottom, 18)

            if let invite = phone.activeInvite {
                qrBlock(invite: invite, paired: phone.pairedFromInvite != nil)
                    .padding(.bottom, 16)
                statusLine(invite: invite, paired: phone.pairedFromInvite)
                    .padding(.horizontal, 26)
                    .padding(.bottom, 14)
            }

            Text(
                "The code works once and expires after 10 minutes. Huske on the iPhone can also "
                    + "scan it itself, or take the link pasted from your clipboard."
            )
            .font(.brandSans(11.5))
            .foregroundStyle(Theme.fgFaint)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 30)
            .padding(.bottom, 18)

            Rectangle().fill(Theme.divider).frame(height: 1)

            HStack(spacing: 10) {
                Button {
                    guard let invite = phone.activeInvite else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(invite.url.absoluteString, forType: .string)
                    copied = true
                    Task {
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        copied = false
                    }
                } label: {
                    Label(copied ? "Copied" : "Copy link", systemImage: copied ? "checkmark" : "link")
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(phone.activeInvite == nil || phone.pairedFromInvite != nil)
                .help("Paste it on your iPhone through Universal Clipboard")
                Spacer()
                Button(phone.pairedFromInvite != nil ? "Done" : "Cancel") {
                    phone.endPairing()
                }
                .buttonStyle(
                    phone.pairedFromInvite != nil
                        ? AnyButtonStyle(PrimaryButtonStyle()) : AnyButtonStyle(SecondaryButtonStyle())
                )
                .keyboardShortcut(phone.pairedFromInvite != nil ? .defaultAction : .cancelAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 430)
        .background(Theme.bg)
    }

    private func qrBlock(invite: PairingInvite, paired: Bool) -> some View {
        ZStack {
            QRCodeView(text: invite.url.absoluteString)
                .frame(width: 236, height: 236)
                .padding(14)
                .background(
                    // Scanners want dark modules on light paper, in dark mode too.
                    RoundedRectangle(cornerRadius: Theme.radiusLG, style: .continuous)
                        .fill(Color.white)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.radiusLG, style: .continuous)
                        .strokeBorder(Theme.cardBorder, lineWidth: 1)
                )
                .opacity(paired ? 0.12 : 1)
                .accessibilityLabel("Pairing QR code")
            if paired {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 76, weight: .regular))
                    .foregroundStyle(Theme.ok)
                    .accessibilityHidden(true)
            }
        }
        .animation(Theme.ease, value: paired)
    }

    @ViewBuilder
    private func statusLine(invite: PairingInvite, paired: PairedDevice?) -> some View {
        if let paired {
            Text("Paired with \(paired.name ?? "your iPhone") ✓")
                .font(.brandSans(13.5, .semibold))
                .foregroundStyle(Theme.ok)
        } else if rendering {
            waitingRow(remaining: invite.expiresAt.timeIntervalSinceNow)
        } else {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                waitingRow(remaining: invite.expiresAt.timeIntervalSince(context.date))
            }
        }
    }

    @ViewBuilder
    private func waitingRow(remaining: TimeInterval) -> some View {
        if remaining <= 0 {
            HStack(spacing: 10) {
                Text("This code expired.")
                    .font(.brandSans(12.5))
                    .foregroundStyle(Theme.fgMuted)
                Button("Show a new code") { model.phoneSync.renewInvite() }
                    .buttonStyle(LinkButtonStyle(fontSize: 12.5))
            }
        } else {
            HStack(spacing: 8) {
                StatusPill(text: "waiting for iPhone", color: Theme.info, pulsing: true, compact: true)
                Spacer()
                Text("Expires in \(Self.countdown(remaining))")
                    .font(.brandSans(12))
                    .foregroundStyle(Theme.fgMuted)
                    .monospacedDigit()
            }
        }
    }

    static func countdown(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.up)))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// A QR code drawn pixel-exact: CoreImage makes one pixel per module and
/// SwiftUI scales it up with interpolation off, so edges stay crisp at any
/// size and on any display scale.
struct QRCodeView: View {
    let text: String

    var body: some View {
        if let image = Self.image(for: text) {
            Image(decorative: image, scale: 1)
                .interpolation(.none)
                .resizable()
                .aspectRatio(1, contentMode: .fit)
        } else {
            Image(systemName: "qrcode")
                .resizable()
                .aspectRatio(1, contentMode: .fit)
                .foregroundStyle(Theme.fgFaint)
        }
    }

    static func image(for text: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        return CIContext(options: [.useSoftwareRenderer: false])
            .createCGImage(output, from: output.extent)
    }
}
