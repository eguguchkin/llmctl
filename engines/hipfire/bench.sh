# shellcheck shell=bash
# ── hipfire: the bench hook (stage 7; the §stage-7-Additions adapter-contract) ─
# The bench report's engine metrics as one JSON line: the engine's τ from
# the container logs (the last τ=/tau= match; a port of the hfctl
# bench_tau; absent from the logs → null — we do not make it up) + the
# ROUTE_SPEC from the route snapshot. The core renders the section as is,
# it does not interpret. The cumulativeness/source are marked in the keys.

# Purpose: the engine_bench_extras <runs_dir> hook — ONE JSON line with the
#   engine metrics for the bench report's «Движковые метрики (адаптер)»
#   section; the core calls it ONCE after all the scenarios.
#
# Side effects: podman logs subprocesses (reading the logs, read-only),
#   route_snapshot (podman logs + a curl /health + python3
#   health_mode.py), python3 (the JSON assembly); stdout — one JSON line.
#   Writes no files.
#
# Limitations/assumptions: requires the CONTAINER global (dispatcher) and
#   route_snapshot (the adapter's health.sh); a log/parse failure → a
#   null tau_s (the metric honestly absent, not a run error); runs_dir is
#   not read (hipfire's engine metrics live in the logs, the measurements
#   JSONL is universal).
#
# @param 1: string     # the bench measurements dir (reserved by the hook contract)
# @stdout string      # {"tau_s":13.18|null,"tau_note":…,"route_spec":…|null}
# @returns integer    # the last command's rc (0)
engine_bench_extras() {
  local runs_dir="$1" tau
  tau=$(podman logs "$CONTAINER" 2>&1 | grep -oE "(τ|tau)=[0-9.]+" | tail -1 | cut -d= -f2-) || true
  route_snapshot
  python3 "$ADAPTER_DIR/tpl/python/bench_tau.py" "$tau" "${ROUTE_SPEC:-}"
}
