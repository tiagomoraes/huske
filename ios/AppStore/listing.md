# Huske for iPhone: App Store listing

The single source for the App Store product page and the App Review notes.
Paste from here into App Store Connect, and change it here first. Limits are
App Store Connect's. Never put review contact details (phone, email) in this
file: the repository is public.

Plan and reasoning: [`docs/research/app-store-distribution.md`](../../docs/research/app-store-distribution.md).

## App information

| Field | Value |
|---|---|
| Name (30) | Huske for iPhone ("Huske" is taken; the home screen still says Huske) |
| Subtitle (30) | Record here, transcribe on Mac |
| Bundle ID | `cloud.tiagomoraes.huske.ios` |
| SKU | `huske-ios` |
| Apple ID | 6838172707 (https://apps.apple.com/app/id6838172707) |
| Primary language | English (U.S.) |
| Primary category | Productivity |
| Secondary category | Utilities |
| Content rights | No third-party content |
| Age rating | 4+ (every questionnaire answer is "None" or "No") |
| Price | Free |
| Availability | All storefronts except China mainland (which requires an ICP filing and AIGC/security declarations). Off for Apple silicon Macs and Apple Vision Pro. |
| Copyright | 2026 Tiago Moraes |
| Support URL | https://huske.tiagomoraes.cloud/support/ |
| Marketing URL | https://huske.tiagomoraes.cloud/ |
| Privacy Policy URL | https://huske.tiagomoraes.cloud/privacy/ |

The support and privacy pages must be live on the site before the first
submission (guideline 2.1(a): "fully functional URLs").

## App Privacy

**Data Not Collected.** Recordings go peer to peer to the user's own Mac,
never to the developer. There are no analytics, crash-reporting SDKs or
servers. Apple's definition of "collect" is data the developer or its
partners can access off the device. Revisit this if that ever changes.

## Promotional text (170)

Record on your iPhone, and your own Mac transcribes it and sends the words back. No cloud, no account.

## Description (4000)

Huske is a voice recorder whose recordings go straight to your own Mac, where Huske transcribes them. There's no cloud and no account. The transcript comes back to your iPhone when the Mac is done.

Record anywhere
• Keeps recording with the screen locked. A Live Activity on the Lock Screen and in the Dynamic Island shows the time, with Pause and Stop.
• Start and stop from the Action button or Control Center without opening the app.
• Siri and Shortcuts can start, pause and stop a recording, and get your latest transcript.
• Play back and share recordings, and copy or share transcripts.

Transcribed on your Mac
• Pair once with the QR code that Huske for Mac shows. Huske for Mac is free at huske.tiagomoraes.cloud.
• Recordings travel over your Wi‑Fi, or directly between the two devices when the phone isn't on a network. They're encrypted with a key that only your two devices hold.
• Your Mac transcribes on the device, and the text appears on the phone, ready to copy.

Private by design
• No account, no analytics, no tracking. Nothing goes to a server.
• Open source under the MIT license.

Huske for iPhone needs iOS 18 or later. Transcription needs Huske running on a Mac with Apple silicon and macOS 14 or later.

Let people know before you record them.

## Keywords (100 bytes)

transcribe,transcription,recorder,voice notes,meeting,dictation,mac,offline,private,audio,notes

## Screenshots

From the `HuskeScreenshots` UI-test tour with demo data. Every conversation
in it is made up, and no real library or Mac name may appear. Upload one 6.9"
set (1320×2868) and one 6.3" set (1206×2622).

1. Recording, with earlier recordings on their way to the Mac.
2. A transcript back on the phone.
3. The Live Activity on the Lock Screen.
4. The Dynamic Island.
5. The library, with each recording's sync state.

## App Review notes (4000 bytes)

> Huske for iPhone is a voice recorder. Each recording is sent directly, over the local network or peer to peer, to the user's own Mac running Huske for Mac. Huske for Mac is free and open source, and is a signed and notarized download at https://huske.tiagomoraes.cloud. The Mac transcribes the recording on the device and sends the transcript back to the phone.
>
> Testing without a Mac: everything on the phone works on its own. That covers recording (also with the screen locked, with a Live Activity and Pause/Stop), the "Huske Record" control for the Action button and Control Center, Siri and Shortcuts actions, playback and sharing. Without a paired Mac, recordings wait as "Waiting for Mac".
>
> Pairing and transcription need a Mac. The attached video shows them on a physical iPhone and Mac: pairing by QR code, recording, sending, and the transcript arriving on the phone. A pairing code is created by the Mac app and works once, for ten minutes, so a static sample code can't be provided. To pair yourself, install Huske for Mac on a Mac with Apple silicon (macOS 14+), open its iPhone pane and choose Pair iPhone.
>
> Permissions:
> - Microphone: to record.
> - Camera: only to scan the pairing QR code that the Mac app shows.
> - Local Network: to find the paired Mac over Bonjour (`_huske-sync._tcp`) and send recordings to it directly.
>
> Background modes:
> - audio: keeps an active recording going while the phone is locked (AVAudioSession record).
> - fetch and processing: finish sending completed recordings to the paired Mac.
>
> The Live Activity shows the recording in progress, as AudioRecordingIntent requires for recordings started from the Action button.
>
> There are no accounts, no servers and no data collection. Encryption is only Apple's: Network.framework TLS with a pre-shared key, and CryptoKit.

## Review video (attach in App Review Information)

Shot on a physical iPhone and a physical Mac, filmed, not a screen recording,
as App Review asks for apps with required hardware. It uses no real
recordings, Mac names or people. Keep it about two minutes.

1. Huske for Mac open on the iPhone pane: choose Pair iPhone, and the QR code appears.
2. The iPhone camera scans it, Huske opens, and Pair is pressed. Both apps show the pairing.
3. Record about 20 seconds of speech. Lock the phone and show the Live Activity. Stop from it.
4. Unlock: the recording shows Sending, then Transcribing.
5. On the Mac the transcript appears. On the phone the transcript arrives and Copy works.
6. The Action button (or Control Center) starts and stops a recording without opening the app.
