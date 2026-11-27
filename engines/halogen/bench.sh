# shellcheck shell=bash
# ── halogen: the bench hooks (Ф3; the §stage-7-Additions adapter-contract) ──
# 1) engine_bench_model — the model id for the bench API requests: the
#    adapter's canon (HALOGEN_MODEL_ID is rendered into compose and echoed
#    by the engine; halogen has no load_completed in the log — the name's
#    source is not the log but a constant the server certainly accepts).
#    2) engine_bench_extras — one JSON line: the /metrics snapshot (the
#    cumulative halogen:* + the bench_extras.py derivatives) + the ROUTE_*
#    from halogen_route_info. The key order is fixed in bench_extras.py.

# Purpose: the engine_bench_model hook — print the model id for the bench
#   API requests (stdout, WITHOUT a trailing newline).
#
# Side effects: none (an adapter constant).
#
# Limitations/assumptions: the server is healthy (the core gate before the
#   scenarios) — the canon certainly matches the MODEL_ID rendered in
#   compose.
#
# @stdout string    # qwen3.8-flash-next
# @returns integer  # always 0
engine_bench_model() {
  printf '%s' "$HALOGEN_MODEL_CANON"
}

# Purpose: the engine_bench_extras <runs_dir> hook — one JSON line with the
#   engine metrics for the bench report's section; the core calls it once
#   after all the scenarios. No uptime computation: halogen returns
#   halogen:busy_for_seconds directly, the counters are cumulative from
#   start (the metrics_note in the JSON marks it).
#
# Side effects: a GET /metrics (curl 5 s) + halogen_route_info (/health,
#   /v1/models, /slots — the ROUTE_*); python3 bench_extras.py (PYTHONPATH
#   at the adapter's python frame); stdout — one JSON line.
#
# Limitations/assumptions: a curl/parser failure → rc ≠ 0 (the core warns,
#   the report section without data); runs_dir is not read (the universal
#   measurements — in the core's JSONL with the llama-server-shape timings,
#   the engine ones — only /metrics).
#
# @param 1: string     # the bench measurements dir (reserved by the contract)
# @stdout string      # one JSON line
# @returns integer    # the curl|python3 pipe's rc (0 — success)
engine_bench_extras() {
  local runs_dir="$1"
  halogen_route_info >/dev/null 2>&1 || true   # ROUTE_* best-effort
  curl -fsS -m 5 "http://127.0.0.1:$PORT/metrics" 2>/dev/null | \
    ROUTE_SPEC="${ROUTE_SPEC:-}" ROUTE_SESSIONS="${ROUTE_SESSIONS:-}" ROUTE_CTX="${ROUTE_CTX:-}" \
    PYTHONPATH="${PYTHONPATH:+$PYTHONPATH:}$ADAPTER_DIR/tpl/python" \
    python3 "$ADAPTER_DIR/tpl/python/bench_extras.py"
}
