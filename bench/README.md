# bench/ — engine benchmarks

Everything in this directory is produced by `lctl bench` — the read-only
benchmark of the **running** engine (it never starts, stops or
re-configures anything; a stopped stack produces a clear error). One file
per engine+profile combination:
`reports/<engine>-<version>-<profile>.md`, rewritten on the next run of
the same combination. The header carries the date, engine, engine version,
profile, model, the fixture md5 and the run parameters — and deliberately
no host information.

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
25k-token document follow-up in two turns (turn 1 = the cold 25k prefill,
turn 2 = the warm re-read). Per turn the report prints wall time, tokens,
decode tok/s and — when the engine supplies timings — `prompt_ms`, the
engine's own prefill time. This scenario is the KV-cache/management
stress: the aggregate session wall is the headline, the per-turn
`prompt_ms` is the prefill data source.

### 4. Parallel load

`--parallel N[,M…]` (default `2,4`, 1..8 possible): N concurrent clients
each issue the merge_sort request; the report prints the aggregate
throughput (Σ completion tokens / wall — a ratio of sums), each request's
own wall, and the aggregate as a percentage of the solo decode. 100 %+ is
a batching/queueing win; far below 100 % means the engine serializes
clients.

## Prefill

Two prefill figures come from scenario 3 (computed by the report reader,
not printed by `lctl bench` directly):

- **warm prefill, tok/s** — the median over session turns 2..15 of
  (prompt tokens / `prompt_ms`): re-prefilling a ~6.5-7k context the
  engine has already seen (the cache/management efficiency);
- **cold 25k prefill, s** — the wall of the follow-up turn 1: a fresh
  25k-token document, nothing cached (the raw prefill muscle).

Engines that do not supply per-request timings show `—` in the warm
column (the cold-25k wall is still measured by the client).

## The 2026-11-27 matrix (a 128 GB Strix Halo, `--runs 1`, one session)

Medians; decode/aggregates in tok/s, walls in seconds. `runs=1` — an
orientation point, not an acceptance run.

| engine / profile | solo decode, tok/s | prose, tok/s | session 15, s | warm prefill, tok/s | cold 25k prefill, s | par-2, tok/s | par-4, tok/s |
|---|---|---|---|---|---|---|---|
| **halogen / flash** | **112.92** | **67.58** | **6.76** | **60 641** | **1.96** | **86.92** | **121.70** |
| gufo / flash (MTP) | 81.44 | 41.60 | 8.62 | 48 710 | 2.71 | 53.21 | 71.66 |
| gufo / 27b (solo) | 65.18 | 20.34 | 25.89 | 22 908 | 47.25 | 27.30 | 27.88 |
| gufo / 27b-parallel | 64.93 | 20.32 | 26.00 | 22 842 | 47.25 | 29.05 | 43.20 |
| hipfire / 27b | 100.63 | 19.67 | 20.65 | — | 26.83 | 26.84 | 26.84 |
| hipfire / 27b-parallel | 92.95 | 15.40 | 30.05 | — | 34.24 | 20.04 | 28.14 |
| hipfire / flash | 75.88 | 45.88 | 13.38 | — | 15.08 | 41.90 | 56.43 |

Readings: halogen leads every column (its warm prefill is ~60k tok/s —
a 6.5k context is re-prefilled in ~110 ms); gufo's flash-MTP halves the
cold 25k prefill against its 27b (2.7 s vs 47.3 s — the smaller weights
and MTP); the multi-slot profiles do not beat the solo profiles at
parallel-2; hipfire supplies no per-request timings, so its warm-prefill
column is empty while its cold-25k walls are client-measured and honest.
