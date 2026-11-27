# bench halogen 0.20.7 — профиль flash

- дата: 2026-11-26T20:32:31+0300 | движок: halogen (версия 0.20.7)
- профиль: flash | модель: qwen3.8-flash-next
- фикстура: merge_sort_thinking_off.txt (md5 253c7ac50857fe6d0e10fb0d2c5e35c0)
- параметры: runs=3, parallel=2,4 | лимит прогона: 3600с

## 1. Соло-декод (канон-фикстура, reasoning off)

| прогон | wall,с | prompt | completion | decode tok/s |
|---|---|---|---|---|
| 1 | 1.40 | 56 | 156 | 111.35 |
| 2 | 1.25 | 56 | 156 | 125.31 |
| 3 | 1.25 | 56 | 156 | 125.29 |

медиана: wall 1.25с | decode 125.29 tok/s (по 3 прогонам)

## 2. Короткий проза-запрос

| прогон | wall,с | prompt | completion | decode tok/s |
|---|---|---|---|---|
| 1 | 5.96 | 25 | 400 | 67.12 |
| 2 | 5.79 | 25 | 400 | 69.08 |
| 3 | 5.79 | 25 | 400 | 69.07 |

медиана: wall 5.79с | decode 69.07 tok/s (по 3 прогонам)

## 3. Агентская сессия (15 ходов) + follow-up-кэш

| ход | wall,с | prompt | completion | tok/s | prompt_ms* | reuse* |
|---|---|---|---|---|---|---|
| 1 | 0.55 | 6419 | 33 | 60.34 | 107.9 | - |
| 2 | 0.41 | 6479 | 22 | 52.97 | 110.8 | - |
| 3 | 0.46 | 6523 | 30 | 64.81 | 101.4 | - |
| 4 | 0.51 | 6582 | 39 | 76.73 | 117.5 | - |
| 5 | 0.52 | 6652 | 37 | 71.58 | 120.2 | - |
| 6 | 0.51 | 6714 | 33 | 64.65 | 110.3 | - |
| 7 | 0.38 | 6780 | 22 | 58.71 | 123.9 | - |
| 8 | 0.30 | 6826 | 15 | 49.95 | 108.8 | - |
| 9 | 0.39 | 6866 | 29 | 75.08 | 111.1 | - |
| 10 | 0.38 | 6923 | 19 | 50.66 | 114.6 | - |
| 11 | 0.44 | 6969 | 31 | 70.01 | 115.4 | - |
| 12 | 0.42 | 7028 | 32 | 76.23 | 116.3 | - |
| 13 | 0.62 | 7089 | 36 | 58.32 | 117.7 | - |
| 14 | 0.46 | 7153 | 34 | 74.19 | 116.1 | - |
| 15 | 0.50 | 7217 | 33 | 66.27 | 118.3 | - |

* из timings движка; «-» — движок timings не прислал
итого сессия: 15 ход(ов), wall суммарный 6.83с

follow-up 25k: turn1=1.98с turn2=1.05с reuse=-

## 4. Параллельная нагрузка

| N | wall,с | Σtok | aggregate tok/s | % от соло | per-request walls,с |
|---|---|---|---|---|---|
| 2 | 5.24 | 456 | 87.00 | 69% | 5.24, 2.10 |
| 4 | 7.51 | 912 | 121.42 | 97% | 7.42, 3.28, 7.51, 3.22 |

## Движковые метрики (адаптер)

- metrics_note: halogen /metrics — кумулятивные счётчики с старта сервера
- route_spec: halogen 0.20.7
- slots: 4
- context: 262144
- engine_up: 1
- requests_total: 36
- busy_for_seconds: 0
- cache_hits_total: 30
- cache_misses_total: 7
- cache_hit_pct: 81.1
- cache_prompt_tokens_saved_total: 152771
- cache_entries: 19
- cache_bytes: 1152374396
- cache_evicted_total: 8
- cache_disk_bytes: 4019845928
- cache_disk_budget_bytes: 68719476736
- cache_disk_hits_total: 4
- draft_tokens_total: 2937
- draft_tokens_accepted_total: 2365
- draft_accept_pct: 80.5
- kv_pool_positions: 524288
- kv_pool_reserved_tokens: 0
- kv_reserved_pct: 0.0
- kv_pool_waiting: 0
- queue_waited_total: 0
- queue_wait_longest_seconds: 0
- queue_gave_up_total: 0

## Вывод

> (заполняется человеком после прогона)
