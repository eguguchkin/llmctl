# llmctl — one control panel for LLM engines (gufo / hipfire / halogen)

One machine — one active engine. `lctl` is the single point of control:
the stack lifecycle (preflight + GPU-prep → bootstrap → units → container →
health/smoke), the exclusive engine switcher, self-healing of known
anomalies. The lifecycle lives in `core/` (engine-independent, one source);
engine specifics live in the adapters `engines/<name>/`: profiles, health
dialect, metrics/watch panels, doctor, pins, config keys.

For the user-facing documentation — what / why / how / scenarios /
benchmarks — see [README.md](README.md). The requirements, invariants and
the core↔adapter contract — [SPEC.md](SPEC.md).

Reply language: Russian (the owner's language). Simple tasks — short and
to the point; detail — for complex topics and acceptance.

## Delivery invariants (mandatory, battery-checked)

- **I1 — a bare Ubuntu in one command**: `git clone && ./lctl start
  <engine> <profile>` (e.g. `lctl start hipfire flash`). The panel itself
  installs (idempotently, sudo at point use): podman, podman-compose,
  containers-storage, psmisc, curl + GPU preparation (render/video groups,
  limits.d memlock — only when `/dev/kfd`/`/dev/dri` exists, an honest
  "re-login required"; a non-GPU machine — an info skip).
- **I2 — scenario acceptance without manual adjustments**: a scenario
  counts as passed only as the command sequence of `lctl` (+ diagnostic
  reads: podman ps/inspect, curl health, journalctl). An off-plan manual
  mutation = the scenario FAILs + a defect into the backlog.
- **I3 — deploy/runs on a machine always from GitHub**: the machine clone
  → pull; tar/cp from a workspace is forbidden (including in EXP windows).
