# bench gufo 0.36 — профиль flash

- дата: 2026-11-27T20:42:57+0300 | движок: gufo (версия 0.36)
- профиль: flash | модель: qwen3.8-flash-next
- фикстура: merge_sort_thinking_off.txt (md5 253c7ac50857fe6d0e10fb0d2c5e35c0)
- параметры: runs=1, parallel=2,4 | лимит прогона: 3600с

## 1. Соло-декод (канон-фикстура, reasoning off)

| прогон | wall,с | prompt | completion | decode tok/s |
|---|---|---|---|---|
| 1 | 2.04 | 56 | 165 | 80.95 |

медиана: wall 2.04с | decode 80.95 tok/s (по 1 прогонам)

## 2. Короткий проза-запрос

| прогон | wall,с | prompt | completion | decode tok/s |
|---|---|---|---|---|
| 1 | 9.62 | 25 | 400 | 41.57 |

медиана: wall 9.62с | decode 41.57 tok/s (по 1 прогонам)

## 3. Агентская сессия (15 ходов) + follow-up-кэш

| ход | wall,с | prompt | completion | tok/s | prompt_ms* | reuse* |
|---|---|---|---|---|---|---|
| 1 | 0.75 | 6419 | 32 | 42.90 | 88.642446 | disk |
| 2 | 0.67 | 6479 | 21 | 31.26 | 158.301199 | live |
| 3 | 0.47 | 6523 | 26 | 55.15 | 0 | disk |
| 4 | 0.63 | 6579 | 38 | 59.95 | 0 | disk |
| 5 | 0.74 | 6649 | 36 | 48.56 | 145.71424 | live |
| 6 | 0.61 | 6711 | 32 | 52.46 | 0 | disk |
| 7 | 0.50 | 6777 | 21 | 41.64 | 145.797154 | live |
| 8 | 0.36 | 6823 | 12 | 33.60 | 132.448746 | live |
| 9 | 0.57 | 6861 | 28 | 49.41 | 94.770524 | disk |
| 10 | 0.44 | 6918 | 18 | 40.55 | 95.941082 | disk |
| 11 | 0.57 | 6964 | 28 | 48.77 | 98.284862 | disk |
| 12 | 0.63 | 7021 | 31 | 49.09 | 143.618079 | live |
| 13 | 0.71 | 7082 | 31 | 43.49 | 142.028305 | live |
| 14 | 0.59 | 7142 | 33 | 56.27 | 145.089404 | live |
| 15 | 0.41 | 7206 | 19 | 46.06 | 144.420795 | live |

* из timings движка; «-» — движок timings не прислал
итого сессия: 15 ход(ов), wall суммарный 8.66с

follow-up 25k (turn 1 = a guaranteed cache miss, the per-run nonce prefix): turn1=17.25с turn2=1.04с reuse=live

## 4. Параллельная нагрузка

| N | wall,с | Σtok | aggregate tok/s | % от соло | per-request walls,с |
|---|---|---|---|---|---|
| 2 | 8.55 | 465 | 54.38 | 67% | 8.55, 3.37 |
| 4 | 9.99 | 930 | 93.11 | 115% | 7.65, 9.99, 7.65, 9.98 |

## Движковые метрики (адаптер)

- metrics_note: cumulative counters since server start; производные «средн» — Σтокены/Σвремя прогона (ratio-of-sums)
- route_spec: mtp
- route_sessions: 2
- route_ctx: 262144
- gen_avg: 47.6
- gen_last: 71.06
- prefill_avg: 1553.39
- prefill_last: 197.52
- cache_pct: 83.4
- spec_pct: 74.83
- tau: 2.17
- kv_pct: 0
- kv_peak: 25284
- tok_prompt: 25448
- tok_cached: 127846
- tok_pred: 2578
- q_proc: 0
- q_def: 0
- lookup_pct: 54.02
- device_lost: 0

## Вывод

> (заполняется человеком после прогона)
