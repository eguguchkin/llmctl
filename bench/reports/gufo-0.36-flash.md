# bench gufo 0.36 — профиль flash

- дата: 2026-11-27T16:18:44+0300 | движок: gufo (версия 0.36)
- профиль: flash | модель: qwen3.8-flash-next
- фикстура: merge_sort_thinking_off.txt (md5 253c7ac50857fe6d0e10fb0d2c5e35c0)
- параметры: runs=1, parallel=2,4 | лимит прогона: 3600с

## 1. Соло-декод (канон-фикстура, reasoning off)

| прогон | wall,с | prompt | completion | decode tok/s |
|---|---|---|---|---|
| 1 | 2.02 | 56 | 165 | 81.57 |

медиана: wall 2.02с | decode 81.57 tok/s (по 1 прогонам)

## 2. Короткий проза-запрос

| прогон | wall,с | prompt | completion | decode tok/s |
|---|---|---|---|---|
| 1 | 9.75 | 25 | 400 | 41.04 |

медиана: wall 9.75с | decode 41.04 tok/s (по 1 прогонам)

## 3. Агентская сессия (15 ходов) + follow-up-кэш

| ход | wall,с | prompt | completion | tok/s | prompt_ms* | reuse* |
|---|---|---|---|---|---|---|
| 1 | 0.91 | 6419 | 32 | 35.09 | 89.454824 | disk |
| 2 | 0.69 | 6479 | 21 | 30.63 | 159.537756 | live |
| 3 | 0.50 | 6523 | 26 | 51.77 | 0 | disk |
| 4 | 0.62 | 6579 | 38 | 60.80 | 0 | disk |
| 5 | 0.73 | 6649 | 36 | 48.96 | 145.911264 | live |
| 6 | 0.61 | 6711 | 32 | 52.53 | 0 | disk |
| 7 | 0.52 | 6777 | 21 | 40.13 | 150.31588 | live |
| 8 | 0.37 | 6823 | 12 | 32.52 | 137.136445 | live |
| 9 | 0.57 | 6861 | 28 | 49.00 | 95.102471 | disk |
| 10 | 0.48 | 6918 | 18 | 37.46 | 96.105689 | disk |
| 11 | 0.59 | 6964 | 28 | 47.70 | 100.177038 | disk |
| 12 | 0.62 | 7021 | 31 | 49.63 | 142.629778 | live |
| 13 | 0.73 | 7082 | 31 | 42.72 | 142.008707 | live |
| 14 | 0.59 | 7142 | 33 | 55.61 | 145.032326 | live |
| 15 | 0.42 | 7206 | 19 | 45.31 | 145.506384 | live |

* из timings движка; «-» — движок timings не прислал
итого сессия: 15 ход(ов), wall суммарный 8.96с

follow-up 25k (turn 1 = a guaranteed cache miss, the per-run nonce prefix): turn1=16.68с turn2=1.50с reuse=live

## 4. Параллельная нагрузка

| N | wall,с | Σtok | aggregate tok/s | % от соло | per-request walls,с |
|---|---|---|---|---|---|
| 2 | 8.56 | 465 | 54.34 | 67% | 8.56, 3.37 |
| 4 | 14.27 | 930 | 65.16 | 80% | 14.27, 5.75, 10.46, 3.01 |

## Движковые метрики (адаптер)

- metrics_note: cumulative counters since server start; производные «средн» — Σтокены/Σвремя прогона (ratio-of-sums)
- route_spec: mtp
- route_sessions: 2
- route_ctx: 262144
- gen_avg: 44.29
- gen_last: 35.24
- prefill_avg: 1548.35
- prefill_last: 195.48
- cache_pct: 83.4
- spec_pct: 74.91
- tau: 2.14
- kv_pct: 0
- kv_peak: 25309
- tok_prompt: 25448
- tok_cached: 127846
- tok_pred: 2603
- q_proc: 0
- q_def: 0
- lookup_pct: 58.0
- device_lost: 0

## Вывод

> (заполняется человеком после прогона)
