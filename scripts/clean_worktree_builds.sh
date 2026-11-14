#!/usr/bin/env bash
# Deletes the SwiftPM build folders of worktrees whose branch is already merged.
#
# Every worktree builds the whole graph from scratch (~2-3.5 GB), and nothing removes it after
# the PR lands: on 2026-10-25 merged worktrees held ~21 GB. Only build output is deleted — the
# worktree, its branch and any uncommitted work stay. Dry run unless --apply.
#
# "Merged" alone is not enough: a worktree just cut from the base has no commits of its own and
# is trivially merged. So a build is only deleted when nothing has built there for
# MIN_AGE_HOURS (default 12).
#
#   scripts/clean_worktree_builds.sh            # list what would go
#   scripts/clean_worktree_builds.sh --apply    # delete it
#   BASE=origin/main scripts/clean_worktree_builds.sh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BASE="${BASE:-origin/main}"
MIN_AGE_HOURS="${MIN_AGE_HOURS:-12}"
APPLY=0
[[ "${1:-}" == "--apply" ]] && APPLY=1

cd "$ROOT_DIR"
git fetch -q origin 2>/dev/null || echo "warning: fetch failed, using local $BASE" >&2
MAIN_DIR="$(git worktree list --porcelain | awk '/^worktree /{print $2; exit}')"

freed=0
while read -r dir; do
  [[ "$dir" == "$MAIN_DIR" ]] && continue
  builds=()
  for b in "$dir/.build" "$dir/Packages/WimmCore/.build"; do
    [[ -d "$b" ]] && builds+=("$b")
  done
  (( ${#builds[@]} )) || continue

  head="$(git -C "$dir" rev-parse HEAD 2>/dev/null)" || continue
  name="$(git -C "$dir" branch --show-current 2>/dev/null)"
  if ! git merge-base --is-ancestor "$head" "$BASE"; then
    echo "keep  ${dir#$MAIN_DIR/}  (${name:-detached} not merged into $BASE)"
    continue
  fi
  # build.db / description.json are rewritten by every build, so they date the last one.
  newest=0
  for b in "${builds[@]}"; do
    for f in "$b" "$b"/*/debug/description.json "$b"/build.db; do
      [[ -e "$f" ]] || continue
      t="$(stat -f %m "$f")"; (( t > newest )) && newest=$t
    done
  done
  age_h=$(( ($(date +%s) - newest) / 3600 ))
  if (( age_h < MIN_AGE_HOURS )); then
    echo "keep  ${dir#$MAIN_DIR/}  (built ${age_h} h ago)"
    continue
  fi
  # A build or test running there right now would fail half-way.
  if pgrep -f "$dir" >/dev/null 2>&1; then
    echo "keep  ${dir#$MAIN_DIR/}  (a process is using it)"
    continue
  fi

  kb="$(du -sk "${builds[@]}" | awk '{t+=$1} END{print t}')"
  freed=$((freed + kb))
  printf "%s  %s  %s MB  (%s)\n" "$( ((APPLY)) && echo "rm  " || echo "would")" \
    "${dir#$MAIN_DIR/}" "$((kb / 1024))" "${name:-detached}"
  if ((APPLY)); then rm -rf "${builds[@]}"; fi
done < <(git worktree list --porcelain | awk '/^worktree /{print $2}')

echo "$( ((APPLY)) && echo "freed" || echo "would free") $((freed / 1024)) MB"
