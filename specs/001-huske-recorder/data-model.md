# Phase 1 — Data Model: Huske

**Date**: 2026-05-07
**Branch**: `001-huske-recorder`
**Source**: `spec.md` § Key Entities, Functional Requirements

The application is filesystem-backed; "data model" here means the in-memory dataclasses used by the running process and the on-disk artifacts they produce. There is no database.

---

## Entity overview

```text
RecordingSession 1───* AudioChunk 1───0..1 Transcript
       │
       └── owns ──> RuntimeConfig (immutable for the session)
```

---

## 1. `RecordingSession`

**Purpose**: A single uninterrupted run of `huske`. Acts as the orchestrator and the unit of session-lock-file ownership.

**Fields**:

| Field | Type | Notes |
|---|---|---|
| `session_id` | `str` | `YYYYMMDDTHHmmss_<rand4>` (e.g., `20260507T090000_8a3f`). Sortable; unique per run. |
| `started_at` | `datetime` (tz-aware, local) | Set at `__init__`. |
| `ended_at` | `datetime \| None` | Set on graceful shutdown; `None` while running. |
| `config` | `RuntimeConfig` | Frozen snapshot of resolved configuration (see §4). |
| `chunks` | `list[AudioChunk]` | In-order list; in-flight chunk is `chunks[-1]` while running. |
| `state` | `Literal["starting","recording","stopping","stopped","failed"]` | See state diagram. |
| `lock_path` | `Path` | `~/huske/audio/<session_id>/.lock`, created at start with current PID. |
| `output_root` | `Path` | Resolved transcript root. |
| `audio_root` | `Path` | Resolved transient audio root: `~/huske/audio/<session_id>/`. |

**Invariants**:
- Exactly one chunk has `state == "capturing"` while `RecordingSession.state == "recording"`.
- `session_id` is the source of truth for filename uniqueness across runs (FR-017).
- Lock file is removed on graceful shutdown; its presence + dead PID flags a recovery candidate (FR-023).

**State transitions**:

```
starting ──validate devices──▶ recording ──stop signal──▶ stopping ──flush queue──▶ stopped
   │                                │                                                   ▲
   └──fatal error──▶ failed◀────────┴── unrecoverable error ─────────────────────────────┘
```

---

## 2. `AudioChunk`

**Purpose**: One time-bounded slice of captured audio. The unit of work passed to the transcription worker.

**Fields**:

| Field | Type | Notes |
|---|---|---|
| `chunk_seq` | `int` | Monotonic per-session, starting at 1. |
| `session_id` | `str` | Foreign key to the parent `RecordingSession`. |
| `start_time` | `datetime` (tz-aware) | Wall-clock at first captured frame. |
| `end_time` | `datetime \| None` | Wall-clock at last captured frame; set when chunk closes. |
| `expected_duration_seconds` | `int` | From config (default 900). |
| `actual_duration_seconds` | `float \| None` | Set on close; equals `expected_*` for normal rotation, less for graceful-stop / sleep-truncation. |
| `gap_seconds` | `float` | 0 if continuous; >0 if a sleep/disconnect gap was detected mid-chunk. |
| `audio_path` | `Path` | Primary (first source's) WAV path; mirrors one entry of `audio_paths`. Kept for back-compat with the recovery scanner and worker fallback. |
| `audio_paths` | `dict[Literal["microphone","system"], Path]` | Per-source WAVs at `~/huske/audio/<session_id>/<chunk_seq:04d>_<HHmmss>_<source>.wav`. Populated by the chunker; the worker transcribes each independently and merges segments by start time. |
| `transcript_path` | `Path \| None` | Set when transcription completes. |
| `state` | `Literal["capturing","finalized","queued","transcribing","transcribed","failed","incomplete"]` | See state diagram. |
| `failure_reason` | `str \| None` | Populated on `failed` / `incomplete`. |
| `audio_sources` | `list[Literal["microphone","system"]]` | Effective sources at chunk start; mutated to record disconnects. |

**Invariants**:
- `actual_duration_seconds <= expected_duration_seconds + small_epsilon`.
- `state == "transcribed"` ⇒ `transcript_path` exists on disk.
- `state == "failed"` ⇒ `audio_path` is preserved (not deleted) per FR-012.
- `chunk_seq` strictly increasing within a session; never reused.

**State transitions**:

```
capturing ──rotation/stop──▶ finalized ──submit──▶ queued
                                                    │
                                                    ▼
                                              transcribing
                                              │      │
                              ┌──success──────┘      └──error──┐
                              ▼                                 ▼
                        transcribed                          failed
                              │
                              └── (audio file deleted unless --keep-audio)

[orphan recovery on next start]
finalized (orphaned) ──valid WAV──▶ queued
                  └──truncated────▶ incomplete (moved to audio/incomplete/)
```

---

## 3. `Transcript`

**Purpose**: The persistent textual artifact produced from one chunk. Lives on disk as a Markdown file with YAML frontmatter; this dataclass is the in-memory mirror used by the writer.

**Fields**:

| Field | Type | Notes |
|---|---|---|
| `session_id` | `str` | |
| `chunk_seq` | `int` | |
| `date` | `date` | Local date of `start_time`. |
| `start_time` | `datetime` (tz-aware) | |
| `end_time` | `datetime` (tz-aware) | |
| `duration_seconds` | `int` | Configured chunk duration. |
| `actual_duration_seconds` | `float` | Captured duration. |
| `gap_seconds` | `float` | |
| `audio_sources` | `list[str]` | |
| `model` | `str` | `"mlx-whisper:<size>"` (e.g., `"mlx-whisper:base"`). |
| `language` | `str` | ISO 639-1, e.g. `"pt"`, `"en"`, or `"auto"` if undetected. |
| `incomplete` | `bool` | `True` if produced from recovery or graceful-stop short chunk. |
| `body` | `str` | Plain text transcript. |
| `segments` | `list[Segment] \| None` | Optional inline-timestamp segments (start/end seconds within chunk). |

**Validation rules** (enforced by writer):
- `body` is UTF-8 text. Empty is allowed in memory, but the live transcription
  pipeline does not persist a file for it. The renderer retains support for the
  legacy single-line note `_(no speech detected)_`.
- All datetimes serialize as ISO 8601 with offset (e.g., `2026-05-07T12:30:00-03:00`).
- The output file's MD5 of frontmatter+body is logged so a future re-transcription can detect drift.

**On-disk format**: defined in `contracts/transcript-format.md`.

---

## 4. `RuntimeConfig`

**Purpose**: Effective configuration after merging defaults, config file, and CLI flags. Frozen at session start.

**Fields**:

| Field | Type | Default | Notes |
|---|---|---|---|
| `chunk_minutes` | `float` | `15` | Allowed range: 0.1–60. |
| `output_root` | `Path` | `~/huske/transcripts` | Day folders live here. |
| `audio_root` | `Path` | `~/huske/audio` | Per-session subdirs created under here. |
| `model` | `str` | `"base"` | Whisper engine only. One of `tiny`, `base`, `small`, `medium`, `large-v3`, `large-v3-turbo`. |
| `compute_type` | `str` | `"int8"` | Kept for back-compat; `float32` opts out of fp16 inference, other values use the MLX default. |
| `device` | `str` | `"auto"` | Kept for back-compat; `cuda` is rejected on macOS. |
| `language` | `str \| None` | `None` (engine decides) | ISO 639-1. Enforced on the `whisper` engine (its decoder takes a language token). On `parakeet` the language is inferred per decode window and cannot be set, so this only drives the drift guard that re-decodes a window which collapsed into English. |
| `keep_audio` | `bool` | `False` | Retain audio after successful transcription (compressed per `keep_audio_format`). |
| `keep_audio_format` | `str` | `"opus"` | Format for kept audio: `opus` (lossy, smallest), `flac` (lossless), or `wav`. |
| `input_device` | `str \| None` | `None` (system default) | Preferred microphone device name. If unavailable, Huske falls back to the default input with a warning. |
| `sample_rate` | `int` | `48000` | Hz. |
| `block_size` | `int` | `1024` | Samples per audio callback. |
| `screenshots_enabled` | `bool` | `False` | Enable periodic screenshots. |
| `screenshots_interval_seconds` | `float` | `60.0` | Seconds between screenshots, minimum 1. |
| `screenshots_root` | `Path` | `~/huske/screenshots` | Screenshot output root. |
| `screenshots_max_dimension` | `int` | `1568` | Downscale each screenshot's long edge to ≤ this many px (0 disables; never upscales). |
| `screenshots_jpeg_quality` | `int` | `60` | JPEG quality for screenshots (1–100). |
| `system_audio_backend` | `str` | `"auto"` | `auto`, `tap`, `sck`, or `off`. `auto` chooses Core Audio process tap on macOS 14.4+ and ScreenCaptureKit fallback otherwise. |
| `log_level` | `str` | `"INFO"` | |

**Validation** (Pydantic):
- `chunk_minutes`: `0.1 <= n <= 60`.
- `output_root` and `audio_root`: parent must exist or be creatable.
- `model`: must be one of the enumerated sizes.
- `device == "cuda"` rejected with a clear message on Apple Silicon (no CUDA).

---

## 5. `RenderState` (UI-only, not persisted)

**Purpose**: The single dataclass the Rich `Live` view re-renders from. Updated from the asyncio loop; consumed by the UI.

**Fields**:

| Field | Type | Notes |
|---|---|---|
| `session_id` | `str` | |
| `recording` | `bool` | |
| `current_chunk_seq` | `int` | |
| `chunk_started_at` | `datetime` | For elapsed display. |
| `next_rotation_at` | `datetime` | For countdown. |
| `peak_levels` | `tuple[float, float]` | Last-second peak per channel, dB. |
| `queue_depth` | `int` | Chunks awaiting/being transcribed. |
| `last_saved` | `Path \| None` | |
| `events` | `deque[Event]` | Capped at 5; rolling. |
| `warnings` | `dict[str, str]` | Active sticky warnings keyed by subsystem, e.g. `"system_audio"`. |

`Event` = `(timestamp, severity ∈ {info,warn,error}, message)`.

---

## Cross-cutting rules

- All datetimes are **timezone-aware** (local tz at startup); never naïve.
- All `Path` values are absolute, expanded (`~` resolved), and created lazily by the component that owns them — `paths.py` centralizes this.
- Pydantic models are used for `RuntimeConfig` only. `RecordingSession`, `AudioChunk`, `Transcript`, `RenderState` are plain dataclasses (`@dataclass(slots=True)`) — they're hot-path mutable state, validation overhead is unwarranted.
- Filenames are produced by **one function** (`paths.transcript_filename(chunk)`) so that FR-014 / FR-015 / FR-017 can't drift between writer and recovery code.
