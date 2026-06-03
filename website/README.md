# huske website

Public landing page for huske, deployed to GitHub Pages from this directory.

## Local preview

The site is plain static files — no build step. Serve with any static server:

```bash
python -m http.server 8000 --directory website
# then open http://localhost:8000
```

## Stack

- Plain HTML + CSS in `index.html`, `site.css`, `colors_and_type.css`
- Two pages: the landing `index.html` (served at `/`) and the docs page
  `docs/index.html` (served at `/docs/` — a directory index is what gives the
  clean URL, since GitHub Pages has no rewrite engine and `.nojekyll` is set).
  The docs page links to shared assets with `../` so it resolves both locally
  and under the `/huske/` project base.
- React 18 (UMD) + Babel Standalone via unpkg, JSX compiled in the browser
- IBM Plex (Sans / Mono / Serif) bundled under `fonts/`
- Logo assets under `assets/`
- Theme toggle persists in `localStorage` (`huske-theme`)

The Babel-in-browser approach keeps the site dependency-free (no `npm`, no
toolchain) at the cost of a one-time ~1 MB compiler download. Acceptable for a
single-page landing; revisit if the site grows.

## Deploy

`.github/workflows/pages.yml` publishes this directory to GitHub Pages on
every push to `main` that touches `website/`. Manual runs via
`workflow_dispatch`.

To enable: in the repo settings under **Pages**, set the source to **GitHub
Actions** (one-time setup).

## Editing

The page is composed from three component files loaded via
`<script type="text/babel">`:

- `components-shell.jsx` — `Mark` logo, `Nav`, `Footer`, theme controller
- `components-hero.jsx` — `Hero`, `InstallTabs`, `LiveDemo` (animated TUI)
- `components-sections.jsx` — `Pillars`, `HowItWorks`, `OutputPreview`,
  `Privacy`, `Releases`, `Community`, `FAQ`

Hardcoded copy that's worth keeping in sync with the rest of the repo (the
release checklist in the root `CLAUDE.md` requires a deep pass over all of this
on every release):

- Version string appears in `Nav` + `Footer` (`components-shell.jsx`), the hero
  eyebrow + live-demo header (`components-hero.jsx`), and the sample frontmatter
  (`components-sections.jsx`) — update them all to match `pyproject.toml`
  `version`. Leave the historical `RELEASES` entries untouched.
- Supported Python versions (`components-hero.jsx`) must match
  `requires-python` in `pyproject.toml`.
- Release timeline data lives in `RELEASES` in `components-sections.jsx`
- GitHub star count in `Nav` (`gh-pill .num`) is live — fetched from the GitHub
  API at runtime via `useGitHubStars`, cached in `localStorage` for 5 minutes,
  and falls back to `—` if the API is unreachable.
