# bench halogen 0.21.0 — профиль flash

- дата: 2026-11-28T00:37:37+0300 | движок: halogen (версия 0.21.0)
- профиль: flash | модель: qwen3.8-flash-next
- фикстура: merge_sort_thinking_off.txt (md5 253c7ac50857fe6d0e10fb0d2c5e35c0)
- параметры: runs=1, parallel=2,4 | лимит прогона: 3600с

## 1. Соло-декод (канон-фикстура, reasoning off)

| прогон | wall,с | prompt | completion | decode tok/s |
|---|---|---|---|---|
| 1 | 1.38 | 56 | 156 | 112.99 |

медиана: wall 1.38с | decode 112.99 tok/s (по 1 прогонам)

## 2. Короткий проза-запрос

| прогон | wall,с | prompt | completion | decode tok/s |
|---|---|---|---|---|
| 1 | 5.92 | 25 | 400 | 67.52 |

медиана: wall 5.92с | decode 67.52 tok/s (по 1 прогонам)

## 3. Агентская сессия (15 ходов) + follow-up-кэш

| ход | wall,с | prompt | completion | tok/s | prompt_ms* | reuse* |
|---|---|---|---|---|---|---|
| 1 | 0.55 | 6419 | 33 | 60.13 | 99.6 | - |
| 2 | 0.41 | 6479 | 22 | 53.53 | 110.4 | - |
| 3 | 0.46 | 6523 | 30 | 65.50 | 101.1 | - |
| 4 | 0.51 | 6582 | 39 | 77.03 | 117.5 | - |
| 5 | 0.51 | 6652 | 37 | 72.49 | 120.3 | - |
| 6 | 0.51 | 6714 | 33 | 65.29 | 110.2 | - |
| 7 | 0.37 | 6780 | 22 | 59.23 | 123.7 | - |
| 8 | 0.30 | 6826 | 15 | 50.13 | 109.2 | - |
| 9 | 0.38 | 6866 | 29 | 75.52 | 111.1 | - |
| 10 | 0.37 | 6923 | 19 | 51.32 | 114.5 | - |
| 11 | 0.44 | 6969 | 31 | 71.02 | 115.6 | - |
| 12 | 0.41 | 7028 | 32 | 77.89 | 116.3 | - |
| 13 | 0.61 | 7089 | 36 | 58.89 | 118.0 | - |
| 14 | 0.45 | 7153 | 34 | 75.27 | 116.3 | - |
| 15 | 0.49 | 7217 | 33 | 66.73 | 118.7 | - |

* из timings движка; «-» — движок timings не прислал
итого сессия: 15 ход(ов), wall суммарный 6.77с

follow-up 25k (turn 1 = a guaranteed cache miss, the per-run nonce prefix): turn1=12.18с turn2=0.98с reuse=-

## 4. Параллельная нагрузка

| N | wall,с | Σtok | aggregate tok/s | % от соло | per-request walls,с |
|---|---|---|---|---|---|
| 2 | 5.28 | 456 | 86.44 | 77% | 5.27, 2.11 |
| 4 | 7.67 | 912 | 118.95 | 105% | 7.67, 3.28, 7.60, 3.11 |

## Движковые метрики (адаптер)

- metrics_note: halogen /metrics — кумулятивные счётчики с старта сервера
- route_spec: halogen 0.21.0
- slots: 4
- context: 262144
- engine_up: 1
- requests_total: 32
- busy_for_seconds: 0
- cache_hits_total: 23
- cache_misses_total: 10
- cache_hit_pct: 69.7
- cache_prompt_tokens_saved_total: 127183
- cache_entries: 21
- cache_bytes: 1273676964
- cache_evicted_total: 8
- cache_disk_bytes: 7095162752
- cache_disk_budget_bytes: 68719476736
- cache_disk_hits_total: 1
- draft_tokens_total: 1947
- draft_tokens_accepted_total: 1587
- draft_accept_pct: 81.5
- kv_pool_positions: 524288
- kv_pool_reserved_tokens: 0
- kv_reserved_pct: 0.0
- kv_pool_waiting: 0
- queue_waited_total: 0
- queue_wait_longest_seconds: 0
- queue_gave_up_total: 0

## Вывод

> (заполняется человеком после прогона)
