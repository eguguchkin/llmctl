# bench halogen 0.20.7 — профиль flash

- дата: 2026-11-27T20:28:42+0300 | движок: halogen (версия 0.20.7)
- профиль: flash | модель: qwen3.8-flash-next
- фикстура: merge_sort_thinking_off.txt (md5 253c7ac50857fe6d0e10fb0d2c5e35c0)
- параметры: runs=1, parallel=2,4 | лимит прогона: 3600с

## 1. Соло-декод (канон-фикстура, reasoning off)

| прогон | wall,с | prompt | completion | decode tok/s |
|---|---|---|---|---|
| 1 | 1.38 | 56 | 156 | 112.86 |

медиана: wall 1.38с | decode 112.86 tok/s (по 1 прогонам)

## 2. Короткий проза-запрос

| прогон | wall,с | prompt | completion | decode tok/s |
|---|---|---|---|---|
| 1 | 5.92 | 25 | 400 | 67.52 |

медиана: wall 5.92с | decode 67.52 tok/s (по 1 прогонам)

## 3. Агентская сессия (15 ходов) + follow-up-кэш

| ход | wall,с | prompt | completion | tok/s | prompt_ms* | reuse* |
|---|---|---|---|---|---|---|
| 1 | 0.54 | 6419 | 33 | 61.49 | 101.2 | - |
| 2 | 0.41 | 6479 | 22 | 53.30 | 110.7 | - |
| 3 | 0.46 | 6523 | 30 | 65.17 | 101.2 | - |
| 4 | 0.51 | 6582 | 39 | 76.98 | 117.2 | - |
| 5 | 0.51 | 6652 | 37 | 72.37 | 120.6 | - |
| 6 | 0.51 | 6714 | 33 | 65.41 | 108.9 | - |
| 7 | 0.37 | 6780 | 22 | 59.72 | 122.8 | - |
| 8 | 0.30 | 6826 | 15 | 50.33 | 108.6 | - |
| 9 | 0.39 | 6866 | 29 | 75.37 | 111.5 | - |
| 10 | 0.37 | 6923 | 19 | 51.33 | 114.7 | - |
| 11 | 0.43 | 6969 | 31 | 71.28 | 115.5 | - |
| 12 | 0.41 | 7028 | 32 | 77.66 | 116.1 | - |
| 13 | 0.61 | 7089 | 36 | 59.06 | 117.3 | - |
| 14 | 0.45 | 7153 | 34 | 75.30 | 116.2 | - |
| 15 | 0.49 | 7217 | 33 | 66.61 | 118.3 | - |

* из timings движка; «-» — движок timings не прислал
итого сессия: 15 ход(ов), wall суммарный 6.76с

follow-up 25k (turn 1 = a guaranteed cache miss, the per-run nonce prefix): turn1=12.09с turn2=1.03с reuse=-

## 4. Параллельная нагрузка

| N | wall,с | Σtok | aggregate tok/s | % от соло | per-request walls,с |
|---|---|---|---|---|---|
| 2 | 5.26 | 456 | 86.67 | 77% | 5.26, 2.10 |
| 4 | 7.51 | 912 | 121.36 | 108% | 7.51, 3.23, 7.42, 3.29 |

## Движковые метрики (адаптер)

- metrics_note: halogen /metrics — кумулятивные счётчики с старта сервера
- route_spec: halogen 0.20.7
- slots: 4
- context: 262144
- engine_up: 1
- requests_total: 32
- busy_for_seconds: 0
- cache_hits_total: 25
- cache_misses_total: 8
- cache_hit_pct: 75.8
- cache_prompt_tokens_saved_total: 127503
- cache_entries: 21
- cache_bytes: 1273676964
- cache_evicted_total: 6
- cache_disk_bytes: 13182804160
- cache_disk_budget_bytes: 68719476736
- cache_disk_hits_total: 3
- draft_tokens_total: 1951
- draft_tokens_accepted_total: 1596
- draft_accept_pct: 81.8
- kv_pool_positions: 524288
- kv_pool_reserved_tokens: 0
- kv_reserved_pct: 0.0
- kv_pool_waiting: 0
- queue_waited_total: 0
- queue_wait_longest_seconds: 0
- queue_gave_up_total: 0

## Вывод

> (заполняется человеком после прогона)
