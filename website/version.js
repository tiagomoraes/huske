// Single source of truth for the versions shown on the huske website.
//
// This is a plain classic script (NOT type="text/babel"), loaded before the
// React UMD + Babel bundles, so the values land on `window` and every JSX
// component can read them as bare globals — the same way components reference
// `React` / `ReactDOM` from the UMD bundles. Both pages (`/` and `/docs/`)
// load this file, so there is exactly one place to change a version.
//
// HUSKE_VERSION is patched automatically by `scripts/release.py` on every
// release — keep it equal to `version` in `pyproject.toml`. Do not hardcode the
// version anywhere else in the site; reference `HUSKE_VERSION` instead. The
// historical `RELEASES` timeline in `components-sections.jsx` is the one
// intentional exception (it records every past version).
//
// HUSKE_PYTHONS tracks `requires-python` in `pyproject.toml`. Update it by hand
// when the supported Python range changes.
window.HUSKE_VERSION = "0.11.0";
window.HUSKE_PYTHONS = ["3.11", "3.12", "3.13", "3.14"];
