# bench halogen 0.20.7 — профиль flash

- дата: 2026-11-27T12:54:54+0300 | движок: halogen (версия 0.20.7)
- профиль: flash | модель: qwen3.8-flash-next
- фикстура: merge_sort_thinking_off.txt (md5 253c7ac50857fe6d0e10fb0d2c5e35c0)
- параметры: runs=1, parallel=2,4 | лимит прогона: 3600с

## 1. Соло-декод (канон-фикстура, reasoning off)

| прогон | wall,с | prompt | completion | decode tok/s |
|---|---|---|---|---|
| 1 | 1.38 | 56 | 156 | 112.92 |

медиана: wall 1.38с | decode 112.92 tok/s (по 1 прогонам)

## 2. Короткий проза-запрос

| прогон | wall,с | prompt | completion | decode tok/s |
|---|---|---|---|---|
| 1 | 5.92 | 25 | 400 | 67.58 |

медиана: wall 5.92с | decode 67.58 tok/s (по 1 прогонам)

## 3. Агентская сессия (15 ходов) + follow-up-кэш

| ход | wall,с | prompt | completion | tok/s | prompt_ms* | reuse* |
|---|---|---|---|---|---|---|
| 1 | 0.55 | 6419 | 33 | 60.20 | 101.0 | - |
| 2 | 0.41 | 6479 | 22 | 53.75 | 109.4 | - |
| 3 | 0.46 | 6523 | 30 | 65.84 | 100.7 | - |
| 4 | 0.51 | 6582 | 39 | 77.07 | 117.4 | - |
| 5 | 0.51 | 6652 | 37 | 72.40 | 120.3 | - |
| 6 | 0.51 | 6714 | 33 | 65.26 | 109.6 | - |
| 7 | 0.37 | 6780 | 22 | 59.42 | 122.8 | - |
| 8 | 0.30 | 6826 | 15 | 50.38 | 108.4 | - |
| 9 | 0.38 | 6866 | 29 | 75.70 | 110.7 | - |
| 10 | 0.37 | 6923 | 19 | 51.33 | 114.7 | - |
| 11 | 0.44 | 6969 | 31 | 71.07 | 115.6 | - |
| 12 | 0.41 | 7028 | 32 | 77.83 | 115.6 | - |
| 13 | 0.61 | 7089 | 36 | 59.12 | 117.2 | - |
| 14 | 0.45 | 7153 | 34 | 75.08 | 116.3 | - |
| 15 | 0.49 | 7217 | 33 | 66.86 | 118.3 | - |

* из timings движка; «-» — движок timings не прислал
итого сессия: 15 ход(ов), wall суммарный 6.76с

follow-up 25k: turn1=1.96с turn2=1.18с reuse=-

## 4. Параллельная нагрузка

| N | wall,с | Σtok | aggregate tok/s | % от соло | per-request walls,с |
|---|---|---|---|---|---|
| 2 | 5.25 | 456 | 86.92 | 77% | 5.25, 2.24 |
| 4 | 7.49 | 912 | 121.70 | 108% | 7.40, 3.28, 7.49, 3.22 |

## Движковые метрики (адаптер)

- metrics_note: halogen /metrics — кумулятивные счётчики с старта сервера
- route_spec: halogen 0.20.7
- slots: 4
- context: 262144
- engine_up: 1
- requests_total: 36
- busy_for_seconds: 0
- cache_hits_total: 29
- cache_misses_total: 8
- cache_hit_pct: 78.4
- cache_prompt_tokens_saved_total: 397977
- cache_entries: 26
- cache_bytes: 1576933384
- cache_evicted_total: 7
- cache_disk_bytes: 10876960608
- cache_disk_budget_bytes: 68719476736
- cache_disk_hits_total: 4
- draft_tokens_total: 2720
- draft_tokens_accepted_total: 2092
- draft_accept_pct: 76.9
- kv_pool_positions: 524288
- kv_pool_reserved_tokens: 0
- kv_reserved_pct: 0.0
- kv_pool_waiting: 0
- queue_waited_total: 0
- queue_wait_longest_seconds: 0
- queue_gave_up_total: 0

## Вывод

> (заполняется человеком после прогона)
