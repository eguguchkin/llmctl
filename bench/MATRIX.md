# bench matrix — the latest run of every combination

- snapshot dates: 2026-11-27
- methodology and caveats: bench/README.md

## profile 27b

| engine | solo tok/s | prose tok/s | session 15, s | 25k prefill (miss), s → tok/s | par-2 tok/s | par-4 tok/s |
|---|---|---|---|---|---|---|
| gufo 0.36 | 71.44 | 20.54 | 14.63 | 50.65 → 495 tok/s | 27.83 | 28.01 |
| hipfire 0.4.7 | 100.47 | 19.65 | 20.67 | 26.93 → 932 tok/s | 26.86 | 26.80 |

## profile 27b-parallel

| engine | solo tok/s | prose tok/s | session 15, s | 25k prefill (miss), s → tok/s | par-2 tok/s | par-4 tok/s |
|---|---|---|---|---|---|---|
| gufo 0.36 | 69.56 | 20.46 | 14.48 | 50.55 → 496 tok/s | 29.14 | 43.14 |
| hipfire 0.4.7 | 92.90 | 15.40 | 30.04 | 34.60 → 725 tok/s | 19.96 | 28.16 |

## profile flash

| engine | solo tok/s | prose tok/s | session 15, s | 25k prefill (miss), s → tok/s | par-2 tok/s | par-4 tok/s |
|---|---|---|---|---|---|---|
| gufo 0.36 | 80.95 | 41.57 | 8.66 | 17.25 → 1 455 tok/s | 54.38 | 93.11 |
| halogen 0.20.7 | 125.12 | 69.09 | 6.60 | 12.10 → 2 074 tok/s | 87.18 | 118.94 |
| hipfire 0.4.7 | 74.75 | 45.79 | 13.38 | 13.20 → 1 901 tok/s | 53.78 | 56.77 |

## How to read

- the 15-turn session is **warm-cache** (the session document is not nonce'd): compare sessions within one matrix session only; the prefill column is not affected (the nonce = a guaranteed miss)
- multi-slot profiles do not beat the solo profiles at parallel-2 — the multi-slot win appears at parallel-4
- engines that emit no reuse marker ("-") are still measured honestly — the nonce guarantees the miss without the marker; a "live" on turn 2 additionally confirms the live cache
- prefill: s → tok/s = prompt_tokens/wall of turn 1 (a guaranteed cache miss); the methodology and the cache trap — bench/README.md

