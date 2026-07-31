// huske website — Docs page. Reuses the shared shell and the hero's InstallTabs.
//
// Version strings are intentionally absent: scripts/release.py only rewrites
// components-shell.jsx + components-sections.jsx, so a hardcoded vX.Y.Z here
// would drift. The Nav pill (shell) carries the version.

// ---- Small building blocks --------------------------------------------------

const DocsCmd = ({ cmd, note }) => (
  <div className="docs-cmd">
    <code className="dc-line"><span className="dc-prompt">$</span> {cmd}</code>
    {note && <span className="dc-note"># {note}</span>}
    <CopyButton text={cmd} className="copy ghost mini" withLabel={false} />
  </div>
);

const DocsTerminal = ({ children }) => (
  <div className="docs-terminal">{children}</div>
);

const DocsCode = ({ path, lang, code }) => (
  <div className="docs-code">
    <div className="dc-head">
      {path && <span className="dc-path">{path}</span>}
      {lang && <span className="dc-lang">{lang}</span>}
      <CopyButton text={code} className="copy ghost" />
    </div>
    <pre className="dc-body"><code>{code}</code></pre>
  </div>
);

const DocsSection = ({ id, num, title, children }) => (
  <section id={id} className="docs-sec">
    <div className="docs-sec-head">
      <span className="docs-sec-num">{num}</span>
      <h2>{title}</h2>
    </div>
    {children}
  </section>
);

const ConfigTable = ({ rows }) => (
  <div className="docs-table-wrap">
    <table className="docs-table">
      <thead>
        <tr><th>key</th><th>default</th><th>what it does</th><th>flag</th></tr>
      </thead>
      <tbody>
        {rows.map((r) => (
          <tr key={r.key}>
            <td><code>{r.key}</code></td>
            <td className="dt-default">{r.def}</td>
            <td>{r.desc}</td>
            <td className="dt-flag">{r.flag ? <code>{r.flag}</code> : <span className="dt-dash">—</span>}</td>
          </tr>
        ))}
      </tbody>
    </table>
  </div>
);

// ---- Scroll-spy for the sticky table of contents ----------------------------

function useScrollSpy(ids, offset = 96) {
  const [active, setActive] = React.useState(ids[0]);
  const key = ids.join(",");
  React.useEffect(() => {
    if (typeof window === "undefined" || !("IntersectionObserver" in window)) return;
    const els = ids.map((id) => document.getElementById(id)).filter(Boolean);
    if (!els.length) return;
    const obs = new IntersectionObserver(
      (entries) => {
        const visible = entries
          .filter((e) => e.isIntersecting)
          .sort((a, b) => a.boundingClientRect.top - b.boundingClientRect.top);
        if (visible[0]) setActive(visible[0].target.id);
      },
      { rootMargin: `-${offset}px 0px -64% 0px`, threshold: 0 }
    );
    els.forEach((el) => obs.observe(el));
    return () => obs.disconnect();
  }, [key, offset]);
  return active;
}

const DOCS_SECTIONS = [
  { id: "install", label: "Install" },
  { id: "first-run", label: "First run" },
  { id: "autostart", label: "Autostart on login" },
  { id: "config", label: "Configuration" },
  { id: "search", label: "Cloud sync" },
  { id: "connect", label: "VPS & MCP" },
];

const DocsToc = ({ active }) => (
  <aside className="docs-toc">
    <div className="docs-toc-inner">
      <div className="docs-toc-label">on this page</div>
      <nav>
        {DOCS_SECTIONS.map((s) => (
          <a key={s.id} href={`#${s.id}`} className={active === s.id ? "active" : ""}>{s.label}</a>
        ))}
      </nav>
      <div className="docs-toc-foot">
        <a href="https://github.com/tiagomoraes/huske" target="_blank" rel="noopener">source ↗</a>
        <a href="https://github.com/tiagomoraes/huske/blob/main/examples/config.toml" target="_blank" rel="noopener">config.toml ↗</a>
        <a href="https://github.com/tiagomoraes/huske/blob/main/docs/server.md" target="_blank" rel="noopener">server guide ↗</a>
      </div>
    </div>
  </aside>
);

// ---- Hero -------------------------------------------------------------------

const DocsHero = () => (
  <section className="docs-hero">
    <div className="page">
      <div className="eyebrow"><span className="dot" /> docs · setup &amp; configuration</div>
      <h1>Set up huske.</h1>
      <p className="docs-hero-lede">
        Install it, grant the macOS capture permission, run it on login, tune it
        to your machine, and optionally publish transcripts to your own private
        repository and always-on agent service.
      </p>
    </div>
  </section>
);

// ---- 01 · Install -----------------------------------------------------------

const InstallDoc = () => (
  <DocsSection id="install" num="01" title="Install">
    <p className="docs-lead">
      The fastest path is <strong>Huske.app</strong>: download, open, and one
      click installs the engine. The engine is also a single Python tool you
      can install directly — for agents, SSH sessions, and headless Macs.
    </p>
    <ul className="docs-facts">
      <li><span className="k">os</span><span className="v">app macOS 14+ · engine macOS 13+ (14.4+ recommended — the Core Audio tap survives screen sharing)</span></li>
      <li><span className="k">python</span><span className="v">{HUSKE_PYTHONS.slice(0, -1).join(", ")}, or {HUSKE_PYTHONS[HUSKE_PYTHONS.length - 1]}</span></li>
      <li><span className="k">disk</span><span className="v">~3 GB for the default <code>base</code> model (downloaded on first run)</span></li>
      <li><span className="k">audio</span><span className="v">no BlackHole, Aggregate Device, or Audio MIDI Setup — Apple's built-in capture is used</span></li>
    </ul>

    <InstallTabs />
    <p className="docs-aside">
      The app build is ad-hoc signed, not notarized: macOS blocks the very
      first open. Approve it under <strong>System Settings → Privacy &amp;
      Security → "Open Anyway"</strong> (one time), or build it yourself from
      source with <code>macos/scripts/build-app.sh</code>.
    </p>

    <h3>Separate service boundary</h3>
    <p>The macOS engine stays a single install. The always-on MCP read service is an independent Linux package:</p>
    <dl className="docs-defs">
      <dt><code>huske</code></dt>
      <dd>Huske.app's engine: record, transcribe, recover, autostart, export, and publish canonical Markdown through Git.</dd>
      <dt><code>huske-mcp</code></dt>
      <dd>A separate package under <code>services/huske_mcp</code> for Linux/VPS. It pulls a read-only Git replica, builds a bounded SQLite index, and serves authenticated MCP. See <a href="https://github.com/tiagomoraes/huske/blob/main/docs/server.md" target="_blank" rel="noopener">the server guide</a>.</dd>
    </dl>
    <DocsTerminal>
      <DocsCmd cmd="uv tool install huske" note="the macOS recording engine" />
    </DocsTerminal>

    <h3>Prereleases and upgrades</h3>
    <p>Install an exact tag straight from the repository, or upgrade with the command for your install method:</p>
    <DocsTerminal>
      <DocsCmd cmd='uv tool install "git+https://github.com/tiagomoraes/huske.git@<tag>"' note="a specific release tag" />
      <DocsCmd cmd="uv tool upgrade huske" />
      <DocsCmd cmd="pipx upgrade huske" />
      <DocsCmd cmd="brew upgrade huske" />
    </DocsTerminal>
    <p className="docs-aside">
      huske checks PyPI at most once a day and prints the right upgrade command
      for you. Set <code>HUSKE_NO_UPDATE_CHECK=1</code> to turn the check off.
    </p>
  </DocsSection>
);

// ---- 02 · First run ---------------------------------------------------------

const FirstRunDoc = () => (
  <DocsSection id="first-run" num="02" title="First run">
    <p className="docs-lead">From a clean install to a transcript on disk.</p>
    <ol className="docs-steps">
      <li>
        <h4>Validate your setup.</h4>
        <DocsTerminal><DocsCmd cmd="huske doctor" /></DocsTerminal>
        <p><code>doctor</code> checks Python, the model, your microphone, the system-audio backend, and that the output paths are writable. The first run triggers the macOS permission prompt. <code>huske doctor --json</code> emits the same checks machine-readably.</p>
      </li>
      <li>
        <h4>Grant the macOS permissions.</h4>
        <p>Open <strong>System Settings → Privacy &amp; Security</strong> and enable, for your terminal (or the resolved <code>huske</code> binary):</p>
        <ul className="docs-bullets">
          <li><strong>Microphone</strong> — for mic capture.</li>
          <li><strong>Audio Capture</strong> (macOS 14.4+ Core Audio tap) <em>or</em> <strong>Screen Recording</strong> (ScreenCaptureKit fallback / screenshots).</li>
        </ul>
        <p className="docs-aside">The grant is per-binary: switching Python environments re-prompts, and it only takes effect on the next launch — quit and re-run after approving.</p>
      </li>
      <li>
        <h4>Record.</h4>
        <p>In <strong>Huske.app</strong>: hit <strong>Start Recording</strong> (⌘R). The Record pane shows live level meters, the current chunk and queue, and an activity feed; pause, screenshots, distillation, and mic switching are one ⌘K away. From a terminal, the same engine runs headless:</p>
        <DocsTerminal><DocsCmd cmd="huske run" /></DocsTerminal>
        <p>Plain progress lines on stdout; <kbd>Ctrl+C</kbd> finalizes the partial chunk, transcribes it, and exits (a menu bar item carries pause/screenshots/stop). The Parakeet model downloads on the first transcription.</p>
      </li>
      <li>
        <h4>Read the output.</h4>
        <p>Transcripts are plain Markdown with YAML frontmatter, one file per chunk:</p>
        <DocsCode lang="text" code={"~/huske/transcripts/YYYY-MM-DD/HHMMSS_<session>_NNN.md"} />
        <p>Point any agent at <code>~/huske/transcripts/</code> — the auto-generated root <code>README.md</code> documents the layout.</p>
      </li>
      <li>
        <h4>Recover after a crash.</h4>
        <DocsTerminal><DocsCmd cmd="huske recover" /></DocsTerminal>
        <p>Audio is written to <code>~/huske/audio/</code> as it's captured. After a SIGKILL, <code>recover</code> transcribes orphaned chunks without re-recording. Unrecoverable WAVs move to <code>~/huske/audio/incomplete/</code>.</p>
      </li>
    </ol>
  </DocsSection>
);

// ---- 03 · Autostart ---------------------------------------------------------

const AutostartDoc = () => (
  <DocsSection id="autostart" num="03" title="Autostart on login">
    <p className="docs-lead">
      The everyday autostart lives in the app: <strong>Configuration → This
      app → Open Huske at login</strong> + <strong>Start recording when Huske
      opens</strong>. Prefer no app at all? <code>huske autostart install</code>
      registers a per-user <code>launchd</code> LaunchAgent that runs a headless
      <code> huske run</code> at every login. macOS only.
    </p>
    <DocsTerminal>
      <DocsCmd cmd="huske autostart install" note="write the plist and load it now" />
      <DocsCmd cmd="huske autostart status" note="installed · loaded · pid · last exit" />
      <DocsCmd cmd="huske autostart start" note="kickstart now (no-op if running)" />
      <DocsCmd cmd="huske autostart stop" note="graceful SIGTERM" />
      <DocsCmd cmd="huske autostart uninstall" note="bootout and remove the plist" />
    </DocsTerminal>

    <h3>Install options</h3>
    <ul className="docs-bullets">
      <li><strong><code>--config &lt;path&gt;</code></strong> — a config.toml passed through to <code>huske run</code>.</li>
      <li><strong><code>--log-level</code></strong> — DEBUG, INFO (default), WARNING, ERROR.</li>
      <li><strong><code>--keep-alive</code> / <code>--no-keep-alive</code></strong> — restart on crash only, on by default (see below).</li>
      <li><strong><code>--force</code></strong> — overwrite an existing plist.</li>
    </ul>
    <p className="docs-aside">
      Default restart policy is <code>KeepAlive=&#123;SuccessfulExit:false&#125;</code> — restart on
      crash only. <code>huske autostart stop</code> (or any clean exit) stays
      stopped until next login. <code>--no-keep-alive</code> disables auto-restart entirely.
    </p>

    <h3>Permissions &amp; logs</h3>
    <p>
      The first time the agent records, macOS prompts for Microphone and the
      capture permission for the resolved binary. If the prompts don't appear
      after login, run <code>huske autostart start</code> once from a terminal so
      they fire while you're present. The agent is headless; output is appended to:
    </p>
    <DocsCode lang="text" code={"~/Library/Logs/huske/agent.out.log\n~/Library/Logs/huske/agent.err.log"} />
    <p className="docs-aside">
      <code>huske doctor</code> reports the agent's state (installed, loaded, pid,
      and the log path on a crash), so you can check it without a separate command.
      The plist lives at <code>~/Library/LaunchAgents/me.huske.plist</code>.
    </p>

    <h3>Lighter idle footprint</h3>
    <p>
      Since the agent runs all day, huske keeps idle RAM low by default:
      {" "}<code>whisper_idle_unload</code> is on, so the transcription model is
      dropped from memory between chunks (freeing ~1–3 GB; the next chunk reloads
      from the local cache in a few seconds). To trim a little more, set
      {" "}<code>menu_bar_enabled = false</code> in a config file, then point the
      agent at it:
    </p>
    <DocsTerminal>
      <DocsCmd cmd="huske autostart install --config ~/.config/huske/config.toml" />
    </DocsTerminal>
  </DocsSection>
);

// ---- 04 · Configuration -----------------------------------------------------

const COMMON_CONFIG = [
  { key: "asr_engine", def: "parakeet", desc: "Transcription backend: parakeet (silence-robust, multilingual) or whisper (legacy mlx-whisper).", flag: "--asr-engine" },
  { key: "speech_gated", def: "true", desc: "Split files on real pauses in speech instead of a fixed clock. Quiet stretches aren't recorded.", flag: "--speech-gated / --no-speech-gated" },
  { key: "silence_split_seconds", def: "60", desc: "Seconds of continuous silence that close the current file (2–600).", flag: "--silence-split" },
  { key: "chunk_minutes", def: "30", desc: "Maximum chunk length (a safety cap; chunks normally close on a pause). 0.1–60.", flag: "--chunk-minutes" },
  { key: "echo_cancel", def: "true", desc: "Suppress system audio that bleeds into the mic over speakers (coherence-based echo suppression) before transcription. Self-gating with headphones.", flag: "--echo-cancel / --no-echo-cancel" },
  { key: "echo_dedup", def: "drop", desc: "Remove a mic run duplicating a system line (full or partial fragment): drop, annotate, or off.", flag: "--echo-dedup" },
  { key: "system_audio_backend", def: "auto", desc: "System-audio capture: auto, tap, sck, or off (mic-only).", flag: "--system-audio-backend" },
  { key: "input_device", def: "system default", desc: "Microphone name, substring match. System audio is independent.", flag: "--input-device" },
  { key: "parakeet_model", def: "parakeet-tdt-0.6b-v3", desc: "Parakeet model id when asr_engine=parakeet (HF repo or local dir).", flag: "--parakeet-model" },
  { key: "model", def: "base", desc: "Whisper model size when asr_engine=whisper: tiny, base, small, medium, large-v3.", flag: "--model" },
  { key: "language", def: "auto-detect", desc: "Transcription language hint, ISO 639-1 (e.g. pt, en).", flag: "--language" },
  { key: "output_root", def: "~/huske/transcripts", desc: "Where Markdown transcripts are written.", flag: "--output-root" },
  { key: "audio_root", def: "~/huske/audio", desc: "Transient WAV chunks (plus incomplete/).", flag: "--audio-root" },
  { key: "keep_audio", def: "false", desc: "Keep audio after transcription (compressed — see keep_audio_format).", flag: "--keep-audio" },
  { key: "keep_audio_format", def: "opus", desc: "Format for kept audio: opus (lossy, smallest), flac (lossless), or wav.", flag: "--keep-audio-format" },
  { key: "log_level", def: "INFO", desc: "DEBUG, INFO, WARNING, ERROR.", flag: "--log-level" },
  { key: "no_ui", def: "false", desc: "Deprecated no-op — huske run is always headless now (the terminal panel moved into Huske.app).", flag: "--no-ui" },
  { key: "screenshots_enabled", def: "false", desc: "Capture a JPEG of every display periodically. Loud — see privacy.", flag: "--screenshots" },
  { key: "screenshots_interval_seconds", def: "60", desc: "Seconds between screenshots (1–3600).", flag: "--screenshot-interval" },
];

const ADVANCED_CONFIG = [
  { key: "sample_rate", def: "48000", desc: "Capture sample rate (Hz).", flag: "" },
  { key: "block_size", def: "1024", desc: "Samples per audio callback block.", flag: "" },
  { key: "channels", def: "2", desc: "Input channel count (1–2; mixed to mono internally).", flag: "" },
  { key: "compute_type", def: "int8", desc: "Back-compat; only float32 disables fp16 on the MLX backend.", flag: "--compute-type" },
  { key: "device", def: "auto", desc: "Back-compat; mlx-whisper always runs on the Apple GPU.", flag: "--device" },
  { key: "whisper_idle_unload", def: "true", desc: "Drop the transcription model from RAM between chunks (frees ~1–3 GB; whisper tiny is less); reloads from the local cache on the next chunk. Set false to keep it warm.", flag: "--idle-unload" },
  { key: "whisper_idle_unload_seconds", def: "120", desc: "Idle seconds before the model is unloaded (min 5).", flag: "" },
  { key: "logs_root", def: "~/huske/logs", desc: "Per-session log files.", flag: "" },
  { key: "menu_bar_enabled", def: "true", desc: "macOS menu bar helper while recording.", flag: "--menu-bar" },
  { key: "menu_bar_label_style", def: "text", desc: "Menu bar label: text or icon.", flag: "" },
  { key: "screenshots_root", def: "~/huske/screenshots", desc: "Screenshot output root.", flag: "--screenshots-root" },
  { key: "screenshots_max_displays", def: "4", desc: "Max displays captured per tick (1–16).", flag: "" },
  { key: "screenshots_max_dimension", def: "1568", desc: "Downscale each screenshot's long edge to ≤ N px via sips (0 disables; never upscales).", flag: "--screenshot-max-dimension" },
  { key: "screenshots_jpeg_quality", def: "60", desc: "JPEG quality for screenshots, 1–100 (re-encoded via sips).", flag: "--screenshot-quality" },
  { key: "sync_enabled", def: "false", desc: "Publish new canonical transcripts after each finalized chunk.", flag: "" },
  { key: "sync_provider", def: "git", desc: "Storage provider boundary; Git is the first implementation.", flag: "" },
  { key: "sync_remote", def: "unset", desc: "Private Git repository SSH or HTTPS remote.", flag: "" },
  { key: "sync_branch", def: "main", desc: "Branch used for the transcript replica.", flag: "" },
  { key: "sync_root", def: "~/huske/sync", desc: "Managed Git checkout; commits are the durable retry queue.", flag: "" },
  { key: "sync_push_timeout_seconds", def: "60", desc: "Deadline for each Git operation.", flag: "" },
];

const ConfigDoc = () => (
  <DocsSection id="config" num="04" title="Configuration">
    <p className="docs-lead">
      Everything is set in one optional TOML file. Precedence is
      {" "}<strong>defaults → config.toml → CLI flags</strong>; flags always win,
      and unknown keys are rejected so a typo is an error, not a silent no-op.
    </p>
    <DocsCode
      path="~/.config/huske/config.toml"
      lang="toml"
      code={"chunk_minutes = 30\nmodel = \"small\"\nlanguage = \"en\"\nsystem_audio_backend = \"auto\"\noutput_root = \"~/work/transcripts\""}
    />
    <p>
      Point at a different file with <code>--config &lt;path&gt;</code>. Copy the
      fully-commented
      {" "}<a href="https://github.com/tiagomoraes/huske/blob/main/examples/config.toml" target="_blank" rel="noopener">examples/config.toml</a>
      {" "}to get every key with its default.
    </p>

    <h3>Common keys</h3>
    <ConfigTable rows={COMMON_CONFIG} />

    <details className="docs-details">
      <summary>All other keys <span className="chev">›</span></summary>
      <p className="docs-aside" style={{ marginTop: 14 }}>
        Advanced capture, UI, distillation, and cloud-sync keys. Most users never touch these.
      </p>
      <ConfigTable rows={ADVANCED_CONFIG} />
    </details>
  </DocsSection>
);

// ---- 05 · Search & MCP ------------------------------------------------------

// Extra clients beyond the landing page's AGENTS set. ${MCP_ENDPOINT} is real
// interpolation; \${...} is a literal placeholder the client resolves itself.
const SearchDoc = () => (
  <DocsSection id="search" num="05" title="Cloud sync">
    <p className="docs-lead">
      Huske.app can publish each finalized transcript to a private Git
      repository. GitHub is the first supported storage provider; Huske uses
      your existing SSH agent or Git credential helper and never stores a token.
    </p>
    <ol className="docs-steps">
      <li>Create an empty <strong>private</strong> repository dedicated to transcript data.</li>
      <li>Open <strong>Cloud sync</strong> in Huske.app and paste its SSH URL.</li>
      <li>Press <strong>Sync now</strong>, then enable automatic sync.</li>
    </ol>
    <DocsTerminal>
      <DocsCmd cmd="huske config set sync_remote git@github.com:you/huske-transcripts.git" />
      <DocsCmd cmd="huske config set sync_enabled true" />
      <DocsCmd cmd="huske sync" note="initial publish or manual reconciliation" />
    </DocsTerminal>
    <p>
      Only <code>transcripts/YYYY-MM-DD/*.md</code> enters the repository.
      Audio, screenshots, statement sidecars, logs, configuration, and
      credentials remain on the Mac. Huske pulls and rebases before each push;
      if an established transcript path contains different bytes, it stops
      instead of overwriting either copy.
    </p>
    <p className="docs-aside">
      The managed checkout is <code>~/huske/sync</code>. A local commit that
      could not be pushed remains there as the durable retry queue and is retried
      at the next session.
    </p>
  </DocsSection>
);

const ConnectDoc = () => (
  <DocsSection id="connect" num="06" title="VPS & MCP">
    <p className="docs-lead">
      MCP no longer runs inside Huske.app. Install the independent
      <code> huske-mcp</code> service on an always-on Linux host; it pulls the
      private repository, maintains its own index, and stays available while the
      recording Mac sleeps.
    </p>
    <DocsCode
      path="/etc/huske-mcp/huske-mcp.env"
      lang="ini"
      code={"HUSKE_MCP_REPOSITORY=git@github.com:you/huske-transcripts.git\nHUSKE_MCP_BRANCH=main\nHUSKE_MCP_DATA_DIR=/var/lib/huske-mcp\nHUSKE_MCP_HOST=127.0.0.1\nHUSKE_MCP_PORT=7641\nHUSKE_MCP_POLL_SECONDS=60\nHUSKE_MCP_TOKEN_FILE=/etc/huske-mcp/token\nHUSKE_MCP_ALLOWED_HOSTS=huske.example.com"}
    />
    <DocsTerminal>
      <DocsCmd cmd="huske-mcp doctor" />
      <DocsCmd cmd="huske-mcp sync" note="initial pull + index" />
      <DocsCmd cmd="huske-mcp serve" />
    </DocsTerminal>
    <p>
      Agents connect to <code>https://huske.example.com/mcp</code> with
      <code> Authorization: Bearer &lt;token&gt;</code>. The tools are
      <code> overview</code>, <code>recap</code>, <code>search</code>,
      <code> fetch</code>, and <code>sync_status</code>.
    </p>

    <h3>Designed for a tiny VPS</h3>
    <p>
      The default <code>tiny</code> profile uses one process, one poll thread,
      SQLite FTS5, an 8 MB page cache, and a 32 MB mmap ceiling. It loads no
      embedding model and is the supported 1 vCPU / 512 MB profile. The optional
      <code> semantic</code> profile adds Model2Vec hybrid retrieval and needs
      more memory.
    </p>

    <h3>Polling plus webhook</h3>
    <p>
      Polling is the correctness path and heals missed deliveries or restarts.
      An optional signed GitHub push webhook at
      <code> /webhooks/github</code> only wakes the poller early; the HTTP
      request never performs Git or indexing work.
    </p>

    <h3>Security posture</h3>
    <ul className="docs-bullets">
      <li><strong>A bearer token is mandatory</strong>, even on loopback, because a reverse proxy can publish a loopback listener.</li>
      <li><strong>Host validation remains enabled.</strong> List the proxy hostname in <code>HUSKE_MCP_ALLOWED_HOSTS</code>.</li>
      <li><strong>The VPS deploy key is read-only.</strong> The service never pushes or mutates its checkout.</li>
      <li><strong>The index is derived.</strong> SQLite stays outside Git and can be rebuilt from canonical Markdown.</li>
      <li><strong>The server holds plaintext.</strong> Encrypt its disk and expose it through TLS or a private overlay network.</li>
    </ul>
    <p>
      Full systemd, Docker, SSH deploy-key, reverse-proxy, webhook, and client
      instructions are in the{" "}
      <a href="https://github.com/tiagomoraes/huske/blob/main/docs/server.md" target="_blank" rel="noopener">server guide</a>.
    </p>

    <h3>No MCP at the destination?</h3>
    <p>
      <code>huske export</code> still writes one Markdown digest per day for a
      Claude Project, NotebookLM, Obsidian, or another document-oriented tool.
      Export is derived and separate from the canonical Git sync tree.
    </p>
  </DocsSection>
);

// ---- Page -------------------------------------------------------------------

const Docs = () => {
  const active = useScrollSpy(DOCS_SECTIONS.map((s) => s.id));
  return (
    <React.Fragment>
      <DocsHero />
      <div className="page docs-shell">
        <DocsToc active={active} />
        <article className="docs-body">
          <InstallDoc />
          <FirstRunDoc />
          <AutostartDoc />
          <ConfigDoc />
          <SearchDoc />
          <ConnectDoc />
        </article>
      </div>
    </React.Fragment>
  );
};

Object.assign(window, { Docs });
