# bench halogen 0.21.0 — профиль flash

- дата: 2026-11-27T23:58:09+0300 | движок: halogen (версия 0.21.0)
- профиль: flash | модель: qwen3.8-flash-next
- фикстура: merge_sort_thinking_off.txt (md5 253c7ac50857fe6d0e10fb0d2c5e35c0)
- параметры: runs=1, parallel=2,4 | лимит прогона: 3600с

## 1. Соло-декод (канон-фикстура, reasoning off)

| прогон | wall,с | prompt | completion | decode tok/s |
|---|---|---|---|---|
| 1 | 1.38 | 56 | 156 | 112.70 |

медиана: wall 1.38с | decode 112.70 tok/s (по 1 прогонам)

## 2. Короткий проза-запрос

| прогон | wall,с | prompt | completion | decode tok/s |
|---|---|---|---|---|
| 1 | 5.94 | 25 | 400 | 67.30 |

медиана: wall 5.94с | decode 67.30 tok/s (по 1 прогонам)

## 3. Агентская сессия (15 ходов) + follow-up-кэш

| ход | wall,с | prompt | completion | tok/s | prompt_ms* | reuse* |
|---|---|---|---|---|---|---|
| 1 | 3.57 | 6419 | 33 | 9.25 | 3214.1 | - |
| 2 | 0.40 | 6479 | 22 | 54.78 | 109.7 | - |
| 3 | 0.46 | 6523 | 30 | 65.04 | 100.9 | - |
| 4 | 0.48 | 6582 | 39 | 81.40 | 117.4 | - |
| 5 | 0.52 | 6652 | 37 | 71.86 | 120.7 | - |
| 6 | 0.49 | 6714 | 33 | 67.22 | 109.2 | - |
| 7 | 0.37 | 6780 | 22 | 59.37 | 123.1 | - |
| 8 | 0.41 | 6826 | 20 | 48.18 | 108.5 | - |
| 9 | 0.38 | 6871 | 28 | 74.01 | 108.6 | - |
| 10 | 0.40 | 6927 | 19 | 48.03 | 115.1 | - |
| 11 | 0.54 | 6973 | 34 | 63.61 | 112.6 | - |
| 12 | 0.41 | 7035 | 32 | 78.03 | 115.3 | - |
| 13 | 0.65 | 7096 | 40 | 61.43 | 115.9 | - |
| 14 | 0.48 | 7164 | 38 | 79.08 | 116.1 | - |
| 15 | 0.34 | 7232 | 20 | 58.21 | 118.5 | - |

* из timings движка; «-» — движок timings не прислал
итого сессия: 15 ход(ов), wall суммарный 9.90с

follow-up 25k (turn 1 = a guaranteed cache miss, the per-run nonce prefix): turn1=12.35с turn2=0.94с reuse=-

## 4. Параллельная нагрузка

| N | wall,с | Σtok | aggregate tok/s | % от соло | per-request walls,с |
|---|---|---|---|---|---|
| 2 | 5.25 | 456 | 86.86 | 77% | 5.25, 2.11 |
| 4 | 7.69 | 912 | 118.55 | 105% | 7.63, 3.14, 7.69, 3.42 |

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
- cache_prompt_tokens_saved_total: 147828
- cache_entries: 18
- cache_bytes: 1091723112
- cache_evicted_total: 3
- cache_disk_bytes: 6217261408
- cache_disk_budget_bytes: 68719476736
- cache_disk_hits_total: 1
- draft_tokens_total: 1969
- draft_tokens_accepted_total: 1601
- draft_accept_pct: 81.3
- kv_pool_positions: 524288
- kv_pool_reserved_tokens: 0
- kv_reserved_pct: 0.0
- kv_pool_waiting: 0
- queue_waited_total: 0
- queue_wait_longest_seconds: 0
- queue_gave_up_total: 0

## Вывод

> (заполняется человеком после прогона)
