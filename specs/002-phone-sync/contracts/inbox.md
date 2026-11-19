# Contract: engine inbox and `huske inbox` / `huske import`

**Status**: v1. The engine (Python) owns the inbox. Producers, which are
Huske.app's phone receiver, the `huske import` CLI, and scripts, hand files over
**only through the CLI**. Huske.app may read `status.json` files directly (a
documented, read-only contract) to avoid spawning a process per poll.

## Why

A recording that did not come from `huske run`'s live capture (an iPhone
recording, a voice memo, any audio file) must enter the same transcription
pipeline and produce ordinary Transcripts under `output_root/YYYY-MM-DD/`. It
must do so whether or not a live engine is running, without ever loading a
second ASR model next to a live one.

## Layout

Config key `inbox_root` (default `~/huske/inbox`).

```text
~/huske/inbox/
├── .lock                 # flock(2) held by the one process transcribing the inbox
├── .staging/             # half-copied items (never processed)
└── <id>/                 # one item per recording
    ├── recording.json    # immutable producer metadata
    ├── audio.<ext>       # original audio (m4a, caf, wav, flac, mp3, aiff, ogg, …)
    ├── status.json       # engine-owned progress, replaced atomically
    └── work/             # transcriber scratch (decoded audio, pieces); transient
```

- `<id>` matches `^[A-Za-z0-9._-]{1,64}$` and must not start with `.` (so it
  can never name `.`, `..`, `.lock` or `.staging`). Re-adding an existing ID is
  a no-op that returns the existing status (idempotent, so a phone re-upload can
  never produce a duplicate transcript); with `--move`, the source file of a
  duplicate add is left where it is.
- Without `--id`, the id is `file-<first 24 hex of sha256(file bytes)>`, so
  re-adding the same file is the same no-op.
- An item directory appears atomically (written under `.staging/` then renamed).
  `.staging/` entries older than a day (a crashed `add`) are removed by the lock
  holder.

### `recording.json`

```json
{
  "id": "4E1C0A5B-0F7E-4C67-9C0B-3C8F3A1B2D11",
  "title": "Reunião com a Ana",
  "origin": "phone",
  "device": "iPhone de Tiago",
  "started_at": "2026-11-19T14:03:00-03:00",
  "duration_seconds": 1834.5,
  "audio_file": "audio.m4a",
  "source_filename": "Reunião com a Ana.m4a",
  "added_at": "2026-11-19T14:34:10-03:00"
}
```

`origin` is `phone` or `file`. `title`, `device`, and `duration_seconds` are
optional (`null` when absent). `started_at` defaults to the file's modification
time minus its duration when the producer does not know it (the duration is
probed with `soundfile`, then `/usr/bin/afinfo`); a timestamp without a UTC
offset is taken as the Mac's local time.

### `status.json`

```json
{
  "id": "4E1C…",
  "state": "processing",
  "updated_at": "2026-11-19T14:35:02-03:00",
  "attempts": 1,
  "chunks_total": 3,
  "chunks_done": 1,
  "session_id": "20261119T140300_5b0f7e4c",
  "transcripts": ["/Users/me/huske/transcripts/2026-11-19/140300_5b0f7e4c_001.md"],
  "error": null
}
```

`state` ∈ `queued` → `processing` → `done` | `failed`. A `failed` item is
retried automatically on later passes until `attempts` reaches 3: a one-shot
`huske inbox process` attempts each item at most once per invocation, and the
live engine waits at least 60 s after a failure before retrying. `attempts`
counts the attempt in progress. `session_id` is known from `add` on.
`chunks_total` is `0` while the audio is being decoded and becomes N once it has
been split; progress is `chunks_done / chunks_total`. `transcripts` lists
absolute paths in chronological order; it is reset at the start of each attempt,
has no entry for a piece without speech, and may be empty for a `done`
recording with no speech. `error` is the first line of the failure reason.

Interruptions:

- A live engine that stops gracefully puts its in-progress item back to
  `queued` without spending the attempt.
- A holder that dies leaves `processing` behind; the next lock holder requeues
  it (the attempt counts, so a recording that crashes the transcriber still
  stops at 3) or marks it `failed` when attempts are exhausted.

## Processing

Whichever process holds `inbox_root/.lock` transcribes queued items. That is
either:

- the **live engine** (`huske run`). It tries to take the lock at startup and
  on every inbox scan (≈ every 5 s), keeps it for its lifetime, and feeds
  inbox jobs to its existing ASR worker beside live chunks (one model in RAM,
  same Metal gate). Decoding and splitting run on a background thread, and only
  one piece of one item is queued at a time, so live chunks interleave with a
  long import and a stopping engine waits for at most one piece;
- or a one-shot **`huske inbox process`** when no live engine runs. It starts the
  ASR worker only if something is runnable.

`flock` is released by the kernel when its holder dies, so there are no stale
locks.

Per item:

1. Decode to 16 kHz mono. `soundfile` handles WAV/FLAC/OGG/MP3/AIFF. Anything it
   cannot read (AAC `.m4a`/`.caf`) goes through macOS's built-in
   `/usr/bin/afconvert`. There is no ffmpeg dependency.
2. Split into pieces of at most `chunk_minutes`, cutting at the quietest point
   near each boundary so words are not split.
3. Each piece becomes one ordinary ASR job and one Transcript. Its session id
   is deterministic for the item, so a retry rewrites the same filenames:
   `<started_at YYYYMMDDTHHMMSS>_<first 8 hex of sha1(id)>`, with `started_at`
   converted to the Mac's local time zone (like every live transcript; this also
   decides the `YYYY-MM-DD` folder and the `HHMMSS` filename prefix). `chunk_seq`
   runs 1…N. `start_time` is `started_at` + the piece offset. Audio source is
   `microphone`; echo handling does not apply. The ASR settings (`asr_engine`,
   `language`, …) are the config's. Pieces are at most `chunk_minutes` long; the
   cut is the quietest point (smoothed over 0.5 s) in the last
   `min(60 s, chunk_minutes / 4)` before each boundary. Audio that decodes to
   nothing is `done` with no transcripts.
4. Extra frontmatter keys (additive under the transcript contract): `origin`,
   `device`, `title`, `import_id`.
5. Written transcripts go through the same post-write hooks as live chunks
   (Git publication, distillation) when those are enabled in the live engine.
   A one-shot `huske inbox process` runs a best-effort Git publication after
   the pass when `sync_enabled`; distillation catches up via `huske distill`.
6. On success the original audio is deleted, unless `keep_audio` is set; then
   it is moved to `audio_root/imported/<YYYY-MM-DD>/<id>.<ext>`.
   `recording.json` and `status.json` stay so status queries keep working
   (`audio_file` then names a file that is gone). A failed item keeps its audio.
   `done` items whose `updated_at` is older than 30 days are pruned by the lock
   holder.

## CLI

All subcommands accept `--json` for machine-readable output, a single JSON
object on stdout (child processes' output is redirected to stderr so it cannot
corrupt it), and `--config PATH`.

```text
huske inbox add FILE [--id ID] [--title T] [--device NAME] [--origin phone|file]
                     [--started-at ISO8601] [--duration SECONDS] [--move] [--json]
    Stage FILE as an inbox item (copy, or move with --move). Prints the item
    (status object + recording.json fields) plus "created": true|false.
    Idempotent per --id. --origin defaults to file.

huske inbox process [--json]
    Transcribe every queued (or retryable failed) item now, then exit:
    {"deferred_to_engine": false, "items": [<item attempted by this run>…]}.
    If another process (normally the live engine) holds the inbox lock, it
    returns immediately with {"deferred_to_engine": true, "items": []}.

huske inbox status [ID ...] [--json]
    {"items": [<status object + recording.json fields>]}, newest first (by
    added_at). An unknown ID comes back as {"id": ID, "state": "unknown"}.

huske inbox retry ID ... [--json]
    Re-queue `failed` items with a fresh 3-attempt budget. Each item in
    {"items": [...]} carries "retried": true|false. Exit 1 if any ID was
    unknown, not failed, or has lost its audio.

huske import FILE ... [--title T] [--started-at ISO8601] [--json]
    Human convenience: `inbox add` for each FILE (origin=file), then
    `inbox process`. {"deferred_to_engine": bool, "items": [<item per FILE>…],
    "errors": [{"file", "error"}…]} (errors only when a FILE was rejected).
```

A validation failure prints `{"error": "…"}`.

Exit codes: 0 on success (including "deferred"), 1 on validation errors (bad
id/origin/timestamp, missing file, invalid config), 2 when processing ran but an
item failed. Command-line parsing errors (unknown flag, missing FILE) come from
the CLI framework, which exits 2 with no JSON, as for every huske command.
