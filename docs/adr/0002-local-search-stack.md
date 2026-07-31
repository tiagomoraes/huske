---
status: superseded-by-0009
---

# Local search stack: MLX-embeddings + multilingual-e5-base + sqlite-vec

## Context

Semantic search over transcripts needs a text-embedding model and a vector
store. The obvious, best-documented choices in 2026 are `sentence-transformers`
(which pulls `torch`, GB-scale) for embeddings and Chroma/LanceDB for storage.
A future reader will wonder why huske instead depends on a v0.1.0 MLX library
and a pre-1.0 SQLite extension.

## Decision

- **Embeddings:** `mlx-embeddings` running `multilingual-e5-base` (768-dim,
  512-token, 94 languages), encoding `"passage: …"` / `"query: …"`.
- **Vector store:** `sqlite-vec` — a `vec0` table in a single transactional
  SQLite file, with partition keys (`session_id`, `day`) and metadata columns
  for real pre-filtered KNN.

## Why (the trade-off)

- **Leanness is a project value.** huske deliberately avoids heavy deps.
  `mlx-embeddings` rides the **same MLX/Metal runtime `mlx-whisper` already
  ships**, so it adds ~no new weight and brings no `torch`/`onnxruntime`.
  `sqlite-vec` is a ~163 KB, zero-dependency C extension on the stdlib
  `sqlite3` — it fits huske's "everything is a local file" design natively.
- **Multilingual.** Transcripts are `auto`-detected (real corpus includes
  `pt` and `en`); multilingual-e5 covers both well, and its 512-token limit
  matches the Passage window size.
- **Pre-filtering.** huske's value is structured queries (date / source /
  session *then* nearest-neighbor). sqlite-vec does this in one SQL statement;
  FAISS/hnswlib and DuckDB-VSS do not.

## Consequences

- Both libraries are pre-1.0 / young (`mlx-embeddings` v0.1.x single-maintainer;
  `sqlite-vec` v0.1.x). We pin versions, isolate each behind a thin module,
  and have `huske doctor` smoke-test embedding + verify sqlite extension
  loading and `sqlite_version >= 3.41`. `fastembed` is the documented fallback
  if a needed model isn't covered by mlx-embeddings' XLM-RoBERTa path.
- Changing the embedding model is expensive — it re-embeds the whole corpus
  (see the model-versioning policy in the spec).

## Considered and rejected

- **sentence-transformers (torch):** reintroduces the exact heavy dependency
  the project avoids, with no PT/EN quality gain over multilingual-e5.
- **fastembed (onnxruntime):** mature and turnkey, but adds a whole ML runtime
  (onnxruntime + pillow + …) huske doesn't have, and is CPU-only on Mac (no
  Metal). Kept as fallback, not default.
- **Ollama:** great models, ~zero Python deps, but forces an external daemon
  users must install and keep running.
- **Chroma / DuckDB-VSS / faiss+sidecar:** heavy deps / experimental
  persistence / weak filtered search respectively.
