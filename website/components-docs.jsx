// huske website — Docs page. Reuses the shared shell (Nav/Footer/CopyButton),
// the hero's InstallTabs, and the MCP setup data published by
// components-sections.jsx (MCP_ENDPOINT / MCP_TOKEN_PATH / AGENTS) so the
// per-agent configs stay a single source of truth with the landing page.
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
  { id: "search", label: "Search & MCP" },
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
        to your machine, and point any MCP agent at your transcripts. Everything
        runs on-device.
      </p>
    </div>
  </section>
);

// ---- 01 · Install -----------------------------------------------------------

const InstallDoc = () => (
  <DocsSection id="install" num="01" title="Install">
    <p className="docs-lead">
      huske is a single Python tool for macOS on Apple Silicon. Pick a package
      manager — <code>uv</code> is recommended for its speed and isolated install.
    </p>
    <ul className="docs-facts">
      <li><span className="k">os</span><span className="v">macOS 13+ (14.4+ recommended — the Core Audio tap survives screen sharing)</span></li>
      <li><span className="k">python</span><span className="v">{HUSKE_PYTHONS.slice(0, -1).join(", ")}, or {HUSKE_PYTHONS[HUSKE_PYTHONS.length - 1]}</span></li>
      <li><span className="k">disk</span><span className="v">~3 GB for the default <code>base</code> model (downloaded on first run)</span></li>
      <li><span className="k">audio</span><span className="v">no BlackHole, Aggregate Device, or Audio MIDI Setup — Apple's built-in capture is used</span></li>
    </ul>

    <InstallTabs />

    <h3>Optional extras</h3>
    <p>The base install records and transcribes. Two opt-in extras add separate, lazily-loaded subsystems:</p>
    <dl className="docs-defs">
      <dt><code>huske</code></dt>
      <dd>Base install. Record, transcribe, recover, autostart, and the dependency-free replication send side.</dd>
      <dt><code>huske[mcp]</code></dt>
      <dd>On-device semantic search and the <code>huske mcp</code> server (<code>huske index</code> + <code>huske mcp</code>). Adds mlx-embeddings, sqlite-vec, and the MCP SDK.</dd>
      <dt><code>huske[server]</code></dt>
      <dd>The off-device server (<code>huske serve</code>) for a box you control. Adds a CPU embedder (fastembed). See <a href="https://github.com/tiagomoraes/huske/blob/main/docs/server.md" target="_blank" rel="noopener">the server guide</a>.</dd>
    </dl>
    <DocsTerminal>
      <DocsCmd cmd="uv tool install 'huske[mcp]'" note="install with the search + MCP extra" />
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
        <DocsTerminal><DocsCmd cmd="huske run" /></DocsTerminal>
        <p>The Rich live panel shows the countdown, mic and system level meters, queue depth, and the last saved transcript. <kbd>Ctrl+C</kbd> finalizes the partial chunk, transcribes it, and exits. The <code>base</code> model downloads on the first transcription.</p>
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
      <code>huske autostart install</code> registers a per-user <code>launchd</code>
      LaunchAgent that runs <code>huske run --no-ui</code> automatically at every
      login. macOS only.
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
      they fire while you're present. The agent has no TUI; output is appended to:
    </p>
    <DocsCode lang="text" code={"~/Library/Logs/huske/agent.out.log\n~/Library/Logs/huske/agent.err.log"} />
    <p className="docs-aside">
      <code>huske doctor</code> reports the agent's state (installed, loaded, pid,
      and the log path on a crash), so you can check it without a separate command.
      The plist lives at <code>~/Library/LaunchAgents/me.huske.plist</code>.
    </p>

    <h3>Lighter idle footprint</h3>
    <p>
      Since the agent runs all day, you may want it to use less RAM while idle.
      Set <code>whisper_idle_unload = true</code> (drops the Whisper model from
      memory between chunks, freeing ~150 MB–3 GB; the next chunk reloads from the
      local cache in a few seconds) and <code>menu_bar_enabled = false</code> in a
      config file, then point the agent at it:
    </p>
    <DocsTerminal>
      <DocsCmd cmd="huske autostart install --config ~/.config/huske/config.toml" />
    </DocsTerminal>
  </DocsSection>
);

// ---- 04 · Configuration -----------------------------------------------------

const COMMON_CONFIG = [
  { key: "chunk_minutes", def: "15", desc: "Chunk (rotation) length in minutes (0.1–60).", flag: "--chunk-minutes" },
  { key: "system_audio_backend", def: "auto", desc: "System-audio capture: auto, tap, sck, or off (mic-only).", flag: "--system-audio-backend" },
  { key: "input_device", def: "system default", desc: "Microphone name, substring match. System audio is independent.", flag: "--input-device" },
  { key: "model", def: "base", desc: "Whisper model: tiny, base, small, medium, large-v3.", flag: "--model" },
  { key: "language", def: "auto-detect", desc: "Transcription language hint, ISO 639-1 (e.g. pt, en).", flag: "--language" },
  { key: "output_root", def: "~/huske/transcripts", desc: "Where Markdown transcripts are written.", flag: "--output-root" },
  { key: "audio_root", def: "~/huske/audio", desc: "Transient WAV chunks (plus incomplete/).", flag: "--audio-root" },
  { key: "keep_audio", def: "false", desc: "Keep raw WAVs after transcription.", flag: "--keep-audio" },
  { key: "log_level", def: "INFO", desc: "DEBUG, INFO, WARNING, ERROR.", flag: "--log-level" },
  { key: "no_ui", def: "false", desc: "Disable the live UI; emit plain log lines.", flag: "--no-ui" },
  { key: "screenshots_enabled", def: "false", desc: "Capture a JPEG of every display periodically. Loud — see privacy.", flag: "--screenshots" },
  { key: "screenshots_interval_seconds", def: "10", desc: "Seconds between screenshots (1–3600).", flag: "--screenshot-interval" },
];

const ADVANCED_CONFIG = [
  { key: "sample_rate", def: "48000", desc: "Capture sample rate (Hz).", flag: "" },
  { key: "block_size", def: "1024", desc: "Samples per audio callback block.", flag: "" },
  { key: "channels", def: "2", desc: "Input channel count (1–2; mixed to mono internally).", flag: "" },
  { key: "compute_type", def: "int8", desc: "Back-compat; only float32 disables fp16 on the MLX backend.", flag: "--compute-type" },
  { key: "device", def: "auto", desc: "Back-compat; mlx-whisper always runs on the Apple GPU.", flag: "--device" },
  { key: "whisper_idle_unload", def: "false", desc: "Drop the Whisper model from RAM between chunks (frees ~150 MB–3 GB); reloads from the local cache on the next chunk.", flag: "--idle-unload" },
  { key: "whisper_idle_unload_seconds", def: "120", desc: "Idle seconds before the model is unloaded (min 5).", flag: "" },
  { key: "logs_root", def: "~/huske/logs", desc: "Per-session log files.", flag: "" },
  { key: "menu_bar_enabled", def: "true", desc: "macOS menu bar helper while recording.", flag: "--menu-bar" },
  { key: "menu_bar_label_style", def: "text", desc: "Menu bar label: text or icon.", flag: "" },
  { key: "screenshots_root", def: "~/huske/screenshots", desc: "Screenshot output root.", flag: "--screenshots-root" },
  { key: "screenshots_max_displays", def: "4", desc: "Max displays captured per tick (1–16).", flag: "" },
  { key: "indexing_enabled", def: "false", desc: "Index each finalized transcript live during huske run.", flag: "" },
  { key: "embedding_model", def: "multilingual-e5-base", desc: "Local embedding model; changing it needs huske index --rebuild.", flag: "" },
  { key: "index_root", def: "~/huske/index", desc: "sqlite-vec passage store (passages.db).", flag: "" },
  { key: "index_low_impact", def: "true", desc: "Throttle the index backfill (CPU priority, batch, memory).", flag: "--low-impact / --fast" },
  { key: "embed_batch_size", def: "16", desc: "Passages per embedding forward pass (1–256).", flag: "" },
  { key: "index_memory_limit_mb", def: "unset", desc: "Hard MB ceiling on the MLX working set during indexing.", flag: "" },
  { key: "mcp_host", def: "127.0.0.1", desc: "huske mcp bind address (loopback only).", flag: "--host" },
  { key: "mcp_port", def: "7641", desc: "huske mcp port.", flag: "--port" },
  { key: "sync_endpoint", def: "unset", desc: "Replicate finalized transcripts to this huske server.", flag: "" },
  { key: "sync_verify_tls", def: "true", desc: "Verify the server's TLS certificate.", flag: "" },
  { key: "sync_root", def: "~/huske/sync", desc: "Durable replication send-outbox.", flag: "" },
  { key: "ingest_host", def: "127.0.0.1", desc: "Server ingest bind address (huske serve).", flag: "--ingest-host" },
  { key: "ingest_port", def: "7642", desc: "Server ingest port.", flag: "--ingest-port" },
  { key: "public_host", def: "unset", desc: "Public hostname validated on ingest.", flag: "--public-host" },
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
        Advanced capture, UI, search-index, and off-device-server keys. Most users never touch these.
      </p>
      <ConfigTable rows={ADVANCED_CONFIG} />
    </details>
  </DocsSection>
);

// ---- 05 · Search & MCP ------------------------------------------------------

// Extra clients beyond the landing page's AGENTS set. ${MCP_ENDPOINT} is real
// interpolation; \${...} is a literal placeholder the client resolves itself.
const DOCS_EXTRA_CLIENTS = [
  {
    id: "claude-desktop",
    label: "Claude Desktop / Cowork",
    selfWire: false,
    lang: "json",
    path: "~/Library/Application Support/Claude/claude_desktop_config.json",
    code:
`{
  "mcpServers": {
    "huske": {
      "command": "npx",
      "args": [
        "-y", "mcp-remote", "${MCP_ENDPOINT}",
        "--allow-http",
        "--header", "Authorization:\${HUSKE_MCP_TOKEN}"
      ],
      "env": { "HUSKE_MCP_TOKEN": "Bearer <token>" }
    }
  }
}`,
  },
  {
    id: "gemini",
    label: "Gemini CLI",
    lang: "json",
    path: "~/.gemini/settings.json",
    code:
`{
  "mcpServers": {
    "huske": {
      "httpUrl": "${MCP_ENDPOINT}",
      "headers": { "Authorization": "Bearer \${HUSKE_MCP_TOKEN}" }
    }
  }
}`,
  },
  {
    id: "generic",
    label: "Any MCP client",
    selfWire: false,
    lang: "json",
    path: "your client's MCP config",
    code:
`{
  "mcpServers": {
    "huske": {
      "url": "${MCP_ENDPOINT}",
      "headers": { "Authorization": "Bearer \${HUSKE_MCP_TOKEN}" }
    }
  }
}`,
  },
];

const DOCS_CLIENT_NOTES = {
  "claude-code": <>Loopback and a bearer header are fully supported, no tunnel. <code>$(cat …)</code> is expanded by your shell at add-time, so the resolved token lands in <code>~/.claude.json</code> — fine on a personal machine.</>,
  codex: <>Recent Codex builds use the streamable-HTTP client automatically; on older ones add <code>experimental_use_rmcp_client = true</code> if the tools don't load. Export <code>HUSKE_MCP_TOKEN</code> in your shell first.</>,
  cursor: <>No <code>type</code> key needed — Cursor infers the transport from <code>url</code>. <code>{"${env:HUSKE_MCP_TOKEN}"}</code> reads your shell environment, so export the token before launching Cursor.</>,
  vscode: <>VS Code uses <code>servers</code> (not <code>mcpServers</code>) and needs <code>"type": "http"</code>. The <code>{"${input:…}"}</code> form prompts once and keeps the token in encrypted secret storage.</>,
  opencode: <><code>{"{file:~/.config/huske/mcp_token}"}</code> reads the token from disk at load time, so nothing is committed. Put the literal <code>Bearer </code> prefix in the file if your build doesn't interpolate inside a string.</>,
  "claude-desktop": <>Claude Desktop's native connectors need a public URL and OAuth, so they can't reach a loopback bearer endpoint. The <code>mcp-remote</code> bridge (needs Node / <code>npx</code>) wraps it as a local stdio server. Write <code>Authorization:</code> with no space — Claude Desktop strips spaces in args — and keep <code>Bearer &lt;token&gt;</code> in the env value. Quit and reopen the app after editing. <strong>Cowork</strong> shares this same config: once Desktop reloads it, huske shows up in Cowork sessions too, no separate setup.</>,
  gemini: <>Gemini CLI uses <code>httpUrl</code> for streamable HTTP (<code>url</code> selects the SSE transport, which huske doesn't expose). <code>{"${HUSKE_MCP_TOKEN}"}</code> is resolved from your environment.</>,
  generic: <>Any client that speaks MCP <strong>Streamable HTTP</strong> (POST <code>/mcp</code>) with a custom <code>Authorization</code> header. huske exposes no SSE endpoint, so pick the streamable-HTTP transport.</>,
};

const ClientPanel = ({ client }) => {
  const [manual, setManual] = React.useState(false);
  const note = DOCS_CLIENT_NOTES[client.id];
  const manualBlock = (
    <React.Fragment>
      <DocsCode path={client.path} lang={client.lang} code={client.code} />
      {note && <p className="docs-client-note">{note}</p>}
    </React.Fragment>
  );

  // Chat apps and the generic "any client" can't self-wire from a pasted
  // prompt, so the manual config is the primary (and only) path for them.
  if (client.selfWire === false) {
    return <div className="docs-manual-only">{manualBlock}</div>;
  }

  return (
    <React.Fragment>
      <div className="docs-prompt">
        <div className="dp-head">
          <span className="dp-label">paste into {client.label}</span>
          <CopyButton text={agentPrompt(client.label)} className="copy ghost" />
        </div>
        <div className="dp-code"><PromptText label={client.label} /></div>
        <div className="dp-foot">The agent reads your token and registers the server itself. No secret is shown on this page.</div>
      </div>
      <div className={`docs-native ${manual ? "open" : ""}`}>
        <button
          type="button"
          className="docs-native-toggle"
          aria-expanded={manual}
          onClick={() => setManual((v) => !v)}
        >
          <span className="chev" aria-hidden="true">›</span>
          rather wire it up yourself? {client.label} config
        </button>
        <div className="docs-native-wrap">
          <div className="docs-native-inner">
            <div className="docs-native-pad">{manualBlock}</div>
          </div>
        </div>
      </div>
    </React.Fragment>
  );
};

const ClientTabs = () => {
  const clients = [...AGENTS, ...DOCS_EXTRA_CLIENTS];
  const [id, setId] = React.useState(clients[0].id);
  const client = clients.find((c) => c.id === id) || clients[0];
  return (
    <div className="docs-clients">
      <div className="docs-client-tabs" role="tablist" aria-label="Select your agent">
        {clients.map((c) => (
          <button
            key={c.id}
            role="tab"
            aria-selected={c.id === id}
            className={`dtab ${c.id === id ? "active" : ""}`}
            onClick={() => setId(c.id)}
          >
            {c.label}
          </button>
        ))}
      </div>
      <ClientPanel key={client.id} client={client} />
    </div>
  );
};

const SearchDoc = () => (
  <DocsSection id="search" num="05" title="Search & MCP">
    <p className="docs-lead">
      Opt into the <code>huske[mcp]</code> extra and every transcript becomes
      searchable by meaning: on-device embeddings, a local vector index, and an
      MCP server your agent queries directly.
    </p>
    <DocsTerminal>
      <DocsCmd cmd="uv tool install 'huske[mcp]'" note="add the search + MCP extra" />
      <DocsCmd cmd="huske index" note="embed your transcripts locally · one-time backfill" />
      <DocsCmd cmd="huske mcp" note="serve search + fetch · prints your endpoint + token" />
    </DocsTerminal>
    <p>
      Search returns nothing until the index is built, so run <code>huske index</code>
      {" "}first (<code>--rebuild</code> after changing the embedding model). The
      server binds loopback at <code>{MCP_ENDPOINT}</code>, speaks Streamable HTTP,
      and exposes two tools: <code>search</code> and <code>fetch</code>.
    </p>

    <h3>The bearer token</h3>
    <p>
      huske generates a token on first run, prints it in the <code>huske mcp</code>
      {" "}banner, and stores it at <code>{MCP_TOKEN_PATH}</code> (mode <code>0600</code>).
      Every request must carry <code>Authorization: Bearer &lt;token&gt;</code>.
      Export it once so the configs below can reference it without writing the
      secret into a file:
    </p>
    <DocsTerminal>
      <DocsCmd cmd="export HUSKE_MCP_TOKEN=$(cat ~/.config/huske/mcp_token)" />
    </DocsTerminal>

    <h3>Connect your agent</h3>
    <p>
      Pick your agent and paste the setup prompt — it reads your token and wires
      the server itself, no tunnel, and the secret never appears here. Prefer to
      edit a config file? Open <em>rather wire it up yourself?</em> for the exact
      config. (Claude Desktop and a generic client are manual-only.)
    </p>
    <ClientTabs />

    <h3>ChatGPT &amp; always-on agents</h3>
    <p>
      ChatGPT can't reach a loopback server and its connector UI has no field for
      a bearer header. To use it, expose huske over a public HTTPS tunnel fronted
      by a proxy that injects the token, then add a custom connector set to
      <em> No authentication</em>:
    </p>
    <DocsCode
      lang="shell"
      code={"# 1. expose the loopback server over public HTTPS\ncloudflared tunnel --url http://127.0.0.1:7641\n\n# 2. front it with a proxy that injects the bearer ChatGPT can't add (Caddy):\n#    huske.example.com {\n#      reverse_proxy 127.0.0.1:7641 {\n#        header_up Authorization \"Bearer {env.HUSKE_MCP_TOKEN}\"\n#      }\n#    }\nHUSKE_MCP_TOKEN=\"$(cat ~/.config/huske/mcp_token)\" caddy run\n\n# 3. ChatGPT → Settings → Apps & Connectors → Advanced → Developer mode,\n#    add a connector at https://huske.example.com/mcp, auth = none."}
    />
    <p className="docs-aside">
      A public tunnel weakens huske's loopback-only posture. For always-on remote
      access, prefer the off-device server: <code>huske[server]</code> replicates
      transcripts to a box you control and runs the agent co-located there, so the
      read endpoint stays loopback. See
      {" "}<a href="https://github.com/tiagomoraes/huske/blob/main/docs/server.md" target="_blank" rel="noopener">the server guide</a>.
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
        </article>
      </div>
    </React.Fragment>
  );
};

Object.assign(window, { Docs });
