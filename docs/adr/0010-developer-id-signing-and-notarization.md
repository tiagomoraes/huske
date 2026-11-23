---
status: accepted
date: 2026-09-16
relates-to: [0006, 0007]
---

# Developer ID signing and notarization for Huske.app

## Context

ADR 0006 shipped Huske.app ad-hoc signed and said so in as many words:
"Distribution is source-build for now (ad-hoc codesign). Signed/notarized
distribution is a separate, later decision." This is that decision.

Two costs have accumulated since.

**Gatekeeper.** `Huske.app.zip` is the download button on the website, and an
ad-hoc bundle has no usable signature, so macOS refuses the first open outright.
The site currently ships the workaround as copy — "macOS blocks the first open
because the build isn't notarized … System Settings → Privacy & Security →
**Open Anyway**". That is a bad first impression for an app whose entire pitch
is that your audio never leaves the machine.

**TCC identity.** The subtler cost. An ad-hoc signature has no team identifier
and its cdhash changes on every build, so the microphone and screen-recording
grants the user gives version *N* do not carry to version *N+1*. Every update
re-prompts. A Developer ID signature gives the bundle a stable designated
requirement, which is what TCC keys the grant to.

The constraint that shapes the entitlements is the architecture from ADR 0006:
**the app is a supervisor, not a recorder.** It embeds no Python, opens no audio
device, and touches no capture API. It spawns the separately installed `huske`
CLI (uv, Homebrew, or a user path — always outside the bundle, always signed by
somebody else) and talks to it over a Unix control socket. The engine is what
opens the microphone and the Core Audio process tap.

## Decision

Sign with **Developer ID Application**, enable the **hardened runtime** with a
**secure timestamp**, **notarize**, **staple the .app**, and keep shipping a
zip named `Huske.app.zip`.

### Entitlements: exactly one

`macos/Huske.entitlements` declares `com.apple.security.device.audio-input`
and nothing else.

That looks wrong at first glance — the app never opens an audio device. It is
required because of *who TCC holds responsible*. When Huske.app spawns the
engine, TCC attributes the engine's microphone access to its responsible
process, which is the app; that attribution is the whole reason ADR 0006
called the app-spawned prompt "friendlier than terminal-level grants". Under
the hardened runtime, TCC then demands the entitlement **on the responsible
binary** — and when it is missing it does not prompt and fall back to a denial
the user can fix in System Settings. It returns `authValue=0`, shows no dialog,
and hands the caller silence. The usage-description string is necessary and not
sufficient once `--options runtime` is on. This is a well-documented trap for
supervisor-shaped apps; OrbStack shipped exactly this bug
([orbstack#2546](https://github.com/orbstack/orbstack/issues/2546)), and Apple
DTS has walked developers through the same failure on the forums
([thread 741303](https://developer.apple.com/forums/thread/741303)).

Everything else was considered and rejected:

- **Spawning the external, differently-signed engine needs no entitlement.**
  Library validation restricts what is loaded *into* this process's address
  space; `posix_spawn` creates a new process that is judged on its own
  signature. `com.apple.security.cs.disable-library-validation` would be
  cargo-cult here — and it is the one exception that weakens the runtime most.
  Verified: a binary signed with these exact flags execs the engine, whose
  interpreter is `adhoc,linker-signed`, and reads its output.
- **System audio is TCC-only, with no entitlement to declare.** The engine
  prefers `AudioHardwareCreateProcessTap` (macOS 14.4+) and falls back to
  ScreenCaptureKit. Both are gated by consent alone —
  `NSAudioCaptureUsageDescription` and Screen Recording — and both purpose
  strings are already in the generated `Info.plist`.
- **No JIT, unsigned executable memory, DYLD environment, or executable page
  protection exceptions.** The app loads no foreign code. The IBM Plex fonts
  are registered as *data* through `CTFontManagerRegisterFontsForURL`.
- **No Apple Events entitlement.** Reveal-in-Finder and open-with go through
  `NSWorkspace`, not AppleScript.
- **No App Sandbox.** Not shipping through the Mac App Store, and a sandbox is
  incompatible with the product: the app has to exec an arbitrary
  user-installed binary and read a transcript root the user chose.
- **Not `com.apple.security.device.microphone`.** That is the App Sandbox-era
  alias. `audio-input` is the key TCC names in its denial under the hardened
  runtime, and one key that works beats two that might.

The entitlements plist deliberately carries no XML comments: Apple DTS has
attributed misplaced entitlements to comments in the file passed to `codesign`.
The justification lives in this ADR instead.

### Dev builds are signed the same way

`macos/scripts/build-app.sh` applies the hardened runtime and the same
entitlements whether it finds a Developer ID identity or falls back to ad-hoc.
Only the secure timestamp is conditional, because ad-hoc cannot have one.

The point is fidelity. The audio-input entitlement is only load-bearing
*under* `--options runtime`; if local builds ran without it, the one failure
mode this ADR exists to prevent would be invisible until it shipped.

### Inside-out, never `--deep`

The bundle has one nested bundle (`Huske_Huske.bundle`, the fonts). The script
seals nested code first and the app last, walking the nests itself. Apple
deprecated `--deep` for signing, and it would also copy the app's entitlements
onto everything it touched.

### Zip, not DMG

The notarization ticket staples to the **bundle**, not to an archive, so the
release order is zip → submit → staple the `.app` → re-zip. A DMG would let the
ticket be stapled to the container instead, but it would change the asset name
the website's download button depends on and add a step that buys nothing for a
single-bundle app.

### CI degrades to unsigned rather than failing

The `build-app` job signs and notarizes when its secrets exist and produces the
same ad-hoc asset when they do not. A fork, and this repository before the
credentials were added, must still cut a release.

## Consequences

- **One last re-prompt.** Changing the code identity from ad-hoc to Developer
  ID invalidates the existing microphone and screen-recording grants; users are
  asked once more after upgrading. From then on grants survive updates, which
  is the point.
- **The "Open Anyway" copy on the website and in the docs can be retired** once
  a notarized build ships. `spctl -a -t exec` goes from `rejected` to
  `accepted (source=Notarized Developer ID)`.
- **Releases get slower and gain a network dependency.** Notarization is a
  round trip to Apple measured in minutes, and it can reject. The failure is
  debuggable: `macos/scripts/notarize-app.sh` prints `xcrun notarytool log` for
  the submission before exiting non-zero.
- **Graceful degradation can hide a misconfiguration.** If a secret is deleted
  or a certificate expires, the release ships unsigned instead of failing loud.
  That trade is accepted deliberately — a broken release is worse than an
  unsigned one — but it makes verifying the published asset a release step, not
  an optional one. See `docs/RELEASE_PLAYBOOK.md`.
- **Two credentials now have expiry dates.** The Developer ID Application
  certificate (five years) and the App Store Connect API key. Both live only as
  GitHub secrets and in the owner's keychain; neither is in the repository.
- **Contributors are unaffected.** With no certificate on the machine,
  `build-app.sh` silently signs ad-hoc exactly as it did before.
