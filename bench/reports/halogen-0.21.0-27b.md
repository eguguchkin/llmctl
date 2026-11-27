# bench halogen 0.21.0 — профиль 27b

- дата: 2026-11-28T02:19:06+0300 | движок: halogen (версия 0.21.0)
- профиль: 27b | модель: halogen-qwen3.8-27b
- фикстура: merge_sort_thinking_off.txt (md5 253c7ac50857fe6d0e10fb0d2c5e35c0)
- параметры: runs=1, parallel=2,4 | лимит прогона: 3600с

## 1. Соло-декод (канон-фикстура, reasoning off)

| прогон | wall,с | prompt | completion | decode tok/s |
|---|---|---|---|---|
| 1 | 2.19 | 56 | 156 | 71.11 |

медиана: wall 2.19с | decode 71.11 tok/s (по 1 прогонам)

## 2. Короткий проза-запрос

| прогон | wall,с | prompt | completion | decode tok/s |
|---|---|---|---|---|
| 1 | 12.94 | 25 | 400 | 30.92 |

медиана: wall 12.94с | decode 30.92 tok/s (по 1 прогонам)

## 3. Агентская сессия (15 ходов) + follow-up-кэш

| ход | wall,с | prompt | completion | tok/s | prompt_ms* | reuse* |
|---|---|---|---|---|---|---|
| 1 | 9.74 | 6419 | 33 | 3.39 | 9141.9 | - |
| 2 | 0.74 | 6479 | 19 | 25.68 | 139.0 | - |
| 3 | 0.53 | 6520 | 20 | 37.84 | 129.0 | - |
| 4 | 1.00 | 6569 | 37 | 37.07 | 136.3 | - |
| 5 | 1.18 | 6637 | 39 | 33.01 | 138.3 | - |
| 6 | 0.53 | 6701 | 21 | 39.96 | 132.7 | - |
| 7 | 0.60 | 6755 | 22 | 36.74 | 159.1 | - |
| 8 | 0.38 | 6801 | 13 | 34.03 | 132.9 | - |
| 9 | 0.61 | 6839 | 29 | 47.20 | 132.9 | - |
| 10 | 0.61 | 6896 | 21 | 34.17 | 138.5 | - |
| 11 | 0.65 | 6944 | 29 | 44.51 | 135.7 | - |
| 12 | 0.78 | 7001 | 32 | 41.26 | 137.6 | - |
| 13 | 0.71 | 7062 | 31 | 43.79 | 139.5 | - |
| 14 | 0.74 | 7121 | 34 | 45.78 | 138.6 | - |
| 15 | 0.58 | 7185 | 20 | 34.44 | 143.8 | - |

* из timings движка; «-» — движок timings не прислал
итого сессия: 15 ход(ов), wall суммарный 19.39с

follow-up 25k (turn 1 = a guaranteed cache miss, the per-run nonce prefix): turn1=40.17с turn2=3.15с reuse=-

## 4. Параллельная нагрузка

| N | wall,с | Σtok | aggregate tok/s | % от соло | per-request walls,с |
|---|---|---|---|---|---|
| 2 | 10.36 | 456 | 44.04 | 62% | 10.35, 3.74 |
| 4 | 13.85 | 912 | 65.86 | 93% | 13.85, 7.08, 13.68, 6.53 |

## Движковые метрики (адаптер)

- metrics_note: halogen /metrics — кумулятивные счётчики с старта сервера
- route_spec: halogen 0.21.0
- slots: 4
- context: 262144
- engine_up: 1
- requests_total: 27
- busy_for_seconds: 0
- cache_hits_total: 22
- cache_misses_total: 6
- cache_hit_pct: 78.6
- cache_prompt_tokens_saved_total: 147480
- cache_entries: 18
- cache_bytes: 2790347112
- cache_evicted_total: 5
- cache_disk_bytes: 16109401960
- cache_disk_budget_bytes: 68719476736
- cache_disk_hits_total: 1
- draft_tokens_total: 2140
- draft_tokens_accepted_total: 1486
- draft_accept_pct: 69.4
- kv_pool_positions: 524288
- kv_pool_reserved_tokens: 0
- kv_reserved_pct: 0.0
- kv_pool_waiting: 0
- queue_waited_total: 0
- queue_wait_longest_seconds: 0
- queue_gave_up_total: 0

## Вывод

> (заполняется человеком после прогона)
