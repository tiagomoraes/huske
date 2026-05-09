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
            <div><strong>0</strong>cloud calls</div>
            <div><strong>0</strong>accounts</div>
            <div><strong>~/huske/</strong>only</div>
          </div>
        </div>

        <div className="pillar" style={{ display: "flex", flexDirection: "column" }}>
          <div className="ph">always · on</div>
          <h3>Continuous capture, no gaps.</h3>
          <p>
            Microphone via <code>sounddevice</code>. System audio via Apple's <code>ScreenCaptureKit</code>.
            Mixed in software, rotated into Markdown chunks every 15 minutes. SIGKILL the
            process and <code>huske recover</code> reclaims orphaned audio.
          </p>
          <div className="stat">
            <div><strong>15 min</strong>default chunks</div>
            <div><strong>6 s — 60 m</strong>configurable</div>
            <div><strong>16 kHz</strong>mono</div>
          </div>
        </div>

        <div className="pillar" style={{ display: "flex", flexDirection: "column" }}>
          <div className="ph">agent · ready</div>
          <h3>A directory your agent can read.</h3>
          <p>
            Plain Markdown, organized by date, full YAML frontmatter, day-level <code>README.md</code>.
            Point Claude Code, codex, or any LLM agent at <code>~/huske/transcripts/</code> and ask
            it about your day.
          </p>
          <div className="stat">
            <div><strong>md</strong>output format</div>
            <div><strong>YAML</strong>frontmatter</div>
            <div><strong>by date</strong>indexed</div>
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
            <p>Microphone via <code>sounddevice</code>. System audio via Apple's <code>ScreenCaptureKit</code>. Mixed in software at 16 kHz mono so chunk boundaries never lose a sample.</p>
          </div>
          <div className="meta">
            <div className="row"><span className="k">backend</span><span className="v">auto · tap · sck · off</span></div>
            <div className="row"><span className="k">permission</span><span className="v">screen recording</span></div>
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
            <div className="row"><span className="k">format</span><span className="v">wav · pcm_s16le · 16 kHz</span></div>
          </div>
        </div>

        <div className="stage">
          <div className="n"><span className="digit">03</span></div>
          <div>
            <h4>Transcribe locally.</h4>
            <p><code>mlx-whisper</code> on Apple Silicon, running on the M-series GPU via MLX. Per-chunk, on-device, no cloud. Per-source segments for mic and system audio so timestamps map back to wall-clock session time.</p>
          </div>
          <div className="meta">
            <div className="row"><span className="k">--model</span><span className="v">large-v3-turbo <span className="opt">(default)</span></span></div>
            <div className="row"><span className="k">engine</span><span className="v">mlx-whisper · apple gpu</span></div>
            <div className="row"><span className="k">latency</span><span className="v">~5–7× realtime · M2</span></div>
          </div>
        </div>

        <div className="stage">
          <div className="n"><span className="digit">04</span></div>
          <div>
            <h4>Write a Markdown ledger.</h4>
            <p>One Markdown file per chunk under <code>YYYY-MM-DD/HHMMSS_session_NNN.md</code>, with YAML frontmatter and per-source turns. A day-level <code>README.md</code> indexes the chunks. That's the agent's input — and the human's, too.</p>
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
            <div className="item"><span className="glyph">└─</span> README.md</div>
            <div style={{ height: 12 }}/>
            <div className="item root"><span className="glyph">▸</span> 2026-05-06/</div>
            <div className="item root"><span className="glyph">▸</span> 2026-05-05/</div>
            <div className="item"><span className="glyph">└─</span> README.md</div>
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
              <div><span className="key">session_id:</span>      <span className="str">"8a3f2c19-08d2-4f29-b71e-1c204aa5a1f0"</span></div>
              <div><span className="key">chunk:</span>            <span className="val">1</span></div>
              <div><span className="key">started_at:</span>       <span className="str">2026-05-07T09:15:00-03:00</span></div>
              <div><span className="key">duration_seconds:</span> <span className="val">900</span></div>
              <div><span className="key">model:</span>            <span className="val">mlx-whisper:large-v3-turbo</span></div>
              <div><span className="key">sources:</span>          <span className="val">[mic, system]</span></div>
              <div><span className="key">host:</span>             <span className="str">"macbook-pro · darwin 24.0.0"</span></div>
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

const Privacy = () => (
  <section id="privacy">
    <div className="page">
      <SectionHead
        num="04"
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
                <span className="desc">It captures every display every 10 s — passwords, banking tabs, DMs. Off by default. Opt in only after reading what you're recording.</span>
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
    ver: "0.4.0", date: "2026-05-09", tag: "latest",
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
        num="05"
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
        num="06"
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
        num="07"
        label="faq"
        lead={<>The questions that actually <span className="accent">come up.</span></>}
      />
      <div className="faq">
        <details open>
          <summary>Does any audio leave my machine? <span className="chev">→</span></summary>
          <div className="answer">
            <p>No. Capture and transcription both run locally — <code>mlx-whisper</code> on Apple Silicon. The only network call huske makes is a once-a-day, opt-out version check against PyPI.</p>
            <p>If you want to verify, <code>HUSKE_NO_UPDATE_CHECK=1</code> turns even that off, and <code>huske doctor</code> shows you which sockets are open.</p>
          </div>
        </details>
        <details>
          <summary>What permissions does it need on macOS? <span className="chev">→</span></summary>
          <div className="answer">
            <p>Microphone permission for your terminal, and Screen Recording permission for system-audio capture via <code>ScreenCaptureKit</code>. macOS prompts for both on first run. Run <code>huske doctor</code> first — it checks both and explains what's missing.</p>
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
            <p>Yes — that's the design target. Files under <code>~/huske/transcripts/</code> are plain Markdown, dated, with frontmatter. Point your agent at the directory and ask. The day-level <code>README.md</code> is auto-generated to be a useful entry point.</p>
            <p>Common pattern: a daily standup recap, a "what did we decide about X this week" query, a search-then-quote across the whole month.</p>
          </div>
        </details>
        <details>
          <summary>Is this only for Apple Silicon? <span className="chev">→</span></summary>
          <div className="answer">
            <p>Yes. The transcription engine (<code>mlx-whisper</code>) runs on the M-series GPU via MLX, and the system-audio capture path uses <code>ScreenCaptureKit</code>, which is macOS-only. Intel Macs and Linux/Windows are not supported in 0.3.</p>
          </div>
        </details>
        <details>
          <summary>How do I configure chunk length, model, output path? <span className="chev">→</span></summary>
          <div className="answer">
            <p>Flags: <code>--chunk-minutes</code> (0.1–60), <code>--model</code> (default <code>large-v3-turbo</code>), <code>--output-root</code> (default <code>~/huske/transcripts</code>), <code>--audio-root</code>. Or set them in <code>~/.config/huske/config.toml</code>.</p>
          </div>
        </details>
        <details>
          <summary>What about the optional screenshots flag? <span className="chev">→</span></summary>
          <div className="answer">
            <p><code>huske run --screenshots</code> captures a JPEG of every display every 10 seconds (<code>--screenshot-interval</code> configurable). They land at <code>~/huske/screenshots/YYYY-MM-DD/&lt;session&gt;/HHMMSS_dN.jpg</code> for multimodal LLM use.</p>
            <p>Off by default. It captures <strong>everything</strong> on screen — passwords, banking tabs, DMs. Read the privacy section before enabling.</p>
          </div>
        </details>
      </div>
    </div>
  </section>
);

Object.assign(window, {
  SectionHead, Pillars, HowItWorks, OutputPreview, Privacy, Releases, Community, FAQ,
});
