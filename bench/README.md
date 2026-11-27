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

The honest prefill rate is measurable **only on a cache miss** — and the
bench documents are byte-identical between runs while the disk cache tier
survives server restarts, so a "first" turn is often a cache hit in
disguise. The arbiters are the `reuse` marker and the engine's own cache
counters (`cache_prompt_tokens_saved_total`).

Evidence from the 2026-11-27 matrix — the honest rate is a few hundred
tok/s, not thousands:

- **gufo / 27b — three independent numbers agree**: the 25k follow-up
  turn 1 (reuse=none) took 47.25 s → **~530 tok/s**; the session document
  on turn 1 (reuse=none, 6.4k tokens) took 11.6 s → **~550 tok/s**; the
  engine's own `prefill_avg` counter over the session = **499 tok/s**.
- **gufo / flash**: follow-up turn 1 = 2.71 s with `reuse=live` — a cache
  hit, not a cold run. No honest cold prefill measured.
- **halogen / flash**: follow-up turn 1 = 1.96 s with no reuse marker, but
  the identical 25k document was in the persistent disk cache from the
  previous day's runs (`cache_prompt_tokens_saved_total` ≈ 398k tokens in
  the same session). Not cold either — no honest number in the matrix.
- **hipfire**: no reuse markers at all; the follow-up walls (27b: 26.83 s
  ≈ 930 tok/s; 27b-parallel: 34.24 s ≈ 730 tok/s; flash: 15.08 s ≈ 1660
  tok/s) are *likely* honest cold runs (the first hipfire runs of the
  day), but the engine cannot confirm it.

The session table's `prompt_ms` column is the engine's prompt-processing
timing **after the cache** — on warm turns it covers only the new tail
(~60–100 tokens), not the whole context. It must never be divided into
the full prompt length.

## The 2026-11-27 matrix (a 128 GB Strix Halo, `--runs 1`, one session)

Medians; decode/aggregates in tok/s, walls in seconds. `runs=1` — an
orientation point, not an acceptance run.

| engine / profile | solo decode, tok/s | prose, tok/s | session 15, s | 25k prefill, s → tok/s | par-2, tok/s | par-4, tok/s |
|---|---|---|---|---|---|---|
| **halogen / flash** | **112.92** | **67.58** | **6.76** | 1.96 (cache hit) | **86.92** | **121.70** |
| gufo / flash (MTP) | 81.44 | 41.60 | 8.62 | 2.71 (cache hit) | 53.21 | 71.66 |
| gufo / 27b (solo) | 65.18 | 20.34 | 25.89 | **47.25 → ~530** | 27.30 | 27.88 |
| gufo / 27b-parallel | 64.93 | 20.32 | 26.00 | 47.25 → ~529 | 29.05 | 43.20 |
| hipfire / 27b | 100.63 | 19.67 | 20.65 | 26.83 → ~930* | 26.84 | 26.84 |
| hipfire / 27b-parallel | 92.95 | 15.40 | 30.05 | 34.24 → ~730* | 20.04 | 28.14 |
| hipfire / flash | 75.88 | 45.88 | 13.38 | 15.08 → ~1660* | 41.90 | 56.43 |

\* hipfire sends no reuse marker — likely cold (the first hipfire runs of
the day), not confirmed by the engine.

Readings: halogen leads every decode/aggregation column; the honest
prefill of the 27B quant is ~530 tok/s (gufo, triple-confirmed) — a
25k-token document costs ~47 s of prefill on a cache miss; the multi-slot
profiles do not beat the solo profiles at parallel-2.

Readings: halogen leads every column (its warm prefill is ~60k tok/s —
a 6.5k context is re-prefilled in ~110 ms); gufo's flash-MTP halves the
cold 25k prefill against its 27b (2.7 s vs 47.3 s — the smaller weights
and MTP); the multi-slot profiles do not beat the solo profiles at
parallel-2; hipfire supplies no per-request timings, so its warm-prefill
column is empty while its cold-25k walls are client-measured and honest.
