// huske website — Hero, install tabs, animated TUI live demo.

const INSTALL_TABS = [
  { id: "uv", label: "uv", badge: "recommended", cmd: "uv tool install huske", note: "fastest install · isolated tool environment" },
  { id: "pipx", label: "pipx", cmd: "pipx install huske", note: "if you already use pipx for cli tools" },
  { id: "brew", label: "brew", cmd: "brew install tiagomoraes/huske/huske", note: "homebrew tap · macOS apple silicon" },
];

const InstallTabs = () => {
  const [active, setActive] = React.useState("uv");
  const [copied, setCopied] = React.useState(false);
  const tab = INSTALL_TABS.find(t => t.id === active);
  const onCopy = () => {
    navigator.clipboard?.writeText(tab.cmd);
    setCopied(true);
    clearTimeout(window.__huskeCopyT);
    window.__huskeCopyT = setTimeout(() => setCopied(false), 1400);
  };
  return (
    <div className="install">
      <div className="tabs" role="tablist">
        {INSTALL_TABS.map(t => (
          <button
            key={t.id}
            role="tab"
            aria-selected={active === t.id}
            className={`tab ${active === t.id ? "active" : ""}`}
            onClick={() => { setActive(t.id); setCopied(false); }}
          >
            {t.label}
            {t.badge && <span className="badge">{t.badge}</span>}
          </button>
        ))}
      </div>
      <div className="body">
        <span className="prompt">$</span>
        <span className="cmd">{tab.cmd}</span>
        <button className={`copy-btn ${copied ? "copied" : ""}`} onClick={onCopy} aria-label="Copy install command">
          {copied ? <><CheckGlyph/> copied</> : <><CopyGlyph/> copy</>}
        </button>
      </div>
      <div className="foot">
        <strong>requires</strong> macOS 13+
        <span className="sep">·</span>
        <span>python 3.11 / 3.12 / 3.13 / 3.14</span>
        <span className="sep">·</span>
        <span>{tab.note}</span>
      </div>
    </div>
  );
};

// ---- TUI live demo: animated level meters + rolling clock + log

function useNow(intervalMs = 200) {
  const [t, setT] = React.useState(0);
  React.useEffect(() => {
    let raf, id;
    const tick = () => { setT(performance.now()); raf = requestAnimationFrame(tick); };
    raf = requestAnimationFrame(tick);
    return () => cancelAnimationFrame(raf);
  }, []);
  return t;
}

function meterChars(level, total = 24) {
  const filled = Math.max(0, Math.min(total, Math.round(level * total)));
  return { fill: "█".repeat(filled), empty: "░".repeat(total - filled) };
}

const Meter = ({ src, level, db }) => {
  const { fill, empty } = meterChars(level);
  return (
    <div className="meter">
      <span className="src">{src}</span>
      <span className="bar">
        <span className="fill">{fill}</span>
        <span className="empty">{empty}</span>
      </span>
      <span className="db">{db}</span>
    </div>
  );
};

const LiveDemo = () => {
  const t = useNow();
  // Two pseudo-noise channels driven by sin sums
  const seconds = t / 1000;
  const micRaw = 0.55 + 0.32 * Math.sin(seconds * 2.4) + 0.18 * Math.sin(seconds * 6.1 + 1.2) + 0.08 * Math.sin(seconds * 17.3);
  const sysRaw = 0.32 + 0.20 * Math.sin(seconds * 1.7 + 0.6) + 0.10 * Math.sin(seconds * 4.5) + 0.05 * Math.sin(seconds * 11.0);
  const mic = Math.max(0.05, Math.min(0.95, micRaw / 1.2));
  const sys = Math.max(0.02, Math.min(0.7, sysRaw));

  // db readout
  const dbMic = (-30 + mic * 24).toFixed(1);
  const dbSys = (-50 + sys * 30).toFixed(1);

  // chunk countdown — 02:46 / 15:00 ticking
  const startedAt = React.useRef(performance.now());
  const elapsed = (performance.now() - startedAt.current) / 1000 + 166; // start at 02:46
  const totalSec = 15 * 60;
  const cur = elapsed % totalSec;
  const fmt = (n) => `${String(Math.floor(n / 60)).padStart(2, "0")}:${String(Math.floor(n % 60)).padStart(2, "0")}`;

  return (
    <div className="tui" aria-label="huske terminal interface">
      <div className="chrome">
        <div className="dots"><span/><span/><span/></div>
        <span className="title">huske <span className="accent">run</span> — ~/code</span>
        <span className="live">live</span>
      </div>
      <div className="accent-stripe"/>
      <div className="body">
        <div className="head">
          <Mark size={16}/>
        <span className="name">huske 0.7.0</span>
          <span className="meta">
            session <code>4f9c2a31-08d2</code>
            <span className="arrow">→</span>
            <code>~/huske/transcripts/</code>
          </span>
        </div>

        <div className="grid">
          <span className="lbl">status</span>
          <span className="val rec"><span className="dot">●</span> RECORDING</span>

          <span className="lbl">chunk</span>
          <span className="val">003 · {fmt(cur)} <span style={{ color: "#75767A" }}>/ 15:00</span> <span style={{ color: "#5C6068", marginLeft: 12 }}>next rotation in {fmt(totalSec - cur)}</span></span>

          <span className="lbl">mic level</span>
          <Meter src="mic" level={mic} db={`${dbMic} dB`}/>

          <span className="lbl">sys level</span>
          <Meter src="tap" level={sys} db={`${dbSys} dB`}/>

          <span className="lbl">queue</span>
          <span className="val">2 chunks pending · transcribing <code>002</code></span>

          <span className="lbl">last saved</span>
          <span className="val saved"><span className="glyph">✓</span> 2026-05-08/091500_4f9c2a31_002.md</span>

          <span className="lbl">model</span>
          <span className="val">mlx-whisper:base · apple gpu</span>
        </div>

        <div className="log">
          <div><span className="ts">09:17:46</span> <span className="ok">✓</span> chunk 002 written · 14:58.4 · 1.2 MB · 38 segments</div>
          <div><span className="ts">09:17:46</span> rotated · chunk 003 started</div>
          <div><span className="ts">09:17:51</span> <span className="warn">⚠</span> sys audio quiet for 8s · check output device</div>
        </div>

        <div className="keys">
          <span><kbd>?</kbd> controls</span>
          <span><kbd>p</kbd> pause</span>
          <span><kbd>s</kbd> screenshots</span>
          <span><kbd>i</kbd> input</span>
          <span><kbd>q</kbd> quit</span>
          <span><kbd>^C</kbd> stop</span>
        </div>
      </div>
    </div>
  );
};

const Hero = () => (
  <section className="hero" id="top">
    <div className="page">
      <div className="hero-stack">
        <div className="eyebrow">
          <span className="dot"/>
          <span className="ver">v0.7.0</span>
          <span className="sep">·</span>
          <span>macOS · apple silicon</span>
          <span className="sep">·</span>
          <span>local-first</span>
        </div>
        <h1 className="wordmark">huske</h1>
        <div className="hero-cols">
          <div className="hero-copy">
            <p className="gloss"><em className="norwegian">huske</em> — Norwegian for "to remember"</p>
            <p className="lede">
              A terminal app that quietly captures your microphone and your computer's system audio,
              transcribes it on your machine with Whisper, and writes a day-organized
              Markdown ledger of everything that was said. Then point your agent at it.
            </p>
          </div>
          <div className="hero-install-col">
            <div id="install" className="hero-install"><InstallTabs/></div>
            <div className="hero-secondary">
              <a className="quiet-link" href="https://github.com/tiagomoraes/huske" target="_blank" rel="noopener"><GhGlyph size={13}/> read the source <span className="arrow">→</span></a>
              <span className="sep">·</span>
              <a className="quiet-link" href="#how">how it works <span className="arrow">→</span></a>
            </div>
          </div>
        </div>
      </div>
    </div>
    <div className="hero-demo-wrap">
      <div className="page">
        <div className="hero-demo-eyebrow">
          <span className="line"/>
          <span className="label">live · what <code>huske run</code> looks like</span>
          <span className="line"/>
        </div>
        <LiveDemo/>
      </div>
    </div>
  </section>
);

const InstallSection = () => (
  <section id="install" className="install-section">
    <div className="page">
      <div className="section-head">
        <div className="label">
          <span className="num" style={{ color: "var(--brand-amber)" }}>00</span>
          <span>install</span>
        </div>
        <div>
          <h2 className="lead">One command. <span style={{ color: "var(--brand-amber)" }}>Three flavors.</span></h2>
          <p className="sub">Pick your package manager. huske ships as a single Python tool — uv is recommended for its speed and isolated install. macOS 13+ on Apple Silicon, Python 3.11–3.14.</p>
        </div>
      </div>
      <div className="install-block"><InstallTabs/></div>
      <div className="install-aux">
        <div>
          <div className="aux-eyebrow">next steps</div>
          <ol className="aux-list">
            <li><span className="step">01</span><span><code>huske doctor</code><br/><span className="muted">validate your setup · prompts for macOS capture permission on first run</span></span></li>
            <li><span className="step">02</span><span><code>huske run</code><br/><span className="muted">start recording · ctrl+c to stop gracefully</span></span></li>
            <li><span className="step">03</span><span>point your agent at <code>~/huske/transcripts/</code><br/><span className="muted">ask it about your day</span></span></li>
          </ol>
        </div>
        <div>
          <div className="aux-eyebrow">upgrading</div>
          <p className="aux-p">huske checks pypi once a day on startup and prints the right command for your install method. Disable with <code>HUSKE_NO_UPDATE_CHECK=1</code>.</p>
          <div className="aux-codes">
            <div><span className="aux-prompt">$</span> uv tool upgrade huske</div>
            <div><span className="aux-prompt">$</span> pipx upgrade huske</div>
            <div><span className="aux-prompt">$</span> brew upgrade huske</div>
          </div>
        </div>
      </div>
    </div>
  </section>
);

Object.assign(window, { Hero, InstallSection, InstallTabs, LiveDemo, Meter, useNow });
