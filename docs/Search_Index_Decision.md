# Search index decision

Date: 2026-07-16

## Decision

WIMM does not maintain a SQLite FTS or vector index for now. Literal recall
uses the durable note sidecars as the source of truth and performs a linear
case-insensitive scan. There is no cache to migrate, repair, invalidate, or
rebuild.

The old embedding queue, reindexing jobs, semantic-search controls, and their
configuration were removed together with the unfinished Wiki, MemoryItem, and
OpenLoop subsystems. Existing generated user data was not deleted.

## Measurement

The current local corpus contained 9,242 note sidecars and approximately 2.5 GB
under the recordings root. Five representative literal queries were run three
times each through a fresh debug `wimm-tui` process, including process
startup, sidecar loading, JSON decoding, filtering, and result rendering (output
was redirected):

| Query | Runs, seconds |
|---|---:|
| `проект` | 1.48, 0.96, 0.93 |
| `встреча` | 0.96, 0.94, 0.94 |
| `документ` | 1.02, 1.11, 1.07 |
| `идея` | 1.25, 0.94, 0.94 |
| absent term | 0.87, 0.90, 0.87 |

Overall median was 0.94 seconds; observed range was 0.87–1.48 seconds. This is a
cold command-line end-to-end measurement, not an in-process UI keystroke
latency measurement. It establishes that the present corpus does not require a
vector index for acceptable explicit recall, while also showing that repeatedly
loading every sidecar is not suitable for search-as-you-type.

## Boundary

Keep notes loaded once in the app process and scan the in-memory collection.
Reconsider a derived SQLite FTS cache only when measurement shows a real
problem—for example, search interaction p95 above 200 ms on a loaded corpus,
startup/recall p95 above 2 seconds, or excessive memory use. If that boundary is
crossed, introduce FTS first: it solves literal retrieval with much less model,
schema, and invalidation complexity than embeddings.

Add a vector index only after a separately evaluated semantic-recall use case
shows materially better answer quality than literal search. Any future index
must be disposable and fully rebuildable from note sidecars; it must never
become a second source of truth.
