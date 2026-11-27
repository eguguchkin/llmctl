# bench/ — engine benchmarks

Everything in this directory is produced by `lctl bench` — the read-only
benchmark of the **running** engine (it never starts, stops or
re-configures anything; a stopped stack produces a clear error). One file
per engine+profile combination:
`reports/<engine>-<version>-<profile>.md`, rewritten on the next run of
the same combination. The header carries the date, engine, engine version,
profile, model, the fixture md5 and the run parameters — and deliberately
no host information.

## Machine-readable artifacts (since 2026-11-27)

Every `lctl bench` run now writes, next to the `.md` report:

- `reports/<combo>.json` — the raw measurements snapshot: `meta` (date,
  engine, version, profile, model, fixture md5, params, truncated) plus
  the scenario rows **verbatim** (solo/prose/session/followup/parallel +
  the adapter extras). The rows are the runner's own lines, no
  recomputation — the single source for every derived number.
- `bench/MATRIX.md` — generated after EVERY bench run by
  `core/py/bench/bench_matrix.py` from the **latest snapshot per
  engine+profile combination** (max `meta.date`; a stale version of the
  same combination silently loses). It renders the per-profile tables
  (solo / prose / session / prefill / parallel columns, the columns' metric
  definitions = the report's), marks a date mismatch between the
  combinations («межсеансовое сравнение условно») and honestly shows `-`
  for a scenario a snapshot lacks. The file is deterministic — same
  snapshots, same bytes.

`bench/MATRIX.md` is the source of truth for the comparison tables
(see below); this file documents the scenarios and the methodology only —
the measurement tables live exclusively in the generated matrix.

## The scenarios

Every run executes the same four scenarios, in this order. Cross-engine
comparison is valid **only** scenario-to-scenario, on the same fixture
md5.

### 1. Solo decode — the canonical fixture

A merge_sort prompt with reasoning off
(`core/tpl/bench/merge_sort_thinking_off.txt`, md5 `253c7ac5…` — the
comparable-tau canon: same prompt bytes for every engine). `--runs N`
repeats the request; the report prints per-run wall time, prompt and
completion tokens, and the **decode throughput** (completion tokens / wall
of the completion phase) with the median. This is the headline decode
number: a long generation on a fixed context, no cache reuse involved.

### 2. Short prose request

A short prompt (~25 tokens), 400 completion tokens forced. Measures decode
throughput on a trivial context — the "typewriter" rate without prefill
weight. Compared with scenario 1 it shows how much a real prompt context
costs the decoder.

### 3. Agent session — 15 turns + follow-up cache

The agent-workload emulation: 15 consecutive turns where each turn's
prompt grows by the previous answer (6.4k → 7.2k prompt tokens), then a
25k-token document follow-up in two turns (turn 1 = the 25k prefill,
turn 2 = the warm re-read). Per turn the report prints wall time, tokens,
decode tok/s and — when the engine supplies timings — `prompt_ms`, the
engine's own prompt-processing time. The aggregate session wall is the
headline; the follow-up turn 1 is the prefill data source (see Prefill).

**The follow-up turn 1 is a guaranteed cache miss**: since 2026-11-27 the
runner prefixes the document with a per-run nonce (`time_ns`), invalidating
the whole prompt's prefix cache — the disk tier can no longer remember the
byte-identical document from a previous run. The length stays constant, so
cross-engine comparison is by tok/s. The 15-turn session document is NOT
nonce'd (its canon is byte-identity across engines), so session walls are
warm-cache numbers whenever the same fixture was prefilled earlier — see
the matrix caveat below.

### 4. Parallel load

`--parallel N[,M…]` (default `2,4`, 1..8 possible): N concurrent clients
each issue the merge_sort request; the report prints the aggregate
throughput (Σ completion tokens / wall — a ratio of sums), each request's
own wall, and the aggregate as a percentage of the solo decode. 100 %+ is
a batching/queueing win; far below 100 % means the engine serializes
clients.

## Prefill — read the numbers carefully

The honest prefill rate is measurable **only on a cache miss**. The bench
documents are byte-identical between runs and the disk cache tier survives
server restarts, so a "first" turn is often a cache hit in disguise. The
arbiters: the `reuse` marker, the engine cache counters
(`cache_prompt_tokens_saved_total`), and the `prompt_ms` timing itself.

**The trap, demonstrated live (halogen/flash, 2026-11-27)**: the same
25k-token prompt was sent twice, the second time after the first had
populated the cache:

- cold (unique prompt prefix → guaranteed miss): `prompt_ms` = **11 746 ms**
  for 25 121 tokens → **~2 140 tok/s**;
- warm (the identical prompt, immediately repeated): `prompt_ms` = **122 ms**.

Dividing the full 25k prompt length by the warm 122 ms gives the absurd
"200 000 tok/s" — that is the cache talking, not the engine. This probe is
now the permanent behavior: the follow-up turn 1 always carries a per-run
nonce (see scenario 3) — **every prefill number in the matrix is an
honest cache miss** (confirmed: the halogen nonce run reproduced the probe
within 4 % — 12.13 s vs 11.75 s).

## The matrix — where the numbers live

**[MATRIX.md](MATRIX.md)** — the comparative table of the latest run of
every engine+profile combination, regenerated automatically by every
`lctl bench` run from the `<combo>.json` snapshots (see the artifacts
section above). It carries the three per-profile tables (solo / prose /
session / prefill / parallel columns) and the reading caveats:

- the 15-turn session walls are **warm-cache** (the session document is
  not nonce'd) — compare sessions within one matrix session only; the
  prefill column is not affected (nonce = a guaranteed miss);
- multi-slot profiles do not beat the solo profiles at parallel-2 — the
  multi-slot wins appear at parallel-4;
- engines that do not emit a `reuse` marker are still honestly measured
  (the nonce guarantees the miss); a `reuse=live` on turn 2 additionally
  confirms the engine's live cache.

The prefill column is a guaranteed cache miss for every engine (the
per-run nonce), so it compares honestly — see the Prefill section above.
The measurement history lives in this directory's git (each report file
is overwritten on the next run of the same combination; the lab's
commits are the archive).
