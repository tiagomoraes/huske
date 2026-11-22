---
status: accepted
date: 2026-11-22
---

# Transcript quality: language, dictionary, and LLM cleanup with any provider

## Context

Real meetings showed three quality gaps:

1. **Language.** Portuguese meetings full of English jargon were garbled.
   Parakeet guesses the language once per decode window, and on code-switched
   speech the guess can collapse into English.
2. **Jargon.** Names, products and acronyms ("Huske", "Jira", "Stripe", "OKR")
   came out misspelled ("USC", "Gira", "strip").
3. **Polish.** Punctuation, casing and misheard words could be fixed after
   transcription by a language model. ADR 0005 already did this with a small
   local model, but people also want Apple Intelligence, the local server they
   already run (Ollama, LM Studio), or a cloud model with their own key. The
   open-source dictation app Handy offers that set of choices.

Engine capabilities, checked against the source code and the model cards:

| | Pin the language | Bias toward a dictionary |
|---|---|---|
| `parakeet-tdt-0.6b-v3` | **No.** The model has no language input. NVIDIA's answer: "only with canary". A priming PR in parakeet-mlx was closed unmerged, and Huske's own experiment found priming changes nothing. | **Word boosting** (parakeet-mlx 0.7+), on **beam search only**. |
| Whisper (mlx-whisper) | **Yes.** A language token goes into every window. | `initial_prompt`, a soft bias by imitation. Only the **last 223 tokens** are kept. With `condition_on_previous_text=False` it reaches **only the first 30-s window**. |

Apple Foundation Models (macOS 26+, Apple silicon), checked against Apple's
documentation and a probe on macOS 27.2 with an M3 Pro:

- **Python bindings.** An official Python SDK exists (`apple-fm-sdk` 0.2.2,
  Apache-2.0), but it is an **alpha** distributed as source only. Installing
  it compiles a Swift bridge and needs a **full Xcode**. `/usr/bin/fm` needs a
  machine-wide `sudo fm license` and its terms forbid programmatic use.
- **Command-line use.** The on-device model works from a plain, ad-hoc-signed
  command-line binary with no entitlement.
- **Context window.** TN3193's figure of **4,096 tokens** is stale on macOS 27.
  `SystemLanguageModel.contextSize` reports **8,192** on "AFM 3 Core
  Advanced", and the overflow error confirms it.
- **Chunk size.** Quality, not context, sets it. Paragraphs of 150–300 tokens
  are cleaned up well, while a ~600-token block came back nearly unchanged.
- **Errors.** macOS 26 throws `LanguageModelSession.GenerationError` and
  macOS 27 replaced it with `LanguageModelError`. A binary built against one
  SDK meets the other's types at run time, so `as?` casts miss.

## Decision

### 1. Language — honest per engine

- `language` stays one config key, normalized (`pt-BR` and `Portuguese`
  become `pt`) and validated against Whisper's code table.
- `huske languages` lists the codes and what each engine does with them.
- **Whisper** pins the language.
- **Parakeet** cannot. There, `language` only arms the existing drift guard,
  and the CLI, the app and the docs say so plainly and point to Whisper
  large-v3-turbo.
- An imported recording can carry its own language (`huske import
  --language`, or an optional `language` in the inbox's `recording.json`).

### 2. A custom dictionary, three strengths

The config holds `vocabulary` (target spellings, in priority order) and
`vocabulary_replacements` (heard → written pairs).

- **Deterministic pass, every engine, every transcript.** Replacements are
  case-insensitive, match whole words only (Unicode lookarounds), and the
  longest match wins. Casing is restored only for terms with *distinctive*
  capitalisation ("OKR", "GitHub", "iPhone"). Title-case terms like "Go" are
  never rewritten, because they can be ordinary words.
- **Whisper prompt.** The terms go into a natural sentence in the spoken
  language, measured with Whisper's own tokenizer to stay under 200 tokens.
  A wrapper on `Whisper.decode`, active only during the `transcribe()` call,
  re-attaches the prompt to every 30-s window: openai-whisper's
  `carry_initial_prompt`, which mlx-whisper lacks.
  - On 155 s of synthetic speech, the prompt-only-on-window-1 version spelled
    "Huske" / "Jira" / "Stripe" right once each; the carried prompt got all
    three right every time (3 of 3).
  - Across one 103-s run, terms spelled right went from 8 of 12 to 11 of 12.
  - A segment that is just the prompt read back is dropped. That guard is
    adapted from Handy.
- **Parakeet word boosting, opt-in** (`parakeet_word_boost`). Measured on 52 s
  of synthetic Portuguese:

  | Decoding | Time | Terms spelled right |
  |---|---|---|
  | Greedy | 0.9 s | 8/14 |
  | Beam 5 | 3.4 s | 8/14 |
  | Beam + boost, weight 2 | 4.0 s | 11/14 |
  | Beam + boost, weight 3.5 | 4.0 s | 12/14 |

  A jargon-free control came out identical to greedy, with no inserted terms.
  At about 4.5× the cost it is not on by default. Weight 3.5 with the CLI's
  beam settings. parakeet-mlx < 0.7 falls back to greedy.
- **LLM glossary.** The dictionary also goes into the cleanup prompt (below),
  and the deterministic pass runs again on the LLM's output.

### 3. LLM cleanup — one pipeline, seven backends

The `huske/distill` subsystem (ADR 0005) is generalized rather than
duplicated. The `distill_*` keys and `huske distill` keep their names for
compatibility; the app calls the feature "Transcript cleanup".
`distill_backend` takes one of seven values:

| Backend | Where text goes | Key |
|---|---|---|
| `mlx` (default) | built-in Qwen subprocess on this Mac | — |
| `apple` | Apple's on-device model, via the helper below | — |
| `ollama` | local daemon | — |
| `openai_compatible` | LM Studio, llama.cpp, vLLM…; off the Mac if the endpoint isn't loopback | optional |
| `openai` / `anthropic` / `openrouter` | the provider's cloud | required |

- **Raw first, never lost.**
  - The ASR worker writes the raw `.md` as before.
  - Cleanup snapshots it to `<name>.asr.txt` once, corrects from that
    snapshot, and atomically rewrites the `.md`.
  - The rewrite adds three frontmatter keys: `postprocessed_by:
    <provider>:<model>`, `postprocessed_at`, and `raw_transcript`.
  - Any transport, timeout, key or consent error leaves the raw `.md`
    byte-for-byte untouched, shows one sticky warning, and is retried later
    by `huske distill`.
- **Off the hot path.**
  - Live sessions use the existing worker thread. Local GPU backends share
    the Metal gate with ASR; Apple and cloud backends don't, so they never
    stall ASR.
  - One-shot `huske inbox process` (iPhone recordings with no engine running)
    cleans up after transcription and before Git publication.
- **Runs, not prose.**
  - `[HH:MM:SS · source]` runs are sent as numbered lines inside
    `<transcript>` tags. Timestamps and sources never reach the model.
  - Every returned line is validated on its own. A missing, duplicated,
    empty, or wildly shorter or longer line keeps its raw text.
  - Unmarked lines are accepted by position only when their count matches,
    which is how Apple's model answers.
  - A context overflow or truncated reply splits the batch and retries.
  - A refusal keeps that batch raw.
  - The tokens per request are a **quality budget per provider** (Apple 300,
    built-in 250, local servers 350–400, cloud 1,500), clamped to the
    context window. Apple's window comes from the helper at run time.
- **Prompt.** Tuned on the smallest model we support:
  - A cautious "fix only obvious errors" prompt made Apple's model return
    lines untouched.
  - An editor's brief with concrete duties made it clean up well while
    keeping colloquial forms ("pra", "tá", "a gente"). The duties: punctuate,
    capitalize, rejoin split words, keep the speakers' words.
  - The transcript is declared data, not instructions.
  - User instructions (`distill_instructions`) are appended. They cannot
    override the format rules.
- **Apple Intelligence through a bundled Swift helper.**
  - `huske-apple-llm` ships in `Huske.app/Contents/Helpers`.
  - It speaks JSON lines on stdin/stdout: `status` and `respond`, served
    strictly in order.
  - It runs a fresh `LanguageModelSession` per request, with
    `permissiveContentTransformations` guardrails (Apple's mode for
    transforming user text) and greedy sampling.
  - It maps errors by their reflected case names, so both the macOS 26 and
    macOS 27 error families are covered.
  - It reports availability as plain reasons, rendered by the engine in
    words: device not eligible, turned off, model downloading, OS too old,
    built without the SDK, or helper not found.
  - The engine finds the helper through `HUSKE_APPLE_LLM_HELPER` (set by the
    app), then `/Applications` or `~/Applications`, then `PATH`.
  - Built against an SDK without FoundationModels, the helper still compiles
    and answers `not_built`.
- **Cloud.**
  - Stdlib HTTP only, no new dependency.
  - OpenAI-compatible providers use `/chat/completions`; Anthropic uses the
    native Messages API.
  - Optional speed knobs (temperature 0, reasoning off, token caps) are
    retried away once if a model rejects them.
  - Truncated or refused replies are errors, never results.
- **Keys in the Keychain, via `/usr/bin/security` only.**
  - Engine and app both go through `huske llm key`, so the item's access list
    trusts `security` itself and no "allow access?" dialog appears from a
    background daemon.
  - Writes are piped to `security -i`, so the key never appears in any argv.
  - Keys are never in config, logs, snapshots or error messages.
  - `HUSKE_KEYCHAIN` redirects to a throwaway keychain for tests.
- **Consent is per host and enforced at send time.**
  - Any target off this Mac needs `distill_cloud_consent` equal to its host:
    a cloud provider, a non-loopback Ollama or OpenAI-compatible endpoint,
    even a `.local` LAN machine.
  - Set it with `huske llm allow-cloud`, which shows the warning first.
  - Switching provider asks again.
  - Named cloud providers always use their official endpoint, so a stale
    endpoint can never receive their key.
  - Listing models sends a key but no transcript text, so it needs no consent.
- **The app is a shell (ADR 0006).**
  - `huske llm status|models|key|allow-cloud|test --json` and `huske
    languages --json` give Huske.app everything it shows.
  - `ControlSnapshot.distill_label` (v4, add-only) names the running backend.

## Consequences

- The transcript contract gains three optional frontmatter keys. The inbox
  contract gains an optional `language`. Both are additive.
- **Release builds.** The Apple helper needs an SDK with FoundationModels
  (Xcode 26+), so the release's app build runs on the `macos-26` runner and
  selects the newest stable Xcode ≥ 26 (`macos/scripts/select-xcode.sh`).
  `HUSKE_REQUIRE_APPLE_LLM=1` makes `build-app.sh` fail rather than ship a
  `not_built` helper. A CI job on `macos-26` packages the app the same way on
  every PR. The regular macOS job stays on Xcode 16 and compiles only the
  helper's stub.
- **The built-in 0.8B model barely corrects.** With the old per-run JSON
  prompt or the new one, it mostly echoes its input, though the batched
  prompt is about 7× faster. Apple Intelligence, a 2B+ model or a cloud model
  is where cleanup quality comes from. The docs say so.
- **Cloud backends send transcript text off the Mac** under the provider's
  terms. This is opt-in twice: the backend choice and the per-host consent.
  Audio never leaves.
- **Not done.**
  - Per-provider prompt libraries (Handy's multiple prompts): one appended
    instruction field covers the meeting use case.
  - Boosting in Parakeet's greedy decoder: about 50 lines in parakeet-mlx,
    but it can't retract a partial match.
  - `apple-fm-sdk` in-process: revisit if Apple ships wheels.

## Considered and rejected

- **Calling Foundation Models in-process through `apple-fm-sdk`.** An alpha
  that needs Xcode at install time would break `uv tool` and Homebrew
  installs for most users.
- **The app calling Foundation Models itself and handing text back.** That
  moves pipeline logic into Swift (ADR 0006) and doesn't work when the
  engine runs headless from the LaunchAgent.
- **Storing keys with the Security framework from the app.** The engine
  would trip an access prompt reading them.
- **Python `keyring`.** It has the same prompt problem the other way round,
  and adds a dependency.
- **A blanket "allow cloud" flag.** Consent tied to a host is what makes
  switching provider safe.
- **Sending whole transcripts per request.** Small models pass long blocks
  through unchanged, and a single failure would cost the whole transcript.
