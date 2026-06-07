// huske website — Pillars, How it works, Output ledger, Privacy, Releases, Community, FAQ.

const SectionHead = ({ num, label, lead, sub }) => (
  <div className="section-head">
    <div className="label">
      <span className="num">{num}</span>
      <span>{label}</span>
    </div>
    <div>
      <h2 className="lead">{lead}</h2>
      {sub && <p className="sub">{sub}</p>}
    </div>
  </div>
);

const Pillars = () => (
  <section id="why">
    <div className="page">
      <SectionHead
        num="01"
        label="why huske"
        lead={<>Three commitments. <span className="accent">Nothing more.</span></>}
        sub="huske does one thing: it listens, and it remembers. Everything below follows from that."
      />
      <div className="pillars">
        <div className="pillar" style={{ display: "flex", flexDirection: "column" }}>
          <div className="ph">local · first</div>
          <h3>Audio never leaves your machine.</h3>
          <p>
            Capture and transcription run on-device with <code>mlx-whisper</code> on Apple Silicon.
            No accounts, no upload, no telemetry. Works offline. The only network call huske makes
            is a once-a-day, opt-out version check.
          </p>
          <div className="stat">
            <div><strong>0</strong>audio uploads</div>
            <div><strong>0</strong>accounts</div>
            <div><strong>~/huske/</strong>only</div>
          </div>
        </div>

        <div className="pillar" style={{ display: "flex", flexDirection: "column" }}>
          <div className="ph">always · on</div>
          <h3>Continuous capture, no gaps.</h3>
          <p>
            Microphone via <code>sounddevice</code>. System audio via Core Audio process tap
            on macOS 14.4+, with ScreenCaptureKit fallback on older macOS. Rotated into
            Markdown chunks every 15 minutes. SIGKILL the
            process and <code>huske recover</code> reclaims orphaned audio.
          </p>
          <div className="stat">
            <div><strong>15 min</strong>default chunks</div>
            <div><strong>6 s — 60 m</strong>configurable</div>
            <div><strong>48 kHz</strong>mono wav</div>
          </div>
        </div>

        <div className="pillar" style={{ display: "flex", flexDirection: "column" }}>
          <div className="ph">agent · ready</div>
          <h3>A directory your agent can read — and search.</h3>
          <p>
            Plain Markdown, organized by date, full YAML frontmatter, root <code>README.md</code>.
            Point Claude Code or any LLM agent at <code>~/huske/transcripts/</code>, or opt into the
            <code>huske[mcp]</code> extra for on-device semantic <a href="#search">search over an MCP server</a>.
          </p>
          <div className="stat">
            <div><strong>md</strong>output format</div>
            <div><strong>vector</strong>local index</div>
            <div><strong>mcp</strong>search + fetch</div>
          </div>
        </div>
      </div>
    </div>
  </section>
);

const HowItWorks = () => (
  <section id="how">
    <div className="page">
      <SectionHead
        num="02"
        label="how it works"
        lead={<>Capture, chunk, transcribe, <span className="accent">write.</span></>}
        sub="Four stages, each one a single shell command's worth of complexity. No magic, no surprise dependencies."
      />
      <div className="pipeline">
        <div className="stage">
          <div className="n"><span className="digit">01</span></div>
          <div>
            <h4>Capture two streams.</h4>
            <p>Microphone via <code>sounddevice</code>. System audio via Core Audio process tap on macOS 14.4+, with ScreenCaptureKit fallback on older macOS. Each source is written as a mono WAV so chunk boundaries stay gapless.</p>
          </div>
          <div className="meta">
            <div className="row"><span className="k">backend</span><span className="v">auto · tap · sck · off</span></div>
            <div className="row"><span className="k">permission</span><span className="v">audio capture · screen recording</span></div>
            <div className="row"><span className="k">prompted</span><span className="v">first run only</span></div>
          </div>
        </div>

        <div className="stage">
          <div className="n"><span className="digit">02</span></div>
          <div>
            <h4>Rotate into chunks.</h4>
            <p>Default 15-minute boundaries; anything from 6 seconds to 60 minutes. WAV written to <code>~/huske/audio/</code>, queued for transcription. Boundaries are gapless — the next chunk starts on the same sample the last one ended.</p>
          </div>
          <div className="meta">
            <div className="row"><span className="k">--chunk-minutes</span><span className="v">0.1 – 60.0 <span className="opt">(15 default)</span></span></div>
            <div className="row"><span className="k">audio root</span><span className="v">~/huske/audio/</span></div>
            <div className="row"><span className="k">format</span><span className="v">wav · pcm_s16le · 48 kHz</span></div>
          </div>
        </div>

        <div className="stage">
          <div className="n"><span className="digit">03</span></div>
          <div>
            <h4>Transcribe locally.</h4>
            <p><code>mlx-whisper</code> on Apple Silicon, running on the M-series GPU via MLX. Per-chunk, on-device, no cloud. Per-source segments for mic and system audio so timestamps map back to wall-clock session time.</p>
          </div>
          <div className="meta">
            <div className="row"><span className="k">--model</span><span className="v">base <span className="opt">(default)</span></span></div>
            <div className="row"><span className="k">engine</span><span className="v">mlx-whisper · apple gpu</span></div>
            <div className="row"><span className="k">latency</span><span className="v">~5–7× realtime · M2</span></div>
          </div>
        </div>

        <div className="stage">
          <div className="n"><span className="digit">04</span></div>
          <div>
            <h4>Write a Markdown ledger.</h4>
            <p>One Markdown file per chunk under <code>YYYY-MM-DD/HHMMSS_&lt;sessionid8&gt;_&lt;seq&gt;.md</code>, with YAML frontmatter and timestamped per-source paragraphs. A root <code>README.md</code> documents the layout. That's the agent's input — and the human's, too.</p>
          </div>
          <div className="meta">
            <div className="row"><span className="k">--output-root</span><span className="v">~/huske/transcripts/</span></div>
            <div className="row"><span className="k">layout</span><span className="v">YYYY-MM-DD/HHMMSS_…_NNN.md</span></div>
            <div className="row"><span className="k">contract</span><span className="v">stable · v1</span></div>
          </div>
        </div>
      </div>
    </div>
  </section>
);

const FILES = [
  { name: "091500_8a3f2c19_001.md", active: true },
  { name: "093000_8a3f2c19_002.md" },
  { name: "094500_8a3f2c19_003.md" },
];

const OutputPreview = () => {
  const [active, setActive] = React.useState(0);
  const [copied, setCopied] = React.useState(false);
  const cur = FILES[active] || FILES[0];
  return (
    <section id="output">
      <div className="page">
        <SectionHead
          num="03"
          label="output"
          lead={<>The output is the <span className="accent">interface.</span></>}
          sub={<>Plain Markdown. Plain directory layout. Stable contract. The format is the API — copy a transcript into a chat, glob the directory from a script, point an agent at it. It's already in the format your tools prefer.</>}
        />
        <div className="ledger">
          <div className="tree">
            <div className="head">~/huske/transcripts/</div>
            <div className="item"><span className="glyph">├─</span> README.md</div>
            <div className="item root"><span className="glyph">▾</span> 2026-05-07/</div>
            {FILES.map((f, i) => (
              <div
                key={f.name}
                className={`item ${i === active ? "active" : ""}`}
                onClick={() => setActive(i)}
                style={{ paddingLeft: 16 }}
              >
                <span className="glyph">{i === FILES.length - 1 ? "└─" : "├─"}</span>
                {f.name}
              </div>
            ))}
            <div style={{ height: 12 }}/>
            <div className="item root"><span className="glyph">▸</span> 2026-05-06/</div>
            <div className="item root"><span className="glyph">▸</span> 2026-05-05/</div>
          </div>
          <div className="doc">
            <div className="crumb">
              <span>2026-05-07</span>
              <span className="arrow">/</span>
              <span style={{ color: "var(--fg)" }}>{cur.name}</span>
              <div className="actions">
                <button onClick={() => {
                  navigator.clipboard?.writeText(cur.name);
                  setCopied(true);
                  setTimeout(() => setCopied(false), 1200);
                }}>{copied ? "✓ copied" : "copy path"}</button>
                <button>open in editor</button>
              </div>
            </div>
            <div className="frontmatter">
              <div><span className="delim">---</span></div>
              <div><span className="key">session_id:</span>      <span className="str">"20260507T091500_8a3f"</span></div>
              <div><span className="key">chunk_seq:</span>       <span className="val">1</span></div>
              <div><span className="key">date:</span>            <span className="str">2026-05-07</span></div>
              <div><span className="key">start_time:</span>      <span className="str">2026-05-07T09:15:00-03:00</span></div>
              <div><span className="key">end_time:</span>        <span className="str">2026-05-07T09:30:00-03:00</span></div>
              <div><span className="key">duration_seconds:</span> <span className="val">900</span></div>
              <div><span className="key">duration_actual_seconds:</span> <span className="val">900.0</span></div>
              <div><span className="key">gap_seconds:</span>     <span className="val">0.0</span></div>
              <div><span className="key">model:</span>            <span className="val">mlx-whisper:base</span></div>
              <div><span className="key">audio_sources:</span>    <span className="val">[microphone, system]</span></div>
              <div><span className="key">language:</span>         <span className="str">auto</span></div>
              <div><span className="key">incomplete:</span>       <span className="val">false</span></div>
              <div><span className="key">huske_version:</span>    <span className="str">{HUSKE_VERSION}</span></div>
              <div><span className="delim">---</span></div>
            </div>

            <h2># Transcript · 09:15:00 — 09:30:00</h2>

            <div className="turn mic">
              <span className="ts">09:15:02</span>
              <span className="src">mic</span>
              <span className="body">morning. let's review the auth bug that came up yesterday — looks like the token refresh is racing the cookie write on slow links.</span>
            </div>
            <div className="turn sys">
              <span className="ts">09:15:14</span>
              <span className="src">sys</span>
              <span className="body">sure, looking at the staging logs now. give me a sec.</span>
            </div>
            <div className="turn mic">
              <span className="ts">09:15:38</span>
              <span className="src">mic</span>
              <span className="body">the timing is interesting — every failure is within 80 ms of the cookie write returning.</span>
            </div>
            <div className="turn sys">
              <span className="ts">09:15:54</span>
              <span className="src">sys</span>
              <span className="body">yeah, i see it. the middleware reads from the request before the response cookie has flushed. easy fix — we can pin the auth header in the same hop.</span>
            </div>
            <div className="turn mic">
              <span className="ts">09:16:21</span>
              <span className="src">mic</span>
              <span className="body">good. let me draft a patch and we can pair on it after standup.</span>
            </div>
          </div>
        </div>
      </div>
    </section>
  );
};

const MCP_ENDPOINT = "http://127.0.0.1:7641/mcp";
const MCP_TOKEN_PATH = "~/.config/huske/mcp_token";

const SETUP_STEPS = [
  { cmd: "uv tool install 'huske[mcp]'", note: "add the on-device search + MCP extra" },
  { cmd: "huske index", note: "embed your transcripts locally · one-time backfill" },
  { cmd: "huske mcp", note: "serve search + fetch · prints your endpoint + token" },
];

// Per-agent native config. The paste-prompt (below) is the primary path; this is
// the "wire it yourself" fallback. Configs verified against each tool's docs.
const AGENTS = [
  {
    id: "claude-code",
    label: "Claude Code",
    lang: "shell",
    path: "or edit ~/.claude.json",
    code:
`claude mcp add --transport http huske \\
  ${MCP_ENDPOINT} \\
  --header "Authorization: Bearer $(cat ${MCP_TOKEN_PATH})"`,
  },
  {
    id: "codex",
    label: "Codex",
    lang: "toml",
    path: "~/.codex/config.toml",
    code:
`# first: export HUSKE_MCP_TOKEN=$(cat ${MCP_TOKEN_PATH})
[mcp_servers.huske]
url = "${MCP_ENDPOINT}"
bearer_token_env_var = "HUSKE_MCP_TOKEN"`,
  },
  {
    id: "cursor",
    label: "Cursor",
    lang: "json",
    path: "~/.cursor/mcp.json",
    code:
`{
  "mcpServers": {
    "huske": {
      "url": "${MCP_ENDPOINT}",
      "headers": { "Authorization": "Bearer \${env:HUSKE_MCP_TOKEN}" }
    }
  }
}`,
  },
  {
    id: "vscode",
    label: "VS Code",
    lang: "json",
    path: ".vscode/mcp.json",
    code:
`{
  "servers": {
    "huske": {
      "type": "http",
      "url": "${MCP_ENDPOINT}",
      "headers": { "Authorization": "Bearer \${env:HUSKE_MCP_TOKEN}" }
    }
  }
}`,
  },
  {
    id: "opencode",
    label: "opencode",
    lang: "json",
    path: "opencode.json",
    code:
`{
  "mcp": {
    "huske": {
      "type": "remote",
      "url": "${MCP_ENDPOINT}",
      "enabled": true,
      "headers": { "Authorization": "Bearer <token>" }
    }
  }
}`,
  },
  {
    id: "hermes",
    label: "Hermes",
    lang: "yaml",
    path: "~/.hermes/config.yaml",
    code:
`mcp_servers:
  huske:
    url: "${MCP_ENDPOINT}"
    headers:
      Authorization: "Bearer <token>"`,
  },
  {
    id: "openclaw",
    label: "OpenClaw",
    lang: "json",
    path: "~/.openclaw/openclaw.json",
    code:
`{
  "mcp": {
    "servers": {
      "huske": {
        "url": "${MCP_ENDPOINT}",
        "transport": "streamable-http",
        "headers": { "Authorization": "Bearer <token>" }
      }
    }
  }
}`,
  },
];

// The Composio-style instruction: paste it into the agent and it wires itself up.
// Plain string for the clipboard; PromptText renders the same words with the
// literal values syntax-highlighted so the code block reads as fill-in-the-values.
const agentPrompt = (label) =>
`Add an MCP server named "huske" to ${label}. Use HTTP (streamable) transport at ${MCP_ENDPOINT}, with the header "Authorization: Bearer <TOKEN>", where <TOKEN> is the contents of ${MCP_TOKEN_PATH} on this machine. It exposes "search" and "fetch" over my local huske transcripts. Start "huske mcp" first, then confirm by calling its search tool.`;

const PromptText = ({ label }) => (
  <>
    Add an MCP server named <span className="lit">huske</span> to {label}. Use HTTP
    (streamable) transport at <span className="lit">{MCP_ENDPOINT}</span>, with the
    header <span className="lit">"Authorization: Bearer &lt;TOKEN&gt;"</span>, where{" "}
    <span className="lit">&lt;TOKEN&gt;</span> is the contents of{" "}
    <span className="lit">{MCP_TOKEN_PATH}</span> on this machine. It exposes{" "}
    <span className="lit">search</span> and <span className="lit">fetch</span> over my
    local huske transcripts. Start <span className="lit">huske mcp</span> first, then
    confirm by calling its search tool.
  </>
);

const SearchRecall = () => {
  const [agentId, setAgentId] = React.useState("claude-code");
  const [showNative, setShowNative] = React.useState(false);
  const agent = AGENTS.find((a) => a.id === agentId) || AGENTS[0];
  const prompt = agentPrompt(agent.label);
  return (
    <section id="search">
      <div className="page">
        <SectionHead
          num="04"
          label="search · mcp"
          lead={<>Recall over <span className="accent">MCP.</span></>}
          sub={<>Opt into the <code>huske[mcp]</code> extra and every transcript becomes searchable by <em>meaning</em>: on-device embeddings, a local vector index, and an MCP server your agent queries directly. Run it, paste one prompt into Claude Code, Codex, Cursor, or any MCP client, and it wires itself up. Nothing but the answer ever leaves your machine.</>}
        />
        <div className="recall connect-grid">
          <div className="panel connect">
            <div className="cstep">
              <div className="cstep-head"><span className="cnum">01</span> run the server</div>
              <div className="setup">
                {SETUP_STEPS.map((s) => (
                  <div className="sline" key={s.cmd}>
                    <code className="sc"><span className="sp">$</span> {s.cmd}</code>
                    <span className="snote"># {s.note}</span>
                    <CopyButton text={s.cmd} className="copy ghost mini" withLabel={false}/>
                  </div>
                ))}
              </div>
            </div>

            <div className="cstep">
              <div className="cstep-head"><span className="cnum">02</span> connect your agent</div>
              <div className="agent-tabs" role="tablist" aria-label="Select your agent">
                {AGENTS.map((a) => (
                  <button
                    key={a.id}
                    role="tab"
                    aria-selected={a.id === agentId}
                    className={`atab ${a.id === agentId ? "active" : ""}`}
                    onClick={() => setAgentId(a.id)}
                  >
                    {a.label}
                  </button>
                ))}
              </div>

              <div className="prompt-block">
                <div className="pb-head">
                  <span className="pb-label">paste into {agent.label}</span>
                  <CopyButton text={prompt} className="copy ghost" />
                </div>
                <div className="pb-code"><PromptText label={agent.label}/></div>
                <div className="pb-foot">the agent reads your token and registers the server itself. no secret is shown on this page.</div>
              </div>

              <div className={`native ${showNative ? "open" : ""}`}>
                <button
                  type="button"
                  className="native-toggle"
                  aria-expanded={showNative}
                  onClick={() => setShowNative((v) => !v)}
                >
                  <span className="chev" aria-hidden="true">›</span>
                  rather wire it up yourself? {agent.label} config
                </button>
                <div className="native-wrap">
                  <div className="native-inner">
                    <div className="native-body">
                      <div className="nb-head">
                        <span className="nb-path">{agent.path}</span>
                        <span className="nb-lang">{agent.lang}</span>
                        <CopyButton text={agent.code} className="copy ghost"/>
                      </div>
                      <pre className="nb-code"><code>{agent.code}</code></pre>
                    </div>
                  </div>
                </div>
              </div>
            </div>
          </div>

          <div className="panel wiring">
            <div className="whead"><span className="dot"/> mcp · loopback</div>
            <div className="wmeta">
              <div className="row"><span className="k">endpoint</span><span className="v">127.0.0.1:7641/mcp</span></div>
              <div className="row"><span className="k">transport</span><span className="v">http · streamable</span></div>
              <div className="row"><span className="k">tools</span><span className="v">search · fetch</span></div>
              <div className="row"><span className="k">model</span><span className="v">multilingual-e5-base · 768d</span></div>
              <div className="row"><span className="k">index</span><span className="v">on-device · sqlite-vec</span></div>
              <div className="row"><span className="k">distill</span><span className="v">qwen3.5:0.8b · opt-in</span></div>
            </div>
            <div className="auth">
              <div className="auth-head"><KeyGlyph/> authentication</div>
              <p className="auth-p">
                Every request carries a bearer token. huske generates one on first run,
                prints it in the <code>huske mcp</code> banner, and stores it at
                {" "}<code>{MCP_TOKEN_PATH}</code> (mode <code>0600</code>).
              </p>
              <p className="auth-p">
                Reference it with <code>$(cat …)</code> or an env var so the secret stays out
                of committed config, and off this page.
              </p>
            </div>
            <div className="wnote">
              <div className="ln"><span className="tick">✓</span><span>Claude Code, Codex, Cursor &amp; more connect direct over loopback. No tunnel.</span></div>
              <div className="ln"><span className="warn">⚠</span><span>ChatGPT needs a public HTTPS tunnel to reach it (opt-in).</span></div>
            </div>
          </div>
        </div>

        <div className="two-stage">
          <div className="ts-head">
            <span className="ts-tag">opt-in</span>
            <span>two-stage recall · distillation</span>
          </div>
          <div className="ts-grid">
            <div className="ts-main">
              <div className="ts-flow">
                <span className="node">transcript</span>
                <span className="arr">→</span>
                <span className="node hot">distil · local LLM</span>
                <span className="arr">→</span>
                <span className="node">statements</span>
                <span className="arr">→</span>
                <span className="node">search</span>
                <span className="arr">→</span>
                <span className="node">fetch grounds in source</span>
              </div>
              <p className="ts-p">
                Set <code>distill_enabled</code> and a local LLM condenses each transcript
                into compact, self-contained <em>statements</em> in a fast, non-reasoning
                pass. huske searches those first — denser and less noisy than raw speech —
                then <code>fetch</code>
                grounds every hit back in the verbatim transcript. The model is just a
                config string, so swap it freely; it runs in its own daemon, stays
                on-device, and degrades gracefully when it's off.
              </p>
            </div>
            <div className="ts-meta">
              <div className="row"><span className="k">model</span><span className="v">qwen3.5:0.8b <span className="opt">· any local tag</span></span></div>
              <div className="row"><span className="k">backend</span><span className="v">ollama · on-device</span></div>
              <div className="row"><span className="k">writes</span><span className="v">&lt;name&gt;.statements.json</span></div>
              <div className="row"><span className="k">default</span><span className="v">off · graceful</span></div>
            </div>
          </div>
        </div>
      </div>
    </section>
  );
};

const Privacy = () => (
  <section id="privacy">
    <div className="page">
      <SectionHead
        num="05"
        label="privacy"
        lead={<>Local-first isn't a vibe. <span className="accent">It's the architecture.</span></>}
      />
      <div className="privacy">
        <div>
          <div className="eyebrow"><span style={{ display: "inline-block", width: 6, height: 6, borderRadius: "50%", background: "var(--brand-amber)" }}/> the deal</div>
          <h3>Audio, transcripts, and screenshots stay on the machine that recorded them.</h3>
          <p>
            huske is local-first by design. The capture pipeline never opens an outbound socket
            for audio. Transcription happens on your Apple GPU. Filenames, frontmatter, logs —
            everything that touches a recording lives on your filesystem, under a path
            <strong> you</strong> chose.
          </p>
          <p>
            The single network call huske makes is a once-a-day version check against PyPI.
            <code>HUSKE_NO_UPDATE_CHECK=1</code> turns it off.
          </p>
        </div>
        <div>
          <ul>
            <li>
              <span className="glyph">✓</span>
              <span>
                <strong>No upload.</strong>
                <span className="desc">Audio, transcripts, and metadata never leave the device.</span>
              </span>
            </li>
            <li>
              <span className="glyph">✓</span>
              <span>
                <strong>No accounts.</strong>
                <span className="desc">Nothing to sign in to, nothing to forget to log out of.</span>
              </span>
            </li>
            <li>
              <span className="glyph">✓</span>
              <span>
                <strong>No telemetry.</strong>
                <span className="desc">huske doesn't measure you. The only beacon is the version check, and it's opt-out.</span>
              </span>
            </li>
            <li className="warn">
              <span className="glyph">⚠</span>
              <span>
                <strong>Local data is still sensitive.</strong>
                <span className="desc">Recordings and transcripts can hold private and regulated content. Get consent. Don't commit them. Redact <code>huske doctor</code> output before sharing.</span>
              </span>
            </li>
            <li className="warn">
              <span className="glyph">⚠</span>
              <span>
                <strong><code>--screenshots</code> is loud.</strong>
                <span className="desc">It captures every display every 60 s — passwords, banking tabs, DMs. Off by default. Opt in only after reading what you're recording.</span>
              </span>
            </li>
          </ul>
        </div>
      </div>
    </div>
  </section>
);

const RELEASES = [
  {
    ver: "0.8.0", date: "2026-06-07", tag: "latest",
    items: [
      { kind: "added", text: <>Opt-in LLM distillation into searchable <strong>statements</strong> (off by default). A local LLM (Ollama; default <code>qwen3.5:0.8b</code>, any tag) condenses each transcript into compact, self-contained claims; with local search on, <code>huske mcp</code> ranks those first and <code>fetch</code> grounds every hit in the verbatim source (two-stage retrieval). Adds <code>huske distill</code> backfill, a <code>huske doctor</code> daemon check, and <code>distill_*</code> config — dependency-free and off the hot path. See <code>docs/distillation.md</code>.</> },
      { kind: "changed", text: <>Screenshots are lighter by default: the capture interval is now <code>60s</code> (was <code>10s</code>), and each frame is downscaled (long edge ≤ <code>1568px</code>) and re-encoded at JPEG quality <code>60</code> in place via macOS <code>sips</code>. New <code>screenshots_max_dimension</code> / <code>screenshots_jpeg_quality</code> config and matching flags.</> },
      { kind: "changed", text: <><code>keep_audio</code> now stores compressed audio instead of raw WAV — each chunk is transcoded after transcription via the new <code>keep_audio_format</code> (default <code>opus</code>, ~12–20× smaller; <code>flac</code> lossless; <code>wav</code> unchanged). Transcription and crash recovery are unaffected.</> },
    ],
  },
  {
    ver: "0.7.4", date: "2026-06-07",
    items: [
      { kind: "added", text: <>Setup guidance for connecting <strong>Claude Desktop and Cowork</strong> through the <code>mcp-remote</code> bridge — both share one <code>claude_desktop_config.json</code>, so the same entry exposes huske in Cowork once Desktop reloads. The home page gained a quick-start strip linking the autostart and MCP guides.</> },
      { kind: "changed", text: <>Lighter footprint, default-on: the transcription worker releases the Metal buffer pool after every chunk (not only on idle unload), and the ScreenCaptureKit capture stack now imports lazily — loading only when the SCK fallback path runs, not on the Core Audio tap path, mic-only mode, or <code>huske recover</code>.</> },
      { kind: "fixed", text: <>The live UI's "N pending" chunk count was always 0 on macOS (it read <code>multiprocessing.Queue.qsize()</code>, which is unimplemented there); it now uses the orchestrator's authoritative pending count.</> },
    ],
  },
  {
    ver: "0.7.3", date: "2026-06-03",
    items: [
      { kind: "fixed", text: <>The <code>huske run</code> startup log now records the running version instead of a stale <code>v0.1.0</code> placeholder.</> },
      { kind: "changed", text: <>The website reads its version from a single source (<code>website/version.js</code>), and the release tooling now verifies every page matches the released version, so the public site no longer drifts to an older version between releases.</> },
    ],
  },
  {
    ver: "0.7.2", date: "2026-06-03",
    items: [
      { kind: "changed", text: <>Website docs page now lives at <code>/docs/</code> (clean URL) instead of <code>/docs.html</code>. In-page nav links no longer expose <code>index.html</code> in the URL.</> },
    ],
  },
  {
    ver: "0.7.1", date: "2026-06-03",
    items: [
      { kind: "added", text: <>Idle whisper-model unload (<code>--idle-unload</code> / <code>whisper_idle_unload = true</code>, off by default). The transcription worker drops the model weights after <code>whisper_idle_unload_seconds</code> of inactivity (default 120 s) and reloads lazily on the next chunk, freeing up to ~3 GB of resident RAM during long recording gaps. Reloads resolve from a pinned local snapshot directory, so they are network-free.</> },
      { kind: "added", text: <><code>--no-menu-bar</code> (<code>menu_bar_enabled = false</code>) now also skips the IPC control socket and its accept thread, cutting an additional ~50–80 MB of idle RSS when the menu-bar helper is disabled.</> },
      { kind: "added", text: <><code>huske doctor</code> reports the autostart LaunchAgent state: whether the agent is installed, loaded, its running PID, and a pointer to any crash log. Informational only; never fails the command; skipped on non-macOS.</> },
      { kind: "added", text: <>New website docs page covering install, macOS permissions, autostart on login, full config reference, and MCP setup for Claude Desktop, Gemini CLI, ChatGPT, and other clients.</> },
      { kind: "added", text: <><code>examples/config.toml</code> now documents every current <code>RuntimeConfig</code> key, including the new <code>whisper_idle_unload</code> and <code>menu_bar_enabled</code> footprint knobs.</> },
    ],
  },
  {
    ver: "0.7.0", date: "2026-06-03",
    items: [
      { kind: "added", text: <>Off-device replication (opt-in <code>huske[server]</code> extra). <code>huske serve</code> runs a single-tenant huske server on a box you control — it receives finalized transcripts pushed from a recording Mac, indexes them with a CPU (<code>fastembed</code>) embedder, and serves the existing <code>search</code>/<code>fetch</code> MCP over loopback to a co-located agent. <code>huske run</code> replicates live when <code>sync_endpoint</code> is set; <code>huske sync</code> backfills. Only the write-only ingest endpoint is network-exposed. See <code>docs/server.md</code>.</> },
      { kind: "added", text: <>huske now sets its OS process title, so it shows as <code>huske</code> (and <code>huske-whisper</code> / <code>huske-embed</code> for its workers) in Activity Monitor, <code>ps</code>, and <code>top</code> instead of a bare Python interpreter.</> },
      { kind: "changed", text: <>Python 3.14 is now supported — <code>requires-python</code> is <code>&gt;=3.11,&lt;3.15</code>, and CI tests against it.</> },
    ],
  },
  {
    ver: "0.6.0", date: "2026-06-02",
    items: [
      { kind: "changed", text: <>Release process collapses into three scripts under <code>scripts/</code>: <code>release.py</code>, <code>release-finalize.py</code>, and <code>update-homebrew-tap.py</code>. The short operational checklist is <code>docs/RELEASE_PLAYBOOK.md</code>; <code>docs/releasing.md</code> remains as the deep reference.</> },
      { kind: "changed", text: <><code>huske/__init__.py</code> now reads the version from <code>pyproject.toml</code> when the package source is adjacent (dev checkout / editable install) and falls back to <code>importlib.metadata</code> for installed wheels. The two hardcoded versions could no longer drift the way <code>0.3.1</code> had to be hotfixed for.</> },
      { kind: "added", text: <><code>.github/workflows/back-merge.yml</code> automatically opens the <code>chore/sync-main-after-vX.Y.Z</code> (or <code>chore/sync-main-hotfix-…</code>) PR when a <code>release: v*</code> / <code>hotfix:*</code> PR merges into <code>main</code>, so the back-merge step no longer relies on the maintainer remembering to open it.</> },
      { kind: "added", text: <><strong>Local semantic search</strong> (opt-in <code>huske[mcp]</code> extra). <code>huske index</code> builds or refreshes a local <code>sqlite-vec</code> passage store from transcripts. Each finalized transcript is embedded via <code>mlx-embeddings</code> (<code>multilingual-e5-base</code>) in an isolated subprocess so the audio drainer is never starved. <code>huske run</code> can continuously index during recording when <code>indexing_enabled = true</code> in config. See <code>docs/adr/0002</code> and <code>CONTEXT.md</code> for the Passage model.</> },
      { kind: "added", text: <><strong><code>huske mcp</code> daemon</strong> exposes <code>search</code> and <code>fetch</code> over a loopback HTTP MCP endpoint (bearer token + Origin/Host validation). Works with any MCP client (Claude Desktop, ChatGPT, etc.). See <code>docs/adr/0001</code>.</> },
      { kind: "added", text: <><code>index_root</code>, <code>indexing_enabled</code>, <code>embedding_model</code>, <code>mcp_host</code>, and <code>mcp_port</code> config keys for the search subsystem.</> },
    ],
  },
  {
    ver: "0.5.0", date: "2026-05-09",
    items: [
      { kind: "added", text: <><code>huske autostart</code> subcommand group to manage a macOS LaunchAgent that runs <code>huske run --no-ui</code> at every login. Verbs: <code>install</code>, <code>uninstall</code>, <code>status</code>, <code>start</code>, <code>stop</code>. Logs at <code>~/Library/Logs/huske/agent.&#123;out,err&#125;.log</code>. Default restart policy is restart-on-crash only.</> },
    ],
  },
  {
    ver: "0.4.0", date: "2026-05-09",
    items: [
      { kind: "added", text: <>Live UI controls panel — press <code>?</code> to open an overlay with <code>p</code> pause/resume, <code>s</code> toggle screenshots, <code>q</code> graceful stop, <code>Esc</code> close. Pausing finalizes the current chunk; screenshot toggle takes effect immediately.</> },
      { kind: "changed", text: <>Group adjacent transcript segments from the same source under a single timestamp range. Long monologues break after ~90 s, and empty/missing-source segments stay ungrouped.</> },
      { kind: "fixed", text: <>Suppress whisper hallucinations on quiet input via per-source noise-floor gating and <code>condition_on_previous_text=False</code>. Fails open on WAV read errors.</> },
    ],
  },
  {
    ver: "0.3.1", date: "2026-05-08",
    items: [
      { kind: "fixed", text: <>Corrected the runtime version reported by <code>huske --version</code>, <code>huske doctor</code>, update checks, transcript metadata, and the TUI.</> },
    ],
  },
  {
    ver: "0.3.0", date: "2026-05-08",
    items: [
      { kind: "changed", text: <>Switched the transcription engine from <code>faster-whisper</code> to <code>mlx-whisper</code>. ~5–7× faster on Apple Silicon, runs on the M-series GPU. Apple Silicon only.</> },
      { kind: "added", text: <>Per-source transcript segments for mic and system audio, with system WAV padding so segment timestamps map back to wall-clock time.</> },
      { kind: "added", text: <>Core Audio process-tap backend for system audio capture.</> },
      { kind: "added", text: <>Optional periodic screenshots — <code>--screenshots</code> captures a JPEG of every display every 10 s for downstream multimodal LLM use. Off by default.</> },
    ],
  },
  {
    ver: "0.2.0", date: "2026-05-07",
    items: [
      { kind: "added", text: <>Update check on startup — banner with the right upgrade command for your install method. Cached for 24 h, opt-out via <code>HUSKE_NO_UPDATE_CHECK=1</code>.</> },
    ],
  },
  {
    ver: "0.1.0", date: "2026-04",
    items: [
      { kind: "added", text: <>Initial always-on macOS terminal recorder with mic + system audio, local transcription, day-organized Markdown output, recovery for orphaned chunks, Rich TUI, and <code>huske doctor</code>.</> },
    ],
  },
];

const Releases = () => (
  <section id="releases">
    <div className="page">
      <SectionHead
        num="06"
        label="releases"
        lead={<>A short, public <span className="accent">changelog.</span></>}
        sub={<>Semantic versioning after 0.1.0. Patch notes are written in plain English and live in the repo. Install with <code>uv tool upgrade huske</code>, <code>pipx upgrade huske</code>, or <code>brew upgrade huske</code>.</>}
      />
      <div className="timeline">
        {RELEASES.map((r, i) => (
          <div key={r.ver} className={`release ${i === 0 ? "latest" : ""}`}>
            <div className="ver">
              <div className="num">
                <span className={`pip ${i > 0 ? "muted" : ""}`}/>
                <span>v{r.ver}</span>
                {r.tag && <span className="tag latest">{r.tag}</span>}
              </div>
              <div className="date">{r.date}</div>
            </div>
            <div className="body">
              <ul>
                {r.items.map((it, j) => (
                  <li key={j} className={it.kind}>
                    <span className="kind">{it.kind}</span>
                    <span>{it.text}</span>
                  </li>
                ))}
              </ul>
            </div>
          </div>
        ))}
      </div>
    </div>
  </section>
);

const Community = () => (
  <section id="community">
    <div className="page">
      <SectionHead
        num="07"
        label="community"
        lead={<>Open source. <span className="accent">Calmly maintained.</span></>}
        sub="huske is a small project. Contributions are welcome, issues are triaged in the open, and there's a clear PR template. Read the contributing guide before opening anything bigger than a typo fix."
      />
      <div className="community">
        <div className="card">
          <div className="top">
            <span>file an issue</span>
            <span>github</span>
          </div>
          <h4>Found a bug? Have a feature in mind?</h4>
          <p>Use the issue templates — bug, feature, or documentation. Include the exact <code>huske doctor</code> output (redacted) and the version. Triage labels are documented in the repo.</p>
          <a className="link" href="https://github.com/tiagomoraes/huske/issues" target="_blank" rel="noopener">open an issue <span className="arrow">→</span></a>
        </div>
        <div className="card">
          <div className="top">
            <span>contribute</span>
            <span>pull requests</span>
          </div>
          <h4>Send a patch.</h4>
          <p>Read <code>CONTRIBUTING.md</code> first. Run the checks listed in the PR template. Small PRs get reviewed quickly; larger ones benefit from an issue thread first to align on direction.</p>
          <a className="link" href="https://github.com/tiagomoraes/huske/blob/main/CONTRIBUTING.md" target="_blank" rel="noopener">contributing guide <span className="arrow">→</span></a>
        </div>
        <div className="card">
          <div className="top">
            <span>security</span>
            <span>privately</span>
          </div>
          <h4>Report a vulnerability.</h4>
          <p>Don't use the public issue tracker for security or privacy reports. The disclosure process and contact are in <code>SECURITY.md</code>. Acknowledged within 72 hours.</p>
          <a className="link" href="https://github.com/tiagomoraes/huske/blob/main/SECURITY.md" target="_blank" rel="noopener">security policy <span className="arrow">→</span></a>
        </div>
      </div>
    </div>
  </section>
);

const FAQ = () => (
  <section id="faq" className="faq-section">
    <div className="page page-narrow">
      <SectionHead
        num="08"
        label="faq"
        lead={<>The questions that actually <span className="accent">come up.</span></>}
      />
      <div className="faq">
        <details open>
          <summary>Does any audio leave my machine? <span className="chev">→</span></summary>
          <div className="answer">
            <p>No. Capture and transcription both run locally — <code>mlx-whisper</code> on Apple Silicon. The only network call huske makes is a once-a-day, opt-out version check against PyPI.</p>
            <p>If you want to keep it fully offline, <code>HUSKE_NO_UPDATE_CHECK=1</code> turns even that off. <code>huske doctor</code> validates local setup without uploading recordings.</p>
          </div>
        </details>
        <details>
          <summary>What permissions does it need on macOS? <span className="chev">→</span></summary>
          <div className="answer">
            <p>Microphone permission for your terminal, plus Audio Capture for the Core Audio tap on macOS 14.4+ or Screen Recording for the ScreenCaptureKit fallback. Screenshots also use Screen Recording. Run <code>huske doctor</code> first — it checks the effective backend and explains what's missing.</p>
          </div>
        </details>
        <details>
          <summary>What if it crashes mid-recording? <span className="chev">→</span></summary>
          <div className="answer">
            <p>Audio is written to <code>~/huske/audio/</code> as it's captured. After a crash or SIGKILL, run <code>huske recover</code> and orphaned chunks transcribe and emit Markdown without re-recording — they were already on disk.</p>
          </div>
        </details>
        <details>
          <summary>Can I use it with Claude Code or another agent? <span className="chev">→</span></summary>
          <div className="answer">
            <p>Yes — that's the design target. Files under <code>~/huske/transcripts/</code> are plain Markdown, dated, with frontmatter. Point your agent at the directory and ask. The root <code>README.md</code> is auto-generated to be a useful entry point.</p>
            <p>For semantic recall across months — "what did we decide about X this week" — install the <code>huske[mcp]</code> extra and run <code>huske mcp</code>. Your agent then searches by meaning over a local index instead of grepping filenames. See <a href="#search">search</a>.</p>
          </div>
        </details>
        <details>
          <summary>How does the semantic search / MCP server work? <span className="chev">→</span></summary>
          <div className="answer">
            <p><code>pip install 'huske[mcp]'</code> adds two subcommands. <code>huske index</code> embeds every transcript into a single local <code>sqlite-vec</code> file with a multilingual model running on the Apple GPU via MLX — the same stack as transcription, so nothing leaves the machine. Set <code>indexing_enabled = true</code> to keep it fresh automatically as you record.</p>
            <p><code>huske mcp</code> serves a loopback HTTP MCP endpoint (bearer token + Origin checks) exposing <code>search</code> and <code>fetch</code>. Claude Code, Cursor, Codex, and most local agents connect directly over loopback — no tunnel. Claude Desktop connects through a small <code>mcp-remote</code> bridge, and ChatGPT needs an HTTPS tunnel; the <a href="docs/#search">docs</a> have copy-paste config for each. Answering still happens in whichever chat model you connect, so result snippets reach that provider when it reads them — the indexing and the index itself stay on-device.</p>
          </div>
        </details>
        <details>
          <summary>What is transcript distillation? <span className="chev">→</span></summary>
          <div className="answer">
            <p>An opt-in second stage for search. Set <code>distill_enabled = true</code> and a <strong>local</strong> LLM condenses each transcript into compact, self-contained <em>statements</em> — the decisions, facts, and commitments, minus the filler. huske embeds those into a separate index and your agent searches them first, then <code>fetch</code> grounds every hit back in the verbatim transcript. Denser recall for "what did we decide about X," with the source always one hop away.</p>
            <p>It runs through a local daemon (Ollama), adds no Python dependency, and is off by default. The model is just a config string — the default <code>qwen3.5:0.8b</code> is the lightest tier and runs across the Apple-Silicon range; swap to <code>qwen3.5:0.8b-mlx</code> for the explicit MLX fast path, or any local tag. Fully on-device, and it degrades gracefully: if the daemon is down, recording and ordinary search carry on. Run <code>huske distill</code> to backfill your history. See the <a href="docs/#search">docs</a>.</p>
          </div>
        </details>
        <details>
          <summary>Is this only for Apple Silicon? <span className="chev">→</span></summary>
          <div className="answer">
            <p>Apple Silicon Mac is the supported target in {HUSKE_VERSION}. The transcription engine (<code>mlx-whisper</code>) runs on the M-series GPU via MLX, and system-audio capture uses macOS-only Core Audio / ScreenCaptureKit APIs.</p>
          </div>
        </details>
        <details>
          <summary>How do I configure chunk length, model, output path? <span className="chev">→</span></summary>
          <div className="answer">
            <p>Flags: <code>--chunk-minutes</code> (0.1–60), <code>--model</code> (default <code>base</code>; choices <code>tiny</code>, <code>base</code>, <code>small</code>, <code>medium</code>, <code>large-v3</code>), <code>--output-root</code>, <code>--audio-root</code>, and <code>--system-audio-backend</code> (<code>auto</code>, <code>tap</code>, <code>sck</code>, <code>off</code>). Or set them in <code>~/.config/huske/config.toml</code>.</p>
          </div>
        </details>
        <details>
          <summary>What about the optional screenshots flag? <span className="chev">→</span></summary>
          <div className="answer">
            <p><code>huske run --screenshots</code> captures a JPEG of every display every 60 seconds (<code>--screenshot-interval</code> configurable). Each is shrunk in place with macOS <code>sips</code> — downscaled to a ~1568 px long edge and re-encoded at JPEG quality 60 — so it stays small to store and ideal as LLM input (tune with <code>--screenshot-max-dimension</code> / <code>--screenshot-quality</code>). They land at <code>~/huske/screenshots/YYYY-MM-DD/&lt;session&gt;/HHMMSS_dN.jpg</code> for multimodal LLM use.</p>
            <p>Off by default. It captures <strong>everything</strong> on screen — passwords, banking tabs, DMs. Read the privacy section before enabling.</p>
          </div>
        </details>
      </div>
    </div>
  </section>
);

// Bridge CTA under the hero — surfaces the two opt-in "power" commands
// (run on login, recall over MCP) with one headline command each and a link
// into the full docs walkthrough. Not a numbered chapter; a quick-start strip.
const SETUP_CARDS = [
  {
    id: "autostart",
    ph: "run on login",
    cmd: "huske autostart install",
    desc: "Registers a launchd agent that records from every login and restarts itself on crash.",
    cta: "Autostart guide",
    href: "docs/#autostart",
    aria: "Run on login — read the autostart guide",
  },
  {
    id: "mcp",
    ph: "recall over mcp",
    cmd: "huske mcp",
    desc: "Serves on-device semantic search over your transcripts to Claude, Codex, Cursor, and more.",
    cta: "MCP setup",
    href: "docs/#search",
    aria: "Recall over MCP — read the MCP setup guide",
  },
];

const SetupStrip = () => (
  <section className="setup-strip" aria-label="Set up huske">
    <div className="page">
      <div className="strip-head"><span className="num">→</span><span>go further</span></div>
      <p className="strip-sub">Two opt-in commands take huske further: record from every login, and search your transcripts straight from your agent.</p>
      <div className="strip-grid">
        {SETUP_CARDS.map((c) => (
          <div className="strip-card" key={c.id}>
            <div className="sc-ph">{c.ph}</div>
            <div className="sc-cmd">
              <span className="sc-cmd-text"><span className="sp">$</span> {c.cmd}</span>
              <CopyButton text={c.cmd} className="copy ghost mini" withLabel={false} />
            </div>
            <p className="sc-desc">{c.desc}</p>
            <a className="sc-cta" href={c.href} aria-label={c.aria}>{c.cta} <span className="arrow">→</span></a>
          </div>
        ))}
      </div>
    </div>
  </section>
);

Object.assign(window, {
  SectionHead, Pillars, SetupStrip, HowItWorks, OutputPreview, SearchRecall, Privacy, Releases, Community, FAQ,
  // Shared so the docs page (components-docs.jsx) reuses the same MCP setup
  // data and per-agent configs — single source of truth.
  MCP_ENDPOINT, MCP_TOKEN_PATH, SETUP_STEPS, AGENTS, agentPrompt, PromptText,
});
