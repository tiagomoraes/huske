import AppKit

/// The small piece of session state encoded into the menu-bar mark.
enum HuskeMenuBarState {
    case idle
    case recording
    case paused
    case stopping

    var accessibilityLabel: String {
        switch self {
        case .idle: "Huske — not recording"
        case .recording: "Huske — recording"
        case .paused: "Huske — recording paused"
        case .stopping: "Huske — finishing recording"
        }
    }
}

extension NSImage {
    /// A compact, monochrome menu-bar signature whose session state is played
    /// by the logo itself rather than appended beside it.
    ///
    /// The mark is a tall spine plus three descending transcript lines. The
    /// transcript lines never change — the spine is the performer:
    ///
    /// - **idle**: the plain mark.
    /// - **recording**: the spine lights a record lamp — a dot floats above a
    ///   shortened spine, like a live indicator on a mast.
    /// - **paused**: the spine splits into twin full-height bars — the pause
    ///   symbol built from the logo's own stroke.
    /// - **stopping**: the spine dissolves into three descending dots while
    ///   the last words are written out.
    ///
    /// Every state shares one 12-unit-wide silhouette, so the status item
    /// never changes width and neighbouring menu extras never shift. Unlike
    /// ``LogoMark`` — the full-colour brand mark on its dark rounded tile —
    /// this is a single-colour glyph with `isTemplate = true`, so macOS
    /// inverts and highlights it for light/dark appearance exactly the way an
    /// SF Symbol behaves.
    static func huskeMenuBarGlyph(
        for state: HuskeMenuBarState,
        pointSize: CGFloat = 15
    ) -> NSImage {
        let logicalHeight: CGFloat = 16
        let logicalWidth: CGFloat = 12
        let unit = pointSize / logicalHeight
        let image = NSImage(
            size: NSSize(width: logicalWidth * unit, height: pointSize), flipped: true
        ) { rect in
            let scale = rect.height / logicalHeight

            func scaledRect(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat)
                -> CGRect
            {
                CGRect(
                    x: rect.minX + x * scale,
                    y: rect.minY + y * scale,
                    width: width * scale,
                    height: height * scale)
            }

            func bar(
                _ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat,
                radius: CGFloat = 0.65
            ) {
                NSBezierPath(
                    roundedRect: scaledRect(x, y, width, height),
                    xRadius: radius * scale,
                    yRadius: radius * scale
                ).fill()
            }

            func dot(_ x: CGFloat, _ y: CGFloat, diameter: CGFloat) {
                NSBezierPath(
                    ovalIn: scaledRect(x, y, diameter, diameter)
                ).fill()
            }

            // The transcript lines, constant across every state. Paused shifts
            // them right to make room for the twin spines.
            func transcriptLines(x: CGFloat = 4.1, trim: CGFloat = 0) {
                bar(x, 4.3, 6.9 - trim, 1.6)
                bar(x, 7.4, 5.4 - trim, 1.6)
                bar(x, 10.5, 3.9 - trim, 1.6)
            }

            NSColor.black.setFill()

            switch state {
            case .idle:
                bar(1.0, 1.4, 1.8, 13.2, radius: 0.75)
                transcriptLines()
            case .recording:
                // Record lamp lit above the mast.
                dot(0.5, 1.0, diameter: 2.8)
                bar(1.0, 4.8, 1.8, 9.8, radius: 0.75)
                transcriptLines()
            case .paused:
                // The spine splits into the pause bars.
                bar(0.6, 1.4, 1.6, 13.2, radius: 0.7)
                bar(3.0, 1.4, 1.6, 13.2, radius: 0.7)
                transcriptLines(x: 6.0, trim: 1.0)
            case .stopping:
                // The spine dissolves while the last words are written out.
                dot(0.95, 2.0, diameter: 1.9)
                dot(0.95, 7.0, diameter: 1.9)
                dot(0.95, 12.0, diameter: 1.9)
                transcriptLines()
            }

            return true
        }
        image.isTemplate = true
        return image
    }
}
