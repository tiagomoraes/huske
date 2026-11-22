# Publishing Huske on the Mac App Store and the iOS App Store

Status: research and plan, 2026-11-22. **No decision has been made.** The owner
decides after reading this.

Scope: what it would take to ship Huske.app on the Mac App Store (MAS) and
Huske for iPhone on the iOS App Store, judged against Apple's current rules.
Nothing here creates App Store Connect records, identifiers, certificates or
profiles, and the Developer ID + notarization channel
([ADR 0010](../adr/0010-developer-id-signing-and-notarization.md)) is
untouched.

Sources are Apple's primary documentation as fetched on 2026-11-22: the App
Review Guidelines ("Last Updated: October 16, 2026"), the Apple Developer
Program License Agreement (DPLA, Schedule 1 "last updated October 29, 2026"),
App Store Connect Help, Apple's developer documentation and technotes, and
answers by Apple DTS engineers on the Developer Forums. Each claim links to
its source. Where no primary source settled a point, the text says so and
marks it **unverified**. Forum quotes were partly read through a summarizing
fetcher; check the wording against the thread before quoting it publicly.

The Mac App Store packaging, CI and review patterns come from a channel the
owner already built for another app (BrowBro: branches `feat/mac-app-store`,
`ci/mas-automation`, `ci/fix-mas-archive-signing`, `chore/mas-build-*`). That
repository was only read, never changed.

---

## Summary and recommendation

**iOS App Store: go.** Nothing structural stands in the way. The iPhone app
is a complete voice recorder on its own: background recording, Lock Screen and
Action button control, a library, playback, sharing and Shortcuts. The Mac
adds transcription. The real risks are App Review's reading of guideline
4.2.3(i) ("work on its own") and 2.1 (full access for the reviewer). Both are
answered with a physical-device video of pairing and sync, precise review
notes, and a few small UI additions. Expect about **6–9 days of work and
2–4 weeks of calendar time**, most of it TestFlight and review.

**Mac App Store: not now.** The current architecture cannot be published there:
- A sandboxed app cannot run the separately installed `huske` engine.
- The guidelines forbid depending on it (2.4.5, 2.5.2, 4.2.3(i), DPLA 3.3.1(D)).

The only full-fidelity route is to embed the whole Python + MLX engine in the
bundle and port the parts of it that the sandbox forbids:
- `git`/SSH sync;
- `~/huske` and `~/.config`;
- multiprocessing semaphores;
- the Keychain CLI;
- the LaunchAgent.

That is roughly **7–11 weeks**, with real unknowns, and a second Mac channel to
maintain forever. Users of that edition would also lose the CLI, SSH sync,
custom Hugging Face models and Ollama management. Keep the Mac on Developer ID,
which Apple fully supports. Revisit the MAS only for a business reason the
website can't serve (discovery, payments, managed-Mac fleets).

**Already done on this branch** (no-regret, low risk):
- `ios/Huske/Resources/PrivacyInfo.xcprivacy` declares no tracking and no
  collected data. Its required reasons are UserDefaults `CA92.1` and file
  timestamps `C617.1`, chosen from the symbols the Release binary actually
  imports.
- `ios/HuskeLiveActivity/PrivacyInfo.xcprivacy` is a minimal manifest for the
  widget extension, which uses no required-reason API.
- `ITSAppUsesNonExemptEncryption = NO` is in the iOS app's Info.plist
  (`ios/project.yml`). The only cryptography is Apple's own (§3.4).
- A Release simulator build passes. Both manifests land in the bundle.

---

## 1. Where Huske stands today

| | Huske.app (macOS) | Huske for iPhone |
|---|---|---|
| Bundle ID | `cloud.tiagomoraes.huske` | `cloud.tiagomoraes.huske.ios`, extension `…ios.LiveActivity` |
| Build | SwiftPM + `macos/scripts/build-app.sh` (no Xcode project) | XcodeGen (`ios/project.yml`), project git-ignored |
| Signing | Developer ID, hardened runtime, notarized, **not sandboxed** | none yet (`DEVELOPMENT_TEAM` empty; simulator ad-hoc) |
| Entitlements | `com.apple.security.device.audio-input` only | none (no App Group, no keychain sharing, no multicast) |
| Engine | separate `huske` CLI (uv/Homebrew), picked by `BinaryLocator` | n/a, sends audio to the Mac |
| Crypto | — | Network.framework TLS 1.2 PSK (`TLS_PSK_WITH_AES_128_GCM_SHA256`), CryptoKit X25519 + HKDF-SHA256 + ChaCha20-Poly1305, SHA-256, `SecRandomCopyBytes` |
| Third-party code | none in the app; the engine is ~100 Python packages | **none** (`macos/Package.swift` has zero dependencies) |
| CI | `release.yml` `build-app` on `macos-26` | build/test only |

The engine, measured on the owner's Mac (`uv tool` install, Python 3.13):
- **1.2 GB** in total, with **396** `.so`/`.dylib` files.
- The largest packages:
  - `torch`, 527 MB, pulled in by `mlx-whisper`;
  - `mlx`, 204 MB, of which `mlx.metallib` is 182 MB;
  - `llvmlite`, 126 MB;
  - `scipy`, 82 MB.
- Programs it runs:
  - `git`, in `sync/client.py` and `config.py`;
  - `/usr/bin/security`, in `distill/keychain.py` and `sync/credentials.py`;
  - `/usr/bin/afconvert` and `/usr/bin/afinfo`, in `inbox/`;
  - `launchctl`, in `agent.py`;
  - `ollama`, in `distill/*`;
  - `open`;
  - `afplay` and `say`, in `echo-test`.

---

## 2. Mac App Store findings

### 2.1 The rules that decide it

[App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/),
2.4.5 (Mac App Store), current numbering:

> (i) They must be appropriately sandboxed, and follow macOS File System Documentation. …
> (ii) They must be packaged and submitted using technologies provided in Xcode; no third-party installers allowed. They must also be self-contained, single app installation bundles and cannot install code or resources in shared locations.
> (iii) They may not auto-launch or have other code run automatically at startup or login without consent nor spawn processes that continue to run without consent after a user has quit the app. …
> (iv) They may not download or install standalone apps, kexts, additional code, or resources to add functionality or significantly change the app from what we see during the review process.
> …
> (vii) They must use the Mac App Store to distribute updates; other update mechanisms are not allowed.
> (viii) Apps should run on the currently shipping OS and may not use deprecated or optionally installed technologies (such as Java).

Other guidelines that apply:
- **2.5.2:** "Apps should be self-contained in their bundles, and may not read or write data outside the designated container area, nor may they download, install, or execute code which introduces or changes features or functionality of the app".
- **4.2.3(i):** "Your app should work on its own without requiring installation of another app to function."
- **4.2.3(ii):** before a first-launch download, "disclose the size of the download and prompt users".
- **2.5.14:** "explicit user consent and … a clear visual and/or audible indication when recording".

The [DPLA](https://developer.apple.com/support/terms/apple-developer-program-license-agreement/)
is a contract, and it is stricter than the guidelines:
- **3.3.1(D):** "all files necessary for the Application to execute on macOS must be in the Application bundle submitted to Apple and must be installed by the App Store".
- **3.3.1(A):** Mac apps "may use only Documented APIs included in the default installation of macOS".
- **3.3.3(A):** "Your Application may not be designed to facilitate Recordings of others without their awareness." This applies to both apps.

**Does 2.4.5 rule out today's architecture? Yes.** A MAS Huske.app that drives
a separately installed engine breaks several rules at once:
- 2.4.5(ii) and DPLA 3.3.1(D): it is not self-contained.
- 4.2.3(i): it needs another install to work.
- 2.4.5(vii): the engine updates outside the store.
- The sandbox: below.

Downloading model **weights** is a separate question with a better answer
(§2.2).

### 2.2 Sandbox fit, item by item

| Capability | Verdict | What it takes | Sources |
|---|---|---|---|
| **Spawn an engine installed outside the bundle** (`/opt/homebrew/bin/huske`, `~/.local/bin/huske`) | **Not compatible** | A child always inherits the app's sandbox. DTS: "There is currently no way to get a dynamic sandbox extension that grants executable access", and "App Review requires that all code within your app be sandboxed." The engine must live in the bundle. | [forum 746478](https://developer.apple.com/forums/thread/746478), [685544](https://developer.apple.com/forums/thread/685544), [706390](https://developer.apple.com/forums/thread/706390), [App Sandbox](https://developer.apple.com/documentation/security/app-sandbox) |
| **Embedded helper tools** (the engine's `python3`, `huske-apple-llm`) | Compatible with changes | Put them in `Contents/MacOS` or `Contents/Helpers`, signed with **exactly** `com.apple.security.app-sandbox` + `com.apple.security.inherit`. "If you specify any other App Sandbox entitlement, the system aborts the child process." | [Embedding a helper tool in a sandboxed app](https://developer.apple.com/documentation/xcode/embedding-a-helper-tool-in-a-sandboxed-app) |
| **Bundled Python + native modules + MLX** | Compatible with changes; the bulk of the work | Every Mach-O is signed inside-out with Apple Distribution, never `--deep`. Code goes in the right bundle locations. No `.pyc` writes into the bundle ("the write breaks the seal"). CPython's `--with-app-store-compliance` patch (3.13+) removes the `itms-services` string that "Apple's macOS App Store is auto-rejecting". The hardened runtime "isn't necessary for App Store apps"; the sandbox is mandatory. | [Placing content in a bundle](https://developer.apple.com/documentation/bundleresources/placing-content-in-a-bundle), [Embedding nonstandard code structures](https://developer.apple.com/documentation/xcode/embedding-nonstandard-code-structures-in-a-bundle), [Creating distribution-signed code](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac), [CPython configure](https://docs.python.org/3/using/configure.html), [compliance patch](https://github.com/python/cpython/blob/main/Mac/Resources/app-store-compliance.patch), [Python-Apple-support](https://github.com/beeware/Python-Apple-support), [Briefcase macOS](https://briefcase.beeware.org/en/latest/reference/platforms/macOS/) |
| **`multiprocessing` (the ASR worker uses spawn)** | Compatible with changes, **must be tested** | `set_executable()` must point at the embedded, inherit-signed `python3`: the app's own binary "will crash in `_libsecinit_appsandbox`" as a child. `multiprocessing.Queue` fails under the sandbox with `PermissionError` in `SemLock`: POSIX semaphores need names of the form `<app group>/<name>`, at most 31 characters (`PSEMNAMLEN`). | [forum 762366](https://developer.apple.com/forums/thread/762366), [706390](https://developer.apple.com/forums/thread/706390), [multiprocessing](https://docs.python.org/3/library/multiprocessing.html), [App Groups entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.application-groups) |
| **MLX Metal kernels** | Likely compatible, **unverified** | Ship `mlx.metallib` next to the executable or set `METAL_PATH`. Run-time Metal kernel compilation is GPU code, not a Mach-O, but no Apple source confirms it under App Review. | [MLX install docs](https://ml-explore.github.io/mlx/build/html/install.html) |
| **Download models at runtime** | Compatible with changes | Apple endorses it: Core ML "Download and compile models within your app as an alternative to bundling"; Apple-hosted asset packs list "machine learning models" (macOS 26+). The rules to follow: disclose the size and prompt first (4.2.3(ii)), never download code (no `trust_remote_code`, no pip), and keep the reviewed app recognisable (2.4.5(iv)). Huske's "any Hugging Face repo" and "Convert and use" are the risky part. | [Core ML: downloading and compiling a model](https://developer.apple.com/documentation/coreml/downloading-and-compiling-a-model-on-the-user-s-device), [Background Assets](https://developer.apple.com/documentation/backgroundassets), [Apple-hosted asset packs](https://developer.apple.com/help/app-store-connect/manage-asset-packs/overview-of-apple-hosted-asset-packs/) |
| **Write `~/huske`, read `~/.config/huske`** | Compatible with changes | In the sandbox, `NSHomeDirectory()` and `~` resolve to the container, so the engine would silently write to `~/Library/Containers/<id>/Data/huske`. A user-visible folder needs an open panel, `files.user-selected.read-write` and a security-scoped bookmark (`files.bookmarks.app-scope`). **An inherited child gets "only the static rights … not any rights added to your sandbox after launch"**, so the app must hand the bookmark to the engine. Temporary-exception entitlements are "carefully examined" and App Review "generally won't allow" them. | [Accessing files from the macOS App Sandbox](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox), [NSHomeDirectory](https://developer.apple.com/documentation/foundation/nshomedirectory()), [Embedding a helper tool](https://developer.apple.com/documentation/xcode/embedding-a-helper-tool-in-a-sandboxed-app), [forum 709333](https://developer.apple.com/forums/thread/709333), [788364](https://developer.apple.com/forums/thread/788364) |
| **Control socket** | Compatible with changes | App and inherited child share one sandbox, so a Unix socket between them is fine, but `sun_path` is **104 bytes**. Huske's path inside the container would be 119 bytes on the owner's Mac (`/Users/tiagomoraes/Library/Containers/cloud.tiagomoraes.huske/Data/Library/Application Support/huske/control-12345.sock`). Put the socket in an app group container with a short ID; DTS: "Just use a short app group ID because of the path limits". | [App Groups entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.application-groups), [forum 788364](https://developer.apple.com/forums/thread/788364), [721701](https://developer.apple.com/forums/thread/721701) |
| **Core Audio process taps** | Compatible | Apple's own tap sample is sandboxed (`app-sandbox`, `device.audio-input`, `files.user-selected.read-write`). It needs `NSAudioCaptureUsageDescription`, which Huske already has. **Unverified:** that TCC attributes the tap and mic of an inherited Python child to the app (documented for networking only). | [Capturing system audio with Core Audio taps](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps), [NSAudioCaptureUsageDescription](https://developer.apple.com/documentation/bundleresources/information-property-list/nsaudiocaptureusagedescription) |
| **ScreenCaptureKit (fallback)** | Compatible | Apple's sample is sandboxed. The Screen Recording prompt requires an app restart after the grant. | [Capturing screen content in macOS](https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-in-macos) |
| **Microphone** | Compatible | Under the sandbox the docs name `device.microphone`; under the hardened runtime, `device.audio-input`. Apple's sandboxed sample uses `audio-input`. **Unverified** which key the sandbox enforces: ship what Xcode writes for App Sandbox → Audio Input and inspect the result. | [device.audio-input](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.device.audio-input), [device.microphone](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.device.microphone) |
| **Login item** | Compatible | The app already uses `SMAppService.mainApp`, opt-in. DTS: login items "are an expected feature of Mac App Store apps"; the limit is consent (2.4.5(iii)). The **engine's own LaunchAgent** (`huske/agent.py`, `launchctl`) can't be used: the sandbox can't write `~/Library/LaunchAgents`. The engine must exit when the app quits unless the user agreed to background running. | [SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice), [forum 706112](https://developer.apple.com/forums/thread/706112) |
| **Bonjour + peer-to-peer (iPhone sync server)** | Compatible | Needs `network.server` + `network.client`, `NSLocalNetworkUsageDescription` and `NSBonjourServices` (both already present). "The multicast entitlement isn't required on macOS." `includePeerToPeer` needs no entitlement. | [network.server](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.network.server), [TN3179](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy), [TN3151](https://developer.apple.com/documentation/technotes/tn3151-choosing-the-right-networking-api) |
| **`git` CLI, `~/.ssh`, `~/.gitconfig`** | **Not compatible** | `/usr/bin/git` is an `xcrun` shim: "xcrun: error: cannot be used within an App Sandbox". `~/.ssh` would need a temporary exception, which review rejects. Replace it with the GitHub REST APIs (Git Database API for multi-file commits) using the Huske Sync GitHub App token, or embed libgit2 over HTTPS. | [forum 746478](https://developer.apple.com/forums/thread/746478), [GitHub contents API](https://docs.github.com/en/rest/repos/contents), [Git trees API](https://docs.github.com/en/rest/git/trees), [libgit2](https://github.com/libgit2/libgit2) |
| **`/usr/bin/security`, `afconvert`, `afinfo`, `ollama`** | Mixed, **unverified** | `/usr/bin` is covered by a static sandbox extension, so the tools may launch, but they run inside Huske's sandbox. Keychain items need the Security framework (or the app holding secrets), not the CLI. Talking to Ollama over localhost works with `network.client`; starting or managing it does not. Decoding phone audio is cleaner in-process (AVFoundation). | [forum 654579](https://developer.apple.com/forums/thread/654579), [746478](https://developer.apple.com/forums/thread/746478) |
| **In-app update checks** (app's GitHub ping, engine's PyPI banner, engine installer and upgrade buttons) | Must go | 2.4.5(vii): "other update mechanisms are not allowed". | Guidelines 2.4.5(vii) |
| **Size** | No constraint | The maximum uncompressed macOS app size is 200 GB. | [Maximum build file sizes](https://developer.apple.com/help/app-store-connect/reference/app-uploads/maximum-build-file-sizes/) |

Precedents, from their App Store listings:
- **Py Editor** embeds CPython 3.11 with NumPy and Pandas
  ([listing](https://apps.apple.com/us/app/py-editor/id6456883927)).
- **Pico AI Server** is "Built on MLX" and downloads models from Hugging Face
  ([listing](https://apps.apple.com/us/app/pico-ai-homelab-llm-server/id6738607769?mt=12)).
- **Whisper Transcription** downloads its on-device speech model
  ([listing](https://apps.apple.com/us/app/whisper-transcription/id1668083311)).
- No store app was found that ships a **Python ML engine**.

### 2.3 Lessons from BrowBro's Mac App Store channel (proven on this team)

- **Two targets, one codebase.**
  - One XcodeGen template with a `BrowBroMAS` scheme (`-D APPSTORE`, its own
    Info.plist and entitlements, no Sparkle).
  - The bundle ID is the same in both channels. It was renamed before the first
    upload, because App Store Connect binds an ID permanently on that upload.
- **Sandbox surprises that reached App Review.**
  - `NSWorkspace.OpenConfiguration.arguments` "is ignored" for sandboxed
    callers.
  - Inside the sandbox, `homeDirectoryForCurrentUser` is the container. The
    real home comes from `getpwuid`.
  - Switching channels resets TCC grants.
- **Signing that works in CI.**
  - Apple Distribution for the app and 3rd Party Mac Developer Installer for the
    `.pkg`, both in one `.p12`.
  - A **manually created** "Mac App Store Connect" profile stored as a secret.
  - `CODE_SIGN_STYLE=Manual` and the identity overridden on the `xcodebuild
    archive` command line. Automatic signing archives with Apple Development
    and fails at export.
  - `xcodebuild -exportArchive` with `method app-store-connect` and
    `destination upload` does the upload; no altool.
  - An **App Manager** API key is enough for this. Cloud signing would need an
    **Admin** key ("Cloud signing permission error").
- **Upload rejections and their fixes.**
  - ITMS-90301: no beta or RC Xcode. Pin the newest release.
  - ITMS-90243: every document type needs `CFBundleTypeName`.
  - Build numbers are consumed by manual uploads, so CI asks Connect for the
    highest build and adds one.
  - Profiles that Xcode generated (even without `IsXcodeManaged`) break manual
    signing.
- **App Review.**
  - Build 9 came back under 2.1 "Information Needed", asking for a screen
    recording and six written answers. The answers must also go in the Notes
    field (4,000 bytes).
  - BrowBro now keeps `packaging/mas/listing.md` as the single source for the
    listing and the review notes, plus a demo-recording kit.

---

## 3. iOS App Store findings

### 3.1 Review of a companion app

There is no guideline written for companions to desktop software. These are
the rules that apply
([guidelines](https://developer.apple.com/app-store/review/guidelines/),
[complete review](https://developer.apple.com/help/app-review/before-submitting-for-review/complete-review)):

- **4.2.3(i):** "Your app should work on its own without requiring installation
  of another app to function." Huske for iPhone records, keeps a library, plays
  back, shares audio and transcripts, and drives Shortcuts with no Mac at all.
  Transcription is the part that needs the Mac. Present it that way in the
  listing and the notes, and don't gate any iPhone feature on the Mac app
  (3.2.2(x): don't force users to "download other apps").
- **2.1(a):** reviewers need full access. A built-in demo mode is allowed only
  "with prior approval by Apple". The DEBUG demo mode should therefore stay out
  of Release builds; 2.5.19 also forbids hidden features.
- **Required hardware (App Review Help):** "Apps with required hardware must
  provide a video (not a screen recording) that shows your app running on a
  physical Apple device as it pairs and interacts with the hardware." Treat the
  Mac as the hardware:
  - film the iPhone scanning the pairing QR on a real Mac;
  - record, stop, and show the upload;
  - show the transcript arriving on both screens.
  
  Attach the video in App Review Information → Attachment
  ([`appReviewAttachments`](https://developer.apple.com/documentation/appstoreconnectapi/app-store-review-attachments)
  covers "demo videos"). Put a link and the explanations in Notes (up to 4,000
  bytes). Mention that the reviewer can test recording without a Mac.
- **2.5.11(i):** register only intents the app handles "without the support of
  an additional app". Start, stop and pause run on the phone. *Get Transcript*
  and *Get Latest Transcript* read the local library, so they qualify. Don't
  add an intent that asks the Mac to do something.
- **2.5.14 and DPLA 3.3.3(A):** recording consent and indicator, and "may not be
  designed to facilitate Recordings of others without their awareness".
  - iOS shows the recording indicator, and the Live Activity shows a red dot.
    Add one sentence about letting others know they are recorded: in the
    listing, and once in the app.
- **2.3 / 2.3.1(a):** describe features accurately and "with specificity in the
  Notes for Review".
- **2.4.1 (iPad):** iPhone-only apps may be reviewed on an iPad in compatibility
  mode. Test there: no Action button, and Live Activities behave differently.
- **Mac availability:** App Store Connect makes compatible iPhone apps
  available on Apple silicon Macs and on Apple Vision Pro unless you opt out
  under Pricing and Availability. Turn both off: the real Mac app is
  Huske.app.

### 3.2 Capability justifications

| Capability | Status | Justification / source |
|---|---|---|
| `UIBackgroundModes: audio` | Fine | Apple's `.record` category docs: "To continue recording audio when your app transitions to the background … add the `audio` value to the UIBackgroundModes key" ([AVAudioSession.Category.record](https://developer.apple.com/documentation/avfaudio/avaudiosession/category-swift.struct/record)). Guideline 2.5.4 lists "audio playback", so state the recording use in the notes. |
| `AudioRecordingIntent` + `LiveActivityIntent` | Fine | "you must start a Live Activity when you begin the audio recording and keep it active as long as you record audio" ([AudioRecordingIntent](https://developer.apple.com/documentation/appintents/audiorecordingintent)). Huske does exactly this. **Unverified:** what happens to a recording when the Live Activity reaches its 8-hour cap; test it before launch. |
| `UIBackgroundModes: fetch, processing` + `BGTaskSchedulerPermittedIdentifiers` | Fine | Background sync of finished recordings. Both identifiers are declared. |
| `NSLocalNetworkUsageDescription`, `NSBonjourServices: _huske-sync._tcp` | Fine | Required by [TN3179](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy). The multicast entitlement is needed only for raw multicast or "arbitrary Bonjour service types", so **not** here ([multicast entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.networking.multicast)). `includePeerToPeer` needs no entitlement. An undetermined permission is silently denied in the background, so pairing must happen in the foreground (it does). |
| `NSSupportsLiveActivities` | Fine | No ads, no sensitive information on the Lock Screen ([HIG: Live Activities](https://developer.apple.com/design/human-interface-guidelines/live-activities)). Handle a user who turned Live Activities off. |
| `NSMicrophoneUsageDescription`, `NSCameraUsageDescription` | Fine | Specific strings already exist (mic; camera for the QR scan). 5.1.1 asks for purpose strings that say why ([purpose strings](https://developer.apple.com/help/app-review/guideline-reference/5-1-1-purpose-strings)). |

### 3.3 Privacy

**Privacy manifest.** Apple requires one for every bundle that contains an
executable, listing the required-reason APIs it uses
([privacy manifest files](https://developer.apple.com/documentation/bundleresources/privacy-manifest-files),
[required-reason API](https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api),
[TN3183](https://developer.apple.com/documentation/technotes/tn3183-adding-required-reason-api-entries-to-your-privacy-manifest)).
`nm -u` on the Release binaries shows:

| Bundle | Symbols that need a reason | Declared |
|---|---|---|
| `Huske.app` | `NSUserDefaults` (sync settings, Mac names), `NSFileModificationDate` (HuskeSync `SyncServer`, compiled into the iOS binary too) | `UserDefaults` → `CA92.1` (the app's own defaults); `FileTimestamp` → `C617.1` (files in the app container) |
| `HuskeLiveActivity.appex` | none | empty manifest |

There are no third-party SDKs. Apple's docs say uploads missing reasons
"aren't accepted" since May 1, 2024. Whether App Store Connect enforces this
for an app's *own* code (as opposed to listed SDKs) is **unverified**; the
manifests make the question moot.

Keep the manifest current as the code changes:
- `ProcessInfo.systemUptime` or `mach_absolute_time` would need `35F9.1`.
- A free-space check before recording would need `E174.1`.
- An App Group shared with the extension would need `1C8F.1`.

**App Privacy label: "Data Not Collected".** Apple: "'Collect' refers to
transmitting data off the device in a way that allows you and/or your
third-party partners to access it for a period longer than what is necessary
to service the transmitted request in real time"
([App privacy details](https://developer.apple.com/app-store/app-privacy-details/)).
Recordings go peer-to-peer to the user's **own** Mac, never to the developer,
and there are no analytics, crash SDKs or relays. Apple doesn't address this
exact case, so this is an inference, but a well-grounded one. Revisit if
crash reporting or a relay is ever added.

**Privacy policy.** A privacy policy URL is required for every app, and
5.1.1(i) also wants it reachable inside the app. A support URL is required and
"must lead to actual contact information"
([App information](https://developer.apple.com/help/app-store-connect/reference/app-information/app-information/)).
The website has neither page today.

### 3.4 Export compliance

Huske's only cryptography:
- Network.framework TLS 1.2 PSK (`sec_protocol_options_add_pre_shared_key`).
- CryptoKit X25519, HKDF-SHA256 and ChaCha20-Poly1305, used for key rotation.
- SHA-256.

All of it is in Apple's OS, and no crypto library is bundled.

App Store Connect Help maps "Your app uses encryption limited to that within
the Apple operating system" to **"No documentation required in App Store
Connect."** The French declaration applies only to standard algorithms *not*
provided by the OS
([export compliance documentation](https://developer.apple.com/help/app-store-connect/reference/app-information/export-compliance-documentation-for-encryption)).
[`ITSAppUsesNonExemptEncryption`](https://developer.apple.com/documentation/bundleresources/information-property-list/itsappusesnonexemptencryption)
`= NO` declares exactly that, and spares the questionnaire on every upload. It
is set on this branch.

Two caveats:
- **The answer is an attestation by the developer.** "you're responsible for all
  liabilities associated with misinterpretation"
  ([overview](https://developer.apple.com/help/app-store-connect/manage-app-information/overview-of-export-compliance)).
- **Year-end report.** Apple says a year-end self-classification report "might" be
  required for exempt encryption
  ([Complying with encryption export regulations](https://developer.apple.com/documentation/security/complying-with-encryption-export-regulations)).
  Under current [EAR §740.17(e)(3)](https://www.ecfr.gov/current/title-15/subtitle-B/chapter-VII/subchapter-C/part-740/section-740.17)
  that report covers mass-market *components* and *executable software*
  (5A992/5D992). A consumer app is neither, so we believe none is due. This is
  not legal advice.

If a third-party crypto library is ever added, flip the key to `YES` and
re-answer.

### 3.5 Setup on App Store Connect and the developer portal

- **Agreements.**
  - "you can distribute free apps on the App Store under the Apple Developer
    Program License Agreement". The Paid Apps Agreement, with its tax and
    banking setup, is needed only for paid apps or in-app purchases
    ([sign and update agreements](https://developer.apple.com/help/app-store-connect/manage-agreements/sign-and-update-agreements/)).
  - BrowBro's notes say to sign the Paid Apps Agreement "even for a free app".
    Apple's help says otherwise; check the Business section once.
  - Agreements are per account. Whatever BrowBro's submission already accepted
    covers Huske.
- **EU Digital Services Act.**
  - Every account must declare trader or non-trader status. Apps without one
    have been removed from the EU storefronts since February 17, 2025.
  - A trader's address, phone and email are verified and **shown publicly** on
    EU product pages.
  - A non-commercial individual "may not be considered a trader"
    ([DSA trader requirements](https://developer.apple.com/help/app-store-connect/manage-compliance-information/manage-european-union-digital-services-act-trader-requirements/)).
  - This is account-level; BrowBro's submission may already have set it.
- **Identifiers.** Explicit App IDs for `cloud.tiagomoraes.huske.ios` and
  `cloud.tiagomoraes.huske.ios.LiveActivity`. The extension must be an
  immediate child of the app ID, which it is
  ([register an App ID](https://developer.apple.com/help/account/identifiers/register-an-app-id/)).
  Neither needs an App Group or other capabilities today. Live Activities need
  only `NSSupportsLiveActivities`, plus Push Notifications if updated by push.
- **The bundle ID is permanent after the first upload.** Universal purchase
  (one record for iOS and macOS) requires the *same* bundle ID on both
  platforms, and separate records "can't" be merged later
  ([add platforms](https://developer.apple.com/help/app-store-connect/create-an-app-record/add-platforms/)).
  The iPhone app (`…huske.ios`) and Huske.app (`…huske`) are already
  different. That only matters if a paid cross-platform purchase is ever
  wanted; for a free app, keep `cloud.tiagomoraes.huske.ios`.
- **Certificates and profiles.**
  - One **Apple Distribution** certificate covers iOS and macOS App Store
    submissions
    ([certificates](https://developer.apple.com/help/account/certificates/certificates-overview)).
    The team already has one from BrowBro; reuse it.
  - Two **App Store** provisioning profiles, one for the app and one for the
    extension
    ([create an App Store profile](https://developer.apple.com/help/account/provisioning-profiles/create-an-app-store-provisioning-profile/)).
- **API key.**
  - Huske's existing `APPLE_API_KEY_*` is a **Developer**-role key for
    notarization. Keep it as is.
  - Add a separate **App Manager** team key for uploads. With App Manager,
    BrowBro's manual-signing pattern works; cloud signing would need Admin.
  - Individual keys can't use provisioning or notary endpoints
    ([creating API keys](https://developer.apple.com/documentation/appstoreconnectapi/creating-api-keys-for-app-store-connect-api)).
- **SDK floor.**
  - Since April 28, 2026, uploads must be built with Xcode 26 and the iOS 26
    SDK.
  - **From April 2027, iOS apps must use the iOS 27 SDK** and target iOS 15+
    ([upcoming requirements](https://developer.apple.com/news/upcoming-requirements/)).
  - Build the iOS app with the newest **released** Xcode 27.x. The App Store
    accepts Xcode 27.2 since October 30
    ([release notes](https://developer.apple.com/help/app-store-connect/release-notes/)).
    Betas are refused (ITMS-90301).
- **Version and build numbers.**
  - `MARKETING_VERSION` comes from `pyproject.toml`, the repo's single source of
    truth. Each App Store submission needs a higher version than the last one,
    so an iOS-only fix means a repo patch release. That's acceptable; just
    don't hand-edit the iOS version.
  - `CFBundleVersion` must be unique and ascending within a version. CI should
    set it, and set `manageAppVersionAndBuildNumber = NO` in the export options
    ([CFBundleVersion](https://developer.apple.com/documentation/bundleresources/information-property-list/cfbundleversion)).
- **TestFlight.**
  - Up to 100 internal testers, with no review.
  - Up to 10,000 external testers. They need Beta App Review, but "A review is
    required only for the first build".
  - Builds last 90 days. External testing needs a beta description, a feedback
    email and contact details
    ([TestFlight overview](https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview/),
    [test information](https://developer.apple.com/help/app-store-connect/test-a-beta-version/provide-test-information/)).
- **Product page.**
  - Text limits: name 30 characters, subtitle 30, promotional text 170,
    description 4,000, keywords 100 bytes.
  - Required fields: support URL, privacy policy URL, category, copyright.
  - Screenshots: 1–10 per size, no alpha. App Store Connect scales down from the
    highest required size. The spec page contradicts itself on which iPhone
    size is required, so upload a 6.9" set (1320×2868) and a 6.3" set
    (1206×2622)
    ([screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/)).
    The `HuskeScreenshots` UI-test tour can produce them from demo data, never
    a real library.
  - The 1024 px icon is fine as it is: no alpha, single size. Icon Composer
    layered icons are optional.
- **Age rating.**
  - The new questionnaire (4+/9+/13+/16+/18+) must be answered.
  - The Shared Location and Dating descriptors added on November 16, 2026 are
    due by January 12, 2027 for every app
    ([set an age rating](https://developer.apple.com/help/app-store-connect/manage-app-information/set-an-app-age-rating/)).
  - Huske should come out **4+**.
- **Pricing and availability.** Free, in all 175 storefronts. Without a Paid Apps
  Agreement the app can only be free anyway.

### 3.6 CI: GitHub Actions or Xcode Cloud

**Recommendation: GitHub Actions**, a new `ios-app-store.yml` modelled on
BrowBro's `app-store.yml`.

Against Xcode Cloud:
- Apple warns that "Xcode Cloud requires a consistent Xcode project or
  workspace that's continuously present. If you use a third-party tool that
  dynamically generates … builds may fail"
  ([setting up Xcode Cloud](https://developer.apple.com/documentation/xcode/setting-up-your-project-to-use-xcode-cloud)).
  Huske's project is generated and git-ignored.
- The rest of Huske's release lives in GitHub Actions.
- Xcode Cloud's 25 free compute hours a month
  ([Xcode Cloud](https://developer.apple.com/xcode-cloud/)) don't outweigh
  either point.

Sketch, not implemented. It belongs to the plan's step 3:

- **Trigger:** `workflow_dispatch` (inputs: `ref`, `dry_run`), and later
  `release: published`. A manual run only appears once the file is on the
  default branch.
- **Runner:**
  - The `xcode-27` image, generally available since October 15, 2026, with
    Xcode 27.0–27.2
    ([changelog](https://github.blog/changelog/2026-10-15-xcode-27-runner-image-generally-available/),
    [image](https://github.com/actions/runner-images/blob/main/images/macos/xcode-27-arm64-Readme.md)).
  - Select the newest *released* 27.x, as `macos/scripts/select-xcode.sh`
    already does for 26.
- **Steps:**
  1. `brew install xcodegen`, then `ios/scripts/generate.sh`.
  2. Import the Apple Distribution `.p12` into a temporary keychain. Run
     `set-key-partition-list -S apple-tool:,apple:,codesign:`, or codesign hangs
     on a GUI prompt
     ([GitHub docs](https://docs.github.com/en/actions/how-tos/deploy/deploy-to-third-party-platforms/sign-xcode-applications)).
  3. Install both App Store profiles. Reject Xcode-managed ones and any with
     `ProvisionedDevices`.
  4. Build number = highest build in App Store Connect + 1. Use the App Store
     Connect API or fastlane's `latest_testflight_build_number`, as BrowBro
     does.
  5. Archive:

     ```bash
     xcodebuild archive -project ios/Huske.xcodeproj -scheme Huske \
       -configuration Release -destination 'generic/platform=iOS' \
       -archivePath "$ARCHIVE" DEVELOPMENT_TEAM=QD5A8CZK76 \
       CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="Apple Distribution" \
       CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
       OTHER_CODE_SIGN_FLAGS="--keychain $KEYCHAIN"
     ```

     The per-target profile specifiers are best set through an `xcconfig` or
     XcodeGen settings, not a global override.
  6. Write the export options:
     - `method app-store-connect`
     - `destination upload`
     - `signingStyle manual`
     - `provisioningProfiles` for both bundle IDs
     - `manageAppVersionAndBuildNumber NO`
     - `uploadSymbols YES`
  7. Export and upload:

     ```bash
     xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$OUT" \
       -exportOptionsPlist "$OPTS" -authenticationKeyPath "$P8" \
       -authenticationKeyID "$KEY_ID" -authenticationKeyIssuerID "$ISSUER"
     ```

     `altool --upload-app` and Transporter also remain supported for uploads
     ([upload builds](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds/)).
  8. In an `if: always()` step, delete the keychain and the `.p8`.
- **Secrets** (new, distinct from the notarization ones):
  - `IOS_DIST_CERT_P12`
  - `IOS_DIST_CERT_PASSWORD`
  - `IOS_PROFILE_APP`
  - `IOS_PROFILE_LIVEACTIVITY`
  - `ASC_KEY_ID`
  - `ASC_ISSUER_ID`
  - `ASC_KEY_P8` (App Manager)
- **Submitting:** by hand in App Store Connect for the first releases. Automate
  `submit_for_review` (fastlane `deliver`, or the App Store Connect API) only
  once the listing is stable.

---

## 4. Blockers, ranked

### Mac App Store

| # | Blocker | Severity |
|---|---|---|
| 1 | Today's app depends on an external engine. The sandbox can't execute it, and 2.4.5(ii)/(vii), 4.2.3(i) and DPLA 3.3.1(D) forbid it. | **Hard.** Changes the architecture. |
| 2 | The engine must be embedded: 1.2 GB, 396 Mach-O files to re-sign with sandbox + inherit, the CPython compliance patch, `.pyc` and code placement, trimming `torch`. | Major |
| 3 | Sync uses the `git` CLI and SSH, which can't run in the sandbox. It needs a GitHub-API (or libgit2) publisher, and the SSH-key option goes away. | Major |
| 4 | `multiprocessing` semaphores fail in the sandbox, and the ASR worker depends on them. | Major, unknown size |
| 5 | Paths: `~/huske` and `~/.config` become the container; a user folder needs a bookmark passed to the engine. Sockets exceed 104 bytes → app group. | Medium |
| 6 | Engine subprocesses (`/usr/bin/security`, `launchctl`, `ollama`, `afconvert`) and the in-app updaters must be replaced or removed. | Medium |
| 7 | Downloading arbitrary Hugging Face repos and converting fine-tunes is a 2.4.5(iv) risk. | Medium (policy) |
| 8 | TCC attribution of mic, system audio and Local Network for an inherited Python child. | Unknown, needs a spike |

### iOS App Store

| # | Blocker | Severity |
|---|---|---|
| 1 | No privacy policy or support page on the website; no privacy link in the app. | **Required** before submission |
| 2 | 4.2.3(i)/2.1 reading of a Mac companion. Needs the device video, precise notes, and a "get Huske for Mac" path in the unpaired state. | Medium (review risk) |
| 3 | Account items only the owner can do: agreements check, DSA status, age rating, App Privacy, review contact. | Required, owner-only |
| 4 | No App Store pipeline yet: App IDs, profiles, App Manager key, workflow. | Required, ~1–2 days |
| 5 | iOS 27 SDK required from April 2027. | Low if built on Xcode 27 from the start |
| 6 | Privacy manifests and the export-compliance key. | **Done on this branch** |

---

## 5. Options for the Mac

### A. Keep the Mac on Developer ID; ship only the iPhone app to the App Store (recommended)

- **Work:** none on the Mac. The iOS plan below.
- **Risks:**
  - The iPhone listing points to a Mac app outside the App Store. That's
    allowed. Word it as "Huske for Mac (free, huske.tiagomoraes.cloud)" and
    never make it a condition for using the iPhone app.
  - Review delays: iPhone releases trail Mac releases by a review cycle. The
    sync protocol's `capabilities` handshake already tolerates the two apps
    being at different versions (`sync-protocol.md`).
- **Users lose:** nothing.
- **Users can't:** find Huske for Mac in the Mac App Store. They still get it
  signed, notarized and auto-checked for updates from GitHub.

### B. Full Mac App Store edition with the engine bundled

- **Work (≈ 7–11 weeks, high uncertainty):**
  1. **Spike (1 week):** a sandboxed app whose embedded `python3` (sandbox +
     inherit) runs MLX inference, a Core Audio tap, the mic, a `multiprocessing`
     worker, and a Unix socket in an app group. Then a TestFlight build through
     App Store Connect validation. This either kills or confirms the option
     cheaply.
  2. **Packaging (2–3 weeks):**
     - A relocatable CPython 3.13 with the compliance patch
       (Python-Apple-support or python-build-standalone).
     - The wheel set: drop `torch`, `PyObjCTest` and anything unused.
     - Lay out the Mach-O files, precompile `.pyc`, and sign every binary
       inside-out with Apple Distribution.
     - An Xcode project (XcodeGen, like iOS) with a `HuskeMAS` scheme
       (`-D APPSTORE`).
  3. **Engine changes (2–3 weeks):**
     - Container-aware `paths.py`, with the output folder taken from a bookmark.
     - An app-group socket path.
     - Sandbox-safe semaphores, or no `multiprocessing.Queue`.
     - A GitHub-API publisher in place of `git`.
     - The Security framework in place of `/usr/bin/security`.
     - No LaunchAgent, no PyPI banner, no Ollama management.
     - Curated models only, with a size prompt.
  4. **App changes (1–2 weeks):**
     - No `BinaryLocator`, engine installer or update check in the MAS build.
     - A folder picker and bookmark handling.
     - Entitlements: sandbox, `network.client`/`server`, audio input,
       user-selected read-write, bookmarks, app group.
     - The engine exits when the app quits unless the user consented.
  5. **CI and review (1–2 weeks):** a MAS job next to `build-app`, listing,
     review notes, a demo video, and at least one review round.
- **Risks:**
  - Items 4 and 8 in §4 could be unsolvable or ugly.
  - App Review may question a 0.5–1 GB Python runtime, run-time Metal
    compilation, or the model catalog.
  - Every Mac release now ships twice (Developer ID and MAS) and waits for
    review.
  - TCC grants don't carry between the two channels.
  - Two editions on one Mac fight over `~/huske` versus the container.
- **Users of the MAS edition lose:**
  - the `huske` CLI (a sandbox + inherit binary can't run from Terminal);
  - SSH-key sync;
  - arbitrary Hugging Face models and "Convert and use";
  - Ollama management (connecting to a running Ollama still works);
  - the engine's LaunchAgent;
  - attaching to a `huske run` started in a terminal;
  - transcripts in `~/huske` by default, unless they pick a folder.

### C. A reduced, Swift-native Mac App Store edition

A small Mac app that:
- captures with AVAudioEngine and a Core Audio tap;
- transcribes with a Swift runtime: Apple's
  [SpeechAnalyzer](https://developer.apple.com/documentation/speech/speechanalyzer)
  on macOS 26+, which keeps model downloads inside the OS, or a Core ML/MLX
  Swift port of Parakeet or Whisper;
- writes the same transcript contract;
- receives iPhone recordings.

- **Work:** ≈ 8–14+ weeks to reach the basics, and **a second engine forever**.
  That is exactly what [ADR 0006](../adr/0006-native-macos-app.md) rejected:
  "every pipeline change … would need to land twice, and the two
  implementations would inevitably drift on the transcript contract."
- **Risks:**
  - Quality regressions against Parakeet/Whisper with AEC3. SpeechAnalyzer's
    quality and its Portuguese support are **not evaluated** here.
  - Product confusion between two Huskes.
- **Users lose:**
  - model choice;
  - echo cancellation as it is today;
  - distillation;
  - every LLM backend except Apple's;
  - Git sync, unless rebuilt;
  - diarization;
  - the CLI.

### D. A Mac App Store "shell" that requires the external engine

**Not viable.** Ruled out by the sandbox (no execute access outside the
bundle), 2.4.5(ii), 4.2.3(i) and DPLA 3.3.1(D). Listed only so nobody spends
time on it.

---

## 6. Plan for the iPhone app (option A)

Effort is focused work for one engineer; calendar time is in brackets.

**Step 0 — owner decisions and account (½ day) [owner]**
1. Decide go/no-go and the open questions in §8.
2. App Store Connect → Business:
   - confirm the agreements are active;
   - set the DSA trader status, if BrowBro hasn't already.
3. Draft or approve the privacy policy text and the support contact.

**Step 1 — code (1–2 days)**
1. *Done:* privacy manifests, `ITSAppUsesNonExemptEncryption`.
2. Add a link to the privacy policy in the app (Mac screen footer, or an
   About row). Guideline 5.1.1(i).
3. In the unpaired state, add a plain "Get Huske for Mac" link to the website,
   in the iPhone app's existing words ("Huske on your Mac transcribes…"). Make
   it never a gate.
4. Add one consent line the first time the user records ("Let people know when
   you record them"). Guideline 2.5.14, DPLA 3.3.3(A).
5. Test:
   - on an iPad in iPhone compatibility mode;
   - with Live Activities turned off;
   - with a recording longer than 8 hours (Live Activity cap);
   - with Local Network denied.
6. Keep the DEBUG demo mode out of Release (it already is).

**Step 2 — identifiers and signing (½ day) [owner clicks, agent scripts]**
1. Register the two App IDs. No extra capabilities.
2. Create two App Store provisioning profiles with the existing Apple
   Distribution certificate.
3. Create an App Manager team API key for Huske.
4. Add the secrets in §3.6.

**Step 3 — CI (1–2 days)**
1. Write `.github/workflows/ios-app-store.yml` (§3.6) and a
   `ios/scripts/verify-ios-archive.sh`. The script checks the manifests, the
   encryption key, the entitlements and the absence of DEBUG code.
2. Run a dry-run `workflow_dispatch` (`destination export`), then a real upload
   to TestFlight internal.

**Step 4 — website (½–1 day)**
1. Publish `/privacy`, covering:
   - nothing collected;
   - recordings travel only to the user's own Mac, encrypted with a key only
     the two devices hold;
   - the Mac app's optional cloud features (LLM cleanup with the user's own
     keys, Git sync to the user's repo), each opt-in.
2. Publish `/support` (GitHub issues + a contact email).
3. Use the site's design skills (`/frontend-design`, `/impeccable`) as usual.

**Step 5 — listing and review material (1–2 days)**
1. Write `ios/AppStore/listing.md` as the single source for the name, subtitle,
   description, keywords, promotional text and the **review notes**
   (BrowBro's pattern). The notes cover:
   - what works without a Mac;
   - what needs Huske for Mac (free, with a link);
   - why background audio, Local Network, camera and Live Activity;
   - the attached video;
   - that nothing leaves the user's devices.
2. Screenshots from the `HuskeScreenshots` tour with demo data, at 6.9" and
   6.3".
3. Shoot the review video on a physical iPhone and Mac: pair by QR, record,
   lock the screen, stop from the Live Activity, sync, then the transcript on
   both devices.
4. Fill in App Privacy ("Data Not Collected"), the age rating (4+), the
   category (Productivity), the price (Free) and availability. Turn off
   availability on Apple silicon Macs and Apple Vision Pro.

**Step 6 — TestFlight (≈ ½ day effort) [1 week calendar]**
1. Internal testing on the owner's devices.
2. Optionally, an external group. The first build goes through Beta App Review.

**Step 7 — submit (≈ ½ day) [days to 2 weeks calendar]**
1. Submit with manual release.
2. Budget one round of "Information Needed" or a 4.2/2.1 question. Answer in
   Resolution Center with the video and notes, as BrowBro had to.

**Total: ≈ 6–9 working days of effort, 2–4 weeks of calendar time.**

---

## 7. Effort summary

| Option | Effort | Calendar | Ongoing cost |
|---|---|---|---|
| iOS App Store (A) | 6–9 days | 2–4 weeks | A review per iPhone release; screenshots and notes kept current; yearly SDK bump |
| Mac B spike only | 1 week | 1–2 weeks | — (decides B) |
| Mac B full edition | 7–11 weeks | 3–4 months with review | Two Mac channels, a 0.5–1 GB bundle, a review per release, sandbox constraints on every engine feature |
| Mac C native edition | 8–14+ weeks | 4–6 months | A second engine forever (contradicts ADR 0006) |

---

## 8. Decisions for the owner

1. **iOS App Store: go?** Recommended: yes.
2. **Mac App Store:** confirm "not now" (option A), or fund the one-week
   option B spike first. Recommended: not now.
3. **DSA trader status** (account-wide). Trader means your address, phone and
   email are public on EU product pages. A free, MIT-licensed hobby app can
   reasonably be "not a trader", but it's your legal call.
4. **Bundle ID:** keep `cloud.tiagomoraes.huske.ios`. It becomes permanent on
   the first upload. Recommended: keep it.
5. **Price and storefronts:** free, everywhere? Recommended: yes. No French
   declaration is needed.
6. **Export compliance attestation:** you attest `NO`. See §3.4 for the
   reasoning.
7. **API key:** a new App Manager key for Huske (recommended), or reuse
   BrowBro's.
8. **Review contact:** the name, email and phone App Review sees. They are not
   public; keep them out of the repo, as BrowBro does.

---

## 9. Checklist: only the owner can do these

- [ ] App Store Connect → Business:
  - [ ] confirm the Program License Agreement (free apps) is accepted;
  - [ ] sign the Paid Apps Agreement plus tax and banking **only** if monetizing.
- [ ] Declare the EU DSA trader / non-trader status, if not already done.
- [ ] Approve the privacy policy text and the support contact. Publish both
      pages on the site.
- [ ] Register the App IDs, create the App Store profiles, create the App
      Manager API key. Add the GitHub secrets.
- [ ] Create the App Store Connect app record (name, SKU, primary language).
      Bundle ID `cloud.tiagomoraes.huske.ios`.
- [ ] Answer the App Privacy questionnaire, the age rating (including the
      January 12, 2027 descriptors) and the export compliance attestation.
- [ ] Set pricing (Free) and availability. Turn off Mac (Apple silicon) and
      Vision Pro availability.
- [ ] Enter the App Review contact details. Record and attach the
      physical-device video.
- [ ] Install TestFlight builds on your own iPhone and accept them. Press
      "Submit for Review" and "Release".

---

## Sources

App Review and agreements
- App Review Guidelines (Last Updated October 16, 2026): https://developer.apple.com/app-store/review/guidelines/
- Provide information for a complete review: https://developer.apple.com/help/app-review/before-submitting-for-review/complete-review
- 5.1.1 purpose strings: https://developer.apple.com/help/app-review/guideline-reference/5-1-1-purpose-strings
- Apple Developer Program License Agreement: https://developer.apple.com/support/terms/apple-developer-program-license-agreement/
- App Store review attachments (API): https://developer.apple.com/documentation/appstoreconnectapi/app-store-review-attachments

Mac sandbox and packaging
- App Sandbox: https://developer.apple.com/documentation/security/app-sandbox
- Embedding a helper tool in a sandboxed app: https://developer.apple.com/documentation/xcode/embedding-a-helper-tool-in-a-sandboxed-app
- Placing content in a bundle: https://developer.apple.com/documentation/bundleresources/placing-content-in-a-bundle
- Embedding nonstandard code structures in a bundle: https://developer.apple.com/documentation/xcode/embedding-nonstandard-code-structures-in-a-bundle
- Creating distribution-signed code for the Mac: https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac
- Accessing files from the macOS App Sandbox: https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox
- App Groups entitlement: https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.application-groups
- App Sandbox information in App Store Connect: https://developer.apple.com/help/app-store-connect/reference/app-uploads/app-sandbox-information/
- Capturing system audio with Core Audio taps: https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps
- Capturing screen content in macOS: https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-in-macos
- SMAppService: https://developer.apple.com/documentation/servicemanagement/smappservice
- Core ML, downloading and compiling a model: https://developer.apple.com/documentation/coreml/downloading-and-compiling-a-model-on-the-user-s-device
- Background Assets: https://developer.apple.com/documentation/backgroundassets
- Maximum build file sizes: https://developer.apple.com/help/app-store-connect/reference/app-uploads/maximum-build-file-sizes/
- DTS forum threads: [654579](https://developer.apple.com/forums/thread/654579), [685544](https://developer.apple.com/forums/thread/685544), [706112](https://developer.apple.com/forums/thread/706112), [706390](https://developer.apple.com/forums/thread/706390), [709333](https://developer.apple.com/forums/thread/709333), [721701](https://developer.apple.com/forums/thread/721701), [746478](https://developer.apple.com/forums/thread/746478), [762366](https://developer.apple.com/forums/thread/762366), [788364](https://developer.apple.com/forums/thread/788364)
- CPython `--with-app-store-compliance`: https://docs.python.org/3/using/configure.html
- BeeWare Python-Apple-support: https://github.com/beeware/Python-Apple-support ; Briefcase macOS: https://briefcase.beeware.org/en/latest/reference/platforms/macOS/

iOS capabilities and privacy
- AVAudioSession.Category.record: https://developer.apple.com/documentation/avfaudio/avaudiosession/category-swift.struct/record
- AudioRecordingIntent: https://developer.apple.com/documentation/appintents/audiorecordingintent
- TN3179 Understanding local network privacy: https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy
- TN3151 Choosing the right networking API: https://developer.apple.com/documentation/technotes/tn3151-choosing-the-right-networking-api
- HIG, Live Activities: https://developer.apple.com/design/human-interface-guidelines/live-activities
- Privacy manifest files: https://developer.apple.com/documentation/bundleresources/privacy-manifest-files
- Describing use of required reason API: https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api
- TN3183: https://developer.apple.com/documentation/technotes/tn3183-adding-required-reason-api-entries-to-your-privacy-manifest
- App privacy details: https://developer.apple.com/app-store/app-privacy-details/

Export compliance
- ITSAppUsesNonExemptEncryption: https://developer.apple.com/documentation/bundleresources/information-property-list/itsappusesnonexemptencryption
- Complying with encryption export regulations: https://developer.apple.com/documentation/security/complying-with-encryption-export-regulations
- Export compliance documentation for encryption: https://developer.apple.com/help/app-store-connect/reference/app-information/export-compliance-documentation-for-encryption
- Overview of export compliance: https://developer.apple.com/help/app-store-connect/manage-app-information/overview-of-export-compliance
- EAR §740.17: https://www.ecfr.gov/current/title-15/subtitle-B/chapter-VII/subchapter-C/part-740/section-740.17

App Store Connect setup and CI
- Upcoming requirements: https://developer.apple.com/news/upcoming-requirements/
- App Store Connect release notes: https://developer.apple.com/help/app-store-connect/release-notes/
- Sign and update agreements: https://developer.apple.com/help/app-store-connect/manage-agreements/sign-and-update-agreements/
- DSA trader requirements: https://developer.apple.com/help/app-store-connect/manage-compliance-information/manage-european-union-digital-services-act-trader-requirements/
- Register an App ID: https://developer.apple.com/help/account/identifiers/register-an-app-id/
- Add platforms (universal purchase): https://developer.apple.com/help/app-store-connect/create-an-app-record/add-platforms/
- Certificates overview: https://developer.apple.com/help/account/certificates/certificates-overview
- Create an App Store provisioning profile: https://developer.apple.com/help/account/provisioning-profiles/create-an-app-store-provisioning-profile/
- Creating API keys: https://developer.apple.com/documentation/appstoreconnectapi/creating-api-keys-for-app-store-connect-api
- Role permissions: https://developer.apple.com/help/app-store-connect/reference/account-management/role-permissions/
- Upload builds: https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds/
- TestFlight overview: https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview/
- Provide test information: https://developer.apple.com/help/app-store-connect/test-a-beta-version/provide-test-information/
- Screenshot specifications: https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/
- App information (URLs, limits): https://developer.apple.com/help/app-store-connect/reference/app-information/app-information/
- Set an age rating: https://developer.apple.com/help/app-store-connect/manage-app-information/set-an-app-age-rating/
- Setting up your project to use Xcode Cloud: https://developer.apple.com/documentation/xcode/setting-up-your-project-to-use-xcode-cloud
- Xcode Cloud: https://developer.apple.com/xcode-cloud/
- GitHub: installing an Apple certificate on macOS runners: https://docs.github.com/en/actions/how-tos/deploy/deploy-to-third-party-platforms/sign-xcode-applications
- GitHub runner images (xcode-27): https://github.com/actions/runner-images/blob/main/images/macos/xcode-27-arm64-Readme.md
