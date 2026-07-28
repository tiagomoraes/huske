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
            Capture and transcription run on-device with <code>Parakeet</code> on Apple Silicon.
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
            on macOS 14.4+, with ScreenCaptureKit fallback on older macOS. Files split on
            real pauses in speech, not a fixed clock. SIGKILL the
            process and <code>huske recover</code> reclaims orphaned audio.
          </p>
          <div className="stat">
            <div><strong>60 s</strong>pause splits a file</div>
            <div><strong>30 min</strong>safety cap</div>
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
            <h4>Split on pauses, not a clock.</h4>
            <p>A file opens when speech starts and closes after a real pause (<code>--silence-split</code>, default 60 s) or at the <code>--chunk-minutes</code> cap. Quiet stretches aren't recorded, so there are no large near-empty files and a conversation isn't cut mid-sentence. WAV written to <code>~/huske/audio/</code>, queued for transcription.</p>
          </div>
          <div className="meta">
            <div className="row"><span className="k">--silence-split</span><span className="v">seconds <span className="opt">(60 default)</span></span></div>
            <div className="row"><span className="k">--chunk-minutes</span><span className="v">cap <span className="opt">(30 default)</span></span></div>
            <div className="row"><span className="k">format</span><span className="v">wav · pcm_s16le · 48 kHz</span></div>
          </div>
        </div>

        <div className="stage">
          <div className="n"><span className="digit">03</span></div>
          <div>
            <h4>Transcribe locally.</h4>
            <p><code>Parakeet</code> on Apple Silicon, running on the M-series GPU via MLX. Multilingual and silence-robust — it emits nothing on quiet input instead of hallucinating filler. Per-chunk, on-device, no cloud. Per-source segments for mic and system audio so timestamps map back to wall-clock session time.</p>
          </div>
          <div className="meta">
            <div className="row"><span className="k">--asr-engine</span><span className="v">parakeet <span className="opt">(default)</span></span></div>
            <div className="row"><span className="k">engine</span><span className="v">parakeet-mlx · apple gpu</span></div>
            <div className="row"><span className="k">languages</span><span className="v">~25 · auto-detected</span></div>
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

// A working replica of ~/huske/transcripts/: day folders open and close, and
// every file (plus the auto-generated README) carries its own frontmatter and
// body, per specs/001-huske-recorder/contracts/transcript-format.md. The days
// tell one story — a support call surfaces an auth race (05-06), the next
// morning pins it down and merges the fix (05-07; chunk 3 shows the
// graceful-stop case), and a system-audio-only talk sits two days back
// (05-05). Always-on recording means ~4 chunks an hour, so older days elide
// their tail behind an "earlier chunks" row.
const DAYS = [
  {
    date: "2026-05-07", dow: "Thu", session: "20260507T091500_8a3f2c19",
    files: [
      {
        name: "091500_8a3f2c19_001.md",
        seq: 1, start: "09:15:00", end: "09:30:00",
        actual: "900.0", incomplete: false,
        turns: [
          { ts: "09:15:02", src: "mic", body: "morning. let's review the auth bug that came up yesterday. looks like the token refresh is racing the cookie write on slow links." },
          { ts: "09:15:14", src: "sys", body: "sure, looking at the staging logs now. give me a sec." },
          { ts: "09:15:38", src: "mic", body: "the timing is interesting, every failure is within 80 milliseconds of the cookie write returning." },
          { ts: "09:15:54", src: "sys", body: "yeah, i see it. the middleware reads from the request before the response cookie has flushed. easy fix, we can pin the auth header in the same hop." },
          { ts: "09:16:21", src: "mic", body: "good. let me draft a patch and we can pair on it after standup." },
        ],
      },
      {
        name: "093000_8a3f2c19_002.md",
        seq: 2, start: "09:30:00", end: "09:45:00",
        actual: "900.0", incomplete: false,
        turns: [
          { ts: "09:30:41", src: "sys", body: "alright, standup. marina, you're up first." },
          { ts: "09:31:02", src: "sys", body: "shipping the export queue today. one flaky retry test left, i'll chase it down after this." },
          { ts: "09:31:48", src: "mic", body: "quick flag from me. the auth race from yesterday is reproducible and the patch is drafted. i want one more pair of eyes before it merges." },
          { ts: "09:32:10", src: "sys", body: "i can pair right after this. is it the same family as the session pinning fix from march?" },
          { ts: "09:32:24", src: "mic", body: "same family, same hop. i'll grab a room for quarter to ten." },
        ],
      },
      {
        name: "094500_8a3f2c19_003.md",
        seq: 3, start: "09:45:00", end: "09:57:22",
        actual: "742.3", incomplete: true,
        turns: [
          { ts: "09:45:12", src: "mic", body: "sharing my screen. the patch pins the auth header in the same hop, so the middleware never sees a stale cookie." },
          { ts: "09:46:05", src: "sys", body: "walk me through the failing case first. ok. refresh fires, the cookie write lands 80 milliseconds later, and the middleware already read the old token. yeah, pin it." },
          { ts: "09:48:33", src: "mic", body: "running the integration suite now." },
          { ts: "09:53:17", src: "sys", body: "green. forty-one passed, including the race repro." },
          { ts: "09:55:48", src: "mic", body: "merging. i'll post in the channel and close the incident." },
        ],
      },
    ],
  },
  {
    // Always-on since login: session start 08:45 + 31 chunks × 15 min = 16:30.
    date: "2026-05-06", dow: "Wed", session: "20260506T084500_c41d09e2",
    earlier: 31,
    files: [
      {
        name: "163000_c41d09e2_032.md",
        seq: 32, start: "16:30:00", end: "16:45:00",
        actual: "900.0", incomplete: false,
        turns: [
          { ts: "16:30:12", src: "sys", body: "thanks for jumping on. since this morning we've had maybe thirty users kicked back to the login screen mid-session." },
          { ts: "16:30:55", src: "mic", body: "no deploys on our side since friday. is it everyone, or is there a pattern?" },
          { ts: "16:31:30", src: "sys", body: "mostly people on hotel wifi or tethering. from the office we can't reproduce it at all." },
          { ts: "16:32:08", src: "mic", body: "slow links. interesting. can you pull two or three HAR files from affected sessions and send them over?" },
          { ts: "16:33:40", src: "mic", body: "got them. i'll dig into the token refresh path first thing tomorrow." },
        ],
      },
    ],
  },
  {
    // Session start 09:00 + 21 chunks × 15 min = 14:15.
    date: "2026-05-05", dow: "Tue", session: "20260505T090000_f0a7d513",
    earlier: 21,
    files: [
      {
        name: "141500_f0a7d513_022.md",
        seq: 22, start: "14:15:00", end: "14:30:00",
        actual: "900.0", incomplete: false,
        sources: "[system]", language: "en",
        turns: [
          { ts: "14:15:09", src: "sys", body: "so the question everyone asks about local-first is sync. and the answer is, you don't sync state, you sync facts." },
          { ts: "14:16:44", src: "sys", body: "every event is immutable. the view is a fold over the log. when two devices disagree, you don't merge objects, you merge histories." },
          { ts: "14:18:21", src: "sys", body: "we'll come back to compaction, because logs grow, and that's where most implementations fall over." },
        ],
      },
    ],
  },
];

// Mirrors the README that huske writes to <output_root>/README.md
// (transcript-format.md, "Auto-generated README" section).
const LEDGER_README = [
  "This directory is managed by huske. Each subdirectory is a local calendar date in YYYY-MM-DD form, holding all transcripts whose chunk start time falls on that date.",
  "Each .md file is a single transcribed audio chunk; filenames sort chronologically (HHMMSS_<sessionid8>_<seq>.md). The YAML frontmatter at the top of each file is the authoritative metadata.",
  "To query: an LLM agent can be pointed at this directory and asked to read files by date/time. No bespoke tooling is required.",
];

const frontmatterRows = (day, f) => [
  ["session_id", `"${day.session}"`, "str"],
  ["chunk_seq", String(f.seq), "val"],
  ["date", day.date, "str"],
  ["start_time", `${day.date}T${f.start}-03:00`, "str"],
  ["end_time", `${day.date}T${f.end}-03:00`, "str"],
  ["duration_seconds", "900", "val"],
  ["duration_actual_seconds", f.actual, "val"],
  ["gap_seconds", "0.0", "val"],
  ["model", "parakeet:tdt-0.6b-v3", "val"],
  ["audio_sources", f.sources || "[microphone, system]", "val"],
  ["language", f.language || "auto", "str"],
  ["incomplete", String(f.incomplete), "val"],
  ["huske_version", HUSKE_VERSION, "str"],
];

const OutputPreview = () => {
  const [selected, setSelected] = React.useState(DAYS[0].files[0].name);
  const [openDays, setOpenDays] = React.useState({ [DAYS[0].date]: true });
  const [copied, setCopied] = React.useState(false);
  const isReadme = selected === "README.md";
  const curDay = DAYS.find((d) => d.files.some((f) => f.name === selected)) || DAYS[0];
  const cur = curDay.files.find((f) => f.name === selected) || DAYS[0].files[0];
  const path = isReadme
    ? "~/huske/transcripts/README.md"
    : `~/huske/transcripts/${curDay.date}/${cur.name}`;
  const select = (name) => { setSelected(name); setCopied(false); };
  const toggleDay = (date) => setOpenDays((o) => ({ ...o, [date]: !o[date] }));
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
            <button
              type="button"
              className={`item ${isReadme ? "active" : ""}`}
              aria-pressed={isReadme}
              onClick={() => select("README.md")}
            >
              <span className="glyph">├─</span> README.md
            </button>
            {DAYS.map((d) => (
              <React.Fragment key={d.date}>
                <button
                  type="button"
                  className="item root"
                  aria-expanded={!!openDays[d.date]}
                  onClick={() => toggleDay(d.date)}
                >
                  <span className="glyph">{openDays[d.date] ? "▾" : "▸"}</span> {d.date}/
                </button>
                {openDays[d.date] && d.earlier && (
                  <div className="item static more" style={{ paddingLeft: 16 }}>
                    <span className="glyph">├─</span> … {d.earlier} earlier chunks
                  </div>
                )}
                {openDays[d.date] && d.files.map((f, i) => (
                  <button
                    key={f.name}
                    type="button"
                    className={`item ${f.name === selected ? "active" : ""}`}
                    aria-pressed={f.name === selected}
                    onClick={() => select(f.name)}
                    style={{ paddingLeft: 16 }}
                  >
                    <span className="glyph">{i === d.files.length - 1 ? "└─" : "├─"}</span>
                    {f.name}
                  </button>
                ))}
              </React.Fragment>
            ))}
            <div className="hint">click folders to open, files to preview</div>
          </div>
          <div className="doc">
            <div className="crumb">
              {isReadme ? (
                <span style={{ color: "var(--fg)" }}>README.md</span>
              ) : (
                <>
                  <span>{curDay.date}</span>
                  <span className="arrow">/</span>
                  <span style={{ color: "var(--fg)" }}>{cur.name}</span>
                </>
              )}
              <div className="actions">
                <button onClick={() => {
                  navigator.clipboard?.writeText(path);
                  setCopied(true);
                  setTimeout(() => setCopied(false), 1200);
                }}>{copied ? "✓ copied" : "copy path"}</button>
              </div>
            </div>
            {isReadme ? (
              <div className="doc-body readme" key="README.md">
                <h2># Huske transcripts</h2>
                {LEDGER_README.map((p, i) => <p key={i}>{p}</p>)}
              </div>
            ) : (
              <div className="doc-body" key={cur.name}>
                <div className="frontmatter">
                  <div><span className="delim">---</span></div>
                  {frontmatterRows(curDay, cur).map(([k, v, cls]) => (
                    <div className="row" key={k}>
                      <span className="key">{k}:</span>
                      <span className={cls}>{v}</span>
                    </div>
                  ))}
                  <div><span className="delim">---</span></div>
                </div>

                <h2># {cur.start.slice(0, 5)} – {cur.end.slice(0, 5)} ({curDay.dow} {curDay.date})</h2>

                {cur.turns.map((t) => (
                  <div className={`turn ${t.src}`} key={t.ts}>
                    <span className="ts">{t.ts}</span>
                    <span className="src">{t.src}</span>
                    <span className="body">{t.body}</span>
                  </div>
                ))}
              </div>
            )}
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
              <div className="row"><span className="k">tools</span><span className="v">search · fetch · recap · overview</span></div>
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
              <div className="ln"><span className="tick">✓</span><span>Phone, web, and hosted agents: <a href="#connect">connector mode</a> (opt-in).</span></div>
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

// Where each client runs decides which endpoint it can use — the whole setup
// story collapses to that one question, so the section leads with it.
const REACH = [
  {
    id: "local",
    where: "on this Mac",
    who: "Claude Code · Codex · Cursor · Claude Desktop",
    how: "loopback",
    detail: "static token · no TLS · nothing exposed",
    tone: "ok",
  },
  {
    id: "remote",
    where: "anywhere else",
    who: "Claude on iPhone · ChatGPT · a hosted agent",
    how: "connector",
    detail: "one HTTPS url · oauth · answers while the Mac sleeps",
    tone: "hot",
  },
];

const CONNECTOR_STEPS = [
  { cmd: "huske mcp set-password", note: "scrypt-hashed, 0600" },
  { cmd: "huske config set mcp_public_url https://huske.example.com/mcp", note: "as clients see it" },
  { cmd: "huske mcp", note: "still binds loopback" },
];

const Connect = () => (
  <section id="connect">
    <div className="page">
      <SectionHead
        num="05"
        label="connect · any device"
        lead={<>Your Mac sleeps. <span className="accent">Your context shouldn't.</span></>}
        sub={<>Everything so far runs on one Mac, and answers only while it's awake. Reaching your transcripts from a phone means the index has to live somewhere that never sleeps — so this section needs <strong>a server you control</strong>, and it is the only part of huske that does. If you don't have one, <a href="#start">step 2</a> already gets your agent searching; come back when you do.</>}
      />

      <div className="prereq">
        <span className="pq-label">before you start</span>
        <ul>
          <li>An always-on server you control (a VPS), with root.</li>
          <li>A domain name pointed at it, with TLS — Caddy does this for you.</li>
          <li>Willingness to keep a reverse-proxy allowlist correct. It is the
            security boundary; a catch-all exposes more than you intend.</li>
        </ul>
        <p className="pq-note">
          Roughly half an hour the first time, plus the upkeep any server needs.
          There is no version of this that is one click — huske would rather say so
          than waste your evening.
        </p>
      </div>

      <div className="recall connect-grid">
        <div className="panel connect">
          <div className="cstep">
            <div className="cstep-head"><span className="cnum">01</span> where does the model run?</div>
            <div className="reach">
              {REACH.map((r) => (
                <div className={`rrow ${r.tone}`} key={r.id}>
                  <div className="rwhere">{r.where}</div>
                  <div className="rbody">
                    <div className="rwho">{r.who}</div>
                    <div className="rhow"><span className="pill">{r.how}</span> {r.detail}</div>
                  </div>
                </div>
              ))}
            </div>
            <p className="rnote">
              One daemon serves both at once. Turning connector mode on changes nothing
              for a client already on loopback.
            </p>
          </div>

          <div className="cstep">
            <div className="cstep-head"><span className="cnum">02</span> turn on connector mode</div>
            <div className="setup">
              {CONNECTOR_STEPS.map((s) => (
                <div className="sline" key={s.cmd}>
                  <code className="sc"><span className="sp">$</span> {s.cmd}</code>
                  <span className="snote"># {s.note}</span>
                  <CopyButton text={s.cmd} className="copy ghost mini" withLabel={false}/>
                </div>
              ))}
            </div>
            <p className="rnote">
              Put a TLS reverse proxy in front, forwarding only <code>/mcp</code>,
              {" "}<code>/.well-known/oauth-*</code> and <code>/oauth/*</code> — an allowlist,
              never a catch-all. The daemon refuses to start without a passphrase, or over
              plain HTTP.
            </p>
          </div>

          <div className="cstep">
            <div className="cstep-head"><span className="cnum">03</span> add one url</div>
            <div className="reach">
              <div className="rrow">
                <div className="rwhere">Claude</div>
                <div className="rbody">
                  <div className="rwho">Settings → Connectors → Add custom connector</div>
                  <div className="rhow">iPhone, iPad, web, and desktop, all from the one url</div>
                </div>
              </div>
              <div className="rrow">
                <div className="rwhere">ChatGPT</div>
                <div className="rbody">
                  <div className="rwho">Settings → Connectors → Advanced → Developer mode</div>
                  <div className="rhow">then Create, and paste the same url</div>
                </div>
              </div>
            </div>
            <p className="rnote">
              Claude registers itself, huske asks for your passphrase once, and it stays
              connected across devices. Not sure what to paste? <code>huske connect</code>
              {" "}prints the exact wiring per client — and which paths work right now.
            </p>
          </div>
        </div>

        <div className="panel wiring">
          <div className="whead"><span className="dot"/> connector · oauth 2.1</div>
          <div className="wmeta">
            <div className="row"><span className="k">endpoint</span><span className="v">one https url · streamable http</span></div>
            <div className="row"><span className="k">auth</span><span className="v">oauth 2.1 · pkce s256 · dcr</span></div>
            <div className="row"><span className="k">scope</span><span className="v">transcripts:read · read-only</span></div>
            <div className="row"><span className="k">tools</span><span className="v">search · fetch · recap · overview</span></div>
            <div className="row"><span className="k">prompts</span><span className="v">catch_me_up · what_was_said_about</span></div>
            <div className="row"><span className="k">tenancy</span><span className="v">single user · no accounts</span></div>
          </div>
          <div className="auth">
            <div className="auth-head"><KeyGlyph/> one passphrase</div>
            <p className="auth-p">
              Stored as a scrypt hash at <code>~/.config/huske/mcp_password</code> (mode
              {" "}<code>0600</code>) — the plaintext is never written. Failed attempts back
              off globally, not per-IP, since an attacker rotating addresses would walk
              straight through a per-IP counter.
            </p>
            <p className="auth-p">
              Tokens are audience-bound to your exact endpoint, so one minted here can't be
              replayed elsewhere. Refresh tokens rotate; <code>oauth.db</code> holds hashes,
              not credentials. <code>huske mcp revoke --all</code> cuts every device off.
            </p>
          </div>
          <div className="wnote">
            <div className="ln"><span className="tick">✓</span><span>Answers while the recording Mac is asleep.</span></div>
            <div className="ln"><span className="tick">✓</span><span>Loopback clients keep the static token, unchanged.</span></div>
            <div className="ln"><span className="warn">⚠</span><span>The one setting that puts a read surface on the network. Opt in deliberately.</span></div>
          </div>
        </div>
      </div>

      <div className="two-stage">
        <div className="ts-head">
          <span className="ts-tag">no mcp?</span>
          <span>one file per day · huske export</span>
        </div>
        <div className="ts-grid">
          <div className="ts-main">
            <div className="ts-flow">
              <span className="node">transcripts</span>
              <span className="arr">→</span>
              <span className="node">statements</span>
              <span className="arr">→</span>
              <span className="node hot">one .md per day</span>
              <span className="arr">→</span>
              <span className="node">any folder-reading tool</span>
            </div>
            <p className="ts-p">
              A Claude Project, NotebookLM, an Obsidian vault, a shared folder — these read
              files and will never speak MCP, and huske natively writes many small files a
              day that such a tool can't rank. <code>huske export</code> collapses each day
              into one document, distilled key points first, verbatim conversation below.
              Incremental and atomic, so a sync client never uploads a half-written file.
            </p>
            <p className="ts-p">
              A complement, not a substitute: you trade semantic search, statement
              grounding, and date filters for whatever full-text search the destination
              has — and syncing it to someone else's cloud puts plaintext transcripts
              there. If the answer matters, use the connector.
            </p>
          </div>
          <div className="ts-meta">
            <div className="row"><span className="k">writes</span><span className="v">~/huske/export/YYYY-MM-DD.md</span></div>
            <div className="row"><span className="k">slim</span><span className="v">--statements-only</span></div>
            <div className="row"><span className="k">rerun</span><span className="v">skips unchanged days</span></div>
            <div className="row"><span className="k">default</span><span className="v">off · never auto-syncs</span></div>
          </div>
        </div>
      </div>
    </div>
  </section>
);

const Privacy = () => (
  <section id="privacy">
    <div className="page">
      <SectionHead
        num="06"
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
    ver: "0.12.0", date: "2026-07-28", tag: "latest",
    items: [
      { kind: "added", text: <><strong>huske starts Ollama for you.</strong> Only relevant if you have set <code>distill_backend = "ollama"</code> — the default backend runs the model itself and needs none of this. When distillation turns on, huske now starts the daemon if the <code>ollama</code> CLI is installed but idle, and pulls the configured model if it's missing, streaming progress into the activity feed, instead of only telling you the daemon is unreachable. It only ever runs the local <code>ollama</code> CLI and will never install Ollama for you. Set <code>distill_auto_manage = false</code> to go back to being told about the problem rather than having it fixed.</> },
      { kind: "fixed", text: <><strong>A latent crash in the built-in distillation backend.</strong> <code>mlx_lm.load()</code> returns two values or three depending on how it's called, and huske unpacked exactly two — correct today, but one argument away from breaking. Found by turning on the type checker in CI, which had been configured and never enforced.</> },
    ],
  },
  {
    ver: "0.11.1", date: "2026-07-27",
    items: [
      { kind: "fixed", text: <><strong>Autostart no longer pins the wrong microphone for the whole session.</strong> Starting at login with Bluetooth earbuds — which pair a few seconds after you sign in — meant huske fell back to the default mic and stayed there, because PortAudio only sees hot-plugged devices after re-initializing. With speech-gated chunking a fallback mic that hears nothing opens no chunk at all, so the session looked stuck on "waiting" while reporting that it was recording. huske now rescans every 30 s while on a fallback mic and switches to the configured device the moment it appears; it also restarts a mic whose stream died after sleep/wake, and keeps the warning visible until the right device is claimed.</> },
      { kind: "fixed", text: <><strong>Huske.app runs the newest engine it finds, not the first.</strong> The app drives the <code>huske</code> CLI, and a Mac collects copies of it — <code>uv tool</code> in <code>~/.local/bin</code>, Homebrew in <code>/opt/homebrew/bin</code> — that upgrade at different times. It used to take whichever came first by location, so a stale install could shadow a current one and the app would offer to upgrade the old engine while a new one sat beside it. It now picks the highest version installed, and Configuration shows which engine is in use plus any others it found.</> },
    ],
  },
  {
    ver: "0.11.0", date: "2026-07-27",
    items: [
      { kind: "added", text: <><strong>Huske.app — a native Mac app, now huske's UI.</strong> A SwiftUI app over the headless engine: start/stop/pause with live mic and system meters, chunk and queue state, a live activity feed, mid-session screenshot and distillation toggles, live microphone switching, a day-grouped transcript browser with full-text search, a Doctor pane, an engine-validated Configuration editor, a menu bar extra, and crash recovery. It attaches to a session started from a terminal or at login, and quitting while recording drains gracefully like Ctrl+C. Download <code>Huske.app.zip</code> above, or see <code>docs/macos-app.md</code>.</> },
      { kind: "added", text: <><strong>⌘K command palette.</strong> Every session and navigation action — start/stop/pause, screenshots, distillation, panes, doctor, recovery, folders, settings — behind one fuzzy-searchable, keyboard-first palette.</> },
      { kind: "added", text: <><strong>Record from the moment you log in, and install in one click.</strong> <em>Open Huske at login</em> and <em>Start recording when Huske opens</em> replace the LaunchAgent as the everyday autostart (the <code>huske autostart</code> LaunchAgent remains for menu-bar-only setups). Onboarding detects uv or Homebrew and installs — or upgrades — the engine with a single button, streaming the package manager's output into the window.</> },
      { kind: "added", text: <><strong>Built-in distillation — Ollama is no longer required.</strong> <code>distill_backend</code> now defaults to <code>"mlx"</code>: huske runs the distillation LLM itself in an isolated subprocess, downloading <code>Qwen3.5-0.8B-4bit</code> (~0.6 GB) on first use exactly like the Parakeet weights, and idle-unloading it like the transcribe worker. Nothing to install or keep running. <code>distill_backend = "ollama"</code> still delegates to a local daemon.</> },
      { kind: "added", text: <><strong>Transcripts that stay in the language you speak.</strong> Parakeet has no language input — it infers one per decode window — and on speech mixing a non-English language with English jargon that guess is unstable enough that a 0.2 s shift in a window boundary can flip two minutes of Portuguese into English. <code>language</code> now reaches the engine and drives a drift guard that re-decodes a window which collapsed into English. To <em>guarantee</em> a language, use the Whisper engine, whose decoder takes a real language token — <code>huske doctor</code> now says so plainly instead of letting the setting look enforced. Whisper also gained <code>large-v3-turbo</code>, faster <em>and</em> more accurate than <code>medium</code>.</> },
      { kind: "added", text: <><strong>A control protocol for external UIs.</strong> <code>huske run --control-socket PATH</code> serves the JSON-line protocol at an explicit socket. Snapshots carry peak levels, chunk and session timing, warnings, recent events, output paths, and the active input device; clients can switch the microphone and list devices over the socket. Plus <code>huske config show|set|unset</code> and <code>huske devices</code> for editing config and inspecting inputs from the command line.</> },
      { kind: "changed", text: <><strong>Silent chunks no longer become files.</strong> A chunk whose transcription produced no text is not written at all, instead of leaving a transcript whose whole body is <code>(no speech detected)</code>. <code>huske run</code> reports "no speech detected — nothing saved"; the app hides the placeholder files already on disk, so the transcript list stops filling with empty days.</> },
      { kind: "changed", text: <><strong>The transport follows you through the app, and the transcript list stays fast.</strong> Recording state and its controls live in the sidebar — status pill, elapsed time, live meters — so you can watch levels from any pane and stop from anywhere. Transcripts are newest-first throughout, paged as you scroll, and a rescan reuses cached per-file verdicts keyed by size and mtime, so a refresh reads only the chunk that just landed.</> },
      { kind: "removed", text: <><strong>The Rich terminal live panel.</strong> <code>huske run</code> is a headless engine now: plain progress lines on stdout, with Huske.app and the menu bar item as the interactive UIs. The <code>?</code>/<code>p</code>/<code>s</code>/<code>d</code>/<code>i</code>/<code>q</code> keyboard controls went with it; <code>--no-ui</code> remains an accepted no-op so existing launchers keep working.</> },
      { kind: "fixed", text: <>The elapsed clock freezes when you stop instead of counting through the drain and overstating the session. Clicking the Dock icon reopens a closed window. Hover works everywhere again — the pointer-cursor overlay was swallowing AppKit mouse tracking — and every control now has its designed hover, pressed, and disabled states.</> },
    ],
  },
  {
    ver: "0.10.0", date: "2026-06-29",
    items: [
      { kind: "added", text: <><strong>Toggle distillation live from the TUI and menu bar.</strong> Distillation no longer has to be chosen at launch — press <code>d</code> in the live UI's <code>?</code> controls overlay, or pick <strong>Toggle distillation</strong> from the macOS menu-bar dropdown, to turn it on or off for the running session. Turning it on first runs the same readiness check as <code>huske doctor</code> (LLM daemon reachable, model pulled) and warns with a fix-it hint if not. It's session-only, so <code>distill_enabled</code> still sets the default.</> },
    ],
  },
  {
    ver: "0.9.1", date: "2026-06-28",
    items: [
      { kind: "fixed", text: <><strong>Speaker-bleed alignment.</strong> Echo cancellation now lines up the mic and system channels correctly even when the saved system reference arrives late, or a chunk opens with only your voice before any system audio — cases the 0.9.0 estimator missed, which left the bleed in the transcript. The delay search now scans for an energetic window, allows a negative lag, and widens to 2 s.</> },
      { kind: "fixed", text: <><strong>Residual-bleed backstop.</strong> When the mic's copy of system audio is too garbled to match by text, an audio-coherence check now drops it if it is acoustically the same as the near-simultaneous system channel. Your own voice is never removed.</> },
    ],
  },
  {
    ver: "0.9.0", date: "2026-06-24",
    items: [
      { kind: "added", text: <><strong>Parakeet is the default transcription engine.</strong> NVIDIA Parakeet (<code>parakeet-tdt-0.6b-v3</code>) via <code>parakeet-mlx</code> on the Apple-Silicon GPU — multilingual with automatic language detection, and (being a transducer) it emits nothing on silence instead of hallucinating repeated filler the way Whisper does. The backend is pluggable (<code>asr_engine</code>); <code>--asr-engine whisper</code> keeps the legacy mlx-whisper path.</> },
      { kind: "added", text: <><strong>Speech-gated segmentation.</strong> Files now split on real pauses in speech, not a fixed clock: a chunk opens when speech starts and closes after a pause (<code>--silence-split</code>, default 60 s) or the <code>--chunk-minutes</code> cap. Quiet stretches produce no file, and a conversation is no longer cut mid-sentence. <code>--no-speech-gated</code> restores fixed-interval rotation.</> },
      { kind: "added", text: <><strong>Speaker-bleed removal</strong> for recording on speakers without headphones, so the system audio isn't transcribed twice: coherence-based echo <em>suppression</em> attenuates the bleed in the mic before transcription (<code>--echo-cancel</code>, self-gating — no effect with headphones, never touches your own voice), and a transcript-level dedup removes any residual mic copy of a system line, including partial fragments (<code>--echo-dedup</code>).</> },
      { kind: "changed", text: <><code>chunk_minutes</code> is now a maximum-length safety cap (default raised 15 → 30 min); speech-gated chunks report their recorded length and are no longer flagged <code>incomplete</code>. The <code>model</code> frontmatter value is now e.g. <code>parakeet:tdt-0.6b-v3</code>.</> },
      { kind: "changed", text: <>The auto-generated <code>~/huske/transcripts/README.md</code> is now a proper entry point for an LLM agent — speech-gated boundaries, the corrected frontmatter schema, and what the <code>mic</code>/<code>system</code> tags mean (you/the room vs. audio played by the computer).</> },
    ],
  },
  {
    ver: "0.8.2", date: "2026-06-10",
    items: [
      { kind: "changed", text: <><code>whisper_idle_unload</code> now defaults to <strong>on</strong>. The transcription worker drops the Whisper model after <code>whisper_idle_unload_seconds</code> of inactivity (default 120 s) and reloads it from the local cache on the next chunk, so huske idles at a few hundred MB instead of holding ~150 MB (<code>base</code>) to ~3 GB (<code>large-v3</code>) resident through the long gaps between chunks. Recording idles far more than it transcribes, and held RAM costs more than a network-free re-read. Pass <code>huske run --no-idle-unload</code> (or set <code>whisper_idle_unload = false</code>) to keep the model warm for back-to-back transcription.</> },
    ],
  },
  {
    ver: "0.8.1", date: "2026-06-10",
    items: [
      { kind: "fixed", text: <>Website: the home-page output ledger is now a functional, interactive file-tree preview instead of a static block.</> },
      { kind: "fixed", text: <>Website: the release history renders Markdown bold correctly instead of showing literal <code>**</code>.</> },
    ],
  },
  {
    ver: "0.8.0", date: "2026-06-07",
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
        num="07"
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
        num="08"
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
        num="09"
        label="faq"
        lead={<>The questions that actually <span className="accent">come up.</span></>}
      />
      <div className="faq">
        <details open>
          <summary>Does any audio leave my machine? <span className="chev">→</span></summary>
          <div className="answer">
            <p>No. Capture and transcription both run locally — <code>Parakeet</code> on Apple Silicon. The only network call huske makes is a once-a-day, opt-out version check against PyPI.</p>
            <p>If you want to keep it fully offline, <code>HUSKE_NO_UPDATE_CHECK=1</code> turns even that off. <code>huske doctor</code> validates local setup without uploading recordings.</p>
          </div>
        </details>
        <details>
          <summary>What permissions does it need on macOS? <span className="chev">→</span></summary>
          <div className="answer">
            <p>Microphone permission for Huske.app (or your terminal, when running the engine directly), plus Audio Capture for the Core Audio tap on macOS 14.4+ or Screen Recording for the ScreenCaptureKit fallback. Screenshots also use Screen Recording. The app's Doctor pane — or <code>huske doctor</code> — checks the effective backend and explains what's missing.</p>
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
            <p><code>huske mcp</code> serves a loopback HTTP MCP endpoint (bearer token + Origin checks) exposing four tools: <code>search</code> and <code>fetch</code> for topics, plus <code>recap</code> (a date range returned whole, in order) and <code>overview</code> (what the corpus actually covers). Claude Code, Cursor, Codex, and most local agents connect directly over loopback — no tunnel. Claude Desktop connects through a small <code>mcp-remote</code> bridge; the <a href="docs/#search">docs</a> have copy-paste config for each. Answering still happens in whichever chat model you connect, so result snippets reach that provider when it reads them — the indexing and the index itself stay on-device.</p>
          </div>
        </details>
        <details>
          <summary>Why can't I just ask <code>search</code> what happened yesterday? <span className="chev">→</span></summary>
          <div className="answer">
            <p>Because a date isn't a semantic neighborhood. Embedding the word "yesterday" and taking the nearest results returns whatever <em>sounds</em> like it, not what was recorded then — and an agent with no map of the corpus can't tell an empty index from an unlucky query.</p>
            <p>So <code>recap</code> answers date ranges directly: every statement in the range, chronological, grouped by day and session, with no embedding computed. <code>overview</code> reports the coverage first. That pair is the difference between "catch me up on today" working and returning three unrelated fragments. Two prompts — <code>catch_me_up</code> and <code>what_was_said_about</code> — ship with the server, so clients that surface them get one-tap actions.</p>
          </div>
        </details>
        <details>
          <summary>Can I query my transcripts from my phone? <span className="chev">→</span></summary>
          <div className="answer">
            <p>Yes, with <a href="#connect">connector mode</a>. Replicate transcripts to a server you control, then set <code>mcp_public_url</code> there and <code>huske mcp</code> additionally serves a small single-tenant <strong>OAuth 2.1</strong> authorization server. Add that one HTTPS url as a custom connector in Claude (iPhone, iPad, web, desktop) or ChatGPT, sign in with your passphrase once, and it answers even while the recording Mac is asleep.</p>
            <p>Why OAuth and not a token: neither client lets you attach a custom bearer header to a remote MCP server — both drive the MCP authorization spec instead. So "expose the token endpoint over TLS" isn't a lighter version of this; it's a version that doesn't connect. Off by default, and the daemon refuses to start without a passphrase or over plain HTTP. <code>huske connect</code> prints the exact steps per client.</p>
          </div>
        </details>
        <details>
          <summary>Why not just sync the transcripts to Google Drive? <span className="chev">→</span></summary>
          <div className="answer">
            <p>It's tempting — no infrastructure, and both Claude and ChatGPT already ship Drive connectors. Two things break. Retrieval quality: a Drive connector does keyword search over whole files, so you lose embedding search over passages, statement grounding, and every date/source filter — over a year of conversational speech across thousands of small files, that's a real downgrade. And it inverts the architecture: your full plaintext transcript history lives in someone else's index under their retention and scanning policy, where a server you run keeps custody with you.</p>
            <p>Where it <em>is</em> useful is a per-day digest rather than the raw corpus, for destinations that read files and will never speak MCP. <code>huske export</code> does exactly that — one <code>.md</code> per day, key points first — and the <a href="#connect">connect section</a> spells out the trade-off.</p>
          </div>
        </details>
        <details>
          <summary>What is transcript distillation? <span className="chev">→</span></summary>
          <div className="answer">
            <p>An opt-in second stage for search. Flip it on in the app (Configuration → Distillation, or mid-session from the Record pane / ⌘K palette) and a <strong>local</strong> LLM condenses each transcript into compact, self-contained <em>statements</em> — the decisions, facts, and commitments, minus the filler. huske embeds those into a separate index and your agent searches them first, then <code>fetch</code> grounds every hit back in the verbatim transcript. Denser recall for "what did we decide about X," with the source always one hop away.</p>
            <p>By default huske runs the model itself (built-in MLX backend — nothing to install; the default <code>Qwen3.5 0.8B</code> downloads on first use like the Parakeet weights), or point <code>distill_backend = "ollama"</code> at your own daemon. Fully on-device, off by default, and it degrades gracefully: if the model isn't ready, recording and ordinary search carry on. Run <code>huske distill</code> to backfill your history. See the <a href="docs/#search">docs</a>.</p>
          </div>
        </details>
        <details>
          <summary>Is this only for Apple Silicon? <span className="chev">→</span></summary>
          <div className="answer">
            <p>Apple Silicon Mac is the supported target in {HUSKE_VERSION}. The transcription engine (<code>Parakeet</code>) runs on the M-series GPU via MLX, and system-audio capture uses macOS-only Core Audio / ScreenCaptureKit APIs.</p>
          </div>
        </details>
        <details>
          <summary>How do I configure chunk length, model, output path? <span className="chev">→</span></summary>
          <div className="answer">
            <p>The app's <strong>Configuration</strong> pane edits everything with the engine's own validation — transcription model, chunking, audio backends, storage paths, distillation. The same settings live in <code>~/.config/huske/config.toml</code> and as flags (<code>--chunk-minutes</code>, <code>--output-root</code>, <code>--audio-root</code>, <code>--system-audio-backend</code> …) for scripted runs.</p>
          </div>
        </details>
        <details>
          <summary>Where did the terminal UI go? <span className="chev">→</span></summary>
          <div className="answer">
            <p>Retired in favor of the app — one UI, maintained properly. <code>huske run</code> still exists and records exactly the same; it's just headless now: plain progress lines, <kbd>Ctrl+C</kbd> to stop, a menu bar item for pause/screenshots/stop, and the same Markdown ledger. Terminal, SSH, and LaunchAgent workflows all keep working — you only lose the in-terminal dashboard, which now lives in Huske.app.</p>
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

// The onboarding IA. Setup used to be spread across the hero, a "go further"
// strip, the search section, and the connect section — four places, none of
// which said what a step costs or requires. So this is the single answer to
// "what do I actually do", as three tiers ordered by effort, each stating its
// prerequisites up front.
//
// The third tier deliberately leads with its requirement rather than its
// benefit: it needs a server the reader has to own, and discovering that after
// following two steps is the worst version of this page.
const TIERS = [
  {
    id: "record",
    num: "01",
    kicker: "everyone starts here",
    title: "Record and transcribe",
    cost: "about 2 minutes",
    terminal: false,
    needs: ["macOS 14+ Apple Silicon"],
    steps: [
      <>Download <strong>Huske.app</strong> and open it.</>,
      <>macOS blocks the first open because the build isn't notarized — go to <strong>System Settings → Privacy &amp; Security</strong> and click <strong>Open Anyway</strong>. Once, ever.</>,
      <>The app installs its engine for you, then asks for <strong>Microphone</strong> and audio-capture permission.</>,
      <>Press record. Transcripts land in <code>~/huske/transcripts/</code>.</>,
    ],
    outcome: "A day-organized Markdown ledger of everything said on your Mac.",
  },
  {
    id: "connect-local",
    num: "02",
    kicker: "the point of all this",
    title: "Let an LLM read it",
    cost: "about 2 minutes",
    terminal: false,
    needs: ["Claude Desktop or Claude Code on this Mac"],
    steps: [
      <>Open the <strong>Connect</strong> pane in Huske.app.</>,
      <>It lists what's left and puts a button on each row — build the index, start the search server, connect your client.</>,
      <>Press them top to bottom. huske edits the client config for you; it merges, so your other MCP servers survive.</>,
      <>Ask your agent something only a meeting would know.</>,
    ],
    outcome: "Semantic search, date recaps, and verbatim quotes — from your own words.",
    cli: "huske setup",
  },
  {
    id: "connect-remote",
    num: "03",
    kicker: "advanced",
    title: "Reach it from your phone",
    cost: "half an hour, and upkeep",
    terminal: true,
    needs: [
      "an always-on server you control (a VPS)",
      "a domain name with TLS",
      "comfort editing a reverse-proxy config",
    ],
    steps: [
      <>Replicate transcripts to your server so they're there when the Mac sleeps.</>,
      <>Set a connector passphrase and the public URL, then restart the read side.</>,
      <>Point a reverse proxy at the documented path allowlist — <em>only</em> those paths.</>,
      <>Add the one URL as a custom connector in Claude or ChatGPT.</>,
    ],
    outcome: "Claude on your iPhone answers from your transcripts while the Mac is asleep.",
    href: "https://github.com/tiagomoraes/huske/blob/main/docs/integrations.md",
    hrefLabel: "Full guide",
  },
];

const GetStarted = () => (
  <section id="start">
    <div className="page">
      <SectionHead
        num="→"
        label="get started"
        lead={<>Three steps. <span className="accent">Two need no terminal.</span></>}
        sub={<>Each one below says what it costs and what it needs before you begin. Stop after step 1 and huske is still a complete transcript ledger; stop after step 2 and your agent can search it. Step 3 is the only one that needs infrastructure, and it says so.</>}
      />
      <div className="tiers">
        {TIERS.map((t) => (
          <div className={`tier ${t.terminal ? "adv" : ""}`} key={t.id}>
            <div className="tier-head">
              <span className="tier-num">{t.num}</span>
              <div className="tier-titles">
                <div className="tier-kicker">{t.kicker}</div>
                <h3>{t.title}</h3>
              </div>
            </div>
            <div className="tier-meta">
              <span className="tm">{t.cost}</span>
              <span className={`tm ${t.terminal ? "warn" : "good"}`}>
                {t.terminal ? "terminal required" : "no terminal"}
              </span>
            </div>
            <div className="tier-needs">
              <span className="tn-label">you need</span>
              <ul>
                {t.needs.map((n, i) => <li key={i}>{n}</li>)}
              </ul>
            </div>
            <ol className="tier-steps">
              {t.steps.map((step, i) => <li key={i}>{step}</li>)}
            </ol>
            <p className="tier-outcome">{t.outcome}</p>
            {t.cli && (
              <p className="tier-cli">
                Prefer a terminal? <code>{t.cli}</code> does the same thing and tells you
                which step you're on.
              </p>
            )}
            {t.href && (
              <a className="tier-link" href={t.href} target="_blank" rel="noopener">
                {t.hrefLabel} <span className="arrow">→</span>
              </a>
            )}
          </div>
        ))}
      </div>
    </div>
  </section>
);

Object.assign(window, {
  SectionHead, Pillars, GetStarted, HowItWorks, OutputPreview, SearchRecall, Connect, Privacy, Releases, Community, FAQ,
  // Shared so the docs page (components-docs.jsx) reuses the same MCP setup
  // data and per-agent configs — single source of truth.
  MCP_ENDPOINT, MCP_TOKEN_PATH, SETUP_STEPS, AGENTS, agentPrompt, PromptText,
});
