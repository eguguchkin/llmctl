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
  `core/tpl/python/bench/bench_matrix.py` from the **latest snapshot per
  engine+profile combination** (max `meta.date`; a stale version of the
  same combination silently loses). It renders the per-profile tables
  (solo / prose / session / prefill / parallel columns, the columns' metric
  definitions = the report's), marks a date mismatch between the
  combinations («межсеансовое сравнение условно») and honestly shows `-`
  for a scenario a snapshot lacks. The file is deterministic — same
  snapshots, same bytes.

Going forward `bench/MATRIX.md` is the source of truth for the comparison
tables; the hand-written matrix below is the historical 2026-11-27 record
(taken right before the snapshot mechanic landed — its numbers are the
same nonce run, just transcribed by hand).

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
nonce (see scenario 3) — **every prefill number in the matrix below is an
honest cache miss** (confirmed: the halogen nonce run reproduced the probe
within 4 % — 12.13 s vs 11.75 s).

## flash profile — engine comparison (2026-11-27, `--runs 1`, FAEX 128 GB, nonce run)

Medians; decode/aggregates in tok/s, walls in seconds. The 25k prefill
column is a guaranteed cache miss for every engine (per-run nonce), so it
compares honestly.

| engine | solo decode, tok/s | prose, tok/s | session 15, s | 25k prefill (miss), s → tok/s | par-2, tok/s | par-4, tok/s |
|---|---|---|---|---|---|---|
| **halogen 0.20.7** | **112.87** | **67.80** | **6.74** | **12.13 → ~2 060** | **87.57** | **119.23** |
| hipfire 0.4.7 | 76.01 | 45.41 | 13.36 | 14.84 → ~1 685 | 42.00 | 60.69 |
| gufo 0.36 (MTP) | 81.57 | 41.04 | 8.96 | 16.68 → ~1 500 | 54.34 | 65.16 |

halogen leads every column; the prefill ladder (halogen ~2 060 > hipfire
~1 685 > gufo ~1 500 tok/s) roughly mirrors the decode ladder.

## 27b profile — engine comparison (same session)

| engine | solo decode, tok/s | prose, tok/s | session 15, s | 25k prefill (miss), s → tok/s | par-2, tok/s | par-4, tok/s |
|---|---|---|---|---|---|---|
| gufo 0.36 | 67.83 | **20.53** | **14.73** | 50.39 → ~500 | 26.27 | 27.98 |
| **hipfire 0.4.7** | **100.48** | 19.66 | 20.68 | **26.94 → ~930** | **26.86** | **26.81** |

hipfire wins solo decode by ~49 % and prefills ~1.9× faster; gufo wins
prose and the session wall. The gufo honest prefill is triple-consistent
across runs: 47.25 s ≈ 530 tok/s (the day's first run, confirmed by the
session turn 1 at 11.6 s ≈ 550 and the engine's `prefill_avg` 499 tok/s),
50.39 s ≈ 496 tok/s (this nonce run).

## 27b-parallel profile — engine comparison (same session)

| engine | solo decode, tok/s | prose, tok/s | session 15, s | 25k prefill (miss), s → tok/s | par-2, tok/s | par-4, tok/s |
|---|---|---|---|---|---|---|
| gufo 0.36 | 67.46 | **20.49** | **14.62** | 50.64 → ~494 | **29.10** | **41.64** |
| **hipfire 0.4.7** | **93.00** | 15.40 | 30.04 | **34.59 → ~723** | 20.04 | 27.13 |

halogen does not ship a 27b profile (the owner's 2026-11-25 decision).

## Matrix caveats

- **Session walls are warm-cache** in this matrix: the 15-turn document is
  not nonce'd and was already in the disk tier from the same day's first
  run (gufo/27b: 14.73 s here vs 25.89 s on the day's cold first pass).
  Do not compare them to a cold-cache session; the prefill column is not
  affected (nonce = guaranteed miss).
- **Multi-slot profiles do not beat the solo profiles at parallel-2**
  (gufo 27b: 26.27 vs 26.27; hipfire 27b: 26.86 vs 26.86) — consistent
  with the earlier serial-DFlash finding; the wins appear at parallel-4
  (gufo 27b-parallel 41.64, halogen 119.23 at 106 % of solo).
- Engines that do not emit a `reuse` marker (halogen, hipfire: `reuse=-`)
  are still honestly measured — the nonce guarantees the miss without the
  marker; gufo's `reuse=live` on turn 2 additionally confirms its live
  cache works.
