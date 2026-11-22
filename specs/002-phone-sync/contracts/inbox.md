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
├── .throughput.json      # measured transcription speed per engine and model,
│                         # written by the lock holder (for `chunk_progress`)
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
optional (`null` when absent). An optional `language` (ISO 639-1, e.g. `"pt"`;
absent when not given) is the recording's spoken language: it overrides the
config's `language` for this item only (`huske import --language`, `huske
inbox add --language`). An unknown code is rejected when adding; one that a
producer wrote by hand is ignored in favour of the config. `started_at` defaults to the file's modification
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

A piece that fails does not stop the attempt: the other pieces are still
transcribed, and the item then ends `failed` with what it has ([Partial
results](#partial-results)).
`chunks_total` is `0` while the audio is being decoded and becomes N once it has
been split. `chunk_progress` (optional number, above 0 and at most 0.99; never
`null`) estimates how far the piece being transcribed has got. It is not real
ASR progress (the transcriber is one opaque call): it is elapsed time against
the speed measured on this Mac for the same engine and model. It is rewritten
at most every 5 s, only grows within a piece, and is absent whenever no piece
is in flight and until one piece of at least 30 s with speech has ever been
measured. Progress is `(chunks_done + chunk_progress) / chunks_total`, with
`chunk_progress` read as 0 when absent. `transcripts` lists
absolute paths in chronological order; it is empty while an attempt decodes
and splits the audio, has no entry for a piece without speech, and may be
empty for a `done` recording with no speech. `error` is the first line of the
failure reason (`chunk 2/3 failed: …`, or `chunks 2, 3 of 5 failed: …` with the
first one's reason).

### Partial results

A long recording that fails partway keeps what it got, and later attempts do
only the rest.

```json
{
  "id": "4E1C…",
  "state": "failed",
  "attempts": 3,
  "chunks_total": 3,
  "chunks_done": 2,
  "missing_chunks": [2],
  "transcripts": [
    "/Users/me/huske/transcripts/2026-11-19/140300_5b0f7e4c_001.md",
    "/Users/me/huske/transcripts/2026-11-19/140300_5b0f7e4c_003.md"
  ],
  "chunk_results": {
    "split": "0f3a9c41d2b7e650",
    "total": 3,
    "done": {
      "1": "/Users/me/huske/transcripts/2026-11-19/140300_5b0f7e4c_001.md",
      "3": "/Users/me/huske/transcripts/2026-11-19/140300_5b0f7e4c_003.md"
    }
  },
  "error": "chunk 2/3 failed: …"
}
```

- `missing_chunks` (optional list of piece numbers 1…N, ascending; never
  `null`) is present on a `failed` item whose audio was split: the pieces that
  have no result. That is every piece that failed and, when the attempt was cut
  short (the ASR worker died), every piece not reached. `chunks_done` and
  `transcripts` then describe the pieces that did finish, and those transcript
  files are ordinary Transcripts, already written and published like any
  other. Any other status write drops the field, so only a `failed` item
  carries it. Readers treat a `failed` item with attempts exhausted, a
  non-empty `missing_chunks` and a non-empty `transcripts` as **partly
  transcribed**: Huske.app hands those transcripts to the phone, marked as
  partial.
- `chunk_results` (optional object, engine-private; other readers ignore it)
  remembers the finished pieces so a later attempt can skip them: `split`
  names how the recording was cut and the ASR settings used, `total` is the
  piece count, `done` maps a finished piece's number to the transcript it wrote
  (`null` for a piece without speech). It is written after every finished
  piece, survives `failed`, a re-queue and `huske inbox retry`, and is removed
  when the item is `done`.
- **Every attempt transcribes only the pieces without a result**: the
  automatic retries, an attempt after a graceful stop or a crash, and the ones
  `huske inbox retry` grants. A piece counts as finished only if the recording
  is cut the same way and transcribed with the same settings as before (same
  piece boundaries, `asr_engine`, model and `language`; otherwise the attempt
  starts over) and, when it wrote a transcript, that file still exists. When
  the last missing piece gets its result the item is `done` and `transcripts`
  lists every piece's transcript in order.
- A failure before the recording could be split (it would not decode this
  time, or the holder died during the last attempt) keeps reporting the pieces
  an earlier attempt finished.

Interruptions:

- A live engine that stops gracefully puts its in-progress item back to
  `queued` without spending the attempt. The pieces it had finished are kept
  (`chunk_results`); the next attempt goes on from there.
- A one-shot `huske inbox process` (or `huske import`) that receives SIGTERM
  does the same: the item goes back to `queued` with its attempt unspent, the
  ASR worker is stopped, the JSON carries `"interrupted": true`, and the pass
  exits 143. Huske.app's watchdog signals the whole process group, so this is
  what a timed-out pass does. The group includes the `afconvert` a decode is
  running: its dying with the pass is the stop, not a decode failure, and the
  item is re-queued the same way.
- The ASR worker exits by itself within about a second if the process that
  started it dies (it polls its parent), so a killed pass or engine cannot leave
  a worker transcribing for nobody.
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
  ASR worker only if something is runnable. It never runs beside a live
  engine: if a `huske run` session is running when it starts, or starts while
  it works (a live session lock, `audio_root/<session>/.lock`, naming a running
  process that is not younger than the lock; checked about once a second), it
  puts the item in progress back to
  `queued` without spending the attempt, stops its worker, releases the inbox
  lock and exits with `deferred_to_engine: true`. The live engine then takes
  the lock on its next scan and transcribes the queue with its own model.

`flock` is released by the kernel when its holder dies, so there are no stale
inbox locks.

A session lock is a plain file holding the PID of its `huske run`, and a
crash leaves it behind. It counts as live only while that PID is running *and*
the process started no later than the lock was written (its modification
time, with 10 s of slack). Otherwise the PID has been handed to an unrelated
process since the crash, which used to keep the dead session "live" for as
long as that process ran: every one-shot pass deferred to it and crash
recovery skipped its chunks. The lock file's format is unchanged (older
engines read it as before); when the start time cannot be read, the PID check
alone decides.

Per item:

1. Decode to 16 kHz mono. `soundfile` handles WAV/FLAC/OGG/MP3/AIFF. Anything it
   cannot read (AAC `.m4a`/`.caf`) goes through macOS's built-in
   `/usr/bin/afconvert`. There is no ffmpeg dependency.
2. Split into pieces of at most `chunk_minutes`, cutting at the quietest point
   near each boundary so words are not split.
3. Each piece becomes one ordinary ASR job and one Transcript. Its session id
   is deterministic for the item, so a piece transcribed again rewrites the
   same file:
   `<started_at YYYYMMDDTHHMMSS>_<first 8 hex of sha1(id)>`, with `started_at`
   converted to the Mac's local time zone (like every live transcript; this also
   decides the `YYYY-MM-DD` folder and the `HHMMSS` filename prefix). `chunk_seq`
   runs 1…N. `start_time` is `started_at` + the piece offset. Audio source is
   `microphone`; echo handling does not apply. The ASR settings (`asr_engine`,
   `language`, the dictionary, …) are the config's, except `language` when the
   item carries its own. With `distill_enabled`, a one-shot `huske inbox
   process` cleans up the new transcripts before publishing them, exactly like
   the live engine (ADR 0013). Pieces are at most `chunk_minutes` long; the
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
    If another process (normally the live engine) holds the inbox lock, or a
    recording session is running, it returns immediately with
    {"deferred_to_engine": true, "items": []}. A session that starts during
    the pass makes it yield: "deferred_to_engine": true, and the item it was
    on is listed back in `queued`.

huske inbox status [ID ...] [--json]
    {"items": [<status object + recording.json fields>]}, newest first (by
    added_at). An unknown ID comes back as {"id": ID, "state": "unknown"}.

huske inbox retry ID ... [--json]
    Re-queue `failed` items with a fresh 3-attempt budget. The pieces an item
    already transcribed are kept: the new attempts transcribe only the missing
    ones, then the item is `done` with the whole transcript. Each item in
    {"items": [...]} carries "retried": true|false (plus "error" when its audio
    is gone). Exit 1 if any ID was unknown, not failed, or has lost its audio.
    Huske.app's iPhone pane runs it for a phone recording the engine gave up
    on ("Try again"), the only way out of `failed`.

huske import FILE ... [--title T] [--started-at ISO8601] [--json]
    Human convenience: `inbox add` for each FILE (origin=file), then
    `inbox process`. {"deferred_to_engine": bool, "items": [<item per FILE>…],
    "errors": [{"file", "error"}…]} (errors only when a FILE was rejected).
```

A validation failure prints `{"error": "…"}`.

Exit codes: 0 on success (including "deferred"), 1 on validation errors (bad
id/origin/timestamp, missing file, invalid config), 2 when processing ran but an
item failed, 143 when the pass was stopped with SIGTERM (`"interrupted": true`). Command-line parsing errors (unknown flag, missing FILE) come from
the CLI framework, which exits 2 with no JSON, as for every huske command.
