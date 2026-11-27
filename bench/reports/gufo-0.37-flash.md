# bench gufo 0.37 — профиль flash

- дата: 2026-11-28T00:40:18+0300 | движок: gufo (версия 0.37)
- профиль: flash | модель: qwen3.8-flash-next
- фикстура: merge_sort_thinking_off.txt (md5 253c7ac50857fe6d0e10fb0d2c5e35c0)
- параметры: runs=1, parallel=2,4 | лимит прогона: 3600с

## 1. Соло-декод (канон-фикстура, reasoning off)

| прогон | wall,с | prompt | completion | decode tok/s |
|---|---|---|---|---|
| 1 | 2.02 | 56 | 165 | 81.72 |

медиана: wall 2.02с | decode 81.72 tok/s (по 1 прогонам)

## 2. Короткий проза-запрос

| прогон | wall,с | prompt | completion | decode tok/s |
|---|---|---|---|---|
| 1 | 9.62 | 25 | 400 | 41.58 |

медиана: wall 9.62с | decode 41.58 tok/s (по 1 прогонам)

## 3. Агентская сессия (15 ходов) + follow-up-кэш

| ход | wall,с | prompt | completion | tok/s | prompt_ms* | reuse* |
|---|---|---|---|---|---|---|
| 1 | 0.74 | 6419 | 32 | 42.94 | 88.92029 | disk |
| 2 | 0.67 | 6479 | 21 | 31.36 | 155.18924 | live |
| 3 | 0.46 | 6523 | 26 | 56.53 | 0 | disk |
| 4 | 0.63 | 6579 | 38 | 60.59 | 0 | disk |
| 5 | 0.76 | 6649 | 36 | 47.70 | 151.245766 | live |
| 6 | 0.61 | 6711 | 32 | 52.63 | 0 | disk |
| 7 | 0.50 | 6777 | 21 | 41.78 | 145.089745 | live |
| 8 | 0.36 | 6823 | 12 | 33.13 | 133.094239 | live |
| 9 | 0.58 | 6861 | 28 | 47.86 | 95.462206 | disk |
| 10 | 0.41 | 6918 | 18 | 43.79 | 95.751501 | disk |
| 11 | 0.57 | 6964 | 28 | 49.18 | 98.223048 | disk |
| 12 | 0.61 | 7021 | 31 | 50.73 | 141.156931 | live |
| 13 | 0.72 | 7082 | 31 | 43.31 | 143.458314 | live |
| 14 | 0.59 | 7142 | 33 | 56.04 | 146.487583 | live |
| 15 | 0.41 | 7206 | 19 | 46.64 | 144.268043 | live |

* из timings движка; «-» — движок timings не прислал
итого сессия: 15 ход(ов), wall суммарный 8.62с

follow-up 25k (turn 1 = a guaranteed cache miss, the per-run nonce prefix): turn1=14.54с turn2=0.84с reuse=live

## 4. Параллельная нагрузка

| N | wall,с | Σtok | aggregate tok/s | % от соло | per-request walls,с |
|---|---|---|---|---|---|
| 2 | 8.56 | 465 | 54.34 | 66% | 8.56, 3.38 |
| 4 | 9.94 | 930 | 93.55 | 114% | 7.66, 9.94, 7.65, 9.94 |

## Движковые метрики (адаптер)

- metrics_note: cumulative counters since server start; производные «средн» — Σтокены/Σвремя прогона (ratio-of-sums)
- route_spec: mtp
- route_sessions: 2
- route_ctx: 262144
- gen_avg: 48.16
- gen_last: 72.71
- prefill_avg: 1548.75
- prefill_last: 190.53
- cache_pct: 83.39
- spec_pct: 76.0
- tau: 2.23
- kv_pct: 0
- kv_peak: 25166
- tok_prompt: 25448
- tok_cached: 127735
- tok_pred: 2460
- q_proc: 0
- q_def: 0
- lookup_pct: 53.25
- device_lost: 0

## Вывод

> (заполняется человеком после прогона)
