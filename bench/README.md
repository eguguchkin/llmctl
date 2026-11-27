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
25k-token document follow-up in two turns (turn 1 = the 25k prefill,
turn 2 = the warm re-read). Per turn the report prints wall time, tokens,
decode tok/s and — when the engine supplies timings — `prompt_ms`, the
engine's own prompt-processing time. The aggregate session wall is the
headline; the follow-up turn 1 is the prefill data source (see Prefill).

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
"200 000 tok/s" — that is the cache talking, not the engine. The engine's
honest prefill rate on this profile is ~2 100 tok/s (a 25k document costs
~12 s of prefill on a miss).

Per-combination prefill figures in the matrices below are marked:
`honest` — a proven cache miss; `cache hit` — the wall is real but the
prefill was served from the cache; `likely cold` — no reuse marker, the
first run of the day, unconfirmed by the engine.

## flash profile — engine comparison (2026-11-27, `--runs 1`, FAEX 128 GB)

Medians; decode/aggregates in tok/s, walls in seconds.

| engine | solo decode, tok/s | prose, tok/s | session 15, s | 25k prefill | par-2, tok/s | par-4, tok/s |
|---|---|---|---|---|---|---|
| **halogen 0.20.7** | **112.92** | **67.58** | **6.76** | **11.7 s ≈ 2 140 tok/s** (honest, cold probe) | **86.92** | **121.70** |
| gufo 0.36 | 81.44 | 41.60 | 8.62 | not measured (cache hit) | 53.21 | 71.66 |
| hipfire 0.4.7 | 75.88 | 45.88 | 13.38 | 15.08 s ≈ 1 660 tok/s (likely cold) | 41.90 | 56.43 |

## 27b profile — engine comparison (same session)

| engine | solo decode, tok/s | prose, tok/s | session 15, s | 25k prefill | par-2, tok/s | par-4, tok/s |
|---|---|---|---|---|---|---|
| gufo 0.36 | 65.18 | 20.34 | **25.89** | **47.25 s ≈ 530 tok/s** (honest, triple-confirmed) | 27.30 | 27.88 |
| **hipfire 0.4.7** | **100.63** | 19.67 | **20.65** | 26.83 s ≈ 930 tok/s (likely cold) | 26.84 | 26.84 |

hipfire wins solo decode by 55 % (the mq4-xts quant + VMM); gufo wins the
prose scenario and the honest prefill is slower (530 tok/s) — but it is
the only triple-confirmed number here (the follow-up wall, the session
document turn 1, and the engine's own `prefill_avg` counter: 47.25 s /
11.6 s / 499 tok/s).

## 27b-parallel profile — engine comparison (same session)

| engine | solo decode, tok/s | prose, tok/s | session 15, s | 25k prefill | par-2, tok/s | par-4, tok/s |
|---|---|---|---|---|---|---|
| gufo 0.36 | 64.93 | **20.32** | **26.00** | 47.25 s ≈ 529 tok/s | **29.05** | **43.20** |
| **hipfire 0.4.7** | **92.95** | 15.40 | 30.05 | 34.24 s ≈ 730 tok/s (likely cold) | 20.04 | 28.14 |

halogen does not ship a 27b profile (the owner's 2026-11-25 decision).

## Missing honest numbers — how to fill them

An honest cold prefill needs a **guaranteed cache miss**. Two ways:
a unique prompt prefix (the cold probe demonstrated above — no engine
restart needed, read-only load over the live port), or wiping the engine's
disk cache tier (needs a maintenance window and the owner's GO). Not yet
measured honestly: gufo/flash (its follow-up turn 1 was a `reuse=live`
cache hit), halogen's full `lctl bench` pass (the probe above covers the
25k point), hipfire confirmations.
