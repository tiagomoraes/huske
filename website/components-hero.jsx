// huske website — Hero, install tabs, animated Huske.app live demo.

// Stable asset name published by the release workflow from v0.11 on.
const APP_DOWNLOAD_URL = "https://github.com/tiagomoraes/huske/releases/latest/download/Huske.app.zip";

const INSTALL_TABS = [
  { id: "uv", label: "uv", badge: "recommended", cmd: "uv tool install huske", note: "fastest install · isolated tool environment" },
  { id: "pipx", label: "pipx", cmd: "pipx install huske", note: "if you already use pipx for cli tools" },
  { id: "brew", label: "brew", cmd: "brew install tiagomoraes/huske/huske", note: "homebrew tap · macOS apple silicon" },
];

const InstallTabs = ({ withApp = true }) => {
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
      {withApp && (
        <>
          <a className="app-cta" href={APP_DOWNLOAD_URL}>
            <span className="app-cta-main"><DownloadGlyph/> Download Huske.app</span>
            <span className="app-cta-note">installs the engine for you on first run</span>
          </a>
          <div className="install-or"><span className="line"/><span className="or">or the engine alone — for agents &amp; SSH</span><span className="line"/></div>
        </>
      )}
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
        <strong>requires</strong> macOS 14+ (app) · 13+ (engine)
        <span className="sep">·</span>
        <span>python {HUSKE_PYTHONS.join(" / ")}</span>
        <span className="sep">·</span>
        <span>{tab.note}</span>
      </div>
      {withApp && (
        <div className="foot gatekeeper">
          unsigned build — first launch is right-click → Open
        </div>
      )}
    </div>
  );
};

const DownloadGlyph = ({ size = 13 }) => (
  <svg width={size} height={size} viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
    <path d="M8 2.5v7.5M4.8 7.2 8 10.4l3.2-3.2M2.8 13.2h10.4"/>
  </svg>
);

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

// The hero demo is a faithful mockup of Huske.app's Record pane (dark
// theme = the same terminal-ink tokens), with the meters and clocks animated.
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

  // clocks — session counts up from 25:21, chunk from 02:46
  const startedAt = React.useRef(performance.now());
  const elapsed = (performance.now() - startedAt.current) / 1000;
  const fmt = (n) => `${String(Math.floor(n / 60)).padStart(2, "0")}:${String(Math.floor(n % 60)).padStart(2, "0")}`;
  const session = fmt(1521 + elapsed);
  const chunk = fmt(166 + elapsed);

  return (
    <div className="tui appdemo" aria-label="Huske app interface">
      <div className="chrome">
        <div className="dots"><span/><span/><span/></div>
        <span className="title">Huske<span className="accent">.app</span></span>
        <span className="live">live</span>
      </div>
      <div className="accent-stripe"/>
      <div className="app-body">
        <aside className="app-side" aria-hidden="true">
          <div className="app-brand"><Mark size={15}/><span className="app-word">huske</span></div>
          <div className="app-nav">
            <span className="item active">Record</span>
            <span className="item">Transcripts</span>
            <span className="item">Doctor</span>
            <span className="item">Configuration</span>
          </div>
          <div className="app-badge">
            <span><span className="dot">●</span> RECORDING</span>
            <span className="sub">chunk 003 · queue 1</span>
          </div>
        </aside>
        <div className="app-main">
          <div className="app-topbar">
            <span className="pill rec"><span className="dot">●</span> RECORDING</span>
            <span className="clock">{session}</span>
            <span className="btn ghost">❚❚ Pause</span>
            <span className="btn stop">■ Stop</span>
          </div>

          <div className="app-card">
            <div className="card-label">LEVELS</div>
            <div className="app-meters">
              <Meter src="microphone" level={mic} db={`${dbMic} dB`}/>
              <Meter src="system" level={sys} db={`${dbSys} dB`}/>
            </div>
          </div>

          <div className="app-cols">
            <div className="app-card">
              <div className="card-label">CURRENT CHUNK</div>
              <div className="chunk-line"><span className="chunk-num">003</span><span className="chunk-timer">{chunk}</span></div>
              <div className="chunk-sub">1 transcription pending</div>
              <div className="chunk-saved"><span className="glyph">✓</span> 091500_4f9c2a31_002.md</div>
            </div>
            <div className="app-card">
              <div className="card-label">ACTIVITY</div>
              <div className="log app-log">
                <div><span className="ts">09:17:46</span> <span className="ok">✓</span> chunk 002 → 091500_4f9c2a31_002.md</div>
                <div><span className="ts">09:17:46</span> rotated · chunk 003 started</div>
                <div><span className="ts">09:17:51</span> <span className="warn">⚠</span> sys audio quiet for 8s</div>
              </div>
            </div>
          </div>

          <div className="app-foot">
            <span><kbd>⌘K</kbd> command palette</span>
            <span><kbd>⌘R</kbd> record</span>
            <span><kbd>⌘F</kbd> search transcripts</span>
            <span className="grow"/>
            <span>parakeet-tdt-0.6b-v3 · apple gpu</span>
          </div>
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
          <span className="ver">v{HUSKE_VERSION}</span>
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
              A native Mac app that quietly captures your microphone and your computer's system audio,
              transcribes it on your machine with Parakeet, and writes a day-organized
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
          <span className="label">live · what Huske.app looks like</span>
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
          <h2 className="lead">Download the app. <span style={{ color: "var(--brand-amber)" }}>It installs the engine.</span></h2>
          <p className="sub">Huske.app is the UI; the huske engine is a single Python tool it installs for you on first run (or install it yourself — it's the same one agents script against). App on macOS 14+, engine on 13+, Apple Silicon, Python {HUSKE_PYTHONS[0]}–{HUSKE_PYTHONS[HUSKE_PYTHONS.length - 1]}.</p>
        </div>
      </div>
      <div className="install-block"><InstallTabs/></div>
      <div className="install-aux">
        <div>
          <div className="aux-eyebrow">next steps</div>
          <ol className="aux-list">
            <li><span className="step">01</span><span>open <code>Huske.app</code><br/><span className="muted">one click installs the engine · Doctor validates mic + capture permissions</span></span></li>
            <li><span className="step">02</span><span>hit <strong>Start Recording</strong> (⌘R)<br/><span className="muted">or flip on “open at login” + “start recording when Huske opens”</span></span></li>
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
