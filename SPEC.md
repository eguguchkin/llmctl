---
id: llmctl-goal
type: goal-and-requirements
title: llmctl — one control panel for LLM engines (gufo/hipfire/halogen)
status: active
tags: [product, unified-control, invariants]
---

# llmctl — goal and requirements

The user-facing documentation (what / why / how / the command surface /
scenarios / benchmarks) lives in [README.md](README.md) and is not
duplicated here. This spec holds the goal, the requirements and the
core↔adapter contracts.

## Problem

Local LLM engines expose different profile formats, health dialects and
metrics, and each one alone is too thin to justify its own install/run/
monitor panel — yet the effective parameters per workload (quant, draft
model, sessions, context, cache) are the owner's actual research subject.
Experiments require fast engine switching on one machine ("exactly one
engine at any moment").

## Goal

One control panel `lctl`: an engine-independent lifecycle (core) + engine
adapters (engines/). Switching an engine = one command; engine comparison
happens on the adapters without core duplication.

## Requirements

### R1 — the command surface

The command surface with the full flags and semantics is documented in
[README.md](README.md#usage) — start/stop/pull/status/logs/doctor/models/
agent-check/watch/bench/uninstall. The contract points here:

- profiles are engine-agnostic names (`flash / 27b / 27b-parallel`); the
  model is an adapter detail;
- `start` is exclusive (the foreign-engine off → bootstrap / a no-op
  "already running" on a matching render / a re-create on a canon or render
  change — the render convergence) and honest (`stop` on nothing active is
  rc 0);
- the legacy verbs `on|off|use|switch|install` are hidden transitional
  aliases (only the new names in usage/docs); the canon in `.env` stores
  the new profile name, legacy names are mapped on read;
- `bench` is read-only over the RUNNING engine — it never starts, stops or
  re-configures anything.

### R2 — the core (core/, engine-independent, one source)

The full stack lifecycle: preflight (the apt five + GPU-prep `gpu_prep`),
bootstrap-first-on (the §B phase order with "units last"), units +
watchdog + the flock discipline (the lock reclaim), self-healing
(`orphan_heal` via containers-storage, pod-infra validation, the honest
off via an explicit podman stop), uninstall v2, the CONTAINERS_CONF scope
of slirp4netns, the battery skeleton (faux substitutes, mutations over
`# fix:<name>` markers).

### R3 — the adapter (engines/<name>/, engine-specific — must stay its own)

The profiles registry (format v2, 2026-11-27: one file of variables
`profiles/<id>.env`, sourced into `P_*` — `profile_src`/`profile_field
1..9` in core/profiles.sh; the core reads only 1–5, the rest is the
adapter dialect; `PROFILE_LIST`/`PROFILE_DEFAULT`/`resolve_profile` stay
in `profiles.sh`); the health dialect (what counts as healthy + the
format); the metrics sources for the watch panels; the doctor checklist;
the engine config keys; the image/model pins; the smoke dialect; the
canon state schema.

### R4 — state and switching

`.data/<engine>/{models,profiles,logs}` + `.env` at the clone root
(gitignored) — the active engine; `.data` is not removed by uninstall.
Cache — per-profile `config/kernel` inside `profiles/<prof>/` (no separate
`cache` dir — the architect 1.1 clarification; the cache moves together
with profiles as state). `switch`/`on --engine` with another engine active
= its honest `off`, then the bootstrap/up of the new one (the `.env` canon
of the former engine is reset — a reproducible document, not state). A
port conflict is diagnostic (die with a hint before the first up). `.env`
is a fully generated document (the render convergence): manual edits do
not survive `start`; the fine-tuning hatch is the adapter mechanisms
(`hipfire config set` / the registry / the gufo canon.env).

### R5 — invariants

I1/I2/I3 (see AGENTS.md) — mandatory, checked by the battery.

### R6 — the halogen boundary pilot

The halogen adapter is written against the finished core; a core edit for
halogen's sake = a boundary defect (in fact — a boundary revision).

### Non-goals (now)

Custom per-engine panels over the shared schema (the engine panels are
identical — dashboard-layout.md §3, the unified dashboard built in W3.3);
changing the engines on the machines without the owner's GO.

## Acceptance

The battery (faux, counters, mutations) + EXP windows on the machines as
clean sequences per И2. The first vertical slice: the core skeleton + the
hipfire adapter, `lctl start hipfire <profile>` end-to-end on a faux
machine.

## NOTES

- **Core/adapter**: the adapter globals `ENGINE_*` (13 — verified against
  the code 2026-11-25, the full list: adapter-contract.md §Глобалы) + the
  hooks `engine_*` (14: §Хуки there) — the contract; the core computes
  `UNIT_NAME="$ENGINE-compose"`, `STOP_MARKER/LOCK_FILE/MODELS_BASE/STATE_BASE/LOG_DIR/LIMITS_FILE`
  from the engine id. The self-healing functions keep the historic `hf_`
  prefix (a rename is cosmetic debt).
- **ADAPTER_DIR/CORE_DIR** resolve from the dispatcher directory (dirname
  SELF), not from `$STACK_DIR` — in production "the clone = the stack" the
  paths coincide with §2.1, but the selfcheck/migration hook `LCTL_DIR`
  does not break the adapter load. The CONTAINERS_CONF scope of compose()
  — from `$STACK_DIR`.
- **The units** render with `Environment=LCTL_ENGINE=__ENGINE__` — the
  engine resolution in `_boot`/`_watchdog` goes through the env (the
  order: `--engine` > the env `LCTL_ENGINE` > the `.env` canon).
- **`on --models-dir`** is not in the surface (R1); the models path — the
  canon `.data/<engine>/models/<set>`.
- **profile_gate**: the refusal explanation takes field 5 of the adapter
  registry (the profile description) — no engine texts in the core.
- **The curl faux with hipfire answers** lives in
  `engines/hipfire/tests/adapter_checks.sh` (the engine dialect); the rest
  of the faux substitutes — in the battery skeleton.
- **The legacy profile names** (27b-single / 27b-slots / flash-multi) are
  the resolve_profile aliases; the `.env` canon stores the new name,
  cur_profile maps on read.

## Debt / notes (live)

- Investigate: on a switch, apply_profile silently skipped writing
  session_cache_bytes into the 27b config (parallel wrote it; a manual run
  of the same command worked; 2026-11-24, deploy 4.2) — re-verify the
  config on future deploys.
- GOTCHAS: the panel's env (the cache budgets via engine_watch_env) is
  read once at the panel process start — restart the panel after a cache
  config change (observed 2026-11-24: "Cache RAM —" with a working config).
- Optional: the real behavior of the snapshot disk cache — env
  HIPFIRE_QWEN4_TAIL_SNAPSHOT_MIN_PROMPT (the 16k-token threshold) /
  TURN_SNAPSHOTS=1, a per-profile decision.
- Cosmetic: selfcheck text wording ("amendment 6").
- Cosmetic: the env fallback `GFCTL_MIRROR_BASE` in the models delivery
  keeps its historic name until the live machines are verified (nothing
  exports it today); `LCTL_MIRROR_BASE` is the primary.
