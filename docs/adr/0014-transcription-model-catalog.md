---
status: accepted
date: 2026-11-22
---

# A transcription model catalog and engine-family registry

## Context

Choosing a transcription model meant three settings that only made sense
together: `asr_engine` (`parakeet` | `whisper`), `parakeet_model` (a repo), and
`model` (a Whisper size from a fixed list). Huske.app mirrored that with three
pickers and a hard-coded list of options.

That shape had three problems:

- **It hid the trade-off people care about.** Does a model pin the language?
  How big is the download? How fast is it on this Mac?
- **A new model needed a code change.** Even a quantized build of Whisper
  turbo meant a code change and a release, because `model` was a `Literal` of
  six sizes.
- **New runtimes had no obvious place.** They are arriving fast. In
  mlx-community alone, Hugging Face lists Qwen3-ASR, Voxtral, Granite Speech
  and Nemotron streaming ASR next to Parakeet and Whisper. Supporting one
  would have meant editing the worker, the config, the doctor and the app.

## Decision

Separate **families** (runtimes, in code) from **models** (weights, in data):

1. **Family registry** (`huske/transcribe/engines/__init__.py`). Each
   `EngineFamily` declares:
   - `label` and the `model:` frontmatter prefix;
   - `pins_language`: whether the model takes the language as an input;
   - `dictionary`: `prompt`, `boost` or `none`;
   - its `runtime` module (checked before a model is offered);
   - a lazy `builder`.

   The worker builds every engine through the registry. A new runtime is one
   engine module plus one `register_family` call.
2. **Model catalog as data** (`huske/transcribe/models.toml`). Each entry has
   an id, family, repo, name, a one-line summary, languages, download size,
   speed and accuracy in words, a measured line, a note, and default or
   recommended flags. A new model of a known family is one entry.
   `tests/unit/test_model_catalog.py` validates entries.
3. **One key, `asr_model`.** It takes a catalog id, a Hugging Face repo or a
   local folder, and wins over the legacy keys. Those keep working and map
   onto the same catalog entries.
   - Resolution lives in one function, `catalog.resolve_model`, used by the
     worker jobs (live and inbox), `huske doctor`, the startup language check
     and the CLI.
   - An unlisted repo is an **ad-hoc model**. Its family comes from the repo
     name or a folder's `config.json`, checked without network, so a model
     released today can be used today.
4. **Labels don't move.** The `model:` frontmatter label is derived from the
   repo name (`whisper-large-v3-turbo` → `mlx-whisper:large-v3-turbo`), which
   reproduces every existing label exactly.
5. **Language and dictionary honesty per model.** Language support is
   computed per model: pinned, detected or unsupported. An English-only
   Parakeet with `language = "pt"` is reported as unsupported, not as merely
   "can't be pinned".
6. **CLI for people and the app.**
   - `huske models` is a table: in use, languages, size, speed, accuracy,
     downloaded.
   - `use` takes an id, a repo or a folder, or offers a numbered picker when
     run in a terminal without arguments. It writes `asr_model` and the
     matching legacy keys, so an older engine sharing the config agrees when
     it can.
   - `download` streams progress as JSON lines with `--json`. It watches the
     cache's blob folder instead of relying on the library's progress
     callbacks, which changed between huggingface_hub versions.
   - `try` transcribes a synthetic macOS `say` sample or `--audio`, and
     reports the speed (× real time) and load time on this Mac.
   - `info` shows one model.
   - Everything takes `--json`, for Huske.app.

The first catalog holds only models verified to load with the shipped
runtimes. They were measured on an M3 Pro with 52 s of synthetic Portuguese
speech dense with English jargon:

| Model | Speed | Jargon terms right |
|---|---|---|
| Parakeet v3 | 51× | 5/10 |
| Whisper large-v3 turbo | 24× | 7/10 |
| Whisper turbo q4 (a third of the size) | 20× | 7/10 |
| Whisper large-v3 | 8× | 9/10 |
| Whisper small | 34× | 3/10 |
| Whisper small q4 | 46× | 3/10 |
| Parakeet 110M (English) | 81× | 6/10 in English |

The `whisper-…-4bit` / `-8bit` repos are excluded on purpose. They ship
`model.safetensors` + `*.tiktoken` for a different runtime, which mlx-whisper
cannot load.

## Consequences

- **Adding models.** A new Parakeet- or Whisper-family model is either a
  config value (ad hoc) or a reviewed catalog entry. Neither touches code.
- **Adding families.** Qwen3-ASR, Voxtral and the rest are one engine module
  plus their runtime dependency each. They are not added here: each needs its
  dependency weighed (size, Apple-silicon wheels, license) and its own
  measurement.
- **Catalog maintenance.** Size and speed are maintained by hand, measured
  with `huske models try`. Entries record the reference machine.
- **No delete command.** The Hugging Face cache is shared with other tools, so
  `huske models` never deletes from it.
- **Old engines.** An engine older than this ignores `asr_model` with its
  unknown-key warning and falls back to the legacy keys, which `use` keeps in
  step.

## Considered and rejected

- **A remote catalog fetched at run time.** It would add a network dependency
  and a trust question for what is a handful of reviewed entries. Ad-hoc repos
  already cover "a model released today".
- **Keeping `model` as the Whisper key and widening its `Literal`.** It still
  needs a release per model and gives no home to other families.
- **Auto-discovering models by searching Hugging Face.** Names are unreliable
  signals of compatibility; the catalog lists what was actually measured.

## Addendum — converting language fine-tunes

Most language fine-tunes on Hugging Face — none of the Brazilian Portuguese
ones exist in MLX form — are Whisper checkpoints in the `transformers` layout.
`huske models convert` turns one into mlx-whisper's layout without PyTorch:

- it renames the tensors (`q_proj→query`, `fc1→mlp1`, `encoder_attn→cross_attn`, …);
- it transposes the two convolutions and casts to float16;
- it checks that every tensor mlx-whisper expects is present.

The download goes to a temporary folder (never the shared Hugging Face cache)
and is deleted afterwards. The result lands in `models_root` with a
`huske-model.json` recording its provenance.

Converted folders appear in `huske models` and in the app. `models use`
refuses a raw `transformers` repo with `code: "needs_conversion"`, so the app
can offer **Convert and use**. Catalog entries can set
`source_format = "transformers"` to be converted on `download`.

Measured on synthetic speech (word error rate):

| Model | PT with English jargon | Plain PT |
|---|---|---|
| `freds0/distil-whisper-large-v3-ptbr` (converted) | 10.0 % | 2.2 % |
| `whisper-large-v3-turbo` | 5.0 % | 0.0 % |
| `whisper-large-v3` | 3.6 % | 1.1 % |

The fine-tune lost the English spellings meetings need ("Cubernets",
"featura"), so no PT-BR fine-tune is in the catalog. The converter is there to
try them on real audio.

Parakeet fine-tunes, such as the PT-BR "TAGARELA" builds, ship as `.nemo` or
ONNX files. Converting those needs NVIDIA's tools and PyTorch, so they are out
of scope for now.
