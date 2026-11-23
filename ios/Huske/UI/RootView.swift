import SwiftUI
import UIKit

struct RootView: View {
    @Bindable var app: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack(path: $app.path) {
            LibraryView(library: app.library, sync: app.sync, recorder: app.recorder) {
                app.showingMac = true
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                HomeHeader(sync: app.sync) { app.showingMac = true }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                RecorderPanel(recorder: app.recorder, sync: app.sync)
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: String.self) { id in
                RecordingDetailView(recordingID: id, library: app.library, sync: app.sync, recorder: app.recorder)
            }
        }
        .background(Brand.bg.ignoresSafeArea())
        .sheet(isPresented: $app.showingMac, onDismiss: {
            if app.pairingState != .working {
                app.pendingInvite = nil
                app.pairingState = .idle
            }
            app.pairingMessage = nil
            app.pairingSuccessMessage = nil
        }) {
            MacSettingsView(app: app)
        }
        .alert(
            app.recorder.problem?.title ?? "",
            isPresented: Binding(
                get: { app.recorder.problem != nil },
                set: { if !$0 { app.recorder.problem = nil } }),
            presenting: app.recorder.problem
        ) { problem in
            if problem == .microphoneDenied {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
                Button("Not Now", role: .cancel) {}
            } else {
                Button("OK", role: .cancel) {}
            }
        } message: { problem in
            Text(problem.message)
        }
        .onOpenURL { app.handle(url: $0) }
        .onChange(of: scenePhase) { _, phase in
            app.sync.scenePhaseChanged(isActive: phase == .active)
        }
    }
}

/// Wordmark on the left, the paired-Mac chip on the right.
private struct HomeHeader: View {
    let sync: SyncManager
    var onMacTapped: () -> Void

    var body: some View {
        HStack(alignment: .center) {
            HStack(spacing: 9) {
                LogoMark()
                    .frame(width: 22, height: 22)
                Text("huske")
                    .font(.plexSerifItalic(27, relativeTo: .title))
                    .foregroundStyle(Brand.fg)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Huske")
            .accessibilityAddTraits(.isHeader)

            Spacer()

            // The paired Mac in plain words; the glyph is the signal (filled
            // = there now, hollow = away, arc = connecting). When only the
            // user can fix the link, the words say what is wrong instead of
            // the Mac's name; the Mac screen has the way out. No capsule.
            Button(action: onMacTapped) {
                HStack(spacing: 7) {
                    if sync.isPaired {
                        LinkGlyph(state: sync.link, isBusy: sync.isRunning)
                        Text(sync.link.headline ?? shortName)
                            .lineLimit(1)
                    } else {
                        Text("Pair your Mac")
                    }
                }
                .font(.plexSans(14, relativeTo: .footnote))
                .foregroundStyle(chipColor)
                .padding(.vertical, 10)
                .padding(.leading, 12)
                .frame(maxWidth: 220, alignment: .trailing)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(accessibilityText)
        }
        .padding(.horizontal, 20)
        .padding(.top, 6)
        .padding(.bottom, 10)
        .background(Brand.bg)
    }

    private var chipColor: Color {
        guard sync.isPaired else { return Brand.amber }
        return sync.link.needsSettings || sync.link.needsPairing ? Brand.err : Brand.fgMuted
    }

    private var shortName: String { sync.macName }

    private var accessibilityText: String {
        guard sync.isPaired else { return "Pair your Mac" }
        return "\(sync.link.accessibilityLabel(macName: sync.macName)). Mac settings"
    }
}

/// The huske mark: an amber spine and three receding lines of "text".
struct LogoMark: View {
    var body: some View {
        Canvas { context, size in
            let u = min(size.width, size.height) / 44
            func bar(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ color: Color) {
                let rect = CGRect(x: x * u, y: y * u, width: w * u, height: h * u)
                context.fill(Path(roundedRect: rect, cornerRadius: 1.2 * u), with: .color(color))
            }
            // logo-mark.svg geometry, cropped from 64 to the 44-unit art box.
            bar(4, 0, 6, 44, Brand.amber)
            bar(14, 14, 26, 5, Brand.fg)
            bar(14, 24, 20, 5, Brand.fg)
            bar(14, 34, 14, 5, Brand.fg)
        }
        .accessibilityHidden(true)
    }
}
