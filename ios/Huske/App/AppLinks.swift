// The public pages the app links to. The App Store wants the privacy policy
// reachable from inside the app (guideline 5.1.1(i)) and a way to get the Mac
// app that transcribes (docs/research/app-store-distribution.md).

import Foundation

enum AppLinks {
    static let site = URL(string: "https://huske.tiagomoraes.cloud/")!
    static let privacy = URL(string: "https://huske.tiagomoraes.cloud/privacy/")!
    static let support = URL(string: "https://huske.tiagomoraes.cloud/support/")!
}
