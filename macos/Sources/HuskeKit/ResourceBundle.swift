// Where a SwiftPM resource bundle (`<Package>_<Target>.bundle`) lives once
// the app is packaged — found by us rather than by `Bundle.module`.
//
// `swift build` generates the `Bundle.module` accessor, and what it generates
// depends on the toolchain. Xcode 27's looks in `Contents/Resources` first.
// Xcode 26's — the one the release workflow builds with — looks only next to
// the `.app` (`Huske.app/Huske_Huske.bundle`, which would break code signing)
// and at the *build machine's* `.build` path, and traps when neither exists.
// v0.15.0's Huske.app crashed on launch everywhere but on the Mac that built
// it. This lookup checks the places a packaged app and a `swift run` binary
// keep the bundle, and returns nil instead of trapping, so a missing bundle
// costs the brand fonts, never the app.

import Foundation

public enum ResourceBundle {
    /// The resource bundle `name` (without `.bundle`), looked up in
    /// `main`'s `Contents/Resources`, then beside the `.app` or the
    /// executable (`swift run`, tests). nil when it is in none of them.
    public static func locate(named name: String, main: Bundle = .main) -> Bundle? {
        let file = name + ".bundle"
        let places = [
            main.resourceURL,
            main.bundleURL,
            main.executableURL?.deletingLastPathComponent(),
        ]
        for place in places.compactMap({ $0 }) {
            let candidate = place.appendingPathComponent(file, isDirectory: true)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
                  isDirectory.boolValue
            else { continue }
            if let bundle = Bundle(url: candidate) { return bundle }
        }
        return nil
    }
}
