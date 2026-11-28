# llmctl — one control panel for LLM inference engines

This project exists because running local LLM engines on one machine is a
pile of fiddly, machine-specific decisions — quants, draft models, session
counts, context sizes, cache budgets, ROCm memlock limits — that get
re-derived by hand for every engine and then lost. `lctl` turns that tribal
knowledge into named, engine-agnostic profiles and one command vocabulary:
a single command installs, starts, stops, switches, monitors and
benchmarks local LLM inference engines, with **exactly one engine active at
any moment**.

The tuning is done once per workload class (solo code, prose, agent
sessions, parallel load), recorded in the profile, and never re-derived per
run. Switching engines becomes a comparison operation: the same canonical
fixture, the same four scenarios, reports that are comparable across
engines. Deployment is deliberately boring — a bare Ubuntu machine becomes
a working stack with one command, all state lives inside the git clone,
and the engine canon is a generated, reproducible document rather than
hand-maintained state.

The lifecycle machinery (preflight → GPU prep → bootstrap → systemd units
→ container → health/smoke) is engine-independent code in `core/`;
everything engine-specific (profiles, health dialect, metrics, watch
panels, model pins) lives in per-engine adapters under `engines/`. The
boundary is a design rule: if an adapter needs a core edit, the boundary
is mis-designed.

## Install

On a bare Ubuntu/Debian machine (nothing preinstalled is required):

```sh
git clone https://github.com/eguguchkin/llmctl
cd llmctl
./lctl start <engine> <profile>
```

The first start installs the prerequisites itself, idempotently and with
point-use of sudo: podman, podman-compose, containers-storage, psmisc,
curl — plus GPU preparation (render/video groups, `/etc/security/limits.d`
memlock for ROCm/KFD, only when `/dev/kfd` or `/dev/dri` exists; an honest
"re-login required" when group membership changes; a no-op on non-GPU
machines). Model weights are pulled automatically on the first start.

The clone **is** the deployment: state lives in `.data/` inside the clone,
the active-engine canon in `.env` at the clone root. Deployments and runs
always go through a git clone (`git pull` to update) — never tar/cp copies.

## Usage

```sh
lctl start <engine> <profile> [--port N] [--bind A] [--no-autostart]
                              [--no-recreate] [--force] [--yes]
lctl stop
lctl pull <engine> <profile>               # prefetch the weights set, touch nothing else
lctl status | logs [-f] | doctor | models  # diagnostics
lctl agent-check                           # regression vs. the recorded references
lctl watch [--interval N]                  # live dashboard (TUI in a terminal, plain stream in a pipe)
lctl bench [--runs N] [--parallel N[,M…]]  # benchmark the RUNNING engine (read-only)
lctl uninstall [--purge]
```

- `start` is exclusive and idempotent: starting another engine performs an
  honest stop of the active one first; starting the same engine+profile
  with an unchanged render is a no-op ("already running — render matches");
  a changed render or canon re-creates the container (render convergence).
- `stop` on nothing active says "not running" and exits 0.
- `start --force` bypasses the RAM gate (with a warning); the gate refuses
  a profile before any download when the machine's memory pool is below
  the profile's threshold.

## Supported engines

| adapter | engine | profiles | note |
|---|---|---|---|
| `engines/gufo/` | gufo 0.36 (llama.cpp lineage, DFlash2/MTP speculation) | `27b`, `27b-parallel`, `flash` | the production engine on the 27B machine |
| `engines/halogen/` | halogen-flash-server 0.21.0 (MTP draft + ngram lookup; 0.21.0+ also serves the 27b ht4 checkpoint) | `flash`, `27b`, `27b-parallel` | the production engine on the flash machine; `27b-parallel` — the evo 60 GiB profile |
| `engines/hipfire/` | hipfire 0.4.7 (VMM batching, mq4-xts quants) | `27b`, `27b-parallel`, `flash` | retired from production, the adapter is kept working |

All engines target the same hardware class: an AMD Strix Halo APU
(Radeon gfx1151, unified LPDDR) on Ubuntu/Debian — a 60 GiB machine is the
27B minimum, 128 GiB is comfortable for every profile; ROCm/KFD memlock
limits are prepared automatically.

## Scenarios and profiles

### Profiles

A profile is a fixed, named recipe — the model, the context, the number of
concurrent contexts (sessions) and the parallel-load behavior it is tuned
for. Profiles are engine-agnostic: `lctl start <engine> <profile>` takes
any engine with the same profile name. One file per profile:
`engines/<engine>/profiles/<id>.env`; the gate refuses a profile before
any download if the machine has less memory.

| profile | model | context | sessions | parallel load |
|---|---|---|---|---|
| `flash` | Qwen3.8 Flash-Next | 262144 | 2–4 | 2–4 clients |
| `27b` | Qwen3.8 27B | 262144 | 1 | solo |
| `27b-parallel` | Qwen3.8 27B | 210000+ | 2 | 2–4 clients |

The `27b` profiles are calibrated for a **64 GB** machine; the `flash`
profile expects **128 GB**. A profile that would not fit the machine's
memory pool is refused before any download; `--force` bypasses with a
warning. Sessions vary slightly per engine (2–4) and the exact weights,
draft models, cache budgets and probe ladders live in the profile files
(`engines/<engine>/profiles/<id>.env`).

### Scenarios

- **First deploy / re-deploy after a version bump** — `git pull` then
  `lctl start <engine> <profile>`; the render convergence decides
  whether the container is re-created (a hotfix to an env template lands
  on the live stack).
- **Engine A/B on one machine** — `lctl stop` (or just `start` the other
  engine), compare `bench` reports; both engines keep their own
  `.data/<engine>/` state and their own canon.
- **Prefetch weights without touching the running stack** — `lctl pull`.
- **Is the engine healthy and sane** — `lctl status --json`, `lctl doctor`,
  `lctl logs -f`.
- **Live monitoring** — `lctl watch`: throughput, cache tiers, prefill
  gauges, speculative-decoding counters, budgets — the panel layout is
  shared, the data sources are the adapter's.
- **Regression check after an engine update** — `lctl agent-check`: a
  scripted 15-turn session + follow-up/doc/restore probes compared
  against the recorded reference values (±25 % → WARN).

## Benchmarks

`lctl bench` benchmarks the **running** engine over the OpenAI-compatible
API (read-only: it never starts, stops or re-configures anything; a stopped
stack produces a clear error). Four scenarios in one report: solo decode on
a canonical fixture (merge_sort, thinking off — the comparable-tau canon),
a short prose request, the 15-turn agent session, and a parallel-load
ladder (2 and 4 concurrent clients; 1..8 possible). One engine+profile
combination rewrites its own report in `bench/reports/`, and the latest
run of every combination is folded into the auto-generated comparative
matrix — **the scenario methodology, the honest-prefill rules (cache
misses only) and the numbers: [bench/README.md](bench/README.md)**.
