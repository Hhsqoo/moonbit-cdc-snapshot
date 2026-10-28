#!/usr/bin/env python3
"""End-to-end smoke test for the native snapshot repository CLI."""

from __future__ import annotations

from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]


def run(*args: str, expect_success: bool = True) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(
        ["moon", "run", "--target", "native", "cmd/main", "--", *args],
        cwd=ROOT,
        text=True,
        encoding="utf-8",
        errors="replace",
        capture_output=True,
        check=False,
    )
    if expect_success and result.returncode != 0:
        raise AssertionError(
            f"command failed: {args}\n{result.stdout}\n{result.stderr}"
        )
    if not expect_success and result.returncode == 0:
        raise AssertionError(f"command unexpectedly succeeded: {args}")
    return result


def main() -> None:
    with tempfile.TemporaryDirectory(prefix="moonbit-cdc-smoke-") as temp:
        root = Path(temp)
        repository = root / "repository"
        source = root / "source"
        (source / "docs" / "empty").mkdir(parents=True)
        payload = bytes((index * 29 + index // 101) % 256 for index in range(1024 * 1024))
        changed = payload[: 512 * 1024] + b"inserted bytes shift later offsets" + payload[512 * 1024 :]
        (source / "payload.bin").write_bytes(payload)
        (source / "docs" / "readme.txt").write_text("stable documentation\n", encoding="utf-8")
        (source / "cache.tmp").write_text("exclude me", encoding="utf-8")

        run("init", str(repository))
        first = run(
            "snapshot",
            str(repository),
            str(source),
            "baseline",
            "--exclude",
            "**/*.tmp",
            "--min",
            "1024",
            "--average",
            "4096",
            "--max",
            "16384",
        )
        assert "snapshot created" in first.stdout
        assert "2 files" in first.stdout
        listing = run("list", str(repository))
        assert "baseline:" in listing.stdout
        details = run("show", str(repository), "baseline")
        assert "kind: directory" in details.stdout
        assert "chunk settings: 1024/4096/16384" in details.stdout
        assert "payload.bin" in details.stdout
        assert "cache.tmp" not in details.stdout
        verified = run("verify", str(repository))
        assert "verified 1 snapshots" in verified.stdout

        restored = root / "restored"
        run("restore", str(repository), "baseline", str(restored))
        assert (restored / "payload.bin").read_bytes() == payload
        assert (restored / "docs" / "readme.txt").read_text(encoding="utf-8") == "stable documentation\n"
        assert (restored / "docs" / "empty").is_dir()
        run("restore", str(repository), "baseline", str(restored), expect_success=False)

        (source / "payload.bin").write_bytes(changed)
        (source / "new.bin").write_bytes(b"a newly added file\n")
        run(
            "snapshot",
            str(repository),
            str(source),
            "updated",
            "--exclude",
            "**/*.tmp",
            "--min",
            "1024",
            "--average",
            "4096",
            "--max",
            "16384",
        )
        comparison = run("compare", str(repository), "baseline", "updated")
        assert "added: 1 files" in comparison.stdout
        assert "changed: 1 files" in comparison.stdout
        reused_line = next(line for line in comparison.stdout.splitlines() if line.startswith("reused chunk bytes:"))
        assert int(reused_line.split(":", 1)[1]) > 0
        analysis = run("analyze", str(repository), "baseline", "updated")
        assert "CDC reuse analysis" in analysis.stdout
        assert "changed: payload.bin" in analysis.stdout
        assert "added: new.bin" in analysis.stdout
        assert "reused: " in analysis.stdout
        analysis_reused_line = next(
            line for line in analysis.stdout.splitlines() if line.startswith("reused total:")
        )
        analysis_reused_bytes = int(analysis_reused_line.split(", ")[1].split()[0])
        assert analysis_reused_bytes == int(reused_line.split(":", 1)[1])
        statistics = run("stats", str(repository))
        assert "snapshots: 2" in statistics.stdout
        assert "missing objects: 0" in statistics.stdout

        preview = run("forget", str(repository), "updated")
        assert "preview:" in preview.stdout
        assert "updated:" in run("list", str(repository)).stdout
        run("forget", str(repository), "updated", "--apply")
        temporary_artifact = repository / "tmp" / "interrupted-write.part"
        temporary_artifact.write_bytes(b"partial")
        gc_preview = run("gc", str(repository))
        assert "preview:" in gc_preview.stdout
        assert "pass --apply" in gc_preview.stdout
        assert "1 temporary files" in gc_preview.stdout
        run("gc", str(repository), "--apply")
        assert not temporary_artifact.exists()
        after_gc = run("stats", str(repository))
        assert "orphan objects: 0" in after_gc.stdout

        invalid = run("snapshot", str(repository), str(source), "../unsafe", expect_success=False)
        assert "error:" in invalid.stdout

    print("CLI smoke test passed")


if __name__ == "__main__":
    main()
