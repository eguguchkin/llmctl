# shellcheck shell=bash
# ── gufo: the bench hooks (stage 7; the §stage-7-Additions adapter-contract) ──
# 1) engine_bench_model — the model id for the bench API requests:
#    parse_route from the container log → ROUTE_MODEL (gufo names may have
#    spaces; LCTL_MODEL is the gguf file name, the server does not accept it
#    — the smoke for the same reason); an empty route → die. 2)
#    engine_bench_extras — one JSON line: the /metrics snapshot (the
#    cumulative counters + the gen_avg/cache_pct/spec_pct/kv_pct derivatives
#    from the watch parser — a bench_extras.py reuse, not a copy) + the
#    log's ROUTE_*. The core calls: model — before the scenarios, extras —
#    once after.

# Purpose: the engine_bench_model hook — print the model id for the bench
#   API requests (stdout, WITHOUT a trailing newline).
#
# Side effects: podman logs (read-only) + parse_route (the ROUTE_* globals);
#   an empty route — die (exit 1): a bench without a model name inevitably
#   fails on every request.
#
# Limitations/assumptions: requires the CONTAINER global (dispatcher) and
#   parse_route (the adapter's health.sh); a log without load_completed =
#   the model is still loading — the core gate has already passed a healthy
#   /ready, so this is a rare race, but an honest refusal beats a silently
#   wrong name.
#
# @stdout string    # the model name from the last load_completed line
# @returns integer  # does not return on an empty route — die
engine_bench_model() {
  parse_route < <(podman logs "$CONTAINER" 2>&1)
  [ -n "$ROUTE_MODEL" ] || die "bench: роут не найден (в логе нет model= из load_completed) — модель ещё грузится? проверь 'lctl status'"
  printf '%s' "$ROUTE_MODEL"
}

# Purpose: the engine_bench_extras <runs_dir> hook — ONE JSON line with the
#   engine metrics for the bench report's section; the core calls it once
#   after all the scenarios. W3.2: the «средн» derivatives are over the
#   uptime (layout §5), so we capture `podman logs -t --tail 50` into a
#   temp file and hand it to bench_extras (the env LCTL_BENCH_UPTIME_LOG;
#   the uptime — from the first podman stamp ≈ the container start).
#
# Side effects: podman logs (read-only, ×2: without -t for parse_route,
#   with -t for the uptime) + parse_route; a GET /metrics via curl (5 s);
#   mktemp + removing the temp file; python3 bench_extras.py with
#   PYTHONPATH at the adapter's python frame; stdout — one JSON line.
#
# Limitations/assumptions: a curl/parser failure → rc ≠ 0 (the core warns,
#   the report section stays without data); a podman logs -t failure →
#   no/empty file → no averages in the JSON (a degradation, not a crash);
#   the /metrics counters are cumulative from server start — marked by the
#   metrics_note key; runs_dir is not read (the universal measurements —
#   in the core's JSONL, the engine ones — only /metrics).
#
# @param 1: string     # the bench measurements dir (reserved by the hook contract)
# @stdout string      # {"metrics_note":…,"route_spec":…,"gen_avg":…,…}
# @returns integer    # the curl|python3 pipe's rc (0 — success)
engine_bench_extras() {
  local runs_dir="$1" ulog rc
  parse_route < <(podman logs "$CONTAINER" 2>&1)
  ulog=$(mktemp)
  podman logs -t --tail 50 "$CONTAINER" >"$ulog" 2>/dev/null || true
  curl -fsS -m 5 "http://127.0.0.1:$PORT/metrics" 2>/dev/null | \
    ROUTE_SPEC="${ROUTE_SPEC:-}" ROUTE_SESSIONS="${ROUTE_SESSIONS:-}" ROUTE_CTX="${ROUTE_CTX:-}" \
    LCTL_BENCH_UPTIME_LOG="$ulog" \
    PYTHONPATH="${PYTHONPATH:+$PYTHONPATH:}$ADAPTER_DIR/tpl/python" \
    python3 "$ADAPTER_DIR/tpl/python/bench_extras.py"
  rc=$?
  rm -f "$ulog"
  return "$rc"
}
