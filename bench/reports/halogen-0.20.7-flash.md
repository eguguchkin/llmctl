# bench halogen 0.20.7 — профиль flash

- дата: 2026-11-27T16:15:55+0300 | движок: halogen (версия 0.20.7)
- профиль: flash | модель: qwen3.8-flash-next
- фикстура: merge_sort_thinking_off.txt (md5 253c7ac50857fe6d0e10fb0d2c5e35c0)
- параметры: runs=1, parallel=2,4 | лимит прогона: 3600с

## 1. Соло-декод (канон-фикстура, reasoning off)

| прогон | wall,с | prompt | completion | decode tok/s |
|---|---|---|---|---|
| 1 | 1.38 | 56 | 156 | 112.87 |

медиана: wall 1.38с | decode 112.87 tok/s (по 1 прогонам)

## 2. Короткий проза-запрос

| прогон | wall,с | prompt | completion | decode tok/s |
|---|---|---|---|---|
| 1 | 5.90 | 25 | 400 | 67.80 |

медиана: wall 5.90с | decode 67.80 tok/s (по 1 прогонам)

## 3. Агентская сессия (15 ходов) + follow-up-кэш

| ход | wall,с | prompt | completion | tok/s | prompt_ms* | reuse* |
|---|---|---|---|---|---|---|
| 1 | 0.54 | 6419 | 33 | 61.50 | 97.5 | - |
| 2 | 0.41 | 6479 | 22 | 53.71 | 108.8 | - |
| 3 | 0.46 | 6523 | 30 | 65.35 | 100.6 | - |
| 4 | 0.50 | 6582 | 39 | 77.38 | 117.1 | - |
| 5 | 0.51 | 6652 | 37 | 72.77 | 118.8 | - |
| 6 | 0.51 | 6714 | 33 | 65.36 | 109.0 | - |
| 7 | 0.37 | 6780 | 22 | 59.32 | 123.8 | - |
| 8 | 0.30 | 6826 | 15 | 50.41 | 107.4 | - |
| 9 | 0.38 | 6866 | 29 | 76.20 | 109.7 | - |
| 10 | 0.37 | 6923 | 19 | 51.40 | 115.2 | - |
| 11 | 0.43 | 6969 | 31 | 71.50 | 115.1 | - |
| 12 | 0.41 | 7028 | 32 | 77.71 | 117.2 | - |
| 13 | 0.61 | 7089 | 36 | 59.27 | 117.1 | - |
| 14 | 0.45 | 7153 | 34 | 75.30 | 115.1 | - |
| 15 | 0.49 | 7217 | 33 | 66.94 | 118.2 | - |

* из timings движка; «-» — движок timings не прислал
итого сессия: 15 ход(ов), wall суммарный 6.74с

follow-up 25k (turn 1 = a guaranteed cache miss, the per-run nonce prefix): turn1=12.13с turn2=1.05с reuse=-

## 4. Параллельная нагрузка

| N | wall,с | Σtok | aggregate tok/s | % от соло | per-request walls,с |
|---|---|---|---|---|---|
| 2 | 5.21 | 456 | 87.57 | 78% | 5.21, 2.23 |
| 4 | 7.65 | 912 | 119.23 | 106% | 7.65, 3.35, 7.59, 3.29 |

## Движковые метрики (адаптер)

- metrics_note: halogen /metrics — кумулятивные счётчики с старта сервера
- route_spec: halogen 0.20.7
- slots: 4
- context: 262144
- engine_up: 1
- requests_total: 34
- busy_for_seconds: 0
- cache_hits_total: 26
- cache_misses_total: 9
- cache_hit_pct: 74.3
- cache_prompt_tokens_saved_total: 152591
- cache_entries: 25
- cache_bytes: 1516282100
- cache_evicted_total: 7
- cache_disk_bytes: 12434993512
- cache_disk_budget_bytes: 68719476736
- cache_disk_hits_total: 3
- draft_tokens_total: 2114
- draft_tokens_accepted_total: 1726
- draft_accept_pct: 81.6
- kv_pool_positions: 524288
- kv_pool_reserved_tokens: 0
- kv_reserved_pct: 0.0
- kv_pool_waiting: 0
- queue_waited_total: 0
- queue_wait_longest_seconds: 0
- queue_gave_up_total: 0

## Вывод

> (заполняется человеком после прогона)
