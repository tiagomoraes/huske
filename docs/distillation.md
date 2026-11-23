# Transcript cleanup with a language model (opt-in)

Huske can clean up each finished transcript with a language model: punctuation,
capitalization, misheard or split words, and your dictionary's spellings. It is
not summarisation — the speakers' words stay theirs. Cleanup is off by default
and independent from cloud sync: the cleaned-up Markdown is what Huske
publishes to Git and what the isolated `huske-mcp` service indexes.

You choose where the model runs:

| `distill_backend` | Runs | Transcript text goes to | Setup |
| --- | --- | --- | --- |
| `apple` | Apple Intelligence, on-device | nowhere — stays on this Mac | Huske.app installed; macOS 26+, Apple silicon, Apple Intelligence on |
| `mlx` (default) | Huske's built-in model (Qwen3.5 0.8B) | nowhere | nothing; downloads ~0.6 GB once |
| `ollama` | your Ollama daemon | this Mac (loopback) | `ollama` installed |
| `openai_compatible` | LM Studio, llama.cpp, vLLM, … | this Mac — or the host in `distill_endpoint` | a running server |
| `openai`, `anthropic`, `openrouter` | the provider's cloud | **the provider** | API key + your consent |

The same applies to iPhone recordings: the live engine cleans them up like
any chunk, and a one-shot `huske inbox process` does it before publishing.

The design rationale lives in
[ADR 0013](adr/0013-transcript-quality-language-dictionary-llm-cleanup.md)
(providers, Apple bridge, keys, consent) and
[ADR 0005](adr/0005-llm-distillation.md) (the original local correction).

## How it works

```text
ASR writes transcript.md (raw)          ← always first; never blocked by cleanup
        │
        ├── copy ──► transcript.asr.txt (raw, local only, kept forever)
        │
        └── LLM, a few runs at a time, as numbered lines
                  │      (timestamps and sources never reach the model)
                  ▼
        transcript.md rewritten atomically:
          same frontmatter + postprocessed_by / postprocessed_at / raw_transcript
          same timestamps, sources and runs; corrected text
```

- Every returned line is checked on its own. A missing, empty, or wildly
  shorter or longer line keeps its raw text.
- A failure — server down, timeout, no key, no consent — leaves the raw `.md`
  exactly as written. Huske shows one warning and `huske distill` catches up
  later. Recording and Git sync never wait for it.
- Text is sent in small batches sized for each model: about 300 tokens for
  Apple Intelligence (its on-device model cleans short passages well and
  leaves long ones untouched), up to ~1,500 for cloud models. Apple's real
  context window is read from the system (8,192 tokens on macOS 27 with an M3
  or later, 4,096 on older Macs).
- Your [dictionary](#the-dictionary) goes into the prompt, and its
  replacements run again on the model's output.
- The transcript is treated as data: the model is told never to follow or
  answer anything said in it.

The frontmatter of a cleaned-up transcript says who did it and where the raw
text is:

```yaml
postprocessed_by: apple:apple-on-device
postprocessed_at: '2026-11-22T10:12:03-03:00'
raw_transcript: 093000_8a3f2c19_001.asr.txt
```

## Setup

The easiest path is Huske.app → Configuration → **Transcript cleanup**: pick
where it runs, and the app checks it, stores keys in your Keychain, asks for
consent before anything leaves your Mac, and has a **Try it** button. The CLI
does the same:

```bash
huske llm status            # where cleanup runs and whether it can right now
huske llm test              # clean up a built-in synthetic sample
huske config set distill_enabled true
```

### Apple Intelligence

```bash
huske config set distill_backend apple
huske llm status
```

Runs entirely on your Mac. It needs macOS 26 or later on Apple silicon with
Apple Intelligence turned on, and **Huske.app installed** — the app carries
the small helper (`Huske.app/Contents/Helpers/huske-apple-llm`) that talks to
Apple's framework. When it isn't available, `huske llm status` says why in
plain words (Mac not eligible, turned off in System Settings, model still
downloading, …). A copy of Huske.app built without the macOS 26 SDK reports
that too. To use a helper you built yourself, set
`HUSKE_APPLE_LLM_HELPER=/path/to/huske-apple-llm`.

### Built-in model (default)

Nothing to install: `mlx-community/Qwen3.5-0.8B-4bit` downloads on first use
(~0.6 GB) and runs in a private subprocess that exits when idle. Honest note:
the 0.8B model is light enough to run beside transcription but corrects little
— it mostly fixes split words. For noticeably better cleanup use Apple
Intelligence, a 2B model (`mlx-community/Qwen3.5-2B-4bit`), or a larger local
or cloud model.

### Ollama or another local server

```toml
distill_backend = "ollama"            # http://127.0.0.1:11434 by default
distill_model = "qwen3.5:2b"
```

```toml
distill_backend = "openai_compatible" # LM Studio: http://127.0.0.1:1234/v1
# distill_endpoint = "http://127.0.0.1:8080"   # llama.cpp, vLLM, … (/v1 is added)
# distill_model unset = the first model the server lists
```

Huske can start `ollama serve` and pull a missing model when
`distill_auto_manage = true`; it never installs Ollama. An endpoint that isn't
on this Mac (a LAN box, a `.local` name, a hosted service) counts as sending
text off your Mac and needs consent, like a cloud provider.

### A cloud provider with your API key

```bash
huske config set distill_backend anthropic     # or openai, openrouter
huske llm key set anthropic                    # prompts; or pipe the key on stdin
huske llm models                               # pick one
huske config set distill_model claude-haiku-5-5
huske llm allow-cloud                          # shows what will be sent, asks first
huske llm test
```

- **Keys live in the macOS Keychain** (item "Huske — Anthropic API key"),
  written and read through `/usr/bin/security`. They are never in the config
  file, logs, the app's snapshot or error messages, and never on a command
  line (`huske llm key set` reads stdin).
- **Consent is per host.** Huske refuses to send transcript text off your Mac
  until `distill_cloud_consent` names the provider's host (`api.anthropic.com`).
  `huske llm allow-cloud --revoke` withdraws it; switching provider asks again.
- **What is sent:** the text of each transcript run (no timestamps, no audio,
  no file names) plus the cleanup instructions and your dictionary. Audio
  never leaves your Mac.
- Anthropic uses its Messages API (default model `claude-haiku-5-5`); OpenAI
  and OpenRouter use `/chat/completions` and need a model chosen
  (`huske llm models`). For any other OpenAI-compatible service (a proxy,
  Groq, Together, …) use `openai_compatible` with its `distill_endpoint`.

### Extra instructions

```toml
distill_instructions = "Remove filler words like 'né' and 'tipo'."
```

Appended to the built-in rules. It can change style; it can't break the
format rules that keep timestamps and lines intact.

## The dictionary

Names, products and jargon you want spelled your way — shared by
transcription and cleanup:

```toml
vocabulary = ["Kubernetes", "OKR", "Huske", "Jira"]

[vocabulary_replacements]   # what the engine wrote = what it should be
"cube ernetes" = "Kubernetes"
"gira" = "Jira"
```

- **Replacements** apply to every transcript right after transcription, on
  every engine: case-insensitive, whole words only.
- **Distinctive capitalisation** in `vocabulary` (an upper-case letter after
  the first: `OKR`, `GitHub`, `iPhone`) is restored when the transcript has it
  in another case. Plain title-case words (`Kubernetes`, `Go`) are not
  rewritten, since they can be ordinary words — they are left to the next two.
- **Whisper** gets the words as its prompt, carried to every 30-second window.
- **Parakeet** can listen for them too with `parakeet_word_boost = true`
  (beam search with word boosting: about 4–5× slower decoding, still well
  above real time; on our test it spelled 12 of 14 jargon terms right instead
  of 8).
- **Cleanup** sees them as spellings to enforce.

## Backfill and re-runs

```bash
huske distill            # clean up transcripts that haven't been
huske distill --force    # redo all of them from the raw .asr.txt
huske distill --fast     # without lowering CPU priority
```

`--force` re-reads `.asr.txt`, so trying another provider never compounds a
previous model's edits. Enabling cleanup does not trigger a surprise backfill.

## Configuration

| Key | Default | Meaning |
| --- | --- | --- |
| `distill_enabled` | `false` | Clean up each finished transcript. |
| `distill_backend` | `"mlx"` | `apple`, `mlx`, `ollama`, `openai_compatible`, `openai`, `anthropic`, `openrouter`. |
| `distill_model` | unset | Backend's default when unset (see above). |
| `distill_endpoint` | unset | Base URL for `ollama` / `openai_compatible`. |
| `distill_cloud_consent` | unset | The one host transcript text may be sent to (`huske llm allow-cloud`). |
| `distill_instructions` | `""` | Extra instructions appended to the built-in rules. |
| `distill_context_tokens` | unset | Override the model's context window used for batching. |
| `distill_timeout_seconds` | `120.0` | Per-request deadline. |
| `distill_auto_manage` | `true` | Start Ollama and pull a missing model when possible. |
| `distill_low_impact` | `true` | Throttle the `huske distill` backfill. |
| `distill_think` | `false` | Allow a reasoning pass (Ollama only). |
| `vocabulary` | `[]` | Spellings to prefer (see [the dictionary](#the-dictionary)). |
| `vocabulary_replacements` | `{}` | Heard → written replacements. |
| `parakeet_word_boost` | `false` | Let Parakeet listen for `vocabulary` words (slower). |

`distill_model = "heuristic"` selects a deterministic identity pass used by
the test suite. `distill_max_statements_per_passage` is accepted for old
configs and unused.

## Footprint and privacy

- On-device backends (`apple`, `mlx`) never open a network connection. Apple's
  model is managed by macOS; the built-in model's process exits after two
  minutes idle so macOS can reclaim its memory, and it never shares the GPU
  with transcription at the same moment.
- Local servers receive transcript text over loopback. Pointing an endpoint
  elsewhere sends it to that machine — Huske asks for consent first.
- Cloud providers receive transcript text under their own terms and
  retention. That is a deliberate, two-step opt-in: choosing the provider and
  allowing its host.
- The raw transcript is always kept locally in `<name>.asr.txt`; it is never
  synced.

## Troubleshooting

- `huske llm status` (or `huske doctor`) names the problem and the fix.
- **Apple Intelligence "isn't available"**: follow the hint; if it says
  Huske.app wasn't found, install the app in Applications.
- **"no API key"**: `huske llm key set <provider>`; **"needs your consent"**:
  `huske llm allow-cloud`.
- **A local server "is not answering"**: start it (LM Studio: Developer →
  Start server) or fix `distill_endpoint`.
- **A cleanup looks wrong**: the raw text is in the sibling `.asr.txt`. Try a
  stronger model and `huske distill --force`, or copy the raw text back.
