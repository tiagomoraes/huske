# Transcript sync options: agent access and backup without a Huske server

- **Status:** decided. The decision is below; the rest of the document is the
  research behind it.
- **Date:** 2026-11-22. Vendor facts were checked against primary sources on
  that date. Products in this space change monthly, so re-check anything
  load-bearing before building on it.
- **Scope:** how external AI agents (Claude, ChatGPT, Codex, Cursor, GitHub
  Copilot, Gemini) can read private Huske transcripts without the user running
  an MCP server, and how those transcripts get backed up. Huske has no server
  of its own. Today's answer is Git sync to a private GitHub repository
  ([ADR 0009](../adr/0009-git-replica-and-isolated-mcp-service.md)).

## Decision (2026-11-22)

Keep GitHub, the Git CLI publisher, and today's transcript layout (per-day
folders of chunk files). There is no GitHub App, no per-meeting files and no
second target for now. Instead, fix the flow that exists.

The fix PR covers:

- **F1:** a ledger of what Huske published, so distillation updates are
  published. Stuck checkouts heal through the `.asr.txt` snapshot, and a
  conflict no longer blocks other transcripts.
- **F2:** plain-language, correctly classified Git errors.
- **F3:** a transcript deleted in the repository stays deleted, with
  `huske sync --republish` as the override.
- **F4:** endless capped-backoff retries.
- **F5:** a sticky `sync` warning, also shown in the Cloud sync pane.
- **F6:** the old checkout is moved aside when the repository changes.
- **F7:** a cross-process lock and stale `index.lock` cleanup.
- **F9:** clearer `huske sync` messages.
- **Agent readability:** a managed `README.md` and `AGENTS.md` at the
  repository root and in the local output root.
- **Cloud sync pane:** a prefilled private-repository link, a sign-in hint,
  "starts with the next session", and the direct-integration path for AI
  tools.

Deferred:

- F8: credential scope, via a GitHub App or deploy key (L1).
- `INDEX.md` and `index.jsonl`.
- Last-success and pending counts in the control snapshot.
- A `huske doctor` sync check.
- L2–L5.

Section 1 describes `develop` at `9555022`, before the fix.

## Summary

1. **GitHub is still the right primary backend.** It is the only storage that
   every agent studied reads natively, and the coding agents (Codex cloud,
   Copilot cloud agent, Cursor cloud agents, Claude Code on the web) read only
   Git forges, mostly only GitHub. Private repositories are free, versioned and
   portable. GitHub states that private repository content at rest is not used
   to train models.
2. **The current flow is not the best Huske can offer.** One bug is critical:
   with distillation on, sync stops for good after the first polished
   transcript (F1). Every SSH failure shows the same meaningless message (F2).
   Meetings deleted on GitHub come back on the next sync (F3). Failures are
   almost invisible (F5). And nothing in the repository tells an agent how to
   read it.
3. **Recommended:** *GitHub, done right*.
   - Sign in with a Huske GitHub App over the device flow. No SSH keys, no
     `known_hosts`, no client secret.
   - Huske creates the private repository itself.
   - The token is scoped to that one repository and kept in the Keychain.
   - The repository ships with `README.md`, `AGENTS.md` and a generated
     `INDEX.md`.
   - A "Connect an AI tool" guide sits in the Cloud sync pane.
   - Keep the Git CLI publisher underneath, so the VPS service and the Git
     outbox design do not change.
4. **Second, optional target: a folder mirror.** Copy transcripts into a
   folder that Google Drive, Dropbox, OneDrive, iCloud Drive or Syncthing
   already syncs. It needs almost no code and no OAuth in Huske, and it gives
   chat assistants a second way in. Its agent value depends on one thing not
   yet tested: **whether Claude, ChatGPT and Gemini read `.md` files through
   their Drive, Dropbox and OneDrive connectors.** Their docs list Google
   Docs, PDF and Office formats, not Markdown.
5. **If you want end-to-end encrypted backup, use a separate target**
   (restic to Backblaze B2 with a key that cannot delete). Anything an agent
   can read natively is, by definition, plaintext to that agent's vendor and
   the storage provider.
6. **Not recommended as agent targets:**
   - Codeberg: its terms forbid this use.
   - Hugging Face: no agent reads private repository files, and its terms are
     unclear on training.
   - Notion: lossy conversion, and OAuth needs a secret an open-source app
     cannot ship.
   - S3, R2, B2, Syncthing, iCloud Drive and a self-hosted Forgejo: no hosted
     agent reads them natively.

No hosted backend that agents read natively is open source. What stays open is
the format (Markdown with YAML frontmatter), the transport (Git) and the backup
tool (restic). Because a Git history can be mirrored anywhere in one command,
choosing GitHub does not lock the data in.

---

## 1. The current GitHub flow, audited as a new user

### How this was tested

The worktree's own `huske config` and `huske sync` (engine `0.14.0`) ran with
an isolated `HOME`, synthetic transcripts, and a local bare repository as the
remote. SSH failures were reproduced deterministically, without touching the
network, by pointing `GIT_SSH_COMMAND` at a stub that prints the exact message
`ssh` prints for each case. The real distiller function
(`huske.distill.distiller.rewrite_transcript_body`) was used to simulate a
distillation pass. The commands are in
[Appendix A](#appendix-a-reproducing-the-audit).

### Every step from a fresh install to "an agent can read my transcripts"

| # | Step | What the user has to know or do | Evidence |
|---|------|----------------------------------|----------|
| 1 | Have a GitHub account | Outside Huske. | — |
| 2 | Create the repository | **Cloud sync → Create a private repository…** opens a blank `github.com/new`. Nothing is prefilled, and nothing checks that the user picked *Private*. | `macos/Sources/Huske/ConnectView.swift:65-67` |
| 3 | Make Git authentication work with no terminal | An SSH key registered on GitHub, loaded into the agent or Keychain with no passphrase prompt, and `github.com` already in `known_hosts`. Huske's docs never explain any of this. The engine runs under launchd or Huske.app, with no TTY, so `ssh` cannot ask. | `huske/config.py:222-224`, `README.md:286-298` |
| 4 | Paste the SSH URL | Free text. It is validated only against option injection. | `huske/config.py:322-334` |
| 5 | Press **Sync now** | Runs `huske sync`, which clones, commits and pushes. The pane shows its stdout. | `macos/Sources/Huske/AppModel.swift:316-338` |
| 6 | Turn on automatic sync | The toggle is rejected while the URL is empty (`sync_enabled=true requires sync_remote`). The worker is built once, when the session starts, so turning it on mid-session does nothing until the next session. The Configuration pane says so; the Cloud sync pane does not. | `huske/config.py:337-339`, `huske/run_loop.py:209-223`, `macos/Sources/Huske/ConfigView.swift:33` |
| 7 | Give an agent access | The only documented path is the separate `huske-mcp` VPS: a Linux host, a deploy key, a reverse proxy with TLS, a bearer token, and an OAuth proxy for consumer apps. Connecting the repository straight to Claude, ChatGPT or Codex is not mentioned anywhere. | `macos/Sources/Huske/ConnectView.swift:117-141`, `docs/integrations.md:49-55` |

Steps 1–3 and 7 all happen outside Huske, and step 3 is where a new user is
most likely to fail. When it does fail, the error message gives no clue why
(F2).

### Failure modes (each reproduced)

**F1 — critical: distillation permanently breaks sync.** Distillation rewrites
the canonical `.md` in place (`huske/config.py:236-237`,
`huske/distill/distiller.py:249-270,315`), and it then queues sync again
(`huske/run_loop.py:328-332`). Sync, however, treats any change to a
transcript it has already published as a hard, non-retryable conflict
(`huske/sync/client.py:210-214`). The sync and distill jobs are both queued
when the file is written (`huske/run_loop.py:282-285`). Sync finishes in
seconds and distillation takes much longer, so the raw version is pushed first
almost every time.

Reproduced: after a published transcript was rewritten, `huske sync` exited 1
with `immutable transcript conflict at transcripts/2026-11-20/…md`,
`retryable=False`. A transcript recorded the *next* day was **not
published**. The copy loop runs in sorted order and aborts at the first
conflict, so every newer transcript is blocked for good. A `huske distill`
backfill over history does the same thing. The test suite covers sync and
distillation separately, but never together. The only way out is to delete
the file on GitHub by hand (see F3).

**F2 — high: every SSH failure shows the same useless message.**
`_command_error` keeps only the *last* line of Git's stderr
(`huske/sync/client.py:320-333`). For SSH remotes that line is always Git's
boilerplate, `and the repository exists.` Reproduced for four distinct causes:

| Cause | What `ssh` printed | What Huske shows | `retryable` |
|---|---|---|---|
| Key not accepted | `Permission denied (publickey).` | `and the repository exists.` | `True` |
| First connection, no `known_hosts` entry | `Host key verification failed.` | `and the repository exists.` | `True` |
| Offline | `Could not resolve hostname github.com` | `and the repository exists.` | `True` |
| Repository deleted, renamed, or no access | `ERROR: Repository not found.` | `and the repository exists.` | `True` |

The `permission denied` and `repository not found` markers can never match, so
permanent errors get retried and the user is never told which of the four
problems they have.

**F3 — high (privacy): you cannot unpublish a meeting.** The publisher only
adds files (`huske/sync/client.py:196-228`). Reproduced: two transcripts were
deleted from the remote, as a user would in the GitHub web UI, and the next
`huske sync` quietly pushed them back. To remove a meeting, the user has to
delete it locally first, then delete it remotely, and then rewrite Git
history, because every earlier version (including the raw pre-distillation
text) stays in history.

**F4 — medium: retries give up after about a minute.** The worker makes 6
attempts with 2/4/8/16/30 s backoff and then stops
(`huske/sync/worker.py:101-109`). The next try happens only when another
transcript is finalized or a new session starts. A meeting recorded offline at
the end of the day stays unpublished until the next recording.

**F5 — medium: background failures are nearly invisible.** A worker error
becomes one `warn` line in the Record view's Activity feed
(`huske/run_loop.py:296`). That feed is a 5-entry ring buffer
(`huske/models.py:122`). The error is not a sticky warning, it is not in the
control snapshot, and it is not shown in the Cloud sync pane. That pane only
shows the last manual **Sync now** result, with no "last synced", no pending
count and no error. `huske doctor` has no sync check at all.

**F6 — medium: changing the repository is a dead end.** After a URL change,
sync refuses with `sync checkout points at a different remote; remove or move
~/huske/sync before changing sync_remote` (`huske/sync/client.py:136-146`). A
GUI user has to delete a hidden folder in Finder.

**F7 — low/medium: no lock between the app and the engine.** **Sync now**
starts a second process on the same checkout that the engine's worker is
using. Reproduced with a held `index.lock`: `Another git process seems to be
running in this repository…`. If a crash leaves the lock behind, every later
sync fails the same way (classified as retryable) until someone deletes it by
hand.

**F8 — low/medium: the credential is broader than the job.** "Huske stores no
GitHub token" is true. But a personal SSH key authenticates *as the user* and
can push to every repository the account can write to. GitHub contrasts it
with a deploy key, which grants "access to a single repository"
([deploy keys](https://docs.github.com/en/authentication/connecting-to-github-with-ssh/managing-deploy-keys)).
Huske only needs one repository.

**F9 — low: misleading success messages.** `repository is already current` is
printed both when nothing exists yet and when files whose names don't match
the transcript naming pattern (`huske/sync/client.py:27-29`) were silently
skipped.

**What already works well.** A deleted repository recreated empty at the same
URL heals itself: the next sync pushed the full history again. Offline never
loses data, because the source tree is the real outbox. (Offline, the fetch
fails before anything is committed, `huske/sync/client.py:118-122`, so the
"Git commit is the outbox" claim is weaker than ADR 0009 says.) Symlinks, path
escapes and option-injected remotes are all refused.

### What an agent actually sees in the repository

```text
transcripts/
  2026-11-19/091500_8a3f2c19_001.md
  2026-11-19/093000_8a3f2c19_002.md
  2026-11-20/140000_b71e0440_001.md
```

- **No README, AGENTS.md or index.** The engine already writes a good
  agent-oriented `README.md` at the output root (`huske/output_readme.py`).
  Sync never copies it, because it only copies `YYYY-MM-DD/*.md`
  (`huske/sync/client.py:61-79`). Confirmed: the published tree has only
  `transcripts/`.
- **Files are chunks, not meetings.** A chunk closes after 60 s of silence or
  at a 15-minute cap (`huske/config.py:83,92`), so a one-hour meeting is at
  least four files. File names (`HHMMSS_<session8>_<seq>.md`) carry no title,
  participants or topic. The frontmatter is accurate but has no title or
  summary.
- **The agent-friendly derivatives exist but stay local.** These are the
  per-day digests from `huske export` and the distilled statement sidecars
  (`docs/integrations.md:67-68`).
- Every commit is `huske <sync@huske.local>` with the message `sync: add N
  transcript(s)`. That is fine for a machine-written log, but it gives an
  agent nothing to navigate by.

This matters because the agents read the repository in different ways. Claude's
GitHub integration copies the files you select into the conversation, so the
selection has to fit in the context window
([Claude GitHub](https://claude.com/docs/connectors/github)). ChatGPT fetches
files on demand, but its repository picker "searches repository names, not
files" ([ChatGPT GitHub](https://help.openai.com/en/articles/11145903)). Coding
agents read `AGENTS.md` before they start work (see §4). With no index or
instructions, each agent has to open and guess its way through hundreds of
opaque chunk files.

---

## 2. Which agents read which services natively

Here **native** means the user signs in from the agent's own settings, with no
server to run and no config file to edit. Several of these "connectors" are
remote MCP servers run by the vendor
([Claude connector directory](https://claude.com/docs/connectors/directory)).
That still counts as native, because the user sets up nothing.

### Matrix (personal accounts, late 2026)

| Agent | GitHub (private) | GitLab | Google Drive | Dropbox | OneDrive (personal) | Notion | S3 / R2 / B2 | HF private | iCloud Drive | Local folder |
|---|---|---|---|---|---|---|---|---|---|---|
| **Claude** (web, desktop, mobile) | ✅ all plans; attach or sync into context; manual **Sync now** | ❌ | ✅ all plans; live search; **`.md` not in the documented file types** | ✅ | ✅ (Microsoft 365 connector; `.md` undocumented) | ✅ | ❌ | ❌ (search only) | ❌ | ✅ Cowork (paid), folders you connect |
| **Claude Code** | ✅ CLI (`git`/`gh`); cloud sessions are GitHub-only (Pro and up) | CLI only | ✅ connectors carry over from claude.ai | ✅ | ✅ | ✅ | ❌ | ❌ | local path only | ✅ |
| **ChatGPT** | ✅ read-only, live, selected repos; on some plans only in deep research or Work | ✅ beta | ✅ live; `.md` undocumented | ✅ (app and Library) | ❌ (work/school accounts only; `.md` not in search types) | ✅ | ❌ (custom MCP only) | ⚠ third-party plugin, unverified | ❌ (Mail and Calendar only) | ✅ desktop app, Work (paid) |
| **Codex** | ✅ cloud (Plus and up); CLI on any plan | ✅ cloud beta | ⚠ plugin (desktop app, CLI) | ⚠ plugin or MCP | ⚠ plugin or MCP | ⚠ plugin or MCP | ❌ | ❌ | local path only | ✅ CLI, IDE, desktop app |
| **Cursor** | ✅ local agent; cloud agents on Premium ($30) and up | ✅ | ⚠ one-click marketplace MCP | ⚠ same | ⚠ same | ⚠ same | ❌ | ⚠ marketplace | local path only | ✅ |
| **GitHub Copilot** | ✅ Chat and Spaces (including Free); cloud agent on paid plans | ❌ (cloud agent is GitHub-only) | ❌ | ❌ | ❌ | ✅ connector (preview) | ❌ | ❌ | local path only | ✅ CLI, VS Code, app |
| **Gemini app** | ⚠ one-off import, ≤5,000 files / 100 MB, not re-synced | ❌ | ✅ reads "document, spreadsheet, presentation, or PDF"; **`.md` unverified** | ⚠ US-only | ❌ | ❌ | ❌ | ❌ | ❌ | upload only |
| **Gemini Notebook** (formerly NotebookLM) | ❌ | ❌ | ✅ Drive sources re-sync "every few minutes"; 50–600 sources per notebook depending on plan | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | `.md` upload, no sync |
| **Microsoft Copilot** (consumer) | ❌ | ❌ | ✅ connector | ❌ | ✅ connector (`.md` not listed) | ❌ | ❌ | ❌ | ❌ | Windows only |

Legend: ✅ native · ⚠ partial or with caveats · ❌ not native (MCP only or
unsupported).

**What the matrix says:**

- **GitHub is the only backend every agent reads**, and the coding agents read
  only Git forges. GitLab is a distant second: ChatGPT and Codex (beta) and
  Cursor read it, but Claude, Copilot and Gemini do not.
- **Google Drive is the best non-Git option, but only for chat assistants**
  (Claude, ChatGPT, Gemini, Gemini Notebook, Microsoft Copilot). Copilot and
  the cloud coding agents can't read it, and **no vendor documents reading
  Markdown files from Drive**.
- **Nobody reads** S3, R2, B2, private Hugging Face files, iCloud Drive,
  Syncthing or a self-hosted forge natively.
- **Agents on the same Mac need no sync at all.** Claude Code, Codex CLI,
  Cursor, Copilot CLI, Antigravity CLI, ChatGPT desktop (Work) and Claude
  Cowork all read a local folder natively. The cheapest improvement for them
  is an `AGENTS.md` in `~/huske/transcripts`.

**Notes that change the picture:**

- **Claude.**
  - GitHub works on every plan with private repos through the Claude GitHub
    App, and it is refreshed by hand: "select Sync now … to fetch the latest
    changes." The selected content must fit in the context window
    ([connector](https://claude.com/docs/connectors/github),
    [help](https://support.claude.com/en/articles/10167454-use-the-github-integration)).
  - The Google Drive connector's readable types are Docs, Sheets, Slides, PDF,
    Office, OpenDocument and images
    ([Drive connector](https://claude.com/docs/connectors/google/drive)).
  - Connectors added in claude.ai carry over to Claude Code
    ([getting started](https://claude.com/docs/connectors/getting-started)).
  - Claude Code on the web clones GitHub only; for other forges you upload a
    bundle
    ([Claude Code on the web](https://code.claude.com/docs/en/claude-code-on-the-web)).
- **ChatGPT.**
  - Pre-indexed "synced" connectors were retired in Aug–Oct 2026, and apps now
    read live ([release notes](https://help.openai.com/en/articles/10128477)).
  - The GitHub app is read-only and limited to the repositories you pick at
    install ([GitHub app](https://help.openai.com/en/articles/11145903)).
  - The SharePoint/OneDrive app does not support personal OneDrive, and its
    search covers `.txt` but not `.md`
    ([SharePoint](https://help.openai.com/en/articles/12143177)).
  - Per-plan gating for each app is no longer published: "App availability
    depends on the app, your ChatGPT plan, region, workspace…"
    ([connected apps](https://help.openai.com/en/articles/11487775)).
- **Codex.** Codex cloud checks out "any repository available to Codex
  through your connected GitHub or GitLab account"
  ([Codex cloud](https://learn.chatgpt.com/docs/cloud)). It is not included on
  Free or Go ([plans](https://help.openai.com/en/articles/11369540)).
- **Cursor.** Cloud agents clone from GitHub, GitLab, Azure DevOps and
  Bitbucket Cloud only, on Premium and higher plans
  ([cloud agents](https://cursor.com/docs/cloud-agent)). Drive, OneDrive,
  Dropbox and Notion come in as one-click MCP plugins
  ([marketplace](https://cursor.com/marketplace)).
- **GitHub Copilot.**
  - The cloud agent "only works with repositories hosted on GitHub"
    ([cloud agent](https://docs.github.com/en/copilot/concepts/agents/cloud-agent/about-cloud-agent)).
  - Spaces are available on Copilot Free and accept repositories and pasted
    "transcripts, notes"
    ([Spaces](https://docs.github.com/en/copilot/concepts/context/spaces)).
  - Its new "Copilot connectors" include Box and Notion but not Drive,
    OneDrive or Dropbox
    ([supported connectors](https://docs.github.com/en/copilot/reference/supported-connectors)).
- **Gemini.**
  - Gemini can't read "any content that isn't in a document, spreadsheet,
    presentation, or PDF"
    ([help](https://support.google.com/gemini/answer/14959807)).
  - GitHub import is a snapshot: "changes to the repository aren't synced"
    ([import code](https://support.google.com/gemini/answer/16176929)).
  - Gemini Notebook (formerly NotebookLM) auto-syncs Drive sources
    ([sources](https://support.google.com/gemininotebook/answer/16215270)).
  - Jules is shutting down on 2026-12-31
    ([changelog](https://jules.google/docs/changelog/2026-10-29/)).
  - Gemini CLI's Google login was replaced by Antigravity CLI on 2026-06-18
    ([announcement](https://developers.googleblog.com/en/an-important-update-transitioning-gemini-cli-to-antigravity-cli/)).

### Training and data-use settings (what the "Connect an AI tool" guide must mention)

| Vendor | Content read through connectors | Setting to check |
|---|---|---|
| Anthropic (consumer plans) | Raw connector content is not used for training, unless it is copied into the conversation. Conversations are used for training if "Help improve Claude" is on. ([privacy](https://privacy.claude.com/en/articles/10023580-is-my-data-used-for-model-training)) | Turn off "Help improve Claude" |
| OpenAI (Free, Go, Plus, Pro) | "may use information accessed from apps to train our models if your 'Improve the model for everyone' setting is on." Business, Enterprise and Edu: not by default. ([connected apps](https://help.openai.com/en/articles/11487775)) | Turn off "Improve the model for everyone" |
| GitHub | "We do not use private repository content at rest to train AI models." Copilot Free, Pro, Pro+ and Max *interaction data* is used unless you opt out. ([changelog](https://github.blog/changelog/2026-03-25-updates-to-our-privacy-statement-and-terms-of-service-how-we-use-your-data/)) | Copilot settings → disable "Allow GitHub to use my data for AI model training" |
| Google Gemini (personal) | Google trains on "summaries, excerpts… and inferences" from connected-app data, and some of it is human-reviewed. Google itself says: "don't connect your apps to Gemini Apps if they contain confidential information that you wouldn't want a reviewer to see." ([privacy](https://support.google.com/gemini/answer/16836988)) | **Advise against** connecting Drive to the personal Gemini app for transcripts. Gemini Notebook personal: not used for direct training ([Notebook privacy](https://support.google.com/gemininotebook/answer/17004255)) |
| Cursor | Privacy Mode on: no training ([data use](https://cursor.com/data-use)) | Turn on Privacy Mode |
| Microsoft Copilot (new consumer app) | File contents "aren't used to train foundation models" ([privacy](https://support.microsoft.com/en-us/privacy/microsoft-copilot/activity-history)) | — |

---

## 3. Candidate backends

### 3.1 GitHub, done differently

**Authentication options for a desktop app writing to one repository:**

- **GitHub App with device flow (best fit).**
  - It needs no client secret, even to refresh: the secret is "Required
    unless the user access token was generated using the device flow"
    ([refreshing tokens](https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/refreshing-user-access-tokens)).
  - User tokens expire after 8 hours and refresh tokens after 6 months.
  - The token request can pass a `repository_id`, which narrows the token to
    a single repository
    ([user access tokens](https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/generating-a-user-access-token-for-a-github-app)).
  - Since 2026-10-13, a **Repository creation** permission lets an app create
    repositories without Administration rights, and "the app or user that
    created it will be given access to it"
    ([changelog](https://github.blog/changelog/2026-10-13-github-app-improvements-for-least-privilege-and-management)).
  - *Still to prototype:* on a personal account installed with "Only select
    repositories", does a repository created with the user's token join the
    installation automatically? Can that install be saved with zero
    repositories?
- **OAuth App, or reusing the `gh` token: avoid.** No OAuth scope is narrower
  than `repo`, which covers every repository the user can reach. `gh` also
  asks for `read:org` and `gist`
  ([OAuth scopes](https://docs.github.com/en/apps/oauth-apps/building-oauth-apps/scopes-for-oauth-apps),
  [gh auth flow](https://raw.githubusercontent.com/cli/cli/trunk/internal/authflow/flow.go)).
- **Fine-grained PAT.** It can be limited to one repository with Contents
  read/write. The creation form can be prefilled by URL, but no parameter
  selects the repository, so the user still picks it and pastes the token
  back
  ([PATs](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens)).
- **Deploy key.** One repository, optionally write-enabled, and it can be added
  through the REST API with Administration: write. The downside: "credentials
  that don't have an expiry date"
  ([deploy keys](https://docs.github.com/en/authentication/connecting-to-github-with-ssh/managing-deploy-keys)).
  An app-generated deploy key is the smallest change from today: keep SSH,
  but use a key scoped to one repository instead of the user's account key.

**Other facts:**

- **Creating the repository without the API.** `github.com/new` officially
  accepts `name`, `description`, `visibility=private` and `owner` as query
  parameters
  ([creating a repository](https://docs.github.com/en/repositories/creating-and-managing-repositories/creating-a-new-repository)).
- **Writing without the Git CLI.** GraphQL `createCommitOnBranch` writes
  several files in one commit, with an optimistic `expectedHeadOid` check,
  and the commits are signed by GitHub
  ([GraphQL commits](https://docs.github.com/en/graphql/reference/commits)).
  It would remove the dependency on Git and SSH. But the Git CLI already
  works, already is the durable outbox, and the VPS service relies on the
  same history, so an HTTPS token passed to `git` gives most of the benefit
  for a fraction of the work.
- **Limits and cost.** The Free plan includes unlimited private repositories.
  GitHub recommends keeping a repository under about 1 GB and enforces a
  limit of 3,000 entries per directory, which per-day folders stay far below
  ([repository limits](https://docs.github.com/en/repositories/creating-and-managing-repositories/repository-limits)).
- **Encryption at rest.** The only primary source is a 2019 changelog:
  "encrypted at rest, by default"
  ([changelog](https://github.blog/changelog/2019-05-22-git-data-encryption-at-rest/)).

### 3.2 Other Git forges

- **GitLab.com.**
  - The Free tier gives 10 GiB per project.
  - Project access tokens require Premium on GitLab.com. On Free, the
    narrowest credentials are a fine-grained PAT (generally available since
    19.2) or a project deploy key with write access
    ([project tokens](https://docs.gitlab.com/user/project/settings/project_access_tokens/),
    [fine-grained PATs](https://docs.gitlab.com/auth/tokens/fine_grained_access_tokens/),
    [deploy keys](https://docs.gitlab.com/user/project/deploy_keys/)).
  - The device flow exists, but its OAuth scopes cover every project
    ([OAuth 2](https://docs.gitlab.com/api/oauth2/)).
  - It is read natively by ChatGPT, Codex and Cursor, but not by Claude,
    Copilot or Gemini.
  - Huske's Git publisher already works with any remote. This is mostly
    documentation plus better error messages.
- **Codeberg: not allowed.** Its terms allow private repositories only for
  FLOSS work or "really small & personal stuff", not "a personal cloud or
  media storage"
  ([terms](https://codeberg.org/codeberg/org/src/branch/main/TermsOfUse.md)).
  The FAQ caps private content at 100 MB
  ([FAQ](https://docs.codeberg.org/getting-started/faq/)).
- **Forgejo, self-hosted.**
  - GPLv3+, and since v15 it supports tokens limited to specific repositories
    ([v15 release](https://forgejo.org/2026-04-release-v15-0),
    [token scopes](https://forgejo.org/docs/latest/user/token-scope/)).
  - It has no device flow, and its OAuth tokens carry full user rights.
  - **No hosted agent reads it.** It is a good place for a backup mirror
    (`git push --mirror`), not for agent access.

### 3.3 A synced folder (zero authentication code in Huske)

- **Google Drive for desktop on macOS.**
  - Streamed files live in `~/Library/CloudStorage` and become on-demand
    placeholders.
  - But "Other folders on your device… can only be mirrored", so the user can
    add `~/huske/transcripts` itself as a mirrored folder. It stays a plain
    local folder, and Huske needs no code at all
    ([stream vs mirror](https://support.google.com/drive/answer/13401938)).
  - Google documents no conflict-copy name; a conflicting edit is saved "under
    its original parent folder"
    ([sync errors](https://support.google.com/drive/answer/2565956)).
- **Dropbox and OneDrive.**
  - Both require the File Provider location, and its path can't be changed
    ([Dropbox](https://help.dropbox.com/installs/macos-faqs),
    [OneDrive](https://support.microsoft.com/office/save-disk-space-with-onedrive-files-on-demand-for-mac-529f6d53-e572-4922-a585-e7a318c135f0)).
  - Files can be turned into online-only placeholders when the disk runs low.
  - Dropbox creates "conflicted copy" files
    ([Dropbox conflicts](https://help.dropbox.com/organize/conflicted-copy)).
  - Huske would copy into those folders rather than record there.
- **iCloud Drive: agents can't read it.**
  - With *Optimize Mac Storage*, files are evicted to placeholders.
  - When versions conflict, iCloud asks which to keep, and "Versions you don't
    select are deleted" ([iCloud](https://support.apple.com/guide/mac-help/mh40780/mac)).
  - With Advanced Data Protection it is end-to-end encrypted
    ([ADP](https://support.apple.com/en-us/102651)).
  - No agent reads it. It is good as a private backup, useless for agents.
- **macOS File Provider caveats for a background writer.**
  - Touching an online-only (dataless) file can hang or fail with `ETIMEDOUT`
    or `EDEADLK`, even on a plain `stat`
    ([TN3150](https://developer.apple.com/documentation/technotes/tn3150-getting-ready-for-data-less-files)).
  - macOS may prompt to "access files managed by your file provider"
    ([prompt](https://support.apple.com/guide/mac-help/apps-access-files-managed-file-provider-mchl4206cab8/mac)).
  - The engine should write atomically (temp file, then rename), never read
    back from the cloud folder, and check that the target folder still exists
    before writing.

### 3.4 Drive, Dropbox and OneDrive APIs

- **Google Drive API.**
  - The `drive.file` scope is non-sensitive and limited to files the app
    created or opened, so no security assessment is needed
    ([scopes](https://developers.google.com/workspace/drive/api/guides/api-specific-auth)).
  - Desktop apps use a loopback redirect with PKCE and are treated as public
    clients ([native apps](https://developers.google.com/identity/protocols/oauth2/native-app)).
  - Apps still in "Testing" status get refresh tokens that expire after 7 days
    ([OAuth](https://developers.google.com/identity/protocols/oauth2)), and a
    shipped app needs brand verification to show its name
    ([brand verification](https://support.google.com/cloud/answer/15549049)).
  - **It can convert Markdown to a Google Doc on upload**
    ([uploads](https://developers.google.com/workspace/drive/api/guides/manage-uploads)).
    That is the one thing a synced folder can't do, and it matters if the
    Drive connectors won't read `.md`.
  - Note that rclone's shared Google client ID is being retired during 2026
    ([rclone Drive](https://rclone.org/drive/)).
- **Dropbox API.**
  - An "App folder" app works with PKCE and no secret, and its refresh tokens
    last until revoked.
  - Once 50 users link the app, there is a two-week window to get production
    approval before new sign-ups freeze
    ([OAuth](https://docs.dropboxapi.com/dropbox-api/docs/oauth),
    [developer guide](https://docs.dropboxapi.com/dropbox-api/docs/developer-resources/developer-guide)).
- **OneDrive (Microsoft Graph).**
  - `Files.ReadWrite.AppFolder` is documented as personal-accounts-only in one
    place and as working for both account types in another
    ([permissions](https://learn.microsoft.com/en-us/onedrive/developer/rest-api/concepts/permissions_reference?view=odsp-graph-online),
    [app folder](https://learn.microsoft.com/en-us/graph/onedrive-sharepoint-appfolder)).
  - Work tenants also need a verified publisher.

Each of these is a full OAuth integration with its own vendor review process,
which means continuing maintenance for a small project.

### 3.5 S3-compatible storage, Notion, Hugging Face, Syncthing

- **Cloudflare R2.**
  - 10 GB free and no egress fees.
  - Tokens can be limited to one bucket, but not to a path prefix.
  - No versioning and no S3 Object Lock
    ([pricing](https://developers.cloudflare.com/r2/pricing/),
    [tokens](https://developers.cloudflare.com/r2/api/tokens/),
    [S3 compatibility](https://developers.cloudflare.com/r2/api/s3/api/)).
- **Backblaze B2.**
  - 10 GB free.
  - A key can be limited to a bucket and prefix with write-only rights: it can
    add new versions but can't read data back or delete history. Object Lock
    is supported
    ([create key](https://www.backblaze.com/apidocs/b2-create-key),
    [Object Lock](https://www.backblaze.com/docs/cloud-storage-object-lock)).
  - That makes it the best credential model for **backup**, but no agent reads
    it.
- **Notion.**
  - The API now accepts Markdown. Limits are 5,000 blocks per page, 500 KB
    per request and 3 requests per second
    ([Markdown](https://developers.notion.com/guides/data-apis/working-with-markdown-content),
    [limits](https://developers.notion.com/reference/request-limits)).
  - Claude, ChatGPT and Copilot read it.
  - Public OAuth needs a client secret
    ([authorization](https://developers.notion.com/docs/authorization)), so an
    open-source app must use per-user internal tokens or a broker server.
  - YAML frontmatter has no native mapping. It is a viable sink but a lossy
    mirror; not recommended.
- **Hugging Face private datasets.**
  - The easiest to code: `huggingface_hub`, device-code login, and a
    `contribute-repos` scope ([OAuth](https://huggingface.co/docs/hub/oauth)).
  - New repositories are public unless `private=True` is passed
    ([API](https://huggingface.co/docs/huggingface_hub/package_reference/hf_api)).
  - Its terms let it "learn from data relating to your use"
    ([terms](https://huggingface.co/terms-of-service)), and at-rest encryption
    of Git-backed repositories is not documented.
  - No agent reads private repository files; Claude's Hugging Face connector
    only searches the hub
    ([connector](https://claude.com/marketplace/connectors/hugging-face)).
  - Not recommended.
- **Syncthing.**
  - MPL-2.0, peer-to-peer, no cloud copy. In its own words, "not a great
    backup application" because deletions propagate
    ([FAQ](https://docs.syncthing.net/users/faq.html)).
  - Useful for replicating to your own NAS or VPS. No agent reads it.

### 3.6 Encrypted backup only

- **restic.**
  - BSD-2 licensed; data, filenames and snapshots are encrypted with AES-256
    and Poly1305.
  - `rest-server --append-only` blocks deletion, but restic "is not designed
    to protect against attackers deleting files at the storage location"
    ([references](https://restic.readthedocs.io/en/stable/100_references.html),
    [rest-server](https://github.com/restic/rest-server)).
- **rclone crypt.** Per-file encryption (XSalsa20-Poly1305, with encrypted
  names) ([crypt](https://rclone.org/crypt/)).

**The tension, stated plainly.** If a connector can read a file, the vendor can
read it too. If something is end-to-end encrypted (restic, crypt, iCloud with
ADP, Syncthing untrusted peers), no agent can read it. So **agent access and
end-to-end-encrypted backup must be two separate targets with separate
credentials.** GitHub's history already gives a versioned off-site copy. It is
just not end-to-end encrypted.

### 3.7 Comparison table

Effort is Huske-side work: **S** about days, **M** about one to two weeks,
**L** more than that or ongoing vendor review.

| Backend | User setup | Narrowest credential | Agents that read it natively | Open source / self-host | Who can read / leaked credential | Cost | Offline, conflict, deletion | Effort, maintenance risk |
|---|---|---|---|---|---|---|---|---|
| **GitHub today** (Git CLI + account SSH key) | Create repo by hand, set up SSH, paste URL | none (account-wide) | all | Git yes, host no | GitHub. Leaked key → every repo the account can write to | free | outbox safe; F1–F7 | built; bugs to fix |
| **GitHub done right** (App + device flow + auto-create) | Click "Connect GitHub", enter code | Contents read/write on one repo, 8 h token | all | Git yes, host no | GitHub. Leaked token → one repo for ≤8 h (refresh token ≤6 months) | free | same outbox; Huske can delete paths via commits | **M**; registering the App is a one-time outward-facing step |
| GitHub + generated deploy key | Click, paste public key (or added via API) | one repo, SSH, no expiry | all | same | one repo until removed | free | same | **S** |
| GitLab.com | Create project, fine-grained PAT or deploy key | one project | ChatGPT, Codex, Cursor | GitLab CE self-host | GitLab. One project | free (10 GiB) | same as Git | **S** (already works; docs and errors) |
| Codeberg / Forgejo | Account or server, token | specific repos | none | yes (GPLv3+) | you / Codeberg | free / VPS | Git | S, but Codeberg terms forbid it |
| Folder mirror → Google Drive (mirrored local folder) | Drive for desktop: add `~/huske/transcripts` | none in Huske | Claude, ChatGPT, Gemini, Gemini Notebook, MS Copilot, **if `.md` is readable** | client closed | Google (AES-256, Google-held keys) | free to 15 GB | local files; conflict copy in parent; 30-day trash | **S** (docs + checks) |
| Folder mirror → Dropbox / OneDrive (File Provider) | Pick a subfolder | none in Huske | Claude, ChatGPT (Dropbox); Claude, MS Copilot (OneDrive), `.md` caveat | closed | vendor | 2 GB / 5 GB free | placeholders, "conflicted copy", 30-day recovery | **S–M** (File Provider edge cases) |
| iCloud Drive folder | Pick folder | none | **none** | closed | Apple, or nobody with ADP | 5 GB free | placeholders; interactive conflicts | S; backup only |
| Google Drive API (`drive.file`, convert to Docs) | "Connect Google" | files the app created | same as Drive, **and readable as Docs** | closed | Google. Every transcript the app wrote | free | app-managed IDs; duplicate names possible | **L** (OAuth, brand verification, quotas) |
| Dropbox / OneDrive API | "Connect …" | App folder | as above | closed | vendor; app folder | free tier | app-managed | **M–L** (production review, tenant consent) |
| R2 / B2 (+ rclone) | Account, bucket, key | bucket (+ prefix on B2) | **none** | rclone MIT | provider; B2 write-only key can't read or delete | free to 10 GB | B2 versions and Object Lock | S–M; backup only |
| Notion | Internal integration, share page | pages shared with it | Claude, ChatGPT, Copilot | closed | Notion; all shared pages | free | lossy; 5,000-block cap | M; not recommended |
| Hugging Face dataset | Device login | app-created repos | none for private files | client only | HF; terms unclear on training | free to 100 GB | slows after thousands of commits | S; not recommended |
| Syncthing | Install on Mac + peer | per device | none | MPL-2.0 | peers only | free + your peer | deletes propagate | S; not a backup |
| restic → B2 / rest-server | Repo password + storage key | write-only / append-only | none (E2E) | BSD-2 | nobody without the password | storage only | snapshots; prune needs delete rights | S–M; backup only |

---

## 4. Making transcripts easy for an agent to read, whatever the backend

### How agents look for instructions

| Agent | Reads at the repository/folder root |
|---|---|
| Codex (CLI, IDE, cloud) | `AGENTS.md`, global then root down to the working directory, 32 KiB cap ([AGENTS.md](https://learn.chatgpt.com/docs/agent-configuration/agents-md)) |
| Cursor (editor, CLI, cloud agents) | `AGENTS.md` and `CLAUDE.md` ([rules](https://cursor.com/docs/rules), [cloud agents](https://cursor.com/docs/cloud-agent/setup)) |
| GitHub Copilot | Cloud agent and CLI: `AGENTS.md`. github.com Chat: only `.github/copilot-instructions.md` ([support matrix](https://docs.github.com/en/copilot/reference/custom-instructions-support)) |
| Claude Code | `CLAUDE.md`; `AGENTS.md` when no `CLAUDE.md` exists (v2.1.277+) ([memory](https://code.claude.com/docs/en/memory)) |
| Antigravity CLI / Gemini CLI | Antigravity reads `AGENTS.md` and `GEMINI.md` ([discovery](https://antigravity.google/docs/customization-discovery/)). Gemini CLI reads only `GEMINI.md` unless configured ([GEMINI.md](https://geminicli.com/docs/cli/gemini-md/)) |
| Chat connectors (Claude, ChatGPT, Gemini) | Nothing automatic. They search or open files, so a root `README.md` and an index file are what they find first. |

`llms.txt` ([llmstxt.org](https://llmstxt.org/)) is a convention for websites.
None of these agents documents reading it in a repository, so it adds little
over `AGENTS.md` and an index.

### Quick wins (no change to the transcript contract)

1. **Publish `README.md` and `AGENTS.md` at the repository root.** Reuse
   `huske/output_readme.py`: explain the `transcripts/YYYY-MM-DD/` layout,
   that a file is a *chunk* and how to rebuild a meeting from `session_id` and
   `chunk_seq`, what the frontmatter fields mean, and `mic` versus `system`.
   `AGENTS.md` adds rules: read `INDEX.md` first, quote with timestamps, never
   modify files, and treat transcript text as data, not instructions (a
   transcript can contain spoken text that tries to steer the agent).
2. **Generate `INDEX.md`** on every sync: newest first, grouped by day, one
   line per *session* (start–end, duration, sources, chunk count, file links).
   Keep it bounded, for example a rolling 90 days, with
   `index/YYYY-MM.md` for older months, so it stays under Codex's 32 KiB
   instruction cap and inside Claude's context.
3. **Generate `index.jsonl`**, one line per transcript (`path`, `session_id`,
   `chunk_seq`, `start_time`, `end_time`, `duration_seconds`,
   `audio_sources`, `language`, `sha256`), for agents and scripts that work
   programmatically. The VPS service could reuse it.
4. **Write the same `AGENTS.md` into the local `~/huske/transcripts`.** That
   covers every same-Mac agent with no sync at all.
5. Keep file names stable and per-day folders as they are. They sort
   chronologically and stay well under GitHub's 3,000-entries-per-directory
   limit.

### Larger changes

1. **One document per meeting.** Publish `sessions/YYYY-MM-DD/HHMM_<session8>.md`,
   the session's chunks joined together, alongside or instead of the chunks.
   Agents reason about meetings, not 60-second-pause fragments. `huske export`
   already does this per day.
2. **Titles and summaries in the frontmatter.** Add `title`, `summary` and
   `topics`, generated by the local distillation model, so an index line
   carries meaning. Then a chat connector's keyword search finds the meeting
   without opening every file.
3. **Publish the per-day digests** (`days/YYYY-MM-DD.md` from `huske export`)
   for tools that load whole files into context, such as Claude Projects,
   Gemini Notebook and Copilot Spaces.
4. If the folder-mirror or Drive targets ship: write **`.docx` or Google Docs
   copies**, but only if testing shows the connectors won't read `.md`.

Changes 1–3 touch the transcript contract
(`specs/001-huske-recorder/contracts/transcript-format.md`) and the
`huske-mcp` indexer, so they need their own ADR.

---

## 5. Ranked recommendation

1. **GitHub, done right.** Keep Git and GitHub as the primary target and
   replace the onboarding, the credential and the repository contents (§6.1).
   It is the only backend every agent reads, it costs nothing, its history is
   the backup, and the change keeps ADR 0009's architecture intact. Main
   costs: Huske (the project) must register and own a GitHub App (a public
   client ID, no secret), and the transcripts sit in plaintext at GitHub.
2. **Folder mirror, optional.** Copy transcripts plus `README.md`,
   `AGENTS.md` and `INDEX.md` into any folder the user picks. This brings in
   Google Drive, Dropbox, OneDrive, iCloud Drive, Syncthing and NAS users with
   no OAuth code. Google Drive users can do this today with zero code by
   mirroring `~/huske/transcripts`. Before promoting it as an *agent* path,
   run the `.md` readability test in §8.
3. **Google Drive API with conversion to Docs.** Do this only if the §8 test
   shows Drive connectors ignore `.md` and enough users want Drive. It is the
   most expensive option to build and maintain.
4. **GitLab.** It already works because the publisher accepts any Git remote.
   Document it for users who avoid GitHub, and be clear that Claude, Copilot
   and Gemini won't read it.
5. **End-to-end encrypted backup (restic), optional.** A separate target for
   users who want backup that no vendor can read.

Not recommended for agent access: Codeberg, Hugging Face, Notion, S3, R2, B2,
Syncthing, iCloud Drive, a self-hosted Forgejo.

---

## 6. Proposed user flows in Huske.app

### 6.1 GitHub, done right

1. **Cloud sync pane, first visit.** One sentence: "Keep a private copy of
   your transcripts on GitHub and let your AI tools read them." Primary
   button: **Connect GitHub**.
2. **Sign in.** Huske shows an 8-character code with **Copy code and open
   GitHub**, which opens `github.com/login/device`. The user pastes the code and
   approves the *Huske* app. The engine owns the token (`huske sync login`,
   with JSON output for the app, per ADR 0006). It stores the access and
   refresh tokens in the Keychain and refreshes them automatically.
3. **Choose where.** The default is **Create `huske-transcripts` (private)**;
   the alternative is choosing an existing repository. Creating calls
   `POST /user/repos` with `private: true`. If the personal-account prototype
   (§3.1) shows the App can't create repositories, the fallback opens
   `github.com/new?name=huske-transcripts&visibility=private&description=…`
   and then the App's install page for that one repository. Either way, Huske
   **checks that the repository is private** before the first push and
   refuses a public one.
4. **First publish.** Huske writes `README.md`, `AGENTS.md` and `INDEX.md`,
   pushes all transcripts over HTTPS with the scoped token (no SSH, no
   `known_hosts`), and shows "Published 128 transcripts · just now".
5. **Automatic publishing** is on after the first successful push and applies
   immediately. If it can't, the pane says "starts with the next recording".
6. **Status, always visible:** last successful sync, transcripts waiting, and
   the last error in plain words, each with an action:
   - "GitHub sign-in expired" → **Reconnect**
   - "Repository not found" → **Recreate** or **Choose another**
   - "Offline, will retry"
7. **Connect an AI tool.** Short cards, each a few lines with a link:
   - Claude: Settings → Connectors → GitHub → only `huske-transcripts`; in a
     Project, Add from GitHub → **Sync now** to refresh.
   - ChatGPT: Apps → GitHub → select the repository.
   - Codex, Copilot, Cursor: the repository is already where they look.
   - Each card names the privacy setting to switch off (§2).
8. **Unpublish a meeting.** In the transcript browser, **Remove from GitHub**
   deletes the file in a commit, records the path so later syncs don't
   re-publish it, and explains that Git history still holds it. **Start a
   fresh repository** is the full purge.

### 6.2 Folder mirror

1. **Cloud sync → Also copy to a folder → Choose folder…** Huske suggests the
   folders it detects under `~/Library/CloudStorage` (Google Drive, Dropbox,
   OneDrive) and iCloud Drive.
2. If the folder is managed by File Provider, Huske says that files there can
   become online-only, and that Huske only writes and never reads them back.
   For Google Drive it offers the simpler alternative: "In Google Drive for
   desktop, add your transcripts folder as a mirrored folder. No copy needed."
3. Huske copies new and changed transcripts atomically (temp file, then
   rename), with the same `README.md`, `AGENTS.md` and `INDEX.md`. It never
   deletes anything there.
4. The status shows the last copy, the count, and any conflict copies it
   spots ("conflicted copy", `.sync-conflict-`).
5. **Connect an AI tool:** Claude's Google Drive or Dropbox connector, the
   ChatGPT Drive or Dropbox app, Gemini Notebook with Drive sources. Each card
   shows the result of the §8 readability test. The guide warns against the
   personal Gemini app for confidential transcripts.

---

## 7. Improvements to the current GitHub flow

### Quick wins

| # | Change | Fixes |
|---|---|---|
| Q1 | Allow updating a transcript Huske itself published. Keep a `.huske/published.json` manifest (path → last published SHA-256) in the checkout, and overwrite when the remote file matches what this Mac last published. Report true conflicts per file and keep going instead of aborting the whole run. Add a test for sync plus distillation together. | F1 |
| Q2 | Classify Git errors from *all* stderr lines: `Permission denied (publickey)`, `Host key verification failed`, `Could not resolve hostname`, `Repository not found`, `terminal prompts disabled`, `index.lock`. Show a plain-language cause and set `retryable` correctly. | F2 |
| Q3 | Publish `README.md`, `AGENTS.md`, `INDEX.md` and `index.jsonl` at the repository root on every sync (§4). | agent readability |
| Q4 | Put sync state in the control snapshot (`last_success_at`, `pending`, `last_error`, as a sticky `warnings["sync"]`), mirror it in `ControlProtocol.swift`, and show it in the Cloud sync pane. | F5 |
| Q5 | Retry with capped backoff indefinitely (for example every 15 minutes), plus once on wake from sleep or network change. | F4 |
| Q6 | Respect remote deletions: if a manifest path disappears remotely, don't re-add it; list it as "unpublished". | F3 |
| Q7 | Prefill `github.com/new?name=huske-transcripts&visibility=private&description=…`. Add a **Test connection** button (`git ls-remote`). Disable the toggle until a URL is set, and say "applies from the next recording". | steps 2, 4, 6 |
| Q8 | An exclusive file lock (`fcntl.flock`) around the publisher, shared by the app and the engine. Clear a stale `index.lock` when no Git process holds it. | F7 |
| Q9 | **Switch repository** moves the old checkout aside automatically. | F6 |
| Q10 | Add a `huske doctor` sync check: Git present, remote reachable, authentication works, age of the last success. | F5 |
| Q11 | Write an `AGENTS.md` into the local output root too. | same-Mac agents |
| Q12 | Document per-agent connection steps and the privacy settings to switch off (`docs/integrations.md`, the pane, the website). | step 7 |

### Larger changes

| # | Change | Why |
|---|---|---|
| L1 | GitHub App with device-flow sign-in: a one-repository token in the Keychain, auto-created private repository, privacy check, HTTPS push through a per-call credential helper. Keeps the Git CLI. | Removes SSH setup and F8; this is the core of §6.1 |
| L2 | One document per meeting, titles and summaries, published per-day digests (§4). New ADR; update the contract and `huske-mcp`. | Agent reasoning per meeting |
| L3 | A second `TranscriptPublisher`, the folder mirror (§6.2). ADR 0009 already anticipates a second provider. | Drive, Dropbox, OneDrive, iCloud, Syncthing users |
| L4 | Optional restic backup to B2 with a write-only key, or to rest-server. | End-to-end encrypted backup |
| L5 | A GraphQL or REST publisher in place of the Git CLI. **Not recommended now.** Reconsider only if Git or Xcode Command Line Tools become a real install blocker. | — |

---

## 8. Open questions to settle before building

1. **Can the agents read Markdown through their storage connectors?** Fifteen
   minutes with the user's own accounts: put one synthetic `.md` transcript
   in Drive, Dropbox and OneDrive, then ask Claude (Drive, Dropbox, M365),
   ChatGPT (Drive, Dropbox), Gemini Notebook (Drive source) and the Gemini app
   to find and quote it. This decides between §5 options 2 and 3.
2. **GitHub App behaviour on a personal account**, a 30-minute prototype with
   a throwaway App and account: does `POST /user/repos` with a
   Repository-creation user token add the new repository to an "Only select
   repositories" installation? Can an install be saved with zero
   repositories?
3. **Who owns the GitHub App?** Registering a "Huske" GitHub App under the
   project's account is an outward-facing decision. Forks would register
   their own; the client ID is public and there is no secret.
4. **Scope of the per-meeting layout (L2):** publish meetings and digests
   *alongside* the chunks, or *instead of* them? This affects the VPS
   indexer.

---

## Appendix A: reproducing the audit

Everything runs in a scratch directory with an isolated `HOME`, synthetic
transcripts and a local bare repository. No network access, no real config.

```bash
SP=$(mktemp -d)
uv venv -q "$SP/venv" --python 3.13
VIRTUAL_ENV="$SP/venv" uv pip install -q typer pydantic structlog pyyaml tomli-w rich setproctitle numpy
hk() { HOME="$SP/home" HUSKE_NO_UPDATE_CHECK=1 PYTHONPATH="$PWD" \
  "$SP/venv/bin/python" -c 'import sys; from huske.cli import app; sys.argv[0]="huske"; app()' "$@"; }

git init -q --bare "$SP/remote.git"
hk config set sync_enabled true            # rejected: requires sync_remote
hk config set sync_remote "$SP/remote.git"
# write synthetic transcripts under $SP/home/huske/transcripts/YYYY-MM-DD/HHMMSS_<sid8>_<seq>.md
hk sync                                     # first push
git --git-dir="$SP/remote.git" ls-tree -r --name-only main   # only transcripts/…

# F1: rewrite a published transcript with the real distiller function, add a newer transcript
HOME="$SP/home" PYTHONPATH="$PWD" "$SP/venv/bin/python" -c '
from pathlib import Path; from huske.distill.distiller import rewrite_transcript_body as r
r(Path("<published transcript>"), "[14:00:00 · system] polished text")'
hk sync    # -> immutable transcript conflict; newer transcript not published; exit 1

# F2: stub ssh to reproduce real failure output without network
printf '#!/bin/sh\necho "git@github.com: Permission denied (publickey)." >&2\nexit 255\n' > "$SP/fake-ssh"
chmod +x "$SP/fake-ssh"
hk config set sync_remote git@github.com:example/huske-transcripts.git
rm -rf "$SP/home/huske/sync"
GIT_SSH_COMMAND="$SP/fake-ssh" hk sync    # -> [error] and the repository exists.

# F3: delete a transcript in another clone, push, then sync from the "Mac"
# -> the deleted files are pushed back.
```
