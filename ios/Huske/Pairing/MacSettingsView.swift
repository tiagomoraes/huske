// The "Mac" screen: pair (scan / paste / Camera link), confirm a pairing, or
// manage the paired Mac (the link to it and why it isn't syncing, last sync,
// Sync now, Copy details, Forget).

import AppIntents
import HuskeSync
import SwiftUI

struct MacSettingsView: View {
    let app: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 32) {
                    Group {
                        if let invite = app.pendingInvite {
                            ConfirmPairingView(app: app, invite: invite)
                        } else if app.sync.isPaired {
                            PairedMacView(app: app)
                        } else {
                            UnpairedView(app: app)
                        }
                    }
                    PolicyLinks()
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 32)
                .animation(Brand.ease, value: app.pendingInvite)
            }
            .background(Brand.bg.ignoresSafeArea())
            .navigationTitle("Mac")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Brand.bg, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .font(.plexSans(17, .semibold))
                }
            }
        }
        .tint(Brand.amber)
    }
}

// MARK: - unpaired

private struct UnpairedView: View {
    let app: AppModel
    @State private var scanning = false

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: "laptopcomputer.and.iphone")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(Brand.fgMuted)
                    .padding(.bottom, 4)
                    .accessibilityHidden(true)
                Text("Send recordings to your Mac")
                    .font(.plexSans(26, .semibold, relativeTo: .title))
                    .kerning(-0.3)
                    .foregroundStyle(Brand.fg)
                Text("Huske on your Mac transcribes what you record here. Pair once; recordings then sync over your local network — never the cloud.")
                    .font(.plexSans(16, relativeTo: .body))
                    .foregroundStyle(Brand.fgMuted)
                    .fixedSize(horizontal: false, vertical: true)
                Link(destination: AppLinks.site) {
                    Text("No Huske on your Mac yet? It’s free at huske.tiagomoraes.cloud")
                        .multilineTextAlignment(.leading)
                }
                .font(.plexSans(16, relativeTo: .body))
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 12)

            Card {
                VStack(alignment: .leading, spacing: 14) {
                    StepRow(number: 1, text: "On your Mac, open Huske → iPhone → Pair iPhone.")
                    StepRow(number: 2, text: "Scan the code it shows, or copy the link and paste it here.")
                }
            }

            VStack(spacing: 12) {
                Button {
                    scanning = true
                } label: {
                    Label("Scan Pairing Code", systemImage: "qrcode.viewfinder")
                }
                .buttonStyle(PrimaryButtonStyle())

                Button {
                    app.pastePairingLink()
                } label: {
                    Label("Paste Pairing Link", systemImage: "doc.on.clipboard")
                }
                .buttonStyle(SecondaryButtonStyle())
            }

            if let message = app.pairingMessage {
                NoticeText(text: message, tone: .error)
            }

            Text("You can also point the iPhone Camera at the code.")
                .font(.plexSans(14, relativeTo: .footnote))
                .foregroundStyle(Brand.fgMuted)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .sheet(isPresented: $scanning) {
            QRScannerSheet { payload in app.receivePairingText(payload) }
        }
    }
}

/// The privacy policy and support pages, reachable whether or not a Mac is
/// paired (App Store guideline 5.1.1(i)).
private struct PolicyLinks: View {
    var body: some View {
        HStack(spacing: 24) {
            Link("Privacy policy", destination: AppLinks.privacy)
            Link("Support", destination: AppLinks.support)
        }
        .font(.plexSans(14, relativeTo: .footnote))
        .tint(Brand.fgMuted)
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

private struct StepRow: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(number)")
                .font(.plexSerif(17, relativeTo: .body))
                .foregroundStyle(Brand.fgFaint)
                .frame(width: 18, alignment: .leading)
            Text(text)
                .font(.plexSans(16, relativeTo: .body))
                .foregroundStyle(Brand.fg)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - confirm

private struct ConfirmPairingView: View {
    let app: AppModel
    let invite: PairingInvite

    /// A Mac paired before keeps the name this iPhone gave it.
    private var macName: String { app.sync.name(forMacID: invite.macID, fallback: invite.macName) }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 10) {
                Eyebrow("Pair with")
                HStack(spacing: 12) {
                    Image(systemName: "laptopcomputer")
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(Brand.fg)
                    Text(macName)
                        .font(.plexSans(26, .semibold, relativeTo: .title))
                        .kerning(-0.3)
                        .foregroundStyle(Brand.fg)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("Recordings from this iPhone will be sent to this Mac over your local network and transcribed there.")
                    .font(.plexSans(16, relativeTo: .body))
                    .foregroundStyle(Brand.fgMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 12)

            // Another link that didn't work arrived while this one waits.
            if let message = app.pairingMessage {
                NoticeText(text: message, tone: .error)
            }

            if let current = app.sync.pairedMac, current.macID != invite.macID {
                NoticeText(text: "This replaces \(app.sync.displayName(of: current)). Recordings not yet transcribed will go to \(macName) instead.",
                           tone: .warn)
            }

            switch app.pairingState {
            case .idle:
                VStack(spacing: 12) {
                    Button("Pair") { app.confirmPairing() }
                        .buttonStyle(PrimaryButtonStyle())
                    Button("Cancel") { app.cancelPairing() }
                        .buttonStyle(SecondaryButtonStyle())
                }
            case .working:
                HStack(spacing: 12) {
                    ProgressView().tint(Brand.amber)
                    Text("Connecting to \(macName)…")
                        .font(.plexSans(16, relativeTo: .body))
                        .foregroundStyle(Brand.fgMuted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 12)
            case let .finished(message):
                NoticeText(text: message, tone: .warn)
                Button("Done") { app.finishPairingFlow() }
                    .buttonStyle(PrimaryButtonStyle())
            }

            Text("Recordings travel straight to this Mac, encrypted with a key only these two devices hold.")
                .font(.plexSans(13, relativeTo: .caption))
                .foregroundStyle(Brand.fgFaint)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - paired

private struct PairedMacView: View {
    let app: AppModel
    @State private var confirmingForget = false
    @State private var scanning = false
    /// "Looking for your Mac…" only earns an explanation once it has lasted.
    @State private var showsSearchHelp = false
    @Environment(\.openURL) private var openURL

    private var sync: SyncManager { app.sync }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            // A link that didn't work (bad, expired) must say so here too,
            // not only before the first pairing.
            if let message = app.pairingMessage {
                NoticeText(text: message, tone: .error)
            }
            if let banner = app.pairingSuccessMessage {
                NoticeText(text: banner, tone: .ok)
            }

            Card(padding: 0) {
                VStack(spacing: 0) {
                    HStack(spacing: 14) {
                        Image(systemName: "laptopcomputer")
                            .font(.system(size: 30, weight: .light))
                            .foregroundStyle(Brand.fg)
                            .frame(width: 44)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(sync.macName)
                                .font(.plexSerif(24, relativeTo: .title2))
                                .foregroundStyle(Brand.fg)
                                .lineLimit(2)
                            LinkStatusLine(state: sync.link, isBusy: sync.isRunning)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(16)
                    divider
                    MacNameRow(sync: sync)
                    divider
                    InfoRow(label: "Last sync", value: sync.lastSyncAt.map { Format.relative($0) } ?? "Never")
                    divider
                    InfoRow(label: "Waiting to send", value: sync.pendingUploadCount == 0 ? "Nothing" : "\(sync.pendingUploadCount)")
                    divider
                    InfoRow(label: "Transcription", value: transcriptionText)
                    divider
                    InfoRow(label: "Paired", value: sync.pairedMac.map { $0.pairedAt.formatted(date: .abbreviated, time: .omitted) } ?? "—")
                }
            }
            .padding(.top, 12)

            // Why it isn't syncing, with the way out. What only the user can
            // fix comes first.
            if sync.link.isBlocked, let why = sync.link.explanation(macName: sync.macName) {
                NoticeText(text: why, tone: .warn)
                if sync.link.needsSettings {
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }
                    .buttonStyle(SecondaryButtonStyle())
                } else if sync.link.needsPairing {
                    Button {
                        scanning = true
                    } label: {
                        Label("Scan Pairing Code", systemImage: "qrcode.viewfinder")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
            } else if !sync.hasConfirmedPairing {
                NoticeText(text: "Waiting for \(sync.macName) to confirm the pairing — keep Huske open on your Mac.", tone: .info)
            } else if let error = sync.lastError {
                NoticeText(text: error, tone: .warn)
            } else if showsSearchHelp, sync.link.isLooking,
                      let why = sync.link.explanation(macName: sync.macName) {
                NoticeText(text: why, tone: .info)
            }

            Button {
                sync.syncNow(.manual)
            } label: {
                HStack(spacing: 10) {
                    if sync.isRunning {
                        ProgressView().tint(Brand.fgOnAmber)
                        Text(activityText)
                    } else {
                        Text("Sync now")
                    }
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(sync.isRunning)

            VStack(alignment: .leading, spacing: 10) {
                Eyebrow("This iPhone")
                Card(padding: 0) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Name shown on your Mac")
                            .font(.plexSans(13, relativeTo: .footnote))
                            .foregroundStyle(Brand.fgMuted)
                        TextField("iPhone", text: Binding(get: { sync.deviceName }, set: { sync.deviceName = $0 }))
                            .font(.plexSans(17, relativeTo: .body))
                            .foregroundStyle(Brand.fg)
                            .submitLabel(.done)
                            .autocorrectionDisabled()
                    }
                    .padding(16)
                }
                Card(padding: 0) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Record without opening Huske")
                            .font(.plexSans(15, .medium, relativeTo: .subheadline))
                            .foregroundStyle(Brand.fg)
                        Text("In Settings › Action Button, choose Controls, then Huske Record. One press starts a recording; the next stops and saves it. Siri and Shortcuts can also start recordings and read transcripts.")
                            .font(.plexSans(14, relativeTo: .footnote))
                            .foregroundStyle(Brand.fgMuted)
                            .fixedSize(horizontal: false, vertical: true)
                        ShortcutsLink()
                            .shortcutsLinkStyle(.automaticOutline)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            CopyDetailsButton(sync: sync)

            Button(role: .destructive) {
                confirmingForget = true
            } label: {
                Text("Forget this Mac")
                    .font(.plexSans(17, .medium, relativeTo: .body))
                    .foregroundStyle(Brand.err)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .confirmationDialog("Forget \(sync.macName)?", isPresented: $confirmingForget, titleVisibility: .visible) {
                Button("Forget This Mac", role: .destructive) { app.forgetMac() }
            } message: {
                Text("Recordings stay on this iPhone but stop syncing. To pair again, make a new code on your Mac.")
            }

            Text("Recordings go straight to \(sync.macName) over your Wi-Fi, or directly when the two are near each other — never through a cloud.")
                .font(.plexSans(13, relativeTo: .caption))
                .foregroundStyle(Brand.fgFaint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .sheet(isPresented: $scanning) {
            QRScannerSheet { payload in app.receivePairingText(payload) }
        }
        .task(id: sync.link.isLooking) {
            showsSearchHelp = false
            guard sync.link.isLooking else { return }
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { showsSearchHelp = true }
        }
    }

    private var divider: some View {
        Rectangle().fill(Brand.divider).frame(height: 1).padding(.leading, 16)
    }

    private var transcriptionText: String {
        switch sync.engineAvailable {
        case true?: return "Ready"
        case false?: return "Not set up on Mac"
        case nil: return "—"
        }
    }

    private var activityText: String {
        if sync.link == .searching { return "Looking for \(sync.macName)…" }
        switch sync.activity {
        case .connecting: return "Connecting…"
        case let .uploading(_, fraction): return "Sending \(Int(fraction * 100))%"
        case .checking: return "Checking transcripts…"
        case .idle: return "Syncing…"
        }
    }
}

/// "Copy details": what sync did lately, as text for a support message.
private struct CopyDetailsButton: View {
    let sync: SyncManager
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                UIPasteboard.general.string = sync.diagnosticsReport()
                copied = true
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(2))
                    copied = false
                }
            } label: {
                Text(copied ? "Copied" : "Copy details")
                    .font(.plexSans(15, .medium, relativeTo: .subheadline))
                    .foregroundStyle(Brand.amber)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Text("What sync did lately, for when something isn't working. No recordings, transcripts or names.")
                .font(.plexSans(13, relativeTo: .caption))
                .foregroundStyle(Brand.fgFaint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// What this iPhone calls the paired Mac, edited in place — so two Macs that
/// both call themselves "MacBook Pro" can be told apart. Empty shows (and
/// means) the Mac's own name; once renamed, the Mac's own name stays visible
/// underneath.
private struct MacNameRow: View {
    let sync: SyncManager
    @FocusState private var editing: Bool

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(alignment: .center, spacing: 0) {
                Text("Name")
                    .font(.plexSans(15, relativeTo: .subheadline))
                    .foregroundStyle(Brand.fgMuted)
                Spacer(minLength: 12)
                TextField(sync.macOwnName ?? "Mac",
                          text: Binding(get: { sync.macNickname }, set: { sync.macNickname = $0 }))
                    .font(.plexSans(15, relativeTo: .subheadline))
                    .foregroundStyle(Brand.fg)
                    .multilineTextAlignment(.trailing)
                    .submitLabel(.done)
                    .autocorrectionDisabled()
                    .focused($editing)
                    .accessibilityLabel("Name for this Mac")
                    .accessibilityHint("Only this iPhone uses it. Leave it empty to use the Mac's own name.")
                // A full 44 pt target; the negative padding lets it reach into
                // the row's own padding instead of making the row taller.
                Button { editing = true } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 18, weight: .regular))
                        .foregroundStyle(editing ? Brand.amber : Brand.fgMuted)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.vertical, -12)
                .padding(.trailing, -12)
                .accessibilityHidden(true)
            }
            if let own = sync.macOwnName, sync.macName != own {
                Text("Calls itself “\(own)”")
                    .font(.plexSans(13, relativeTo: .footnote))
                    .foregroundStyle(Brand.fgFaint)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .onTapGesture { editing = true }
    }
}

private struct InfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.plexSans(15, relativeTo: .subheadline))
                .foregroundStyle(Brand.fgMuted)
            Spacer(minLength: 12)
            Text(value)
                .font(.plexSans(15, relativeTo: .subheadline))
                .foregroundStyle(Brand.fg)
                .multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }
}

struct NoticeText: View {
    enum Tone { case info, ok, warn, error }

    let text: String
    let tone: Tone

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .accessibilityHidden(true)
            Text(text)
                .font(.plexSans(15, relativeTo: .subheadline))
                .foregroundStyle(Brand.fg)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Brand.radiusLG, style: .continuous).fill(color.opacity(0.11)))
    }

    private var color: Color {
        switch tone {
        case .info: return Brand.info
        case .ok: return Brand.ok
        case .warn: return Brand.warn
        case .error: return Brand.err
        }
    }

    private var symbol: String {
        switch tone {
        case .info: return "info.circle.fill"
        case .ok: return "checkmark.circle.fill"
        case .warn: return "exclamationmark.circle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }
}
