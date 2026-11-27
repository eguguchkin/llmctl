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

Three sibling panels (gfctl/gufo, hfctl/hipfire, then halogen) duplicated
the lifecycle and self-healing, while the engine specifics (profiles,
metrics, health dialects) are the owner's actual research subject.
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

Ported from hfctl/gfctl with the name adaptation: preflight (the apt five
+ GPU-prep `gpu_prep`), bootstrap-first-on (the §B phase order with "units
last"), units + watchdog + the flock discipline (`hf_lock_reclaim`),
self-healing (`orphan_heal` via containers-storage, pod-infra validation,
the honest off via an explicit podman stop), uninstall v2, the
CONTAINERS_CONF scope of slirp4netns, the battery skeleton (faux
substitutes, mutations over `# fix:<name>` markers).

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

И1/И2/И3 (see AGENTS.md) — mandatory, checked by the battery.

### R6 — the halogen boundary pilot

The halogen adapter is written against the finished core; a core edit for
halogen's sake = a boundary defect (in fact — a boundary revision).

### Non-goals (now)

Migrating gfctl/hfctl before their current work is done; custom per-engine
panels over the shared schema (the engine panels are identical —
dashboard-layout.md §3, the unified dashboard built in W3.3); changing the
engines on the machines without the owner's GO.

## Acceptance

The battery (faux, counters, mutations) + EXP windows on the machines as
clean sequences per И2. The first vertical slice: the core skeleton + the
hipfire adapter, `lctl start hipfire <profile>` end-to-end on a faux
machine.

## NOTES (the stage-2 delta, implemented in 1.1)

- **Core/adapter**: the adapter globals `ENGINE_*` (13 — verified against
  the code 2026-11-25, the full list: adapter-contract.md §Глобалы) + the
  hooks `engine_*` (14: §Хуки there) — the contract; the core computes
  `UNIT_NAME="$ENGINE-compose"`, `STOP_MARKER/LOCK_FILE/MODELS_BASE/STATE_BASE/LOG_DIR/LIMITS_FILE`
  from the engine id. The `hf_*` self-healing names are kept (§2.4).
- **ADAPTER_DIR/CORE_DIR** resolve from the dispatcher directory (dirname
  SELF), not from `$STACK_DIR` — in production "the clone = the stack" the
  paths coincide with §2.1, but the selfcheck/migration hook `LCTL_DIR`
  does not break the adapter load. The CONTAINERS_CONF scope of compose()
  — from `$STACK_DIR` (as in hfctl).
- **The units** render with `Environment=LCTL_ENGINE=__ENGINE__` — the
  engine resolution in `_boot`/`_watchdog` goes through the env (the
  order: `--engine` > the env `LCTL_ENGINE` > the `.env` canon).
- **bench/watch/agent-check**: the historical stage-2 delta — the router
  had only `agent-check` then; watch (stage 4, W3.3 — the unified
  dashboard) and bench were added later and fixed in R1 (2026-11-25).
- **`on --models-dir`** from hfctl did not migrate (not in R1); the models
  path — the canon `.data/<engine>/models/<set>`.
- **profile_gate**: the refusal explanation takes field 5 of the adapter
  registry (the profile description) — no engine texts in the core.
- **The curl faux with hipfire answers** lives in
  `engines/hipfire/tests/adapter_checks.sh` (the engine dialect); the rest
  of the faux substitutes — in the battery skeleton.
- **1.2**: the start/stop/pull surface (the §A automaton in cmd_start: the
  foreign off → bootstrap/ensure/recreate; stop — over the units of the
  active engine, before the engine resolution); the hipfire registry was
  renamed flash/27b/27b-parallel (legacy — the resolve_profile aliases,
  the `.env` canon — the new name, cur_profile maps on read); the verb
  aliases on|off|use|switch|install — transitional, not documented in
  usage.
