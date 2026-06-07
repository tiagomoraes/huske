# Huske

Huske is a local-first macOS recorder that captures microphone + system audio,
transcribes it on-device with Whisper, and writes structured Markdown
transcripts. Recording and transcription always happen on-device; an optional,
always-on off-device **huske server** can hold a **Replica** of the transcripts
and serve search to a remote MCP client when the recording Mac is offline. This
glossary defines the project's domain language. It is a glossary only — not a
spec, not a design doc.

## Language

### Recording & transcription

**RecordingSession**:
One uninterrupted run of `huske run`, identified by a `session_id`.
_Avoid_: recording, capture session.

**Chunk** (a.k.a. **AudioChunk**):
A fixed-duration (~15 min) slice of one session's audio, producing exactly one
Transcript.
_Avoid_: using "chunk" for any text/retrieval unit — see **Passage**.

**Segment**:
One Whisper-emitted utterance within a Chunk, carrying `{start, end, text,
source}`; rendered into the transcript body but not persisted as structured
data.
_Avoid_: using "segment" for the retrieval unit — see **Passage**.

**Transcript**:
The Markdown-plus-YAML-frontmatter file written for one Chunk, stored under
`output_root/YYYY-MM-DD/`.

**Source**:
The origin of audio for a Segment: `mic` (microphone) or `system` (system
audio). There is no speaker diarization — source is the only speaker-like axis.

### Search & retrieval (this initiative)

**Passage**:
A retrieval-sized window of transcript text (target ~256–512 tokens, slight
overlap, broken at large time gaps), built by grouping consecutive Segments by
time **regardless of Source**, embedded into exactly one vector. Carries a
single time range and the **set** of Sources it spans. The unit a search
returns to an LLM.
_Avoid_: chunk, segment, snippet, excerpt.

**Statement**:
A self-contained, decontextualized factual claim distilled from a Transcript by
a **local LLM** (e.g. Ollama), carrying the time range of its source Passage as
provenance. Statements are the compact, more-searchable "memory" of a
Transcript: search ranks Statements, then **fetch** drills into the source
Transcript for depth. Each is embedded into one vector and held in a separate
statement index, and the set for a Transcript is written to a
`<name>.statements.json` sidecar. Opt-in (see docs/adr/0005).
_Avoid_: "summary" (a Statement is one atomic claim, not a paragraph); "memory"
as a type name (it is the role Statements play, not the unit).

### Replication & serving (this initiative)

**huske server**:
An optional, always-on remote deployment of huske (e.g. on a VPS) that holds a
**Replica** of one user's transcripts and serves search to a **co-located
agent** when the recording Mac is offline. It runs the same indexing and MCP
code as the local install.
_Avoid_: "backend", "cloud service" (both imply multi-tenant; the huske server
is single-tenant — one deployment holds exactly one user's Replica).

**Replica**:
The off-device copy of the transcript corpus held by the **huske server**. The
on-device transcripts remain authoritative; the Replica is kept in sync **from**
them, never the reverse.

**Co-located agent**:
An agent (the user's "hermes" agent) that runs on the **same host** as the
**huske server** and queries its search locally — the same way Claude on the
recording Mac reaches that Mac's loopback daemon. In the chosen design the
**huske server**'s search is never queried across the network; only **Ingest**
crosses the network.
_Avoid_: "remote client" — the consuming agent is co-located, not remote.

**Ingest**:
The act — and the authenticated endpoint — by which a **huske server** receives
a finalized **Transcript** pushed from a recording Mac and feeds it into the
server's index. Because a finalized Transcript is immutable, Ingest is
idempotent: re-pushing the same Transcript is a no-op.

## Relationships

- A **RecordingSession** contains one or more **Chunks**.
- A **Chunk** produces exactly one **Transcript** and contains many **Segments**.
- A **Transcript** is windowed into one or more **Passages** for retrieval, and
  (optionally) distilled into one or more **Statements**.
- A **Passage** spans one or more **Segments** and carries a single time range
  and Source set.
- A **Statement** is distilled from a **Passage** and grounded back to its
  Transcript by time range; search ranks Statements, fetch returns the Passage.
- The optional **huske server** holds a **Replica** of the **Transcripts** and
  serves **Passages** to a **co-located agent** when the recording Mac is
  offline.

## Flagged ambiguities

- "chunk" was about to be reused for the embedding unit. Resolved: a **Chunk**
  is always the ~15-min audio slice; the embedding/retrieval unit is a
  **Passage**. A whole Chunk's transcript is far too coarse to embed as one
  vector.
- "segment" already names Whisper's per-utterance output, so it cannot also
  name the retrieval unit. Resolved: retrieval unit is **Passage**; a Passage
  is built by windowing across Segments.
