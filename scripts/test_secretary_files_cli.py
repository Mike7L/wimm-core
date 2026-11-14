#!/usr/bin/env python3
"""End-to-end file-secretary CLI smoke on disposable data; no model calls."""
import argparse
import base64
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cli", type=Path, default=Path(".build/debug/WimmCLI"))
    cli = parser.parse_args().cli.resolve()
    with tempfile.TemporaryDirectory(prefix="wimm-secretary-cli-") as temporary:
        root = Path(temporary).resolve()
        library, workspace = root / "library", root / "_ME"
        recordings = library / "Recordings"
        for path in (recordings, workspace / "docs", workspace / "secretary/protocol"):
            path.mkdir(parents=True)
        (workspace / "recordings").symlink_to(recordings, target_is_directory=True)
        name = "Wimm_2026-10-30_12-00-00"
        (recordings / f"{name}.txt").write_text("Планирую проверить новый CLI. Ёж 🦔.\n")
        (recordings / f"{name}.meta.json").write_text(json.dumps({"recordingId": "smoke-note"}))
        document = workspace / "docs/me.md"
        document.write_text(f"# Smoke\n\n## Plans\n\nСтарый план [S1].\n\n[S1]: ../recordings/{name}.meta.json\n")
        registry = document.with_suffix(".sources.json")
        registry.write_text(json.dumps({"sources": [{"source_id": "S1", "status": "pending",
            "path": f"../recordings/{name}.meta.json", "note_file": f"{name}.txt", "reason": "unread"}],
            "source_count": 1, "counts": {"pending": 1}, "batches": []}))
        (workspace / "secretary/protocol/packet.md").write_text("Preserve plans as plans and cite sources.")
        (workspace / "secretary/review_queue.md").write_text("# Questions\n")
        env = dict(os.environ, WIMM_TEST_MODE="1", WIMM_BASE_DIR=str(library),
                   WIMM_CLI_PATH=str(cli), WIMM_PRIVATE_MODE="0")
        wall_times = []

        def call(*arguments):
            started = time.perf_counter()
            result = subprocess.run([str(cli), "secretary", *arguments], env=env,
                                    capture_output=True, text=True, timeout=60)
            if result.returncode:
                raise RuntimeError(f"CLI failed ({result.returncode}): {result.stderr}\n{result.stdout}")
            wall_times.append({"command": " ".join(arguments[:1]),
                               "elapsed_ms": (time.perf_counter() - started) * 1000})
            return json.loads(result.stdout)

        manifest = call("prepare", str(document), "--packet-kb", "256")
        assert manifest["timings_ms"]["total"] >= 0
        run = manifest["run_id"]
        assert manifest["source_ids"] == ["S1"], manifest
        data = json.loads(Path(manifest["input"]).read_text())
        assert "Ёж 🦔" in data["sources"][0]["full_text"]
        page = call("read", run, "--source", "S1", "--limit-bytes", "17")
        assert page["next_offset"] > 0 and not page["complete"]
        outline = call("read", run, "--outline")
        assert outline["read_results"] and outline["work_counts"].get("export_files_written", 0) == 0
        section = call("read", run, "--section", "Plans")
        assert section["document_blocks"] and section["work_counts"].get("export_files_written", 0) == 0
        refreshed = call("read", run, "--source", "S1", "--refresh")
        assert refreshed["work_counts"]["notes_built"] == 1, refreshed
        assert "library_note_count" not in refreshed["work_counts"], refreshed
        assert refreshed["work_counts"]["export_files_written"] == 3, refreshed
        block = next(b for b in data["document_blocks"] if "Старый план" in b["text"])
        response = workspace / "secretary/response.json"
        response.write_text(json.dumps({"summary": "A proposed plan", "edits": [
            {"operation": "insert_after", "block": block["id"], "sources": ["S1"],
             "text": "Планирую проверить новый CLI [S1].\n\n"}],
            "done_no_additions": [], "unfinished": [], "questions": []}, ensure_ascii=False))
        before = document.read_bytes()
        preview = call("apply", run, "--response", str(response), "--dry-run")
        assert not preview["committed"] and before == document.read_bytes()
        applied = call("apply", run, "--response", str(response))
        assert applied["committed"] and not applied["findings"], applied
        assert applied["stored_sources"] == ["S1"] and applied["bookkeeping"]["stored"] == 1, applied
        assert applied["usage"]["cost_usd"] is None
        assert "Планирую проверить новый CLI [S1]" in document.read_text()
        assert call("apply", run, "--response", str(response)) == applied
        snapshot = root / "snapshot.json"
        call("snapshot", run, "--output", str(snapshot))
        state = json.loads(snapshot.read_text())
        assert state["phase"] == "applied" and json.loads(base64.b64decode(state["report"])) == applied
        compact = library / "AgentState/SecretaryFileSessions" / f"{run}.json"
        assert json.loads(compact.read_text())["storage"] == "wimm-secretary-content-v1"
        checkpoints = library / "AgentState/SecretarySessionArchive/checkpoints"
        metadata_path = next(checkpoints.rglob("*-latest.json"))
        assert metadata_path.parent.parent == checkpoints
        metadata = json.loads(metadata_path.read_text())
        full = root / "checkpoint.json"
        call("snapshot", "--checkpoint", str(metadata_path.parent / f"{metadata['sha256']}.json.lzfse"), "--output", str(full))
        evidence = json.loads(full.read_text())["_checkpoint_files"]
        assert base64.b64decode(evidence["docs/me.md"]) == document.read_bytes()
        assert base64.b64decode(evidence["docs/me.sources.json"]) == registry.read_bytes()
        assert "secretary/runs/" + run + "/response.json" in evidence
        # Exports must not overwrite an existing file or bypass private mode.
        for arguments, private in [([run, "--output", str(snapshot)], "0"),
                                   ([run, "--output", str(root / "private.json")], "1")]:
            blocked = subprocess.run([str(cli), "secretary", "snapshot", *arguments],
                                     env=dict(env, WIMM_PRIVATE_MODE=private), capture_output=True, timeout=60)
            assert blocked.returncode != 0
        assert not (root / "private.json").exists()
        traces = list((library / "AgentState/SecretaryFileSessions" / f"{run}.timings").glob("*.json"))
        assert any(json.loads(p.read_text())["outcome"] == "replayed" for p in traces)
        print("PASS: prepare → paged reads → dry-run → apply → replay → compact/full snapshots; temporary library only")
        print(json.dumps({"prepare_ms": manifest["timings_ms"], "refresh_ms": refreshed["timings_ms"],
            "refresh_work": refreshed["work_counts"], "apply_ms": applied["timings_ms"],
            "cli_wall_ms": wall_times}, indent=2))


if __name__ == "__main__":
    main()
