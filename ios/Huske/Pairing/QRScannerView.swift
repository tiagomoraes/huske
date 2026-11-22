// In-app QR scanner (VisionKit DataScanner, QR only). Calls `onFound` once
// with the first payload that contains a Huske pairing link.

import SwiftUI
import VisionKit

struct QRScannerSheet: View {
    var onFound: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                if QRScannerView.isAvailable {
                    QRScannerView(onFound: { payload in
                        onFound(payload)
                        dismiss()
                    })
                    .ignoresSafeArea()
                    ScannerFrame()
                    VStack {
                        Spacer()
                        Text("Point at the code in Huske on your Mac")
                            .font(.plexSans(15, .medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(Capsule().fill(.black.opacity(0.55)))
                            .padding(.bottom, 40)
                    }
                } else {
                    unavailable
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
        }
        .tint(Brand.amber)
    }

    private var unavailable: some View {
        VStack(spacing: 14) {
            Image(systemName: "qrcode.viewfinder")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(Brand.fgMuted)
            Text("Scanning isn't available here")
                .font(.plexSans(20, .semibold, relativeTo: .title3))
                .foregroundStyle(Brand.fg)
            Text(QRScannerView.unavailableReason)
                .font(.plexSans(15, relativeTo: .subheadline))
                .foregroundStyle(Brand.fgMuted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Brand.bg)
    }
}

private struct ScannerFrame: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 24, style: .continuous)
            .strokeBorder(Brand.amber, lineWidth: 3)
            .frame(width: 240, height: 240)
            .shadow(color: .black.opacity(0.3), radius: 12)
            .accessibilityHidden(true)
    }
}

struct QRScannerView: UIViewControllerRepresentable {
    var onFound: (String) -> Void

    @MainActor static var isAvailable: Bool {
        DataScannerViewController.isSupported && DataScannerViewController.isAvailable
    }

    @MainActor static var unavailableReason: String {
        if !DataScannerViewController.isSupported {
            return "This device can't scan codes. Copy the link on your Mac and use “Paste pairing link” instead."
        }
        return "Allow camera access for Huske in Settings, or copy the link on your Mac and paste it."
    }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isPinchToZoomEnabled: true,
            isGuidanceEnabled: false,
            isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }

    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {}

    static func dismantleUIViewController(_ controller: DataScannerViewController, coordinator: Coordinator) {
        controller.stopScanning()
    }

    func makeCoordinator() -> Coordinator { Coordinator(onFound: onFound) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        private let onFound: (String) -> Void
        private var delivered = false

        init(onFound: @escaping (String) -> Void) {
            self.onFound = onFound
        }

        func dataScanner(_ dataScanner: DataScannerViewController,
                         didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            for item in addedItems {
                guard !delivered, case let .barcode(barcode) = item,
                      let payload = barcode.payloadStringValue,
                      PairingLink.containsPairingLink(payload) else { continue }
                delivered = true
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                dataScanner.stopScanning()
                onFound(payload)
                return
            }
        }
    }
}
