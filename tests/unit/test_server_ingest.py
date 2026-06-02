"""Pure ingest logic: path-safety, hash verification, idempotent storage."""

from __future__ import annotations

from pathlib import Path

import pytest

from huske.server.ingest import (
    HashMismatchError,
    RelPathError,
    content_sha256,
    resolve_target,
    store_transcript,
    validate_rel_path,
    verify_hash,
)

_GOOD = "2026-06-02/120000_abcd1234_001.md"


def test_validate_accepts_canonical_rel_path() -> None:
    assert validate_rel_path(_GOOD) == _GOOD
    assert validate_rel_path("2026-12-31/235959_x_999.md")


@pytest.mark.parametrize(
    "bad",
    [
        "../etc/passwd",
        "/abs/120000_x_001.md",
        "2026-06-02/../120000_x_001.md",
        "2026-06-02/sub/dir.md",  # nested dir not allowed
        "notadate/120000_x_001.md",
        "2026-06-02/120000_x_001.txt",  # not .md
        "2026-06-02/.md",  # name must start alphanumeric
        "2026-06-02/120000_x_001.md/..",
        "2026-6-2/x.md",  # not zero-padded date
        "",
        "120000_x_001.md",  # missing date dir
        "2026-06-02\\120000_x_001.md",  # backslash
    ],
)
def test_validate_rejects_unsafe(bad: str) -> None:
    with pytest.raises(RelPathError):
        validate_rel_path(bad)


def test_resolve_target_stays_within_root(tmp_path: Path) -> None:
    target = resolve_target(tmp_path, _GOOD)
    assert tmp_path.resolve() in target.parents
    with pytest.raises(RelPathError):
        resolve_target(tmp_path, "../escape.md")


def test_verify_hash() -> None:
    verify_hash("hello", content_sha256("hello"))  # no raise
    with pytest.raises(HashMismatchError):
        verify_hash("hello", content_sha256("world"))


def test_store_transcript_writes_and_is_idempotent(tmp_path: Path) -> None:
    status, path = store_transcript(tmp_path, _GOOD, "first content")
    assert status == "stored"
    assert path.read_text(encoding="utf-8") == "first content"
    assert path == (tmp_path / _GOOD)

    # Identical content → no-op.
    status2, path2 = store_transcript(tmp_path, _GOOD, "first content")
    assert status2 == "unchanged"
    assert path2 == path

    # Changed content (defensive; transcripts are immutable in practice).
    status3, _ = store_transcript(tmp_path, _GOOD, "new content")
    assert status3 == "stored"
    assert path.read_text(encoding="utf-8") == "new content"


def test_store_transcript_rejects_traversal(tmp_path: Path) -> None:
    with pytest.raises(RelPathError):
        store_transcript(tmp_path, "../../evil.md", "x")
    # Nothing leaked outside the root.
    assert not (tmp_path.parent / "evil.md").exists()


def test_store_transcript_leaves_no_temp_files(tmp_path: Path) -> None:
    store_transcript(tmp_path, _GOOD, "content")
    day_dir = tmp_path / "2026-06-02"
    assert sorted(p.name for p in day_dir.iterdir()) == ["120000_abcd1234_001.md"]
