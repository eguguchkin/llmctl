#!/usr/bin/env python3
# Purpose: a snapshot of the halogen /metrics → ONE JSON line for the
#   engine_bench_extras hook (Ф3, the stage-7 §Additions contract): the
#   cumulative halogen:* counters + the derivatives (cache hit_pct, spec
#   accept_pct, kv reserved_pct) + ROUTE_* (env set by the hook from
#   halogen_route_info). The key order is fixed → the bench report section
#   is stable. A missing metric key (an old image) → null — a section
#   degradation, not a crash.
#
# Side effects: none (stdin/env → stdout).
#
# Limitations/assumptions: stdlib only; the prometheus text — "name value"
#   lines, HELP/TYPE skipped; the values are rounded (float → 2 decimals,
#   percents → 1); the counters are cumulative FROM SERVER START (the
#   metrics_note in the JSON).
#
# @stdin string    # the GET /metrics body
# @stdout string   # one JSON line
# @returns integer # 0
import json
import os
import sys


def parse_metrics(text):
    # @param 1: string        # the prometheus text
    # @returns dict[str,float] # name → value (garbage skipped)
    d = {}
    for line in text.splitlines():
        parts = line.strip().split()
        if len(parts) != 2 or parts[0].startswith('#'):
            continue
        try:
            d[parts[0]] = float(parts[1])
        except ValueError:
            pass
    return d


def num(m, name, pct=False):
    # @param 1: dict       # the metrics
    # @param 2: string     # the metric name
    # @param 3: bool       # True — the value as percents ×100 (1 decimal)
    # @returns int|float|None  # None — no metric (a degradation, not a crash)
    v = m.get(name)
    if v is None:
        return None
    if pct:
        return round(v * 100, 1)
    return int(v) if float(v).is_integer() else round(v, 2)


def ratio_pct(m, num_name, den_name):
    # @returns float|None  # num/den ×100 (1 decimal); a 0/missing den → None
    d = m.get(den_name)
    n = m.get(num_name)
    if not d or n is None:
        return None
    return round(n / d * 100, 1)


def _cache_hit_pct(m):
    # @returns float|None  # hits/(hits+misses) ×100; a 0/missing denominator → None
    h = m.get("halogen:cache_hits_total")
    ms = m.get("halogen:cache_misses_total")
    if h is None or ms is None or (h + ms) == 0:
        return None
    return round(h / (h + ms) * 100, 1)


m = parse_metrics(sys.stdin.read())
out = {
    "metrics_note": "halogen /metrics — кумулятивные счётчики с старта сервера",
    "route_spec": os.environ.get("ROUTE_SPEC") or None,
    "slots": int(os.environ["ROUTE_SESSIONS"]) if os.environ.get("ROUTE_SESSIONS", "").isdigit() else None,
    "context": int(os.environ["ROUTE_CTX"]) if os.environ.get("ROUTE_CTX", "").isdigit() else None,
    "engine_up": num(m, "halogen:engine_up"),
    "requests_total": num(m, "halogen:requests_total"),
    "busy_for_seconds": num(m, "halogen:busy_for_seconds"),
    "cache_hits_total": num(m, "halogen:cache_hits_total"),
    "cache_misses_total": num(m, "halogen:cache_misses_total"),
    "cache_hit_pct": _cache_hit_pct(m),
    "cache_prompt_tokens_saved_total": num(m, "halogen:cache_prompt_tokens_saved_total"),
    "cache_entries": num(m, "halogen:cache_entries"),
    "cache_bytes": num(m, "halogen:cache_bytes"),
    "cache_evicted_total": num(m, "halogen:cache_evicted_total"),
    "cache_disk_bytes": num(m, "halogen:cache_disk_bytes"),
    "cache_disk_budget_bytes": num(m, "halogen:cache_disk_budget_bytes"),
    "cache_disk_hits_total": num(m, "halogen:cache_disk_hits_total"),
    "draft_tokens_total": num(m, "halogen:draft_tokens_total"),
    "draft_tokens_accepted_total": num(m, "halogen:draft_tokens_accepted_total"),
    "draft_accept_pct": ratio_pct(m, "halogen:draft_tokens_accepted_total",
                                  "halogen:draft_tokens_total"),
    "kv_pool_positions": num(m, "halogen:kv_pool_positions"),
    "kv_pool_reserved_tokens": num(m, "halogen:kv_pool_reserved_tokens"),
    "kv_reserved_pct": ratio_pct(m, "halogen:kv_pool_reserved_tokens",
                                 "halogen:kv_pool_positions"),
    "kv_pool_waiting": num(m, "halogen:kv_pool_waiting_for_room"),
    "queue_waited_total": num(m, "halogen:queue_waited_total"),
    "queue_wait_longest_seconds": num(m, "halogen:queue_wait_longest_seconds"),
    "queue_gave_up_total": num(m, "halogen:queue_gave_up_total"),
}
print(json.dumps(out))
