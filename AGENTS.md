# llmctl — one control panel for LLM engines (gufo / hipfire / halogen)

One machine — one active engine. `lctl` is the single point of control:
the stack lifecycle (preflight + GPU-prep → bootstrap → units → container →
health/smoke), the exclusive engine switcher, self-healing of known
anomalies. The lifecycle lives in `core/` (engine-independent, one source);
engine specifics live in the adapters `engines/<name>/`: profiles, health
dialect, metrics/watch panels, doctor, pins, config keys.

For the user-facing documentation — what / why / how / scenarios /
benchmarks — see [README.md](README.md). The requirements and the
core↔adapter contract — [SPEC.md](SPEC.md). The historical work plan
(stages 0–8, all completed) lives in the git history of PLAN.md.

The parent projects — **standalone** until migration: gfctl (gufo),
hfctl (hipfire). They are the source of techniques and code (port "on
touch"), not dependencies. The third engine, **halogen, is the pilot of
the core↔adapter boundary**: if an adapter needs a core edit, the boundary
is mis-designed.

Reply language: Russian (the owner's language). Simple tasks — short and
to the point; detail — for complex topics and acceptance.

Development protocol: dev-flow

## Delivery invariants (the hfctl/gfctl heritage, mandatory)

- **И1 — a bare Ubuntu in one command**: `git clone && ./lctl start
  <engine> <profile>` (e.g. `lctl start hipfire flash`). The panel itself
  installs (idempotently, sudo at point use): podman, podman-compose,
  containers-storage, psmisc, curl + GPU preparation (render/video groups,
  limits.d memlock — only when `/dev/kfd`/`/dev/dri` exists, an honest
  "re-login required"; a non-GPU machine — an info skip).
- **И2 — scenario acceptance without manual adjustments**: a scenario
  counts as passed only as the command sequence of `lctl` (+ diagnostic
  reads: podman ps/inspect, curl health, journalctl). An off-plan manual
  mutation = the scenario FAILs + a defect into the backlog.
- **И3 — deploy/runs on a machine always from GitHub**: the machine clone
  → pull; tar/cp from a workspace is forbidden (including in EXP windows).

## Development conventions

- The cycle: **architect (task.md) → developer → tester → reviewer**; code
  is not written without a contract; the machines are not touched from
  sub-stages (deploy is a separate window by the owner's GO).
- The battery: `tests/run_checks.sh`, faux substitutes
  (systemctl/podman/id/flock), mutations over the `# fix:<name>` markers
  on tree COPIES (bash -n of the mutant file-by-file), counters fixed in
  the reports.
- Known lessons move into the core deliberately (the registry below):
  rootless-netns/AppArmor-pasta (the CONTAINERS_CONF detour),
  card0↔card1 (recreate), bootstrap-guard×migration-`.env` chicken-and-egg
  (.env is not "state" but a reproducible document), flock zombies
  (detecting a live-but-stuck holder), the honest off (an explicit podman
  stop).

## Known debt / notes (the live tail of the former PLAN.md)

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
