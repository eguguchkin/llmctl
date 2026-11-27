---
id: llmctl-goal
type: goal-and-requirements
title: llmctl — единый пульт управления LLM-движками (gufo/hipfire/halogen)
status: active
tags: [product, unified-control, invariants]
---

# llmctl — цель и требования

## Проблема

Три родственные обвязки (gfctl/gufo, hfctl/hipfire, планируемый halogen)
дублируют жизненный цикл и само-лечение, при этом движковая специфика
(профили, метрики, health-диалекты) — и есть предмет исследования пользователя.
Эксперименты требуют быстрого переключения движков на одной машине
(«в каждый момент ровно один движок»).

## Цель

Единый пульт `lctl`: движко-независимый жизненный цикл (core) + движковые
адаптеры (engines/). Переключение движка = одна команда; сравнение движков
ведётся на адаптерах без дублей ядра.

## Требования

### R1 — командная поверхность (1.2: start/stop/pull, позиционные аргументы; апрув пользователя 2026-11-21; флаговый набор start синхронизирован с usage/кодом 2026-11-25 — --bind от OPS1/Round 5)

```
lctl start <engine> <profile> [--port N] [--bind A] [--no-autostart]
                              [--no-recreate] [--force] [--yes]
                               # эксклюзивный старт (автомат §А: чужой off → bootstrap / ensure no-op «уже
                               # запущено» при совпадении рендера / recreate при смене канона ИЛИ
                               # расхождении рендера — конвергенция, этап 8; --no-recreate — записать
                               # рендер без пересоздания живого стека)
lctl stop                                  # остановить активный движок (честный off по юнитам); ничего активно — «не запущено», rc 0
lctl pull <engine> <profile>               # prefetch весов сета, не трогая работающее (без старта/конфига/юнитов)
lctl status / logs [-f] / doctor / models / agent-check / uninstall [--purge]   # диагностика — core-каркас + движковые секции через хуки
lctl watch [--interval N]                  # живой дашборд движка (TUI в терминале / plain-стрим в пайпе; панель — адаптер)
lctl bench [--runs N] [--parallel N[,M…]]  # бенч ЖИВОГО движка (read-only; отчёт bench/reports/<engine>-<version>-<profile>.md)
```

Профили — движко-agnostic имена: `flash / 27b / 27b-parallel` (модель — деталь
адаптера). Старые глаголы `on|off|use|switch|install` — скрытые алиасы
переходного периода (в usage/доках только новые имена); канон в `.env`
хранит новое имя профиля, legacy-имена маппятся при чтении.

### R2 — ядро (core/, движко-независимое, один источник)

Переносится из hfctl/gfctl с адаптацией имён (см. PLAN этап 1):
preflight (apt-пятёрка + GPU-prep `gpu_prep`), bootstrap-first-on
(порядок фаз §Б с «юнитами последними» — Р1), юниты+watchdog+flock-дисциплина
(`hf_lock_reclaim`), самолечение (`orphan_heal` через containers-storage,
pod-infra-валидация, честный off через явный podman stop), uninstall v2,
CONTAINERS_CONF-скоуп slirp4netns, каркас батареи (faux-подставки, мутации
по `# fix:<имя>`; известный баг bash -n мультифайлов — починить при переносе).

### R3 — адаптер (engines/<имя>/, движковое — обязано быть своим)

profiles-реестр (формат v2, 2026-11-27: файл-переменные `profiles/<id>.env`,
сорсится в `P_*` — `profile_src`/`profile_field 1..9` в core/profiles.sh;
ядро читает только 1–5, остальное — диалект адаптера; `PROFILE_LIST`/
`PROFILE_DEFAULT`/`resolve_profile` остаются в `profiles.sh`); health-диалект (что считать healthy + формат); источники
метрик для watch-панелей; doctor-чеклист; движковые конфиг-ключи; пины
образов/моделей; smoke-диалект; state-схема канона.

### R4 — состояние и переключение

`.data/<engine>/{models,profiles,logs}` + `.env` в корне клона (gitignore) — активный движок; `.data` не удаляется uninstall'ом. Cache — per-profile `config/kernel` внутри `profiles/<prof>/` (отдельного каталога `cache` нет — уточнение architect 1.1, кэш переезжает вместе с profiles как состояние). `switch`/`on --engine` при активном другом движке = его честный `off` затем bootstrap/up нового (канон `.env` прежнего движка сбрасывается — воспроизводимый документ, не состояние). Конфликт портов — диагностично (die с подсказкой до первого up). `.env` — полностью генерируемый документ (конвергенция рендера, этап 8): ручные правки не переживают `start`; люк тонких настроек — адаптерные механизмы (`hipfire config set` / реестр / gufo canon.env).

### R5 — инварианты

И1/И2/И3 (см. AGENTS.md) — обязательны, проверяемы батареей.

### R6 — halogen-пилот границы

Адаптер halogen пишется на готовом ядре; правка ядра под halogen =
дефект границы (по факту — ревизия boundary).

### Не-цели (сейчас)

Миграция gfctl/hfctl до завершения их текущих работ; кастомные per-engine
панели поверх общей схемы (панели движков идентичны — dashboard-layout.md
§3, единый дашборд построен в W3.3); замена движков на машинах без GO
пользователя.

## Приёмка

Батарея (faux, счётчик, мутации) + EXP-окна на машинах чистыми
последовательностями по И2. Первый вертикальный срез: core-скелет +
hipfire-адаптер, `lctl start hipfire <profile>` на faux-машине end-to-end.

## NOTES (дельта этапа 2, реализация 1.1)

- **Ядро/адаптер**: глобалы адаптера `ENGINE_*` (13 — верифицировано по
  коду 2026-11-25, полный список: adapter-contract.md §Глобалы) + хуки
  `engine_*` (14: §Хуки там же) — контракт; ядро вычисляет
  `UNIT_NAME="$ENGINE-compose"`, `STOP_MARKER/LOCK_FILE/MODELS_BASE/STATE_BASE/LOG_DIR/LIMITS_FILE` от id движка. `hf_*`-имена самолечения сохранены (§2.4).
- **ADAPTER_DIR/CORE_DIR** резолвятся от каталога диспетчера (dirname SELF), а не от `$STACK_DIR` — в проде «клон = стек» пути совпадают с §2.1, но selfcheck/migration-крючок `LCTL_DIR` не ломает загрузку адаптера. CONTAINERS_CONF-скоуп compose() — от `$STACK_DIR` (как в hfctl).
- **Юниты** рендерятся с `Environment=LCTL_ENGINE=__ENGINE__` — резолюция движка в `_boot`/`_watchdog` идёт через env (порядок: `--engine` > env `LCTL_ENGINE` > канон `.env`).
- **bench/watch/agent-check**: историческая дельта этапа 2 — тогда роутер
  содержал только `agent-check`; watch (этап 4, W3.3 — единый дашборд) и
  bench добавлены позже и зафиксированы в R1 (2026-11-25).
- **`on --models-dir`** из hfctl не переезжал (нет в R1); путь моделей — канон `.data/<engine>/models/<сет>`.
- **profile_gate**: пояснение отказа берёт поле 5 реестра адаптера (описание профиля) — движковых текстов в ядре нет.
- **curl-faux с hipfire-ответами** живёт в `engines/hipfire/tests/adapter_checks.sh` (движковый диалект), остальные faux-подставки — в каркасе батареи.
- **1.2**: поверхность start/stop/pull (§А-автомат в cmd_start: чужой off → bootstrap/ensure/recreate; stop — по юнитам активного, до резолюции движка); реестр hipfire переименован flash/27b/27b-parallel (legacy — алиасы resolve_profile, канон .env — новое имя, cur_profile маппит при чтении); verb-алиасы on|off|use|switch|install — переходный период, в usage не документируются.
