#!/bin/bash
# Waits until the Wimm Studio "Друг" window hands over the user's next spoken
# answer, then prints it as JSON (note, path, finished_at, text).
# An answer that arrived while nobody was waiting is printed at once; each
# answer is printed only once. Exits 2 with "timeout" after $1 minutes (default 30).
set -euo pipefail

dir="$HOME/Library/Application Support/Wimm/Conversation"
answer="$dir/answer.json"
seen="$dir/.answer_seen"
deadline=$(( $(date +%s) + ${1:-30} * 60 ))

while true; do
  if [[ -f "$answer" ]]; then
    sum=$(cksum < "$answer")
    if [[ "$sum" != "$(cat "$seen" 2>/dev/null || true)" ]]; then
      printf '%s\n' "$sum" > "$seen"
      cat "$answer"
      exit 0
    fi
  fi
  if (( $(date +%s) >= deadline )); then
    echo "timeout"
    exit 2
  fi
  sleep 0.2
done
