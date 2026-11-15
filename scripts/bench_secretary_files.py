#!/usr/bin/env python3
"""Time the file-secretary CLI on an invented library; no model calls.

Builds a disposable library, document and registry from a fixed seed, then runs
prepare (cold and warm) -> read -> apply --dry-run -> apply and prints the wall
time and the CLI's own stage timings. Not a CI check: times are machine noise
there, and correctness is test_secretary_files_cli.py.

To compare two builds, run each with --keep and diff docs/me.md and
docs/me.sources.json under the printed directories: they must be byte-identical.
"""
import argparse
import json
import os
from pathlib import Path
import random
import shutil
import subprocess
import tempfile
import time

WORDS = ("план встреча документ идея проект решение вопрос срок список дом "
         "работа текст балкон поезд аптека").split()


def build(root, notes, pending):
    """Most sources are settled (applied, with a matching mark); the newest
    `pending` ones are unread and make up the packet."""
    rng = random.Random(2)
    library, workspace = root / "library", root / "_ME"
    recordings = library / "Recordings"
    for path in (recordings, workspace / "docs", workspace / "secretary/protocol", library / "AgentState"):
        path.mkdir(parents=True)
    (workspace / "recordings").symlink_to(recordings, target_is_directory=True)
    body, definitions, sources, marks = ["# Bench\n"], [], [], {}
    for i in range(1, notes + 1):
        name = f"Wimm_2026-{1 + i % 9:02d}-{1 + i % 28:02d}_{i % 24:02d}-{i % 60:02d}-{i % 60:02d}_{i:06d}"
        text = " ".join(rng.choice(WORDS) for _ in range(60)) + f" заметка {i}.\n"
        (recordings / f"{name}.txt").write_text(text)
        (recordings / f"{name}.meta.json").write_text(json.dumps({"recordingId": f"bench-{i}"}))
        unread = i > notes - pending
        sources.append({"source_id": f"S{i}", "status": "pending" if unread else "applied",
                        "path": f"../recordings/{name}.meta.json", "note_file": f"{name}.txt",
                        "reason": "unread" if unread else "bench"})
        if i % 4 == 1:
            body.append(f"## Тема {i}\n")
        if not unread:
            body.append(" ".join(rng.choice(WORDS) for _ in range(40)) + f" [S{i}].\n")
            marks[f"{name}.txt"] = {"status": "applied", "source": f"S{i}", "markedAt": "2026-01-01T00:00:00Z",
                                    "noteId": f"bench-{i}", "text": "", "analysis": ""}
        definitions.append(f"[S{i}]: ../recordings/{name}.meta.json")
    document = workspace / "docs/me.md"
    document.write_text("\n".join(body) + "\n" + "\n".join(definitions) + "\n")
    # Indented like a real registry: the host patches rows in place by their indentation.
    document.with_suffix(".sources.json").write_text(json.dumps(
        {"sources": sources, "source_count": notes,
         "counts": {"pending": pending, "applied": notes - pending}, "batches": []},
        ensure_ascii=False, indent=2))
    (library / "AgentState/marks.json").write_text(json.dumps({"schema": "AgentState@v1", "marks": marks}))
    (workspace / "secretary/protocol/packet.md").write_text("Preserve plans as plans and cite sources.")
    (workspace / "secretary/review_queue.md").write_text("# Questions\n")
    return library, workspace, document


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--cli", type=Path, default=Path(".build/arm64-apple-macosx/release/WimmCLI"))
    parser.add_argument("--notes", type=int, default=3000)
    parser.add_argument("--pending", type=int, default=40, help="unread sources making up the packet (at most 60)")
    parser.add_argument("--keep", action="store_true", help="leave the directory for a comparison")
    arguments = parser.parse_args()
    cli = arguments.cli.resolve()
    assert 1 <= arguments.pending <= 60 < arguments.notes, "pending must be 1-60 and below notes"
    root = Path(tempfile.mkdtemp(prefix="wimm-secretary-bench-")).resolve()
    try:
        library, workspace, document = build(root, arguments.notes, arguments.pending)
        env = dict(os.environ, WIMM_TEST_MODE="1", WIMM_BASE_DIR=str(library),
                   WIMM_CLI_PATH=str(cli), WIMM_PRIVATE_MODE="0")
        rows = []

        def call(label, *command):
            started = time.perf_counter()
            result = subprocess.run([str(cli), "secretary", *command], env=env,
                                    capture_output=True, text=True, timeout=600)
            wall = (time.perf_counter() - started) * 1000
            try:
                reply = json.loads(result.stdout)
            except json.JSONDecodeError:
                raise SystemExit(f"{label} failed ({result.returncode}): {result.stderr[-2000:]}")
            rows.append((label, wall, reply.get("timings_ms") or {}))
            return reply

        # The invented marks carry no note fingerprints, so the default selection would
        # re-offer every settled note as changed; select the unread ones by registry.
        prepare = ("prepare", str(document), "--packet-kb", "64", "--unread-pending",
                   "--max-sources", str(arguments.pending))
        call("prepare cold", *prepare)
        manifest = call("prepare warm", *prepare)
        run, selected = manifest["run_id"], manifest["source_ids"]
        expected = {f"S{i}" for i in range(arguments.notes - arguments.pending + 1, arguments.notes + 1)}
        assert set(selected) == expected, f"packet holds {len(selected)} sources, expected the {len(expected)} unread"
        data = json.loads(Path(manifest["input"]).read_text())
        call("read outline", "read", run, "--outline")
        call("read section", "read", run, "--section", "Тема 1")
        targets = [b for b in data["document_blocks"] if not b["text"].startswith(("#", "[S"))]
        assert targets, "the packet has no document block to edit"
        # One edit per block; the sources are spread over the blocks the packet holds.
        groups = [selected[i::len(targets)] for i in range(min(len(targets), len(selected)))]
        response = workspace / "secretary/response.json"
        response.write_text(json.dumps({"summary": "bench", "edits": [
            {"operation": "insert_after", "block": block["id"], "sources": group,
             "text": "Новый факт про балкон " + "".join(f"[{source}]" for source in group) + ".\n\n"}
            for block, group in zip(targets, groups)],
            "done_no_additions": [], "unfinished": [], "questions": []}, ensure_ascii=False))
        call("apply dry-run", "apply", run, "--response", str(response), "--dry-run")
        applied = call("apply", "apply", run, "--response", str(response))
        assert applied.get("committed") and not applied.get("findings"), \
            f"apply: committed={applied.get('committed')}, findings={applied.get('findings', [])[:3]}"
        assert sorted(applied["stored_sources"]) == sorted(selected)

        print(f"{arguments.notes} notes, document {document.stat().st_size / 1e6:.1f} MB, "
              f"{len(selected)} sources, {len(groups)} edits; {cli}")
        for label, wall, stages in rows:
            top = sorted(((v, k) for k, v in stages.items() if k not in ("total", "bookkeeping")), reverse=True)[:4]
            print(f"  {label:14s} {wall:7.0f} ms   " + ", ".join(f"{k} {v:.0f}" for v, k in top))
        if arguments.keep:
            print(f"kept: {workspace / 'docs'}")
    finally:
        if not arguments.keep:
            shutil.rmtree(root, ignore_errors=True)


if __name__ == "__main__":
    main()
