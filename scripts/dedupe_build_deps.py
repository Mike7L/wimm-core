#!/usr/bin/env python3
"""Makes identical SwiftPM dependency files across checkouts share disk blocks (APFS clones).

Every checkout's .build unzips its own copy of FluidAudio's NemoTextProcessing binary framework
(~200 MB), byte-identical in every checkout. This replaces each duplicate with a copy-on-write
clone of one canonical file (`cp -c`), so N checkouts cost the space of one. Contents and paths
do not change, so SwiftPM does not notice; a later write to a clone simply un-shares that file.

`repositories/` is left alone: SwiftPM already copies those git packs out of its global cache
as APFS clones (measured 2026-10-25: cloning 2.2 GB of packs freed nothing), so `du` overstates
them. Build output is never touched — its files differ per checkout anyway.

  scripts/dedupe_build_deps.py            # report what would be shared
  scripts/dedupe_build_deps.py --apply

`du` keeps counting each clone in full; free space (`df`) is where the saving shows.
"""
import filecmp
import os
import subprocess
import sys
from collections import defaultdict
from pathlib import Path

MIN_BYTES = 1 << 20
SUBDIRS = ("artifacts",)
MARK = "app.wimm.dedupe"  # xattr on a clone; holds the canonical path, so reruns skip it


def build_dirs(main: Path):
    out = subprocess.run(["git", "-C", str(main), "worktree", "list", "--porcelain"],
                         capture_output=True, text=True, check=True).stdout
    for line in out.splitlines():
        if line.startswith("worktree "):
            root = Path(line.split(" ", 1)[1])
            for b in (root / ".build", root / "Packages/WimmCore/.build"):
                if b.is_dir():
                    yield b


def candidates(build: Path):
    for sub in SUBDIRS:
        base = build / sub
        if not base.is_dir():
            continue
        for dirpath, _, files in os.walk(base):
            for name in files:
                path = Path(dirpath) / name
                if path.is_symlink():
                    continue
                size = path.stat().st_size
                if size >= MIN_BYTES:
                    # Same relative path under artifacts/ = same downloaded file.
                    yield path.relative_to(build).as_posix(), size, path


def marked(path: Path, canonical: Path) -> bool:
    out = subprocess.run(["xattr", "-p", MARK, str(path)], capture_output=True, text=True)
    return out.returncode == 0 and out.stdout.strip() == str(canonical)


def main():
    apply = "--apply" in sys.argv
    repo = Path(__file__).resolve().parent.parent
    main_dir = Path(subprocess.run(["git", "-C", str(repo), "rev-parse", "--git-common-dir"],
                                   capture_output=True, text=True, check=True).stdout.strip())
    main_dir = (repo / main_dir).resolve().parent

    groups = defaultdict(list)
    for build in build_dirs(main_dir):
        for rel, size, path in candidates(build):
            groups[(rel, size)].append(path)

    shared = 0
    for (rel, size), paths in sorted(groups.items()):
        if len(paths) < 2:
            continue
        canonical = paths[0]
        for dup in paths[1:]:
            if marked(dup, canonical):
                continue
            if not filecmp.cmp(canonical, dup, shallow=False):
                continue
            shared += size
            print(f"{'clone' if apply else 'would clone'} {size >> 20:5d} MB  {dup}")
            if apply:
                tmp = dup.with_name(dup.name + ".dedupe-tmp")
                subprocess.run(["cp", "-c", "-p", str(canonical), str(tmp)], check=True)
                subprocess.run(["xattr", "-w", MARK, str(canonical), str(tmp)], check=True)
                os.replace(tmp, dup)
    print(f"{'shared' if apply else 'would share'} {shared >> 20} MB")


if __name__ == "__main__":
    main()
