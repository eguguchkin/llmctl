# bench halogen 0.20.7 — профиль flash

- дата: 2026-11-27T20:40:12+0300 | движок: halogen (версия 0.20.7)
- профиль: flash | модель: qwen3.8-flash-next
- фикстура: merge_sort_thinking_off.txt (md5 253c7ac50857fe6d0e10fb0d2c5e35c0)
- параметры: runs=1, parallel=2,4 | лимит прогона: 3600с

## 1. Соло-декод (канон-фикстура, reasoning off)

| прогон | wall,с | prompt | completion | decode tok/s |
|---|---|---|---|---|
| 1 | 1.25 | 56 | 156 | 125.12 |

медиана: wall 1.25с | decode 125.12 tok/s (по 1 прогонам)

## 2. Короткий проза-запрос

| прогон | wall,с | prompt | completion | decode tok/s |
|---|---|---|---|---|
| 1 | 5.79 | 25 | 400 | 69.09 |

медиана: wall 5.79с | decode 69.09 tok/s (по 1 прогонам)

## 3. Агентская сессия (15 ходов) + follow-up-кэш

| ход | wall,с | prompt | completion | tok/s | prompt_ms* | reuse* |
|---|---|---|---|---|---|---|
| 1 | 0.45 | 6419 | 33 | 74.03 | 96.8 | - |
| 2 | 0.40 | 6479 | 22 | 54.40 | 107.8 | - |
| 3 | 0.46 | 6523 | 30 | 65.88 | 100.1 | - |
| 4 | 0.50 | 6582 | 39 | 77.90 | 115.7 | - |
| 5 | 0.51 | 6652 | 37 | 73.07 | 117.8 | - |
| 6 | 0.50 | 6714 | 33 | 65.81 | 107.7 | - |
| 7 | 0.37 | 6780 | 22 | 60.11 | 121.3 | - |
| 8 | 0.29 | 6826 | 15 | 51.17 | 106.3 | - |
| 9 | 0.38 | 6866 | 29 | 76.50 | 108.6 | - |
| 10 | 0.37 | 6923 | 19 | 51.84 | 112.6 | - |
| 11 | 0.43 | 6969 | 31 | 71.82 | 113.4 | - |
| 12 | 0.41 | 7028 | 32 | 78.72 | 113.8 | - |
| 13 | 0.60 | 7089 | 36 | 59.69 | 114.7 | - |
| 14 | 0.45 | 7153 | 34 | 75.88 | 114.2 | - |
| 15 | 0.49 | 7217 | 33 | 67.29 | 116.4 | - |

* из timings движка; «-» — движок timings не прислал
итого сессия: 15 ход(ов), wall суммарный 6.60с

follow-up 25k (turn 1 = a guaranteed cache miss, the per-run nonce prefix): turn1=12.10с turn2=1.02с reuse=-

## 4. Параллельная нагрузка

| N | wall,с | Σtok | aggregate tok/s | % от соло | per-request walls,с |
|---|---|---|---|---|---|
| 2 | 5.23 | 456 | 87.18 | 70% | 5.23, 2.10 |
| 4 | 7.67 | 912 | 118.94 | 95% | 7.58, 3.43, 7.67, 3.26 |

## Движковые метрики (адаптер)

- metrics_note: halogen /metrics — кумулятивные счётчики с старта сервера
- route_spec: halogen 0.20.7
- slots: 4
- context: 262144
- engine_up: 1
- requests_total: 58
- busy_for_seconds: 0
- cache_hits_total: 50
- cache_misses_total: 9
- cache_hit_pct: 84.7
- cache_prompt_tokens_saved_total: 254772
- cache_entries: 25
- cache_bytes: 1516282100
- cache_evicted_total: 14
- cache_disk_bytes: 13930614808
- cache_disk_budget_bytes: 68719476736
- cache_disk_hits_total: 3
- draft_tokens_total: 3874
- draft_tokens_accepted_total: 3156
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
