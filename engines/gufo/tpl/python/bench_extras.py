#!/usr/bin/env python3
# Purpose: a snapshot of the gufo /metrics → one JSON line for the
#   engine_bench_extras hook (stage 7): the cumulative counters + the
#   derivatives from the watch_engine parser (REUSE — the watch panel's
#   formulas, not a copy; PYTHONPATH is set by the hook) + the ROUTE_* of
#   the last load_completed line (env ROUTE_*, set by the hook). W3.2: the
#   «средн» derivatives — a ratio-of-sums OVER THE UPTIME (layout §5) —
#   the uptime comes from env LCTL_BENCH_UPTIME (sec, an explicit override
#   — the battery seam) or from the container log LCTL_BENCH_UPTIME_LOG
#   (`podman logs -t`, the hook writes it to a temp file; the first
#   podman stamp ≈ the start). The key order is fixed → the bench report
#   is stable from run to run.
#
# Side effects: none (stdin/env → stdout; the uptime file is only read).
#
# Limitations/assumptions: stdlib only; a missing metric key → no key in
#   the JSON (an old engine image — a report-section degradation, not a
#   crash); no uptime (empty env, no log/without stamps) → no averages in
#   the JSON — the section is honest; the derivatives are rounded to 2
#   decimals, integer counters print without the fraction; empty ROUTE_*
#   → null.
#
# @stdin string    # the GET /metrics body (a prometheus text)
# @stdout string   # one JSON line
# @returns integer # 0
import json
import os
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                '..', '..', '..', '..',
                                'core', 'tpl', 'python', 'watch'))
import watch_engine  # noqa: E402  (a sibling — the gufo panel's formulas)
from watch_frame import parse_metrics  # noqa: E402  (W3: moved into the frame)


def bench_uptime():
    # @returns float|None  # the uptime for the ratio-of-sums:
    #   LCTL_BENCH_UPTIME (sec, a non-number → None) > LCTL_BENCH_UPTIME_LOG
    #   (a `podman logs -t` file, fix:w32-uptime via uptime_from_log,
    #   now=real) > None
    env_s = os.environ.get('LCTL_BENCH_UPTIME')
    if env_s:
        try:
            return float(env_s)
        except ValueError:
            pass
    log_p = os.environ.get('LCTL_BENCH_UPTIME_LOG')
    if log_p:
        try:
            with open(log_p) as f:
                return watch_engine.uptime_from_log(f.read().splitlines(),
                                                    time.time())
        except OSError:
            return None
    return None


def jnum(v):
    # @param 1: float|None  # a value from engine_stats
    # @returns int|float|None  # integers without the fraction, the rest — 2 decimals
    if v is None:
        return None
    if isinstance(v, float) and v.is_integer():
        return int(v)
    return round(v, 2)


def main():
    # W3.3 v2: bench = a lifetime run — the window = the snapshot itself
    #     (a ratio-of-sums over the seconds counters Σtokens/Σtime; the
    #     panel session semantics do not apply here — the bench seam is
    #     untouched, the numbers are the former ones)
    m = parse_metrics(sys.stdin.read())
    stats = watch_engine.engine_stats(m, bench_uptime(), window=m) or {}
    out = {"metrics_note": "cumulative counters since server start; "
                           "производные «средн» — Σтокены/Σвремя прогона "
                           "(ratio-of-sums)"}
    for key in ("route_spec", "route_sessions", "route_ctx"):
        env_v = os.environ.get(key.upper()) or ""
        out[key] = env_v or None
    for key in ("gen_avg", "gen_last", "prefill_avg", "prefill_last",
                "cache_pct", "spec_pct", "tau", "kv_pct", "kv_peak",
                "tok_prompt", "tok_cached", "tok_pred", "q_proc", "q_def",
                "lookup_pct", "device_lost"):
        v = jnum(stats.get(key))
        if v is not None:
            out[key] = v
    print(json.dumps(out, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
