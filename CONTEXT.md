# Huske

Huske is a local-first macOS recorder that captures microphone + system audio,
transcribes on-device, and writes structured Markdown. An optional Git publisher
copies finalized transcripts to a private repository. The separate, always-on
**huske-mcp service** pulls a **Replica**, indexes it, and serves agents while the
recording Mac is offline.

## Recording and transcription

**RecordingSession**:
One uninterrupted run of `huske run`, identified by a `session_id`.

**Chunk** (a.k.a. **AudioChunk**):
A bounded slice of one RecordingSession's audio, producing exactly one
Transcript. Do not use "chunk" for text retrieval.

**Segment**:
One ASR-emitted utterance within a Chunk, carrying `{start, end, text, source}`.
Do not use "segment" for the retrieval unit.

**Transcript**:
The canonical Markdown-plus-YAML-frontmatter file written for one Chunk under
`output_root/YYYY-MM-DD/`. A finalized Transcript is immutable.

**Source**:
The audio origin: `mic` or `system`. Huske does not perform speaker diarization.

## Publication and replication

**GitPublisher**:
The recording-app component that reconciles canonical Transcripts into a
dedicated Git checkout and pushes them. Git is the first cloud provider; GitHub
is the documented host. It never publishes audio, screenshots, logs, config, or
credentials.

**ReplicaRepository**:
The private Git repository used as the durable handoff and history. It is not
the Huske source-code repository.

**Replica**:
The off-device read copy pulled from the ReplicaRepository. On-device
Transcripts remain authoritative; sync never flows from the VPS back into the
recording tree.

**huske-mcp service**:
The independent Linux/VPS package under `services/huske_mcp`. It owns Git pull,
the derived SQLite index, and the permanent MCP endpoint. It is not a mode or
subprocess of the recording application.

## Search and retrieval

**Passage**:
A retrieval-sized window built from consecutive transcript runs regardless of
Source. It carries one time range and the set of Sources it spans. It is the
unit returned by search and recap.

**Statement**:
A local distill artifact: one polished transcript run written to a
`<name>.statements.json` sidecar (skip-hash plus the corrected lines). The
uncorrected ASR snapshot lives in `<name>.asr.txt`. Both are derived and
optional; the remote index reads the polished canonical Markdown.

**Tiny profile**:
The 512 MB service profile. It uses Unicode SQLite FTS5 and metadata filters
without a resident model. Results identify their mode as `fts5`.

**Semantic profile**:
The larger-memory service profile. It combines Model2Vec dense retrieval with
FTS5 using reciprocal-rank fusion. Results identify their mode as `hybrid`.

**Recap**:
A chronological retrieval over a date range rather than a topic query. A date
is not a semantic neighborhood, so recap never depends on embeddings.

**Overview**:
The map of corpus coverage and density plus Replica health.

**Export**:
One derived Markdown file per day for destinations that read files rather than
MCP. Exports are regenerable and never authoritative.

## Relationships

- A RecordingSession contains one or more Chunks.
- A Chunk produces exactly one Transcript and contains many Segments.
- GitPublisher appends Transcripts to ReplicaRepository.
- huske-mcp pulls ReplicaRepository into Replica.
- A Transcript is windowed into Passages in the service's derived index.
- Search ranks Passages; fetch returns a Passage with neighboring context.
- Recap returns Passages chronologically; Overview describes their coverage.
- Statements and Exports are optional derivations of Transcripts.

## Retired terms

**huske server**, **Ingest**, and **Connector** described the pre-ADR-0009
architecture: a custom HTTP ingest endpoint plus an MCP/OAuth server inside the
main Huske distribution. Those components and commands were removed. Use
**GitPublisher**, **ReplicaRepository**, and **huske-mcp service** for the new
architecture.
