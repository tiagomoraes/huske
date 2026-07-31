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
            No accounts, no audio upload, no telemetry. Works offline. Cloud sync is an explicit
            opt-in and publishes only canonical transcript Markdown to the private Git repository
            you choose.
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
          <h3>A private ledger your agents can reach.</h3>
          <p>
            Plain Markdown, organized by date, full YAML frontmatter, root <code>README.md</code>.
            Read <code>~/huske/transcripts/</code> directly, or let Huske.app publish only
            those canonical files to private Git for the isolated <a href="#search">always-on service</a>.
          </p>
          <div className="stat">
            <div><strong>md</strong>output format</div>
            <div><strong>git</strong>durable handoff</div>
            <div><strong>mcp</strong>isolated read side</div>
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

const SearchRecall = () => (
  <section id="search">
    <div className="page">
      <SectionHead
        num="04"
        label="cloud · sync"
        lead={<>Your Mac writes. <span className="accent">Private Git carries.</span></>}
        sub={<>Huske.app publishes each finalized transcript to a private repository using your existing Git credentials. No ingest API, no token stored by huske, and no network work on the audio hot path.</>}
      />
      <div className="recall connect-grid">
        <div className="panel connect">
          <div className="cstep">
            <div className="cstep-head"><span className="cnum">01</span> create one private repository</div>
            <p className="rnote">
              Keep transcript data separate from the Huske source. Paste its SSH
              URL into the app's <strong>Cloud sync</strong> pane.
            </p>
          </div>
          <div className="cstep">
            <div className="cstep-head"><span className="cnum">02</span> sync now, then automate</div>
            <div className="setup">
              {[
                { cmd: "huske config set sync_remote git@github.com:you/huske-transcripts.git", note: "or use Huske.app" },
                { cmd: "huske config set sync_enabled true", note: "publish after every transcript" },
                { cmd: "huske sync", note: "initial/manual reconciliation" },
              ].map((s) => (
                <div className="sline" key={s.cmd}>
                  <code className="sc"><span className="sp">$</span> {s.cmd}</code>
                  <span className="snote"># {s.note}</span>
                  <CopyButton text={s.cmd} className="copy ghost mini" withLabel={false}/>
                </div>
              ))}
            </div>
          </div>
          <div className="cstep">
            <div className="cstep-head"><span className="cnum">03</span> retry without another database</div>
            <p className="rnote">
              Huske pulls and rebases before pushing. A commit left offline is
              the durable retry queue; a byte conflict at an established
              transcript path stops safely instead of overwriting either copy.
            </p>
          </div>
        </div>
        <div className="panel wiring">
          <div className="whead"><span className="dot"/> published surface</div>
          <div className="wmeta">
            <div className="row"><span className="k">included</span><span className="v">transcripts/YYYY-MM-DD/*.md</span></div>
            <div className="row"><span className="k">excluded</span><span className="v">audio · screenshots · logs</span></div>
            <div className="row"><span className="k">credentials</span><span className="v">ssh-agent · Git helper</span></div>
            <div className="row"><span className="k">checkout</span><span className="v">~/huske/sync</span></div>
            <div className="row"><span className="k">default</span><span className="v">off · explicit opt-in</span></div>
          </div>
          <div className="wnote">
            <div className="ln"><span className="tick">✓</span><span>Only canonical Markdown crosses the boundary.</span></div>
            <div className="ln"><span className="tick">✓</span><span>Git work runs in one coalescing background thread.</span></div>
            <div className="ln"><span className="warn">⚠</span><span>The private repository contains plaintext transcripts.</span></div>
          </div>
        </div>
      </div>
    </div>
  </section>
);

const Connect = () => (
  <section id="connect">
    <div className="page">
      <SectionHead
        num="05"
        label="isolated · mcp"
        lead={<>Your Mac sleeps. <span className="accent">Your context stays available.</span></>}
        sub={<>Run the separate <code>huske-mcp</code> package on a VPS. It owns no capture code: it pulls a read-only Git replica, incrementally indexes Markdown, and exposes authenticated Streamable HTTP MCP.</>}
      />
      <div className="prereq">
        <span className="pq-label">the boundary</span>
        <ul>
          <li>Huske.app only records and pushes canonical transcript files.</li>
          <li>The VPS deploy key is read-only; polling is the consistency path.</li>
          <li>The derived SQLite database lives outside Git and can be rebuilt.</li>
        </ul>
      </div>
      <div className="recall connect-grid">
        <div className="panel connect">
          <div className="cstep">
            <div className="cstep-head"><span className="cnum">01</span> tiny by default</div>
            <p className="rnote">
              One process, one poll thread, SQLite FTS5, an 8 MB page cache, and
              a 32 MB mmap ceiling. No resident model. This is the supported
              profile for 1 vCPU / 512 MB.
            </p>
          </div>
          <div className="cstep">
            <div className="cstep-head"><span className="cnum">02</span> webhook for latency, polling for truth</div>
            <p className="rnote">
              A signed GitHub push webhook only wakes the poller. Missed webhook,
              restart, or network outage: the next poll still converges.
            </p>
          </div>
          <div className="cstep">
            <div className="cstep-head"><span className="cnum">03</span> connect your agents</div>
            <p className="rnote">
              Use <code>https://huske.example.com/mcp</code> with an
              <code> Authorization: Bearer &lt;token&gt;</code> header. The
              service refuses to start without that token, even on loopback.
            </p>
          </div>
        </div>
        <div className="panel wiring">
          <div className="whead"><span className="dot"/> huske-mcp · vps</div>
          <div className="wmeta">
            <div className="row"><span className="k">sync</span><span className="v">git pull · fast-forward only</span></div>
            <div className="row"><span className="k">index</span><span className="v">SQLite WAL · incremental SHA-256</span></div>
            <div className="row"><span className="k">tools</span><span className="v">overview · recap · search · fetch · sync_status</span></div>
            <div className="row"><span className="k">auth</span><span className="v">mandatory bearer · Host validation</span></div>
            <div className="row"><span className="k">optional</span><span className="v">Model2Vec hybrid semantic profile</span></div>
          </div>
          <div className="wnote">
            <div className="ln"><span className="tick">✓</span><span>Answers while the recording Mac is offline.</span></div>
            <div className="ln"><span className="tick">✓</span><span>systemd caps the tiny service below a 512 MB VPS.</span></div>
            <div className="ln"><span className="warn">⚠</span><span>The VPS holds plaintext; encrypt and expose it deliberately.</span></div>
          </div>
        </div>
      </div>
      <p className="section-cta">
        <a href="docs/#connect">Open the full Git, VPS, webhook, and MCP guide →</a>
      </p>
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
          <h3>Audio and screenshots stay on the Mac. Transcript sync is explicit.</h3>
          <p>
            huske is local-first by design. The capture pipeline never opens an outbound socket
            for audio. Transcription happens on your Apple GPU. Filenames, frontmatter, logs —
            everything that touches a recording lives on your filesystem, under a path
            <strong> you</strong> chose.
          </p>
          <p>
            By default, the only network call is a once-a-day version check
            against PyPI. <code>HUSKE_NO_UPDATE_CHECK=1</code> turns it off.
            Enabling Cloud sync additionally pushes canonical plaintext
            transcripts to the private Git repository you chose.
          </p>
        </div>
        <div>
          <ul>
            <li>
              <span className="glyph">✓</span>
              <span>
                <strong>No audio upload.</strong>
                <span className="desc">Audio and screenshots never enter the sync repository. Transcript sync is off by default.</span>
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
            <p>No. Capture and transcription both run locally — <code>Parakeet</code> on Apple Silicon. Cloud sync, when explicitly enabled, publishes canonical transcript Markdown only; audio and screenshots never enter Git.</p>
            <p>With sync off, the only network call is the once-a-day version check. <code>HUSKE_NO_UPDATE_CHECK=1</code> turns that off too.</p>
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
            <p>For permanent indexed access, enable private Git sync and run the separate <code>huske-mcp</code> service on a VPS. It offers topic search, exact date/source/session filters, chronological recap, overview, and contextual fetch.</p>
          </div>
        </details>
        <details>
          <summary>How does the isolated MCP service work? <span className="chev">→</span></summary>
          <div className="answer">
            <p>Huske.app pushes immutable Markdown into a private repository. The independent Linux service pulls it read-only, incrementally updates a SQLite WAL index by transcript SHA-256, and serves Streamable HTTP MCP with mandatory bearer authentication.</p>
            <p>The default <code>tiny</code> profile is FTS5-only and supports a 1 vCPU / 512 MB VPS. The optional <code>semantic</code> profile adds Model2Vec dense retrieval and reciprocal-rank fusion when more RAM is available.</p>
          </div>
        </details>
        <details>
          <summary>Why can't I just ask <code>search</code> what happened yesterday? <span className="chev">→</span></summary>
          <div className="answer">
            <p>Because dates are exact filters, not relevance signals. <code>recap</code> returns the requested range chronologically; <code>overview</code> reports corpus coverage first. Use <code>search</code> for topics and <code>fetch</code> before quoting.</p>
          </div>
        </details>
        <details>
          <summary>Can I query my transcripts from my phone? <span className="chev">→</span></summary>
          <div className="answer">
            <p>Yes, when the phone's agent supports a remote MCP URL with a bearer header. Put <code>huske-mcp</code> behind TLS or a private overlay network and use its permanent endpoint.</p>
            <p>Clients that insist on browser OAuth and cannot attach a bearer header need an external identity-aware proxy. OAuth account management is intentionally not embedded in the tiny transcript service.</p>
          </div>
        </details>
        <details>
          <summary>Why not just sync the transcripts to Google Drive? <span className="chev">→</span></summary>
          <div className="answer">
            <p>Future storage providers can fit the same boundary, but Git is the first because it gives an auditable durable handoff, simple read-only deploy keys on the VPS, and deterministic conflict handling.</p>
            <p>For document-only destinations, <code>huske export</code> still produces one digest per day. That is separate from the canonical Git replica.</p>
          </div>
        </details>
        <details>
          <summary>What is transcript distillation? <span className="chev">→</span></summary>
          <div className="answer">
            <p>An optional local derivation. A local LLM condenses transcripts into inspectable <code>.statements.json</code> sidecars that <code>huske export</code> can use. Canonical Markdown remains the record.</p>
            <p>The sidecars are regenerable and are not pushed by Cloud sync; the isolated VPS service builds its own index from canonical transcripts. Run <code>huske distill</code> to backfill them.</p>
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
    kicker: "private cloud sync",
    title: "Publish the ledger",
    cost: "about 2 minutes",
    terminal: false,
    needs: ["an empty private GitHub repository", "Git or SSH credentials already working on this Mac"],
    steps: [
      <>Open <strong>Cloud sync</strong> in Huske.app.</>,
      <>Paste the private repository URL and press <strong>Sync now</strong>.</>,
      <>Enable automatic sync after the initial push succeeds.</>,
      <>Huske publishes only canonical transcript Markdown after each finalized chunk.</>,
    ],
    outcome: "A durable private Git replica that catches up automatically after outages.",
    cli: "huske sync",
  },
  {
    id: "connect-remote",
    num: "03",
    kicker: "advanced",
    title: "Serve it to agents",
    cost: "half an hour, and upkeep",
    terminal: true,
    needs: [
      "an always-on server you control (a VPS)",
      "TLS or a private overlay network",
      "a read-only deploy key for the transcript repository",
    ],
    steps: [
      <>Install the separate <code>huske-mcp</code> package on the VPS.</>,
      <>Configure its read-only repository, bearer token, and allowed proxy hostname.</>,
      <>Run the initial pull/index, then enable the supplied systemd unit.</>,
      <>Connect any agent that supports Streamable HTTP MCP plus a bearer header.</>,
    ],
    outcome: "An authenticated permanent MCP endpoint that works while the Mac sleeps.",
    href: "docs/#connect",
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
              // Same-site hrefs (docs/#…) stay in this tab; only off-site ones open a new one.
              <a
                className="tier-link"
                href={t.href}
                {...(/^https?:/.test(t.href) ? { target: "_blank", rel: "noopener" } : {})}
              >
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
});
