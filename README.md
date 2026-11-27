# llmctl — one control panel for LLM inference engines

`lctl` is a single command that installs, starts, stops, switches, monitors
and benchmarks local LLM inference engines on one machine — with exactly one
engine active at any moment. The lifecycle (preflight → GPU prep → bootstrap
→ systemd units → container → health/smoke) is engine-independent code in
`core/`; everything engine-specific (profiles, health dialect, metrics,
watch panels, model pins) lives in per-engine adapters under `engines/`.

**Supported engines**

| adapter | engine | profiles | note |
|---|---|---|---|
| `engines/gufo/` | gufo 0.36 (llama.cpp lineage, DFlash2/MTP speculation) | `27b`, `27b-parallel`, `flash` | the production engine on the 27B machine |
| `engines/halogen/` | halogen-flash-server 0.20.7 (MTP draft + ngram lookup) | `flash` | the production engine on the flash machine |
| `engines/hipfire/` | hipfire 0.4.7 (VMM batching, mq4-xts quants) | `27b`, `27b-parallel`, `flash` | retired from production, the adapter is kept working |

All engines target the same hardware class: an AMD Strix Halo APU
(Radeon gfx1151, unified LPDDR) on Ubuntu/Debian — a 60 GiB machine is the
27B minimum, 128 GiB is comfortable for every profile; ROCm/KFD memlock
limits are prepared automatically.

## Why

Three sibling control panels (gfctl for gufo, hfctl for hipfire) duplicated
the lifecycle and self-healing while the genuinely interesting part — the
engine dialects — kept drifting apart. llmctl collapses the lifecycle into
one audited core and expresses each engine as a thin adapter. Switching
engines on one machine is one command, so A/B benchmarking is a routine,
not a project.

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
- Profiles are engine-agnostic names: `flash`, `27b`, `27b-parallel`.
  The actual model files and serve flags are the adapter's business —
  one profile per file in `engines/<engine>/profiles/<id>.env`.
- `stop` on nothing active says "not running" and exits 0.
- `start --force` bypasses the RAM gate (with a warning); the gate refuses
  a profile before any download when the machine's memory pool is below
  the profile's threshold.

## Scenarios

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
stack produces a clear error). Four scenarios in one report:
solo decode on a canonical fixture (merge_sort, thinking off — the
comparable-tau canon), a short prose request, the 15-turn agent session,
and a parallel-load ladder (2 and 4 concurrent clients; 1..8 possible).
The report lands in `bench/reports/<engine>-<version>-<profile>.md` —
a header with date/engine/version/profile/model/fixture md5 and no host
information. One engine+profile combination rewrites its own report.
Cross-engine comparisons are valid only within the same scenario and the
same fixture md5.

Recorded reference points (a 128 GB Strix Halo, `--runs 1`, 2026-11-27):
halogen/flash solo 112.9 tok/s, parallel-4 121.7 tok/s, agent session
6.8 s — the fastest of all seven engine×profile combinations tested;
see `bench/reports/` for the full set.

## Development

- `tests/run_checks.sh` — the acceptance battery (176 checks): faux
  substitutes for systemctl/podman/curl/etc., mutation tests over
  `# fix:<name>` markers on tree copies, golden renders.
- The core↔adapter contract: the adapter declares `ENGINE_*` globals and
  `engine_*` hooks; if an adapter needs a core edit, the boundary is
  mis-designed (see SPEC.md). A new adapter is a new directory plus
  `profiles/*.env` files — no core edits.
- Architecture, invariants and requirements: [SPEC.md](SPEC.md).
- Working conventions for agents: [AGENTS.md](AGENTS.md).
