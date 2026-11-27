# bench matrix — the latest run of every combination

- snapshot dates: 2026-11-28
- methodology and caveats: bench/README.md

## profile 27b

| engine | solo tok/s | prose tok/s | session 15, s | 25k prefill (miss), s → tok/s | par-2 tok/s | par-4 tok/s |
|---|---|---|---|---|---|---|
| gufo 0.37 | 71.04 | 20.49 | 14.56 | 50.77 → 494 tok/s | 27.74 | 27.98 |
| halogen 0.21.0 | 71.11 | 30.92 | 19.39 | 40.17 → 625 tok/s | 44.04 | 65.86 |
| hipfire 0.4.8 | 100.61 | 19.65 | 20.67 | 26.98 → 930 tok/s | 26.89 | 26.83 |

## profile 27b-parallel

| engine | solo tok/s | prose tok/s | session 15, s | 25k prefill (miss), s → tok/s | par-2 tok/s | par-4 tok/s |
|---|---|---|---|---|---|---|
| gufo 0.37 | 68.76 | 20.44 | 14.83 | 50.88 → 493 tok/s | 29.02 | 43.07 |
| hipfire 0.4.8 | 92.86 | 15.41 | 30.02 | 34.55 → 726 tok/s | 20.02 | 26.32 |

## profile flash

| engine | solo tok/s | prose tok/s | session 15, s | 25k prefill (miss), s → tok/s | par-2 tok/s | par-4 tok/s |
|---|---|---|---|---|---|---|
| gufo 0.37 | 81.72 | 41.58 | 8.62 | 14.54 → 1 726 tok/s | 54.34 | 93.55 |
| halogen 0.21.0 | 112.99 | 67.52 | 6.77 | 12.18 → 2 061 tok/s | 86.44 | 118.95 |
| hipfire 0.4.8 | 75.91 | 45.41 | 13.43 | 15.19 → 1 652 tok/s | 53.80 | 56.86 |

## How to read

- the 15-turn session is **warm-cache** (the session document is not nonce'd): compare sessions within one matrix session only; the prefill column is not affected (the nonce = a guaranteed miss)
- multi-slot profiles do not beat the solo profiles at parallel-2 — the multi-slot win appears at parallel-4
- engines that emit no reuse marker ("-") are still measured honestly — the nonce guarantees the miss without the marker; a "live" on turn 2 additionally confirms the live cache
- prefill: s → tok/s = prompt_tokens/wall of turn 1 (a guaranteed cache miss); the methodology and the cache trap — bench/README.md

