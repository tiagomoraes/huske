// huske website — Mark, Nav, theme controller, Footer, shared icons.

const Mark = ({ size = 22 }) => (
  <svg viewBox="0 0 64 64" width={size} height={size} aria-hidden="true">
    <rect x="14" y="10" width="6" height="44" rx="1.2" fill="currentColor"/>
    <rect x="24" y="24" width="26" height="5" rx="1.2" fill="currentColor"/>
    <rect x="24" y="34" width="20" height="5" rx="1.2" fill="currentColor"/>
    <rect x="24" y="44" width="14" height="5" rx="1.2" fill="currentColor"/>
  </svg>
);

const ArrowRight = ({ size = 14 }) => (
  <svg viewBox="0 0 14 14" width={size} height={size} fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
    <path d="M2.5 7h9M8 3.5L11.5 7 8 10.5"/>
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

const KeyGlyph = ({ size = 13 }) => (
  <svg viewBox="0 0 16 16" width={size} height={size} fill="none" stroke="currentColor" strokeWidth="1.4" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
    <circle cx="5.5" cy="5.5" r="3"/>
    <path d="M7.7 7.7l5 5M11 11l1.5-1.5M9.5 9.5L11 8"/>
  </svg>
);

// ---- Reusable copy-to-clipboard button ----
const CopyButton = ({ text, className = "copy", withLabel = true }) => {
  const [copied, setCopied] = React.useState(false);
  return (
    <button
      type="button"
      className={`${className} ${copied ? "copied" : ""}`}
      onClick={() => {
        navigator.clipboard?.writeText(text);
        setCopied(true);
        setTimeout(() => setCopied(false), 1400);
      }}
      aria-label={copied ? "Copied" : "Copy to clipboard"}
    >
      {copied ? <CheckGlyph/> : <CopyGlyph/>}
      {withLabel && <span>{copied ? "copied" : "copy"}</span>}
    </button>
  );
};

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
function useTheme() {
  const [theme, setTheme] = React.useState(() => {
    if (typeof window === "undefined") return "dark";
    return localStorage.getItem("huske-theme") || "dark";
  });
  React.useEffect(() => {
    document.documentElement.setAttribute("data-theme", theme);
    localStorage.setItem("huske-theme", theme);
  }, [theme]);
  return [theme, setTheme];
}

const ThemeToggle = ({ theme, setTheme }) => (
  <button
    className="icon-btn"
    onClick={() => setTheme(theme === "dark" ? "light" : "dark")}
    aria-label="Toggle theme"
    title={theme === "dark" ? "switch to paper" : "switch to ink"}
  >
    {theme === "dark" ? <SunIcon/> : <MoonIcon/>}
  </button>
);

// `base` prefixes the in-page anchors so the shared Nav works on the docs page
// (docs/index.html): on the landing page base="" → "#why"; on the docs page
// base="../" → "../#why" (i.e. /huske/#why). `docsHref` is the link to the docs
// page itself: "docs/" from the landing root, "./" when already on the docs page.
const Nav = ({ theme, setTheme, base = "", docsHref = "docs/" }) => {
  const stars = useGitHubStars();
  const at = (id) => `${base}#${id}`;
  return (
    <nav className="nav">
      <a href={base || "#"} className="brand">
        <Mark/>
        <span className="word">huske</span>
        <span className="ver">v0.7.2</span>
      </a>
      <div className="links">
        <a href={at("why")}>why</a>
        <a href={at("how")}>how</a>
        <a href={at("output")}>output</a>
        <a href={at("search")}>search</a>
        <a href={at("privacy")}>privacy</a>
        <a href={at("releases")}>releases</a>
        <a href={at("faq")}>faq</a>
        <a href={docsHref}>docs</a>
      </div>
      <div className="right">
        <ThemeToggle theme={theme} setTheme={setTheme}/>
        <a className="gh-pill" href="https://github.com/tiagomoraes/huske" target="_blank" rel="noopener" title="Star huske on GitHub">
          <GhGlyph size={13}/>
          <span>github</span>
          <span className="sep"/>
          <span className="star"><StarGlyph/></span>
          <span className={`num ${stars == null ? "loading" : ""}`}>{stars == null ? "—" : formatStars(stars)}</span>
        </a>
      </div>
    </nav>
  );
};

const Footer = ({ base = "", docsHref = "docs/" }) => (
  <footer className="foot">
    <div className="page">
      <div className="grid">
        <div className="col">
          <div style={{ display: "flex", alignItems: "center", gap: 10, marginBottom: 18, color: "var(--fg)" }}>
            <Mark size={22}/>
            <span style={{ fontWeight: 600, letterSpacing: "-0.03em", fontSize: 18 }}>huske</span>
          </div>
          <p>A local-first audio recall instrument for the terminal. <span className="gloss">huske</span> — Norwegian for "to remember."</p>
          <p style={{ fontFamily: "var(--font-mono)", fontSize: 11, letterSpacing: "0.06em" }}>MIT · macOS 13+ · Apple Silicon</p>
        </div>
        <div className="col">
          <h5>product</h5>
          <ul>
            <li><a href={`${base}#why`}>why huske</a></li>
            <li><a href={`${base}#how`}>how it works</a></li>
            <li><a href={`${base}#output`}>output format</a></li>
            <li><a href={`${base}#search`}>search &amp; mcp</a></li>
            <li><a href={`${base}#privacy`}>privacy</a></li>
            <li><a href={`${base}#faq`}>faq</a></li>
            <li><a href={docsHref}>docs</a></li>
          </ul>
        </div>
        <div className="col">
          <h5>resources</h5>
          <ul>
            <li><a href="https://github.com/tiagomoraes/huske" target="_blank" rel="noopener">github</a></li>
            <li><a href="https://github.com/tiagomoraes/huske/blob/main/CHANGELOG.md" target="_blank" rel="noopener">changelog</a></li>
            <li><a href="https://github.com/tiagomoraes/huske/blob/main/specs/001-huske-recorder/quickstart.md" target="_blank" rel="noopener">quickstart</a></li>
            <li><a href="https://github.com/tiagomoraes/huske/blob/main/specs/001-huske-recorder/contracts/cli.md" target="_blank" rel="noopener">cli contract</a></li>
            <li><a href="https://pypi.org/project/huske/" target="_blank" rel="noopener">pypi</a></li>
          </ul>
        </div>
        <div className="col">
          <h5>community</h5>
          <ul>
            <li><a href="https://github.com/tiagomoraes/huske/issues" target="_blank" rel="noopener">issues</a></li>
            <li><a href="https://github.com/tiagomoraes/huske/blob/main/CONTRIBUTING.md" target="_blank" rel="noopener">contributing</a></li>
            <li><a href="https://github.com/tiagomoraes/huske/blob/main/CODE_OF_CONDUCT.md" target="_blank" rel="noopener">code of conduct</a></li>
            <li><a href="https://github.com/tiagomoraes/huske/blob/main/SECURITY.md" target="_blank" rel="noopener">security</a></li>
            <li><a href="https://github.com/tiagomoraes/huske/blob/main/SUPPORT.md" target="_blank" rel="noopener">support</a></li>
          </ul>
        </div>
      </div>
      <div className="meta">
        <div className="left">
          <Mark size={18}/>
          <span>huske v0.7.2</span>
          <span style={{ color: "var(--fg-faint)" }}>·</span>
          <span>built by tiagomoraes</span>
          <span style={{ color: "var(--fg-faint)" }}>·</span>
          <span>mit license</span>
        </div>
        <div className="right">
          <span>made for the terminal</span>
          <span style={{ color: "var(--fg-faint)" }}>·</span>
          <span style={{ fontFamily: "var(--font-serif)", fontStyle: "italic", textTransform: "none", letterSpacing: 0 }}>to remember</span>
        </div>
      </div>
    </div>
  </footer>
);

Object.assign(window, {
  Mark, ArrowRight, SunIcon, MoonIcon, GhGlyph, StarGlyph, CopyGlyph, CheckGlyph, KeyGlyph,
  CopyButton, useGitHubStars, formatStars,
  useTheme, ThemeToggle, Nav, Footer,
});
