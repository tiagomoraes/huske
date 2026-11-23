// huske website — Mark, Nav, theme controller, Footer, shared icons.

// The logo mark. `lit` paints the first bar amber, the way the app icon does.
const Mark = ({ size = 22, lit = false }) => (
  <svg viewBox="0 0 64 64" width={size} height={size} aria-hidden="true">
    <rect className={lit ? "lit" : undefined} x="14" y="10" width="6" height="44" rx="1.2" fill="currentColor"/>
    <rect x="24" y="24" width="26" height="5" rx="1.2" fill="currentColor"/>
    <rect x="24" y="34" width="20" height="5" rx="1.2" fill="currentColor"/>
    <rect x="24" y="44" width="14" height="5" rx="1.2" fill="currentColor"/>
  </svg>
);

const SunIcon = () => (
  <svg viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.4" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
    <circle cx="8" cy="8" r="3"/>
    <path d="M8 1.5v1.5M8 13v1.5M14.5 8H13M3 8H1.5M12.6 3.4l-1.05 1.05M4.45 11.55L3.4 12.6M12.6 12.6l-1.05-1.05M4.45 4.45L3.4 3.4"/>
  </svg>
);

const MoonIcon = () => (
  <svg viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.4" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
    <path d="M13.5 9.5A6 6 0 1 1 6.5 2.5 5 5 0 0 0 13.5 9.5z"/>
  </svg>
);

const MenuIcon = () => (
  <svg viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" aria-hidden="true">
    <path d="M2.5 4.5h11M2.5 8h11M2.5 11.5h11"/>
  </svg>
);

const GhGlyph = ({ size = 14 }) => (
  <svg viewBox="0 0 16 16" width={size} height={size} fill="currentColor" aria-hidden="true">
    <path d="M8 0C3.58 0 0 3.58 0 8a8 8 0 0 0 5.47 7.59c.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2 .37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27.68 0 1.36.09 2 .27 1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.01 8.01 0 0 0 16 8c0-4.42-3.58-8-8-8z"/>
  </svg>
);

const StarGlyph = ({ size = 12 }) => (
  <svg viewBox="0 0 16 16" width={size} height={size} fill="currentColor" aria-hidden="true">
    <path d="M8 1l2.16 4.38 4.84.7-3.5 3.41.83 4.82L8 12.05l-4.33 2.27.83-4.83L1 6.08l4.84-.7L8 1z"/>
  </svg>
);

const CopyGlyph = () => (
  <svg viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.4" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
    <rect x="5" y="5" width="9" height="9" rx="1.5"/>
    <path d="M2 11V3a1 1 0 0 1 1-1h7"/>
  </svg>
);

const CheckGlyph = () => (
  <svg viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
    <path d="M3 8.5l3 3 7-7"/>
  </svg>
);

const Chev = () => <span className="chev" aria-hidden="true">›</span>;

// ---- Reusable copy-to-clipboard button ----
const CopyButton = ({ text, label = "Copy", mini = false }) => {
  const [copied, setCopied] = React.useState(false);
  return (
    <button
      type="button"
      className={`copy ${mini ? "mini" : ""} ${copied ? "copied" : ""}`}
      onClick={() => {
        navigator.clipboard?.writeText(text);
        setCopied(true);
        setTimeout(() => setCopied(false), 1400);
      }}
      aria-label={copied ? "Copied" : `${label}: ${text}`}
    >
      {copied ? <CheckGlyph/> : <CopyGlyph/>}
      {!mini && <span>{copied ? "Copied" : label}</span>}
    </button>
  );
};

// A terminal block: one row per command, each with its own copy button.
const Term = ({ lines }) => (
  <div className="term">
    {lines.map((l) => (
      <div className="term-line" key={l.cmd}>
        <code><span className="prompt">$</span>{l.cmd}</code>
        {l.note && <span className="note">{l.note}</span>}
        <CopyButton text={l.cmd} mini/>
      </div>
    ))}
  </div>
);

// ---- Live GitHub star count (cached, fails quiet) ----
const STARS_CACHE_KEY = "huske-stars";
const STARS_TTL_MS = 5 * 60 * 1000; // refetch at most every 5 min per visitor

function formatStars(n) {
  if (n >= 1000) {
    const k = n / 1000;
    return `${k >= 10 ? Math.round(k) : k.toFixed(1).replace(/\.0$/, "")}k`;
  }
  return String(n);
}

function useGitHubStars(repo = "tiagomoraes/huske") {
  const [stars, setStars] = React.useState(() => {
    try {
      const raw = localStorage.getItem(STARS_CACHE_KEY);
      if (!raw) return null;
      const { n } = JSON.parse(raw);
      return typeof n === "number" ? n : null;
    } catch (e) { return null; }
  });
  React.useEffect(() => {
    let fresh = false;
    try {
      const raw = localStorage.getItem(STARS_CACHE_KEY);
      if (raw) {
        const { t } = JSON.parse(raw);
        fresh = typeof t === "number" && Date.now() - t < STARS_TTL_MS;
      }
    } catch (e) {}
    if (fresh) return;
    let alive = true;
    fetch(`https://api.github.com/repos/${repo}`)
      .then((r) => (r.ok ? r.json() : Promise.reject(r.status)))
      .then((d) => {
        if (!alive || typeof d.stargazers_count !== "number") return;
        setStars(d.stargazers_count);
        try {
          localStorage.setItem(STARS_CACHE_KEY, JSON.stringify({ n: d.stargazers_count, t: Date.now() }));
        } catch (e) {}
      })
      .catch(() => {});
    return () => { alive = false; };
  }, [repo]);
  return stars;
}

// ---- Theme ----
// An explicit choice (the toggle) is remembered; until then the site follows
// the system appearance, like the Mac and iPhone apps do.
function systemTheme() {
  try {
    return window.matchMedia("(prefers-color-scheme: light)").matches ? "light" : "dark";
  } catch (e) { return "dark"; }
}

function useTheme() {
  const [chosen, setChosen] = React.useState(() => {
    try { return localStorage.getItem("huske-theme"); } catch (e) { return null; }
  });
  const [system, setSystem] = React.useState(systemTheme);
  React.useEffect(() => {
    let mq;
    try { mq = window.matchMedia("(prefers-color-scheme: light)"); } catch (e) { return undefined; }
    const onChange = () => setSystem(systemTheme());
    mq.addEventListener?.("change", onChange);
    return () => mq.removeEventListener?.("change", onChange);
  }, []);
  const theme = chosen || system;
  React.useEffect(() => {
    document.documentElement.setAttribute("data-theme", theme);
  }, [theme]);
  const setTheme = (t) => {
    setChosen(t);
    try { localStorage.setItem("huske-theme", t); } catch (e) {}
  };
  return [theme, setTheme];
}

const ThemeToggle = ({ theme, setTheme }) => (
  <button
    type="button"
    className="icon-btn"
    onClick={() => setTheme(theme === "dark" ? "light" : "dark")}
    aria-label={theme === "dark" ? "Use the light theme" : "Use the dark theme"}
    title={theme === "dark" ? "Light theme" : "Dark theme"}
  >
    {theme === "dark" ? <SunIcon/> : <MoonIcon/>}
  </button>
);

// `base` prefixes the in-page anchors so the shared Nav works on the docs page
// (docs/index.html): on the landing page base="" → "#iphone"; on the docs page
// base="../" → "../#iphone". `docsHref` is the link to the docs page itself:
// "docs/" from the landing root, "./" when already on the docs page.
const NAV_LINKS = [
  { id: "iphone", label: "iPhone" },
  { id: "how", label: "How it works" },
  { id: "quality", label: "Transcripts" },
  { id: "sync", label: "Sync" },
  { id: "privacy", label: "Privacy" },
  { id: "releases", label: "Changelog" },
];

const Nav = ({ theme, setTheme, base = "", docsHref = "docs/" }) => {
  const stars = useGitHubStars();
  const at = (id) => `${base}#${id}`;
  return (
    <nav className="nav" aria-label="Main">
      <div className="page nav-inner">
        <a href={base || "#top"} className="brand" aria-label="huske, home">
          <Mark size={20} lit/>
          <span className="word">huske</span>
          <span className="ver">v{HUSKE_VERSION}</span>
        </a>
        <div className="nav-links">
          {NAV_LINKS.map((l) => <a key={l.id} href={at(l.id)}>{l.label}</a>)}
          <a href={docsHref}>Docs</a>
        </div>
        <div className="nav-right">
          <details className="nav-menu">
            <summary className="icon-btn" aria-label="Menu"><MenuIcon/></summary>
            <div className="sheet">
              {NAV_LINKS.map((l) => <a key={l.id} href={at(l.id)}>{l.label}</a>)}
              <a href={docsHref}>Docs</a>
            </div>
          </details>
          <ThemeToggle theme={theme} setTheme={setTheme}/>
          <a className="gh" href="https://github.com/tiagomoraes/huske" target="_blank" rel="noopener" title="huske on GitHub">
            <GhGlyph size={15}/>
            <span className="label">GitHub</span>
            <span className="num" aria-label={stars == null ? undefined : `${stars} stars`}>
              <StarGlyph/>{stars == null ? "—" : formatStars(stars)}
            </span>
          </a>
        </div>
      </div>
    </nav>
  );
};

const GH = "https://github.com/tiagomoraes/huske";

// Huske for iPhone on the App Store. The id is App Store Connect's Apple ID
// for the app record (docs/research/app-store-distribution.md).
const IOS_APP_STORE_URL = "https://apps.apple.com/app/id6838172707";

const Footer = ({ base = "", docsHref = "docs/" }) => (
  <footer className="foot">
    <div className="page">
      <div className="foot-grid">
        <div className="about">
          <a href={base || "#top"} className="brand"><Mark size={20} lit/><span className="word">huske</span></a>
          <p>Records on your Mac and your iPhone, and writes down what was said on your Mac. Open source, MIT licensed.</p>
        </div>
        <div>
          <h5>Product</h5>
          <ul>
            <li><a href={`${base}#iphone`}>Huske for iPhone</a></li>
            <li><a href={`${base}#how`}>How it works</a></li>
            <li><a href={`${base}#quality`}>Transcripts</a></li>
            <li><a href={`${base}#sync`}>Cloud sync</a></li>
            <li><a href={`${base}#privacy`}>Privacy</a></li>
            <li><a href={docsHref}>Docs</a></li>
          </ul>
        </div>
        <div>
          <h5>Reference</h5>
          <ul>
            <li><a href={`${GH}/blob/main/CHANGELOG.md`} target="_blank" rel="noopener">Changelog</a></li>
            <li><a href={`${GH}/blob/main/docs/macos-app.md`} target="_blank" rel="noopener">The Mac app</a></li>
            <li><a href={`${GH}/blob/main/ios/README.md`} target="_blank" rel="noopener">The iPhone app</a></li>
            <li><a href={`${GH}/blob/main/docs/transcription-models.md`} target="_blank" rel="noopener">Transcription models</a></li>
            <li><a href={`${GH}/blob/main/specs/001-huske-recorder/contracts/transcript-format.md`} target="_blank" rel="noopener">Transcript format</a></li>
            <li><a href="https://pypi.org/project/huske/" target="_blank" rel="noopener">PyPI</a></li>
          </ul>
        </div>
        <div>
          <h5>Community</h5>
          <ul>
            <li><a href={GH} target="_blank" rel="noopener">Source</a></li>
            <li><a href={`${GH}/issues`} target="_blank" rel="noopener">Issues</a></li>
            <li><a href={`${GH}/blob/main/CONTRIBUTING.md`} target="_blank" rel="noopener">Contributing</a></li>
            <li><a href={`${GH}/blob/main/SECURITY.md`} target="_blank" rel="noopener">Security</a></li>
            <li><a href={`${base}support/`}>Support</a></li>
            <li><a href={`${base}privacy/`}>Privacy policy</a></li>
          </ul>
        </div>
      </div>
      <div className="foot-meta">
        <span>huske v{HUSKE_VERSION}</span>
        <span>Built by tiagomoraes</span>
        <span>MIT license</span>
        <span className="to">huske, Norwegian for “to remember”</span>
      </div>
    </div>
  </footer>
);

Object.assign(window, {
  Mark, SunIcon, MoonIcon, GhGlyph, StarGlyph, CopyGlyph, CheckGlyph, Chev,
  CopyButton, Term, useGitHubStars, formatStars,
  useTheme, ThemeToggle, Nav, Footer, GH, IOS_APP_STORE_URL,
});
