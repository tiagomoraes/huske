"""Tests for the release-prep / finalize / homebrew-tap scripts.

These tests exercise the *pure* parsing and rewriting helpers — the ones
that are easy to get wrong and where a regression silently corrupts a
release. The CLI-level behavior (subprocess calls into git/gh/pip) is
left to manual end-to-end validation since mocking those is brittle.
"""

from __future__ import annotations

import importlib.util
import sys
from pathlib import Path
from types import ModuleType

import pytest

_SCRIPTS_DIR = Path(__file__).resolve().parents[2] / "scripts"


def _load(name: str, filename: str) -> ModuleType:
    """Load a hyphen-named script as an importable module under ``name``."""
    spec = importlib.util.spec_from_file_location(name, _SCRIPTS_DIR / filename)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


release_script = _load("release_script", "release.py")
release_finalize = _load("release_finalize", "release-finalize.py")
update_homebrew_tap = _load("update_homebrew_tap", "update-homebrew-tap.py")

# ---------------------------------------------------------------------------
# release.py — markdown → JSX
# ---------------------------------------------------------------------------


def test_markdown_to_jsx_plain_text() -> None:
    assert release_script._markdown_text_to_jsx("just words.") == "just words."


def test_markdown_to_jsx_backticks_become_code() -> None:
    out = release_script._markdown_text_to_jsx("Run `huske run` to start.")
    assert out == "Run <code>huske run</code> to start."


def test_markdown_to_jsx_braces_in_text_are_escaped() -> None:
    out = release_script._markdown_text_to_jsx("rule {restart: false}")
    assert out == "rule &#123;restart: false&#125;"


def test_markdown_to_jsx_braces_in_code_are_escaped_too() -> None:
    out = release_script._markdown_text_to_jsx("config: `KeepAlive={SuccessfulExit:false}`")
    assert "<code>KeepAlive=&#123;SuccessfulExit:false&#125;</code>" in out


def test_markdown_to_jsx_unclosed_backtick_is_passed_through() -> None:
    out = release_script._markdown_text_to_jsx("oops `unterminated")
    assert "`" in out  # we don't crash; we just leave the stray tick


# ---------------------------------------------------------------------------
# release.py — CHANGELOG section → JSX items array
# ---------------------------------------------------------------------------


def test_changelog_to_jsx_items_single_section() -> None:
    body = "### Added\n\n- A new feature with `code`.\n"
    out = release_script._changelog_to_jsx_items(body)
    assert 'kind: "added"' in out
    assert "<code>code</code>" in out


def test_changelog_to_jsx_items_multiple_sections() -> None:
    body = (
        "### Added\n\n"
        "- new thing\n\n"
        "### Fixed\n\n"
        "- old bug\n"
    )
    out = release_script._changelog_to_jsx_items(body)
    assert 'kind: "added"' in out
    assert 'kind: "fixed"' in out
    # "added" must come before "fixed" — same order as the source.
    assert out.index('kind: "added"') < out.index('kind: "fixed"')


def test_changelog_to_jsx_items_continuation_lines_join() -> None:
    body = (
        "### Added\n\n"
        "- first line\n"
        "  continues here\n"
        "  and here\n"
    )
    out = release_script._changelog_to_jsx_items(body)
    assert "first line continues here and here" in out


def test_changelog_to_jsx_items_empty_dies(capsys: pytest.CaptureFixture[str]) -> None:
    with pytest.raises(SystemExit):
        release_script._changelog_to_jsx_items("### Added\n\n")
    err = capsys.readouterr().err
    assert "could not parse" in err.lower()


# ---------------------------------------------------------------------------
# release.py — file edits (against fixture files)
# ---------------------------------------------------------------------------


def _write(p: Path, contents: str) -> Path:
    p.write_text(contents, encoding="utf-8")
    return p


def test_bump_pyproject_replaces_only_the_first_version_line(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    pyproject = _write(
        tmp_path / "pyproject.toml",
        '[project]\nname = "huske"\nversion = "0.4.0"\n\n[tool.foo]\nversion = "9.9.9"\n',
    )
    monkeypatch.setattr(release_script, "PYPROJECT", pyproject)

    release_script.bump_pyproject("0.5.0")
    text = pyproject.read_text(encoding="utf-8")
    assert 'version = "0.5.0"' in text
    assert 'version = "9.9.9"' in text  # the second one (different section) survives


def test_move_changelog_unreleased_moves_body(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    changelog = _write(
        tmp_path / "CHANGELOG.md",
        "# Changelog\n\n"
        "## Unreleased\n\n"
        "### Added\n\n- a new thing\n\n"
        "## 0.4.0 - 2026-05-09\n\n"
        "### Fixed\n\n- prior fix\n",
    )
    monkeypatch.setattr(release_script, "CHANGELOG", changelog)

    body = release_script.move_changelog_unreleased("0.5.0", "2026-05-10")
    text = changelog.read_text(encoding="utf-8")

    assert text.startswith("# Changelog\n\n## Unreleased\n\n## 0.5.0 - 2026-05-10")
    assert "a new thing" in body
    # The old 0.4.0 section is still there.
    assert "## 0.4.0 - 2026-05-09" in text


def test_move_changelog_unreleased_dies_when_empty(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    changelog = _write(
        tmp_path / "CHANGELOG.md",
        "# Changelog\n\n## Unreleased\n\n## 0.4.0 - 2026-05-09\n\n- prior\n",
    )
    monkeypatch.setattr(release_script, "CHANGELOG", changelog)
    with pytest.raises(SystemExit):
        release_script.move_changelog_unreleased("0.5.0", "2026-05-10")


def test_update_version_js_patches_single_global(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    vjs = _write(
        tmp_path / "version.js",
        'window.HUSKE_VERSION = "0.4.0";\nwindow.HUSKE_PYTHONS = ["3.11"];\n',
    )
    monkeypatch.setattr(release_script, "WEBSITE_VERSION_JS", vjs)
    release_script.update_version_js("0.5.0")
    text = vjs.read_text(encoding="utf-8")
    assert 'window.HUSKE_VERSION = "0.5.0";' in text
    assert "0.4.0" not in text
    # The unrelated supported-Python line is left untouched.
    assert 'window.HUSKE_PYTHONS = ["3.11"];' in text


def test_update_readme_pin_bumps_install_tag(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    readme = _write(
        tmp_path / "README.md",
        'uv tool install "git+https://github.com/tiagomoraes/huske.git@v0.4.0"\n',
    )
    monkeypatch.setattr(release_script, "README", readme)
    release_script.update_readme_pin("0.5.0")
    text = readme.read_text(encoding="utf-8")
    assert "huske.git@v0.5.0" in text
    assert "v0.4.0" not in text


def _seed_website(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Path:
    """Create a minimal website/ tree and point the release module at it."""
    web = tmp_path / "website"
    (web / "docs").mkdir(parents=True)
    monkeypatch.setattr(release_script, "WEBSITE_DIR", web)
    monkeypatch.setattr(release_script, "WEBSITE_SECTIONS", web / "components-sections.jsx")
    monkeypatch.setattr(release_script, "README", tmp_path / "README.md")
    return web


def test_scan_stale_website_versions_clean_site_passes(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    web = _seed_website(tmp_path, monkeypatch)
    (web / "version.js").write_text('window.HUSKE_VERSION = "0.5.0";\n', encoding="utf-8")
    (web / "components-hero.jsx").write_text("<span>v{HUSKE_VERSION}</span>\n", encoding="utf-8")
    (web / "components-shell.jsx").write_text("huske v{HUSKE_VERSION}\n", encoding="utf-8")
    (web / "components-docs.jsx").write_text('{HUSKE_PYTHONS.join(" / ")}\n', encoding="utf-8")
    (web / "index.html").write_text("<html></html>\n", encoding="utf-8")
    (web / "docs" / "index.html").write_text("<html></html>\n", encoding="utf-8")
    (web / "components-sections.jsx").write_text(
        'const MCP = "127.0.0.1:7641";\n'
        "const RELEASES = [\n"
        '  { ver: "0.5.0", tag: "latest" },\n'
        '  { ver: "0.4.0" },\n'
        "];\n",
        encoding="utf-8",
    )
    assert release_script.scan_stale_website_versions("0.5.0") == []


def test_scan_stale_website_versions_flags_previous_version_outside_releases(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    web = _seed_website(tmp_path, monkeypatch)
    (web / "version.js").write_text('window.HUSKE_VERSION = "0.5.0";\n', encoding="utf-8")
    # A component still hardcodes the PREVIOUS version outside RELEASES -> flagged.
    (web / "components-hero.jsx").write_text(
        '<span className="name">huske 0.4.0</span>\n', encoding="utf-8"
    )
    (web / "components-shell.jsx").write_text("huske v{HUSKE_VERSION}\n", encoding="utf-8")
    (web / "components-docs.jsx").write_text('{HUSKE_PYTHONS.join(" / ")}\n', encoding="utf-8")
    # A React CDN pin: looks version-ish, must NEVER be flagged.
    (web / "index.html").write_text(
        '<script src="https://unpkg.com/react@18.3.1/react.js"></script>\n', encoding="utf-8"
    )
    (web / "components-sections.jsx").write_text(
        'const MCP = "127.0.0.1:7641";\n'  # IPv4 -> never a version
        "<p>Semantic versioning after 0.1.0.</p>\n"  # policy prose -> not the prev version
        "const RELEASES = [\n"
        '  { ver: "0.5.0", tag: "latest" },\n'
        '  { ver: "0.4.0" },\n'  # historical previous -> allowed
        "];\n",
        encoding="utf-8",
    )
    problems = release_script.scan_stale_website_versions("0.5.0", prev_version="0.4.0")
    joined = "\n".join(problems)
    assert "components-hero.jsx" in joined and "previous version 0.4.0" in joined
    # The historical RELEASES 0.4.0, the CDN pin, the IPv4 literal, and the
    # 0.1.0 version-policy prose are all left alone — searching for the specific
    # previous version is what keeps those out.
    assert "components-sections.jsx" not in joined
    assert "index.html" not in joined
    assert "18.3.1" not in joined


def test_scan_stale_website_versions_flags_outdated_latest_release(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    web = _seed_website(tmp_path, monkeypatch)
    (web / "version.js").write_text('window.HUSKE_VERSION = "0.5.0";\n', encoding="utf-8")
    (web / "components-hero.jsx").write_text("v{HUSKE_VERSION}\n", encoding="utf-8")
    (web / "components-shell.jsx").write_text("v{HUSKE_VERSION}\n", encoding="utf-8")
    (web / "components-docs.jsx").write_text("ok\n", encoding="utf-8")
    # version.js is current, but nobody added the new RELEASES entry.
    (web / "components-sections.jsx").write_text(
        "const RELEASES = [\n  { ver: \"0.4.0\", tag: \"latest\" },\n];\n",
        encoding="utf-8",
    )
    problems = release_script.scan_stale_website_versions("0.5.0")
    assert any("newest RELEASES entry" in p for p in problems)


def test_update_sections_releases_inserts_new_entry_and_demotes_latest(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    sections = _write(
        tmp_path / "sections.jsx",
        "const RELEASES = [\n"
        '  {\n    ver: "0.4.0", date: "2026-05-09", tag: "latest",\n'
        '    items: [],\n  },\n'
        "];\n",
    )
    monkeypatch.setattr(release_script, "WEBSITE_SECTIONS", sections)
    body = "### Added\n\n- a feature\n"
    release_script.update_sections_releases("0.5.0", "2026-05-10", body)
    text = sections.read_text(encoding="utf-8")

    # New entry exists, marked latest.
    assert 'ver: "0.5.0"' in text
    assert text.find('ver: "0.5.0"') < text.find('ver: "0.4.0"')
    # tag: "latest" appears exactly once and on the new entry.
    assert text.count('tag: "latest"') == 1
    assert text.find('tag: "latest"') < text.find('ver: "0.4.0"')


# ---------------------------------------------------------------------------
# release_finalize.py — CHANGELOG section extraction
# ---------------------------------------------------------------------------


def test_extract_changelog_section_finds_target_version(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    changelog = _write(
        tmp_path / "CHANGELOG.md",
        "# Changelog\n\n"
        "## Unreleased\n\n"
        "## 0.5.0 - 2026-05-09\n\n"
        "### Added\n\n- new thing\n\n"
        "## 0.4.0 - 2026-05-08\n\n- old\n",
    )
    monkeypatch.setattr(release_finalize, "CHANGELOG", changelog)
    body = release_finalize.extract_changelog_section("0.5.0")
    assert "new thing" in body
    assert "old" not in body


def test_extract_changelog_section_missing_dies(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    changelog = _write(
        tmp_path / "CHANGELOG.md",
        "# Changelog\n\n## Unreleased\n\n## 0.4.0 - 2026-05-08\n\n- old\n",
    )
    monkeypatch.setattr(release_finalize, "CHANGELOG", changelog)
    with pytest.raises(SystemExit):
        release_finalize.extract_changelog_section("0.5.0")


# ---------------------------------------------------------------------------
# update_homebrew_tap.py — rewrite_formula
# ---------------------------------------------------------------------------


_SAMPLE_FORMULA = '''class Huske < Formula
  desc "Whatever"
  homepage "https://example.com"
  url "https://files.pythonhosted.org/packages/aa/bb/cc/huske-0.4.0.tar.gz"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"
  license "MIT"

  resource "numpy" do
    url "https://files.pythonhosted.org/old/numpy-2.0.0.whl"
    sha256 "1111111111111111111111111111111111111111111111111111111111111111"
  end

  resource "Pygments" do
    url "https://files.pythonhosted.org/old/pygments-2.0.0.whl"
    sha256 "2222222222222222222222222222222222222222222222222222222222222222"
  end

  def install
  end
end
'''


def test_rewrite_formula_updates_url_sha_and_resources() -> None:
    pip_pkgs = {
        "numpy": (
            "https://files.pythonhosted.org/new/numpy-2.4.4.whl",
            "a" * 64,
        ),
        "pygments": (
            "https://files.pythonhosted.org/new/pygments-2.20.0.whl",
            "b" * 64,
        ),
    }
    new_text, added, removed = update_homebrew_tap.rewrite_formula(
        _SAMPLE_FORMULA,
        new_sdist_url="https://files.pythonhosted.org/9e/3b/.../huske-0.5.0.tar.gz",
        new_sdist_sha="c" * 64,
        pip_pkgs=pip_pkgs,
    )
    assert "huske-0.5.0.tar.gz" in new_text
    assert "c" * 64 in new_text
    assert "numpy-2.4.4.whl" in new_text
    assert "pygments-2.20.0.whl" in new_text
    assert "a" * 64 in new_text
    assert "b" * 64 in new_text
    # Old sha values gone.
    assert "1" * 64 not in new_text
    assert "2" * 64 not in new_text
    # Old huske sha gone.
    assert "0" * 64 not in new_text
    assert added == []
    assert removed == []


def test_rewrite_formula_reports_added_and_removed() -> None:
    pip_pkgs = {
        "numpy": (
            "https://files.pythonhosted.org/new/numpy-2.4.4.whl",
            "a" * 64,
        ),
        "newdep": (
            "https://files.pythonhosted.org/new/newdep-1.0.0.whl",
            "d" * 64,
        ),
        # pygments missing — should be reported as "removed" in formula.
    }
    new_text, added, removed = update_homebrew_tap.rewrite_formula(
        _SAMPLE_FORMULA,
        new_sdist_url="https://files.pythonhosted.org/9e/3b/.../huske-0.5.0.tar.gz",
        new_sdist_sha="c" * 64,
        pip_pkgs=pip_pkgs,
    )
    assert "newdep" in added
    assert "pygments" in removed
    # numpy was updated, pygments left untouched (not in pip report).
    assert "numpy-2.4.4.whl" in new_text
    assert "pygments-2.0.0.whl" in new_text  # unchanged because not in pip_pkgs


def test_rewrite_formula_preserves_unrelated_content() -> None:
    pip_pkgs = {
        "numpy": ("https://example.com/numpy-2.4.4.whl", "a" * 64),
        "pygments": ("https://example.com/pygments-2.20.0.whl", "b" * 64),
    }
    new_text, _, _ = update_homebrew_tap.rewrite_formula(
        _SAMPLE_FORMULA,
        new_sdist_url="https://example.com/huske-0.5.0.tar.gz",
        new_sdist_sha="c" * 64,
        pip_pkgs=pip_pkgs,
    )
    assert "class Huske < Formula" in new_text
    assert 'desc "Whatever"' in new_text
    assert "def install" in new_text
    assert "end\nend\n" in new_text


def test_normalize_handles_underscores_and_case() -> None:
    assert update_homebrew_tap.normalize("Pyobjc_Core") == "pyobjc-core"
    assert update_homebrew_tap.normalize("PyYAML") == "pyyaml"
