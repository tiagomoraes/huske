# Huske

Huske is a local-only macOS recorder that captures microphone + system audio,
transcribes it on-device with Whisper, and writes structured Markdown
transcripts. This glossary defines the project's domain language. It is a
glossary only — not a spec, not a design doc.

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

## Relationships

- A **RecordingSession** contains one or more **Chunks**.
- A **Chunk** produces exactly one **Transcript** and contains many **Segments**.
- A **Transcript** is windowed into one or more **Passages** for retrieval.
- A **Passage** spans one or more **Segments** and carries a single time range
  and Source set.

## Flagged ambiguities

- "chunk" was about to be reused for the embedding unit. Resolved: a **Chunk**
  is always the ~15-min audio slice; the embedding/retrieval unit is a
  **Passage**. A whole Chunk's transcript is far too coarse to embed as one
  vector.
- "segment" already names Whisper's per-utterance output, so it cannot also
  name the retrieval unit. Resolved: retrieval unit is **Passage**; a Passage
  is built by windowing across Segments.
