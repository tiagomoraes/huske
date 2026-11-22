# Transcription models

Huske transcribes on your Mac with a model you choose. Models come in
**families** — one runtime each — and a family can load many models:

| Family | Runtime | Language | Dictionary |
| --- | --- | --- | --- |
| Parakeet | `parakeet-mlx` | works it out from the audio; **can't be pinned** | listens for your words with `parakeet_word_boost` (slower) |
| Whisper | `mlx-whisper` | **pinned** to the language you choose | steers decoding (prompt), always on |

Every model gets the dictionary's corrections and the optional LLM cleanup.
The design is recorded in
[ADR 0014](adr/0014-transcription-model-catalog.md).

## Choosing a model

```bash
huske models                 # the list: in use, languages, size, speed, downloaded
huske models info whisper-large-v3-turbo
huske models use             # pick from a numbered list
huske models use whisper-large-v3-turbo
huske models download whisper-large-v3-turbo   # fetch now instead of on first use
huske models try whisper-large-v3-turbo        # speed on this Mac, on a synthetic sample
huske models try whisper-large-v3-turbo --audio ~/Desktop/sample.m4a
huske models convert <repo>                    # a transformers Whisper fine-tune → MLX
```

In Huske.app: Configuration → Transcription → **Model** → Change…

The choice is stored as `asr_model` in `~/.config/huske/config.toml` and applies
from the next recording (a running session keeps its model). `huske run
--asr-model <model>` overrides it for one session.

### Which one?

Measured on an M3 Pro with synthetic speech — 52 s of Portuguese meeting talk
dense with English jargon, counting 10 jargon terms:

| Model | Size | Speed | Jargon right | Pick it when |
| --- | --- | --- | --- | --- |
| `parakeet-tdt-0.6b-v3` (default) | 2.5 GB | 51× real time | 5/10 (9/10 in English) | one European language per meeting |
| `whisper-large-v3-turbo` | 1.6 GB | 24× | 7/10 | the language must be locked (mixed-language meetings) |
| `whisper-large-v3-turbo-q4` | 0.5 GB | 20× | 7/10 | same, with a third of the memory |
| `whisper-large-v3` | 3.1 GB | 8× | 9/10 | accuracy matters more than time |
| `whisper-small` / `-q4` | 0.5 / 0.2 GB | 34× / 46× | 3/10 | light machines, simple speech |
| `parakeet-tdt_ctc-110m` | 0.5 GB | 81× (English) | 6/10 (English) | English only, as light as it gets |

`huske models` shows the full list, including `whisper-medium`, `-base`,
`-tiny` and the English-only `parakeet-tdt-0.6b-v2`. All of these run far
faster than real time, and transcription happens after each chunk closes, so
any of them keeps up with live recording.

### A model released today

Any compatible Hugging Face repo or local folder works without waiting for a
Huske release:

```bash
huske models try someone/parakeet-tdt-0.6b-v4     # does it load, how fast, how good
huske models use someone/parakeet-tdt-0.6b-v4
```

Huske picks the family from the repo name (`parakeet…`, `…whisper…`) or, for
a folder, from its `config.json`. If it can't tell, it says so. Whisper models
must be in mlx-whisper's layout (`config.json` + `weights.npz` or
`weights.safetensors`); builds made for other runtimes (`model.safetensors` +
`*.tiktoken`, as in `whisper-…-4bit`) won't load — prefer the `-q4` builds.

### Fine-tunes for one language (Brazilian Portuguese, …)

Most language fine-tunes on Hugging Face are Whisper models published in the
`transformers` layout, not MLX. Huske converts them once, on your Mac — a
rename of the tensors, a transpose and a cast to float16, no PyTorch:

```bash
huske models convert freds0/distil-whisper-large-v3-ptbr   # → ~/huske/models/distil-whisper-large-v3-ptbr
huske models try ~/huske/models/distil-whisper-large-v3-ptbr --audio ~/Desktop/a-real-meeting.m4a
huske models use ~/huske/models/distil-whisper-large-v3-ptbr
```

The download goes to a temporary folder and is deleted after conversion;
converted models live in `models_root` (default `~/huske/models`) and show up
in `huske models` and in the app. In Huske.app, pasting such a repo into
"Another model" offers **Convert and use**. Parakeet fine-tunes are published
as `.nemo` or ONNX files, which need NVIDIA's tools to convert; they are not
supported yet.

**What we measured for Portuguese** (word error rate on synthetic speech —
clean TTS, so treat it as a sanity check, not a verdict on real accented
audio):

| Model | Portuguese with English jargon | Plain Portuguese |
| --- | --- | --- |
| `whisper-large-v3` | 3.6 % | 1.1 % |
| `whisper-large-v3-turbo` | 5.0 % | 0.0 % |
| `whisper-large-v3-turbo-q4` | 5.0 % | 1.1 % |
| `parakeet-tdt-0.6b-v3` | 6.4 % | 2.2 % |
| `freds0/distil-whisper-large-v3-ptbr` (converted) | 10.0 % | 2.2 % |

The PT-BR fine-tune was worse on both, and clearly worse on English jargon: it
writes borrowed words the Portuguese way ("Cubernets", "featura", "data dog").
Fine-tunes trained on Portuguese text tend to lose the English spellings that
meetings full of jargon need, so none is in the catalog. If your meetings are
plain Portuguese with strong regional accents, a fine-tune may still win on
*your* audio — convert it and compare with `huske models try … --audio`.

## Adding a model to the catalog (maintainers)

The catalog is data: [`huske/transcribe/models.toml`](../huske/transcribe/models.toml).
For a model of an existing family:

1. **Check it loads and measure it**: `huske models try <repo>` on the
   synthetic sample, and on real speech with `--audio` (synthetic text only in
   anything you commit).
2. **Add an entry** (for a `transformers`-layout Whisper fine-tune, add
   `source_format = "transformers"`: `huske models download` then converts it
   into `models_root`) with a new, never-reused `id`, the `repo`, a plain
   one-line `summary`, `languages` (omit for every Whisper language),
   `size_mb` (weights), `speed` / `accuracy` in the catalog's words, and the
   `measured` line from step 1. Put a `note` on anything people must know
   before choosing (English only, can't pin the language…).
3. `pytest tests/unit/test_model_catalog.py` checks every entry is well formed
   (unique ids and repos, a registered family, known language codes, exactly
   one default).

The app and the CLI pick the entry up with no other change.

## Adding a new family (maintainers)

A new runtime — say Qwen3-ASR or Voxtral — is one module and one registration:

1. `huske/transcribe/engines/<family>.py`: a `TranscriptionEngine` subclass.
   `transcribe(audio)` gets 16 kHz mono float32 and returns `Segment`s with
   start/end seconds and text; `unload()` drops the weights; optionally
   `set_options(language=…, vocabulary=…, word_boost=…)` for per-job language
   and dictionary. Import the runtime lazily inside the class: the worker runs
   it in its own subprocess.
2. Register it in `huske/transcribe/engines/__init__.py` with
   `register_family(EngineFamily(...))`: `name`, `label`, the `model:`
   frontmatter prefix, whether it `pins_language`, how it uses the dictionary
   (`prompt` / `boost` / `none`), the importable `runtime` module, and a
   `builder`.
3. Add its runtime to `pyproject.toml` (with the platform markers the others
   use) and catalog entries for its models.
4. If it can pin the language or take a prompt, mirror what `WhisperEngine`
   does; if not, say so through `pins_language=False` / `dictionary="none"` —
   every surface reads those, so nothing over-promises.

Nothing else changes: the worker builds engines through the registry, the
config resolves models through `huske.transcribe.catalog.resolve_model`, and
`huske models --json` gives the app everything it shows.

## Configuration

| Key | Default | Meaning |
| --- | --- | --- |
| `asr_model` | unset | Catalog id, Hugging Face repo, or local folder. Wins over the keys below. |
| `asr_engine` | `"parakeet"` | Legacy: family when `asr_model` is unset. |
| `parakeet_model` | `mlx-community/parakeet-tdt-0.6b-v3` | Legacy: Parakeet repo when `asr_model` is unset. |
| `model` | `"base"` | Legacy: Whisper size when `asr_model` is unset and `asr_engine = "whisper"`. |
| `parakeet_word_boost` | `false` | Parakeet listens for your dictionary words (beam search, slower). |
| `models_root` | `~/huske/models` | Where converted models are kept. |

`huske models use` writes `asr_model` and the matching legacy keys, so an older
Huske that shares the config file (a second install) transcribes with the same
model when it can express it. The transcript's `model:` frontmatter keeps the
`<family>:<model>` form (`parakeet:tdt-0.6b-v3`, `mlx-whisper:large-v3-turbo`).
