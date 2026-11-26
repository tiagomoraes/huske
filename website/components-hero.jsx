// huske website — Hero, engine install tabs, and the hero plate: a faithful
// replica of Huske.app's Transcripts pane next to a real screenshot of
// Huske for iPhone. Every conversation on the plate is made up.

// Stable asset name published by the release workflow from v0.11 on.
const APP_DOWNLOAD_URL = "https://github.com/tiagomoraes/huske/releases/latest/download/Huske.app.zip";

const INSTALL_TABS = [
  { id: "uv", label: "uv", cmd: "uv tool install huske", note: "An isolated tool environment. The fastest way." },
  { id: "pipx", label: "pipx", cmd: "pipx install huske", note: "If you already use pipx for command-line tools." },
  { id: "brew", label: "Homebrew", cmd: "brew install tiagomoraes/huske/huske", note: "From the huske tap." },
];

const InstallTabs = () => {
  const [active, setActive] = React.useState("uv");
  const tab = INSTALL_TABS.find((t) => t.id === active);
  return (
    <div className="install">
      <div className="install-tabs" role="tablist" aria-label="Install the engine with">
        {INSTALL_TABS.map((t) => (
          <button key={t.id} type="button" role="tab" aria-selected={active === t.id} onClick={() => setActive(t.id)}>
            {t.label}
          </button>
        ))}
      </div>
      <div className="install-line" role="tabpanel">
        <code><span className="prompt">$</span>{tab.cmd}</code>
        <CopyButton text={tab.cmd}/>
      </div>
      <div className="install-foot">
        {tab.note} Python {HUSKE_PYTHONS[0]}–{HUSKE_PYTHONS[HUSKE_PYTHONS.length - 1]}, macOS 13 or later.
      </div>
    </div>
  );
};

const DownloadGlyph = () => (
  <svg viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.7" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
    <path d="M8 2.5v7.5M4.8 7.2 8 10.4l3.2-3.2M2.8 13.2h10.4"/>
  </svg>
);

// ---- Small line icons, drawn to match the app's sidebar ----
const I = ({ d, children }) => (
  <svg viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.3" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
    {d && <path d={d}/>}
    {children}
  </svg>
);
const IconRecord = () => <I d="M2 7v2M4.5 5v6M7 3v10M9.5 5.5v5M12 4v8M14 7v2"/>;
const IconDoc = () => <I d="M4 1.8h5.2L12.5 5v9.2H4zM9 1.8V5h3.5M6 8h4.5M6 10.5h4.5"/>;
const IconPhone = () => <I><rect x="4.5" y="1.5" width="7" height="13" rx="1.6"/><path d="M7.2 3.4h1.6"/></I>;
const IconCloud = () => <I d="M4.6 12.5H4a3 3 0 0 1-.4-5.97A4.5 4.5 0 0 1 12.3 6 3.25 3.25 0 0 1 12 12.5h-.6M8 14V8.5M6 10.3 8 8.3l2 2"/>;
const IconDoctor = () => <I d="M3.5 2v4a3 3 0 0 0 6 0V2M6.5 9v1.5a3.2 3.2 0 0 0 6.4 0V9.4"><circle cx="12.9" cy="8" r="1.3"/></I>;
const IconSliders = () => <I d="M2 4h12M2 8h12M2 12h12"><circle cx="5" cy="4" r="1.4"/><circle cx="10.5" cy="8" r="1.4"/><circle cx="6.5" cy="12" r="1.4"/></I>;
const IconSearch = () => <I><circle cx="7" cy="7" r="4.3"/><path d="M10.2 10.2 13.8 13.8"/></I>;
const IconRefresh = () => <I d="M13 8a5 5 0 1 1-1.5-3.55M13 2.5v2.6h-2.6"/>;
const IconFolder = () => <I d="M1.8 4.2c0-.6.4-1 1-1h3.4l1.3 1.5h5.7c.6 0 1 .4 1 1v6.6c0 .6-.4 1-1 1H2.8c-.6 0-1-.4-1-1z"/>;
const IconClock = () => <I><circle cx="8" cy="8" r="6"/><path d="M8 4.8V8l2.2 1.4"/></I>;
const IconChip = () => <I><rect x="4" y="4" width="8" height="8" rx="1.2"/><path d="M6 1.8V4M10 1.8V4M6 12v2.2M10 12v2.2M1.8 6H4M1.8 10H4M12 6h2.2M12 10h2.2"/></I>;
const IconGlobe = () => <I><circle cx="8" cy="8" r="6"/><path d="M2 8h12M8 2c1.8 1.8 1.8 10.2 0 12M8 2c-1.8 1.8-1.8 10.2 0 12"/></I>;
const PauseGlyph = () => <svg viewBox="0 0 10 10" aria-hidden="true"><rect x="1.5" y="1" width="2.4" height="8" rx=".6" fill="currentColor"/><rect x="6.1" y="1" width="2.4" height="8" rx=".6" fill="currentColor"/></svg>;
const StopGlyph = () => <svg viewBox="0 0 10 10" aria-hidden="true"><rect x="1" y="1" width="8" height="8" rx="1.6" fill="var(--rec-on)"/></svg>;

function usePrefersReducedMotion() {
  const [reduced, setReduced] = React.useState(() => {
    try { return window.matchMedia("(prefers-reduced-motion: reduce)").matches; } catch (e) { return false; }
  });
  React.useEffect(() => {
    let mq;
    try { mq = window.matchMedia("(prefers-reduced-motion: reduce)"); } catch (e) { return undefined; }
    const on = () => setReduced(mq.matches);
    mq.addEventListener?.("change", on);
    return () => mq.removeEventListener?.("change", on);
  }, []);
  return reduced;
}

const fmtClock = (s) => `${String(Math.floor(s / 60)).padStart(2, "0")}:${String(Math.floor(s % 60)).padStart(2, "0")}`;

// The transport dock at the bottom of the app's sidebar: a session is
// recording while you read a transcript. The clock and the levels are live.
const Dock = () => {
  const reduced = usePrefersReducedMotion();
  const [t, setT] = React.useState(0);
  React.useEffect(() => {
    if (reduced) return undefined;
    const start = performance.now();
    const id = setInterval(() => setT((performance.now() - start) / 1000), 100);
    return () => clearInterval(id);
  }, [reduced]);
  const mic = reduced ? 0.62 : Math.max(0.08, Math.min(0.92, 0.5 + 0.28 * Math.sin(t * 2.3) + 0.14 * Math.sin(t * 6.7 + 1.1)));
  const sys = reduced ? 0.4 : Math.max(0.05, Math.min(0.8, 0.34 + 0.2 * Math.sin(t * 1.6 + 0.5) + 0.1 * Math.sin(t * 4.9)));
  return (
    <div className="dock" aria-hidden="true">
      <div className="dock-state"><span className="rec-dot"/>Recording<span className="t">{fmtClock(1521 + t)}</span></div>
      <div className="dock-meter"><span>mic</span><span className="track"><span className="fill" style={{ transform: `scaleX(${mic})` }}/></span></div>
      <div className="dock-meter"><span>sys</span><span className="track"><span className="fill" style={{ transform: `scaleX(${sys})` }}/></span></div>
      <div className="dock-btns"><span><PauseGlyph/>Pause</span><span><StopGlyph/>Stop</span></div>
    </div>
  );
};

const PLATE_LIST = [
  { day: "Thursday, November 19", rows: [
    { tm: "10:12", pv: "So the decision is to ship the mobile build on Friday and keep the retention review for next week.", mt: "14 min · you + remote", on: true },
    { tm: "09:30", pv: "Bom dia a todos, obrigado por entrarem na chamada. Hoje vamos revisar o roadmap.", mt: "15 min · you + remote" },
    { tm: "09:15", pv: "Okay, quick idea before I forget it: the inbox should sort by who is waiting on me.", mt: "5 min · iPhone" },
  ] },
  { day: "Wednesday, November 18", rows: [
    { tm: "16:30", pv: "Thanks for jumping on. Since this morning about thirty users were sent back to the login screen.", mt: "15 min · you + remote" },
    { tm: "11:20", pv: "The second part is pricing. We said three tiers, but I think two is enough.", mt: "10 min · you + remote" },
  ] },
];

const PLATE_LINES = [
  { tc: "10:12:10", who: "remote", tx: "So the decision is to ship the mobile build on Friday and keep the retention review for next week." },
  { tc: "10:12:24", who: "you", tx: "Agreed. I’ll move the Kubernetes upgrade to Monday so it doesn’t collide with the release." },
  { tc: "10:12:41", who: "remote", tx: "Can you post the OKR dashboard link in Slack after the call?" },
  { tc: "10:12:50", who: "you", tx: "Sure, right after. And I’ll ask Marta to review the pricing page." },
];

// Shared by the hero and the echo comparison.
const TLine = ({ l, i, className = "", children }) => (
  <div className={`tline ${className}`} style={i == null ? undefined : { "--i": i }}>
    <div className="mg">
      <span className="tc">{l.tc}</span>
      <span className={`who ${l.who === "remote" ? "remote" : ""}`}>{l.who}</span>
    </div>
    <div className="tx">{l.tx}{children}</div>
  </div>
);

const MacReplica = () => (
  <div className="mac" role="img" aria-label="Huske.app showing a transcript of a call: each line has its time and who said it, and the sidebar shows a recording in progress.">
    <aside className="mac-side">
      <div className="lights"><i/><i/><i/></div>
      <div className="mac-brand"><Mark size={17} lit/><span className="word">huske</span></div>
      <div className="mac-nav">
        <span><IconRecord/>Record</span>
        <span className="on"><IconDoc/>Transcripts</span>
        <span><IconPhone/>iPhone</span>
        <span><IconCloud/>Cloud sync</span>
        <span><IconDoctor/>Doctor</span>
        <span><IconSliders/>Configuration</span>
      </div>
      <Dock/>
    </aside>
    <div className="mac-list" aria-hidden="true">
      <div className="mac-list-head"><b>Transcripts</b><span><IconRefresh/><IconFolder/></span></div>
      <div className="mac-search"><IconSearch/>Search transcripts<kbd>⌘F</kbd></div>
      {PLATE_LIST.map((d) => (
        <React.Fragment key={d.day}>
          <div className="mac-day">{d.day}</div>
          {d.rows.map((r) => (
            <div className={`mac-row ${r.on ? "on" : ""}`} key={r.tm}>
              <span className="tm">{r.tm}</span>
              <div><div className="pv">{r.pv}</div><div className="mt">{r.mt}</div></div>
            </div>
          ))}
        </React.Fragment>
      ))}
    </div>
    <div className="mac-detail">
      <h4>10:12 – 10:26 (Thu 2026-11-19)</h4>
      <div className="mac-facts">
        <span><IconClock/>14m 0s</span>
        <span className="mono"><IconChip/>parakeet:tdt-0.6b-v3</span>
        <span><IconGlobe/>en</span>
      </div>
      <div className="mac-clean"><span>Cleaned up with Apple Intelligence</span><b>Show original</b></div>
      <div className="tlines">
        {PLATE_LINES.map((l, i) => <TLine key={l.tc} l={l} i={i}/>)}
      </div>
    </div>
  </div>
);

const Hero = () => (
  <section className="hero" id="top">
    <div className="page">
      <div className="hero-grid">
        <div>
          <p className="nameline"><span className="word">huske</span><span className="gloss">Norwegian for “to remember”</span></p>
          <h1>Record on your Mac and your iPhone. Your Mac writes down what was said.</h1>
          <p className="hero-lede">
            Huske records your microphone and the audio your Mac plays, takes your iPhone’s
            recordings over Wi‑Fi or straight from the phone, and transcribes all of it on the Mac.
            You keep plain Markdown files, and nothing goes to a server you didn’t choose.
          </p>
        </div>
        <div className="get" id="install">
          <a className="btn btn-primary" href={APP_DOWNLOAD_URL}><DownloadGlyph/>Download Huske.app</a>
          <p className="get-note">
            Version {HUSKE_VERSION}, signed and notarized by Apple, so it opens straight from the
            download. macOS 14 or later on Apple silicon. The app installs its engine on first run.
          </p>
          <p className="get-iphone">
            On your iPhone, get <a href={IOS_APP_STORE_URL}>Huske for iPhone</a>. It’s free on the App Store.
          </p>
          <p className="get-or">Or install the engine alone, for terminals, SSH and agents:</p>
          <InstallTabs/>
        </div>
      </div>
      <div className="plate">
        <MacReplica/>
        <figure className="plate-phone" style={{ margin: 0 }}>
          <img className="shot" src="assets/iphone/recording.webp" width="603" height="1311"
            alt="Huske for iPhone recording “Supplier call — follow-up” at 12:38, above a list of recordings on their way to the Mac."/>
        </figure>
        <p className="plate-cap">Huske.app’s Transcripts pane and Huske for iPhone. The conversations are made up.</p>
      </div>
    </div>
  </section>
);

Object.assign(window, { Hero, InstallTabs, TLine, MacReplica, usePrefersReducedMotion, APP_DOWNLOAD_URL, DownloadGlyph });
