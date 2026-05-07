# Feature Specification: Huske — Always-On Terminal Audio Recorder & Transcriber

**Feature Branch**: `001-huske-recorder`
**Created**: 2026-05-07
**Status**: Draft
**Input**: Build a terminal app named `huske` that continuously records microphone and system audio, transcribes it locally with a Whisper-class model, splits work into configurable chunks, and writes organized Markdown transcripts for later LLM-assisted review.

## Overview

**Huske** ("remember" in Norwegian) is a terminal application that continuously captures the user's microphone and computer system audio while it is running, splits the audio into fixed-duration chunks (default: 15 minutes), transcribes each chunk locally using a Whisper-class speech-to-text model, and writes the resulting text to a structured directory tree organized by day. The intent is to produce a personal, machine-readable record of the user's spoken activity throughout the day that a downstream LLM agent can later query, summarize, and act on (e.g., creating todos, scheduling follow-ups). This first version delivers only the capture + transcription + filesystem-output loop; LLM consumption is intentionally out of scope.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Always-On Capture That Yields Transcripts (Priority: P1)

A knowledge worker starts huske from the terminal in the morning before beginning their day. The app records microphone and system audio continuously and, every 15 minutes, finalizes the current audio chunk, transcribes it locally, and writes the transcript to disk. Recording continues uninterrupted into the next chunk. At the end of the day, the user stops huske and finds a complete written record of everything that was said into the mic and played from the computer.

**Why this priority**: This is the core value loop of the product. Without continuous capture and reliable periodic transcription delivery, no other feature has any value. This is the MVP.

**Independent Test**: Run huske on a quiet machine for ~17 minutes while occasionally speaking. Confirm that at the ~15-minute mark a new transcript file appears in the configured output directory containing the spoken text, and that recording continues into a second chunk without gaps.

**Acceptance Scenarios**:

1. **Given** huske is started in the terminal, **When** the user speaks for the first 15 minutes of operation, **Then** at the end of that 15-minute chunk a transcript file is created and recording for the next chunk has already begun.
2. **Given** huske has been running for 32 minutes, **When** the user inspects the output directory, **Then** at least two finalized transcript files are present and a third chunk is in progress.
3. **Given** huske is recording, **When** audio plays from another application on the same computer, **Then** that audio is captured and reflected in the next transcript.
4. **Given** huske is recording, **When** the user issues a graceful stop (e.g., Ctrl+C or a quit command), **Then** the in-progress chunk — even if shorter than 15 minutes — is finalized, transcribed, and saved before the process exits.

---

### User Story 2 - Organized Daily Knowledge Base on Disk (Priority: P2)

A user who has been running huske for several days wants to find the transcript covering a specific time window. They navigate the output directory and see one folder per day. Inside each day's folder, transcript files are named in chronological order with clear time labels, making it trivial to locate the chunk that covers any given moment. Each transcript file includes enough metadata (date, start time, end time) at the top to be self-describing if opened standalone or read by an external tool.

**Why this priority**: Without this structure, transcripts become an unsorted dump that defeats the "knowledge base" purpose and prevents downstream LLM agents from selectively loading relevant context. This is required for the product to be useful beyond the first day, but the underlying capture loop (US1) can be demonstrated without it.

**Independent Test**: Run huske across two distinct calendar days (or simulate by changing system clock). Confirm two day-folders exist, each containing chunk files whose names sort chronologically and whose metadata headers correctly identify the day and time window covered.

**Acceptance Scenarios**:

1. **Given** transcripts have been produced over multiple days, **When** the user lists the output directory, **Then** there is one subdirectory per calendar day named in a sortable date format.
2. **Given** several chunks were transcribed within the same day, **When** the user lists that day's folder, **Then** files are named so that lexicographic sort matches chronological order, and the filename includes the chunk's start time.
3. **Given** an external program opens a single transcript file, **When** it reads the file, **Then** the file content begins with metadata identifying the date, start time, end time, and chunk duration before the transcribed text body.

---

### User Story 3 - Live Terminal UI Showing Recording Status (Priority: P3)

While huske is running, the user keeps the terminal visible and can see at a glance: that recording is active, how long the current chunk has been running, when the next transcription will fire, audio input level indicators, the path of the most recently saved transcript, and any errors or warnings. The interface is visually pleasant — not a raw log scroll — and updates in place.

**Why this priority**: Improves trust ("is it actually recording?") and discoverability, but the underlying capture and transcription loop (US1+US2) functions correctly without it. A user could verify operation by watching the output directory; the UI makes that unnecessary.

**Independent Test**: Start huske and observe the terminal. Confirm that within a few seconds a status display appears showing recording state and a countdown to the next chunk boundary, and that the display updates continuously without scrolling artifacts. After a chunk is saved, the "last saved transcript" indicator should update.

**Acceptance Scenarios**:

1. **Given** huske is running, **When** the user looks at the terminal, **Then** a status panel shows that recording is active and a countdown to the next chunk boundary that decreases in real time.
2. **Given** a chunk has just been transcribed and saved, **When** the user looks at the terminal, **Then** the most recently saved transcript path is shown and the chunk counter has incremented.
3. **Given** an audio device error occurs (e.g., microphone disconnected), **When** the user looks at the terminal, **Then** a clear, non-fatal warning is displayed and the panel reflects the degraded state.

---

### Edge Cases

- **Graceful shutdown mid-chunk**: User stops huske 6 minutes into a 15-minute chunk. The partial chunk MUST be finalized, transcribed, and saved with metadata that accurately reflects its shorter duration.
- **Hard kill / crash**: Process is killed abruptly (SIGKILL, power loss). On next start, huske MUST detect any orphaned audio fragments from the prior run and either recover/transcribe them or move them to a clearly-labeled "incomplete" location — never silently delete unsaved audio.
- **Long transcription overrun**: Whisper takes longer than 15 minutes to transcribe a chunk on a slow machine. Recording of the next chunk MUST NOT be blocked or interrupted; transcription jobs are queued and processed without dropping audio.
- **Disk full / write failure**: If the output directory is full or unwritable, huske MUST surface a clear error in the UI, retain the audio data needed to complete unwritten transcripts, and continue trying — it MUST NOT silently lose recorded audio.
- **No audio input available**: If neither the microphone nor the system audio source is available at startup, huske MUST refuse to start with a clear message rather than recording silence indefinitely.
- **Audio device disconnect mid-session**: Microphone unplugged or system audio capture fails partway through a chunk. Huske MUST log the gap, continue with whatever sources remain available, and reflect the degradation in the UI.
- **Long silence**: A chunk contains only silence (or mostly silence). The transcript file is still produced (so the time window is accounted for), but its body MAY note that no speech was detected.
- **System sleep / suspend**: Laptop is closed mid-chunk. On resume, huske MUST detect the gap, finalize the pre-sleep portion as its own (shorter) chunk if substantive audio was captured, and start a fresh chunk after wake.
- **Same-minute rapid restart**: User stops and immediately restarts huske within seconds. New transcripts MUST NOT overwrite the previous run's final chunk; filenames disambiguate.

## Requirements *(mandatory)*

### Functional Requirements

#### Capture
- **FR-001**: System MUST continuously capture audio from the user's microphone while huske is running.
- **FR-002**: System MUST continuously capture audio from the computer's system output (audio played by other applications) while huske is running.
- **FR-003**: System MUST capture both sources concurrently into a single combined audio stream per chunk for transcription, without dropping audio at chunk boundaries.
- **FR-004**: System MUST refuse to start if no usable audio input source is available, and surface a clear actionable error.

#### Chunking
- **FR-005**: System MUST segment captured audio into fixed-duration chunks with a default duration of 15 minutes.
- **FR-006**: System MUST allow the user to configure the chunk duration before starting a session.
- **FR-007**: System MUST close each chunk at the configured boundary and immediately begin a new chunk with no perceptible gap in capture.
- **FR-008**: When huske is shut down gracefully mid-chunk, system MUST finalize the partial chunk and submit it for transcription before exiting.

#### Transcription
- **FR-009**: System MUST transcribe each finalized audio chunk using a locally-running speech-to-text model (Whisper-class), without sending audio to any remote service.
- **FR-010**: Transcription MUST run asynchronously to capture, so that a slow transcription run never blocks recording of subsequent chunks.
- **FR-011**: System MUST produce one transcript file per audio chunk.
- **FR-012**: If transcription of a chunk fails, system MUST retain the source audio for that chunk in a recoverable location, surface a clear error, and continue capturing.

#### Output Layout
- **FR-013**: System MUST write transcript files into a configurable output directory; the default location MUST be a stable, predictable path under the user's home directory.
- **FR-014**: System MUST organize transcripts into one subdirectory per calendar day, named in a sortable date format (e.g., `YYYY-MM-DD`).
- **FR-015**: Each transcript filename MUST include the chunk's start time in a sortable format such that lexicographic order equals chronological order.
- **FR-016**: Each transcript file MUST begin with a metadata header identifying at minimum: calendar date, chunk start time, chunk end time, chunk duration, and the run/session it belongs to.
- **FR-017**: When two chunks would otherwise produce the same filename (e.g., rapid restart), system MUST disambiguate filenames so no transcript is overwritten.
- **FR-018**: The output directory layout MUST be plain files in a documented structure that an external LLM agent can read without bespoke tooling.

#### Terminal Interface
- **FR-019**: System MUST present a non-scrolling status display in the terminal while running, showing at minimum: recording state, elapsed time in current chunk, countdown to next chunk boundary, and path of the most recently saved transcript.
- **FR-020**: System MUST visibly indicate when a transcription is in progress and when one has just completed.
- **FR-021**: System MUST allow the user to stop huske from the terminal via a documented input (e.g., Ctrl+C or a key/command), triggering graceful shutdown per FR-008.
- **FR-022**: Errors and warnings MUST be surfaced in the UI in a way that does not destroy the existing layout, and MUST distinguish recoverable warnings from fatal errors.

#### Resilience
- **FR-023**: If a previous huske run terminated abnormally and left orphaned audio fragments, on next startup the system MUST either complete their transcription or move them to a clearly-labeled "incomplete" location — it MUST NOT silently delete them.
- **FR-024**: System MUST continue functioning across system sleep/wake cycles, finalizing the pre-sleep audio as its own chunk when appropriate and resuming capture after wake.

### Key Entities

- **Recording Session**: A single uninterrupted run of huske from start to graceful stop. Has a unique session identifier used to disambiguate output and group transcripts produced in the same run.
- **Audio Chunk**: A fixed-duration (default 15 min) slice of captured audio bounded by chunk boundaries or session start/end. Has a start time, end time, actual duration, source mix (mic + system), and a status (capturing → finalized → transcribing → transcribed | failed).
- **Transcript**: The textual output of a successfully transcribed chunk. Carries metadata (date, start/end time, duration, session ID) plus the text body. Stored as a single file in the day's folder.
- **Day Folder**: A subdirectory grouping all transcripts whose chunk start time falls on a single calendar date.
- **Output Root**: The configurable top-level directory under which all day folders live. Must be a stable filesystem path that a downstream LLM agent can be pointed at.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A user who runs huske continuously for an 8-hour workday ends the day with a complete set of transcript files covering every minute of that workday — there are no time gaps in the transcript record other than ones explicitly attributable to system sleep or audio device unavailability, both of which are visibly reflected in the metadata.
- **SC-002**: After each 15-minute chunk boundary, the corresponding transcript file is available on disk within 2 minutes on a typical modern laptop, even while huske continues recording the next chunk uninterrupted.
- **SC-003**: A user can locate the transcript covering any specific minute of a past day in under 15 seconds, using only a standard file browser, by navigating day folder → time-labeled file.
- **SC-004**: An external LLM agent pointed at the output root and given no bespoke parsing logic — only the documented file layout — can correctly identify which transcript files cover a user-specified date and time range with 100% accuracy.
- **SC-005**: At least 95% of audio chunks captured during normal operation (no device disconnects, sufficient disk space) are successfully transcribed and written to disk on the first attempt.
- **SC-006**: A user starting huske for the first time can begin recording and produce their first transcript file without consulting documentation beyond the in-terminal display, within 2 minutes of launching the binary.
- **SC-007**: When huske is stopped mid-chunk, the partial chunk's transcript is on disk within 90 seconds of the stop signal, with metadata accurately reflecting the shorter duration.
- **SC-008**: Across a 4-hour continuous run, huske produces zero unrecoverable audio loss events — every second of audio that was captured is either transcribed or, if transcription fails, retained in source form for retry.

## Assumptions

- **Single-user, single-machine, personal use**: Huske is built for one user recording on their own machine for their own knowledge base. Multi-user, networked, or shared-recording scenarios are out of scope.
- **Local-only processing**: All audio processing and transcription happens on the user's machine. No audio or transcript data leaves the device. (This is a hard requirement implied by the brief, treated as an assumption-of-record here.)
- **Recording consent is the user's responsibility**: Capturing system audio may incidentally include other parties' voices (e.g., participants in a video call). Compliance with applicable recording-consent laws is the user's responsibility, not enforced by the app.
- **Mic + system audio mixed, not separated**: For v1, the two sources are mixed into a single stream before transcription. Speaker diarization and per-source channels are out of scope.
- **Language handled by the underlying model**: Language detection and multi-language support are inherited from the chosen Whisper-class model with sensible defaults; explicit per-session language configuration is not required for v1.
- **Default chunk duration is 15 minutes**, configurable. Reasonable bounds (e.g., 1–60 minutes) apply.
- **Default output root is a predictable path under `$HOME`** (e.g., `~/huske/transcripts/`), configurable at startup. The path is documented so it can be passed to a downstream LLM agent (e.g., Claude Code) in a follow-up integration.
- **Raw audio is deleted after a chunk is successfully transcribed** to bound disk usage, unless the user opts in to retention. Audio for failed-transcription chunks is retained until retried.
- **LLM integration is out of scope for v1**: Querying the transcripts via an LLM, creating Todoist tasks via MCP, scheduling, etc. are explicitly future work. v1 must produce a structured output that *enables* such integrations, not implement them.
- **Target platform is macOS 13 (Ventura) or newer on Apple Silicon**. System-audio capture uses Apple's ScreenCaptureKit framework directly — no virtual audio driver (BlackHole), no Aggregate Device, no Audio MIDI Setup. The user grants Screen Recording permission on first launch and never thinks about it again.
- **Configuration is provided via CLI flags or a small config file** read at startup. Live reconfiguration mid-session is not required for v1.
