#!/usr/bin/env python3
# Purpose: the gufo panel's engine data for `lctl watch` (W3.2 — the
#   restyle per the approved dashboard-layout.md §5 layout): the K_*
#   /metrics constants of gufo, the computed indicators (the FINAL
#   methodologies: «средн» = a ratio-of-sums OVER THE UPTIME — gen/prefill
#   are computed from uptime, the v2 seconds formulas are gone;
#   τ = accepted/cycles), the uptime from the first `podman logs -t` stamp
#   (no uptime key in HTTP — the recon semantics), the route parsers
#   (event=load_completed, + draft_limit) and the cache configuration
#   (event=configured). The shared wire primitives (parse_metrics, Deltas,
#   sparkline, TZ/podman-RFC3339) live in the core/tpl/python/watch/
#   watch_frame.py frame (imported from there). The counter semantics
#   source — gufo/docs/internal/server.md:1557–1583, the key emitter —
#   gufo/src/cli/serve/http_server.cpp:1595–1685 (12 counters + 5 gauges).
#
# Side effects: none (pure functions; uptime_from_log is pure, now is a
#   parameter).
#
# Limitations/assumptions: stdlib only; the metric names come only from
#   the EXP-007 fact base + the emitter code (never made up); a missing
#   key → None (an old engine image — a «—» degradation in the render, not
#   a crash); gufo_prompt_state_*_bytes are deliberately NOT read (they
#   are emitted only to claim runners, absent on Qwen/Flash-Next —
#   docs:1580–1583).
import re

import watch_frame  # noqa: E402  # podman_ts_epoch — a frame wire format

# The /metrics keys (the full list, http_server.cpp:1595–1685). COUNTERS:
K_LOST = 'gufo_device_lost_total'
K_PROMPT = 'llamacpp:prompt_tokens_total'  # HELP: excluding cache hits
K_CACHED = 'llamacpp:prompt_tokens_cached_total'
K_PROMPT_S = 'llamacpp:prompt_seconds_total'
K_PRED = 'llamacpp:tokens_predicted_total'
K_PRED_S = 'llamacpp:tokens_predicted_seconds_total'
K_PEAK = 'llamacpp:n_tokens_max'  # TYPE counter — a monotonic maximum
K_ROUNDS = 'llamacpp:spec_decode_num_drafts_total'  # the VERIFICATION ROUNDS — the denominator of τ and the drafts pulse
K_DRAFT_TOK = 'llamacpp:spec_decode_num_draft_tokens_total'
K_ACC = 'llamacpp:spec_decode_num_accepted_tokens_total'
K_LOOKUP = 'gufo_spec_lookup_tokens_total'
K_LOOKUP_ACC = 'gufo_spec_lookup_accepted_tokens_total'
# GAUGES:
K_GEN_LAST = 'llamacpp:predicted_tokens_seconds'  # the last non-zero speed
K_PREFILL_LAST = 'llamacpp:prompt_tokens_seconds'
K_Q_PROC = 'llamacpp:requests_processing'
K_Q_DEF = 'llamacpp:requests_deferred'
K_KV = 'llamacpp:kv_cache_usage_ratio'


def _div(a, b):
    # @returns float|None  # a/b; a missing operand or a zero denominator → None
    if a is None or b is None or b == 0:
        return None
    return a / b


def _pct(a, b):
    # @returns float|None  # a/b×100; the same guards as _div
    if a is None or b is None or b == 0:
        return None
    return a / b * 100.0


def uptime_from_log(buf, now):
    # @param 1: iterable  # the log buffer lines (seed+live, `podman logs -t`)
    # @param 2: float     # now (time.time()); a parameter — pure (the
    #   battery pins are deterministic)
    # @returns int|None   # the uptime from the buffer's FIRST podman stamp
    #   (≈ the container start, ±sec; a log rotation/cleanup → an
    #   underestimate — ratified, the panel's docstring); no stamps → None
    # (the mutation marker — at the return below: cut it → the function
    #   returns None)
    for line in buf:
        ep = watch_frame.podman_ts_epoch(line)
        if ep is not None:
            up = int(now - ep)
            return max(0, up)  # fix:w32-uptime (cutting the marker → None →
            #   the selfcheck uptime/average pins fail)
    return None


def engine_stats(m, uptime_sec=None, window=None):
    # @param 1: dict|None   # the watch_frame.parse_metrics /metrics of
    #   this tick
    # @param 2: float|None  # the uptime sec (gufo — uptime_from_log; v2:
    #   not part of «средн» — an active window, not lifetime)
    # @param 3: dict|None   # the session deltas (the frame's SessionBase,
    #   W3.3 v2): «средн» = an exact ratio-of-sums over the session's
    #   seconds counters — gen-avg Δpredicted/Δpredicted_seconds,
    #   prefill-avg Δprompt/Δprompt_seconds (cached excluded by the
    #   emitter, HELP:1601), τ = Δaccepted/Δrounds; a None window (no base
    #   pinned — the seed (a), a fail tick, a recreate) → raw «—», the
    #   apply_tick hold patch keeps it. Idles do not dilute the denominator
    #   (amendment A1: one request in a session → its decode speed, not
    #   wall).
    # @returns dict|None    # an empty/None m → None (a dead tick). The
    #   gauge/counter/kv/queue/lookup keys unchanged (the sources are
    #   alive, the rows are gone — the data is not rendered; a dict cleanup
    #   is a separate decision, not "while we're at it"). The values are
    #   NOT rounded (the render formats). A None value = no key or a
    #   division by 0.
    if not m:
        return None
    prompt = m.get(K_PROMPT)
    cached = m.get(K_CACHED)
    pred = m.get(K_PRED)
    w = window or {}
    gen_avg = _div(w.get(K_PRED), w.get(K_PRED_S)) if w.get(K_PRED_S) else None  # fix:w33-gufo-window
    prefill_avg = (_div(w.get(K_PROMPT), w.get(K_PROMPT_S))
                   if w.get(K_PROMPT_S) else None)
    tau = _div(w.get(K_ACC), w.get(K_ROUNDS)) if w.get(K_ROUNDS) else None
    return {
        'gen_avg': gen_avg,   # v2: a session ratio-of-sums (the hold in apply_tick)
        'gen_last': m.get(K_GEN_LAST),
        'prefill_avg': prefill_avg,  # v2: a session ratio-of-sums
        'prefill_last': m.get(K_PREFILL_LAST),
        # the cache effect: prompt_tokens_total ALREADY excludes cache
        # hits (HELP http_server.cpp:1601) → the denominator = prompt +
        # cached, otherwise >100%
        'cache_pct': _pct(cached, prompt + cached)
        if prompt is not None and cached is not None else None,
        # acceptance — over the PROPOSED TOKENS; K_ROUNDS (rounds) is not the denominator
        'spec_pct': _pct(m.get(K_ACC), m.get(K_DRAFT_TOK)),
        # τ — the average accepted draft length per cycle (D2: the
        # «ток/цикл» unit is printed by the frame); v2: the session window
        'tau': tau,
        'kv_pct': None if m.get(K_KV) is None else m[K_KV] * 100.0,
        'kv_peak': m.get(K_PEAK),
        'q_proc': m.get(K_Q_PROC),
        'q_def': m.get(K_Q_DEF),
        'tok_prompt': m.get(K_PROMPT),
        'tok_cached': m.get(K_CACHED),
        'tok_pred': m.get(K_PRED),
        'lookup_pct': _pct(m.get(K_LOOKUP_ACC), m.get(K_LOOKUP)),
        'lookup_tok': m.get(K_LOOKUP),
        'lookup_acc': m.get(K_LOOKUP_ACC),
        'device_lost': m.get(K_LOST),
    }


# The keys for the session window (SessionBase): COUNTERS ONLY. The gauges
# (predicted/prompt_tokens_seconds, requests_processing, the kv ratio)
# dive — a negative Δ = a false session reset exactly on a working tick
# (the live window 2026-11-24: «средн»/τ «—» forever, processing 1→0
# on every done). The frame knows no keys (R6) — the filter is here.
SESSION_KEYS = (K_LOST, K_PROMPT, K_CACHED, K_PRED, K_PRED_S, K_PROMPT_S,
                K_PEAK, K_ROUNDS, K_DRAFT_TOK, K_ACC, K_LOOKUP,
                K_LOOKUP_ACC)

RE_TTFT = re.compile(r' ttft_ms=([0-9.]+)')


def ttft_ms_list(buf):
    # @param 1: iterable  # the log buffer lines (seed+live, `podman logs -t`)
    # @returns list[float]  # ttft_ms in the buffer's line order
    # The source — the finished request's LogRequest details
    # (GenerationLogDetails, generation_metrics.hpp:167 →
    # http_server.cpp:2642); the ' ttft_ms=' marker is unique to done
    # lines (progress lines do not contain it) —
    # dashboard-methods-gufo.md §TTFT
    out = []
    for line in buf:
        m = RE_TTFT.search(line)
        if m:
            out.append(float(m.group(1)))
    return out


def ttft_scheme(tt):
    # @param 1: list[float]  # the session's ttft_ms (the order = the
    #   buffer's line order)
    # @returns dict  # {'ttft_s','ttft_win'}; the §TTFT dual: «средн» — the
    #   whole session in the buffer (after a recreate the buffer is fresh),
    #   «окно» — the rolling 10 requests; the hipfire-lifetime branch is
    #   unreproducible (the 200-line rotation — ratified). Empty → both
    #   None (the seed «—»); the between-requests hold is natural (the
    #   buffer unchanged)
    if not tt:
        return {'ttft_s': None, 'ttft_win': None}
    win = tt[-10:]
    return {'ttft_s': sum(tt) / len(tt) / 1000.0,          # ms → s (the
            'ttft_win': sum(win) / len(win) / 1000.0}      # frame's «%.2f с»)


def parse_route_lines(lines):
    # @param 1: iterable  # the log buffer lines
    # @returns dict  # {'spec','draft_limit','sessions','ctx','model'} from
    #   the LAST event=load_completed line (the last one wins — the last
    #   recreate); the parse_route lib/health.sh semantics 1:1: model —
    #   the substring between 'model=' and 'sessions=' (gufo names contain
    #   spaces); + draft_limit (the Спекуляция config «dflash2 K=7» is
    #   assembled by compose_scheme); no line → all ''
    spec = draft_limit = sessions = ctx = model = ''
    for line in lines:
        if 'event=load_completed' not in line:
            continue
        m = re.search(r'speculative=([^ ]+)', line)
        spec = m.group(1) if m else ''
        m = re.search(r'draft_limit=([0-9]+)', line)
        draft_limit = m.group(1) if m else ''
        m = re.search(r'sessions=([0-9]+)', line)
        sessions = m.group(1) if m else ''
        m = re.search(r'context_tokens=([0-9]+)', line)
        ctx = m.group(1) if m else ''
        if 'model=' in line:
            model = line.split('model=', 1)[1].split('sessions=', 1)[0].strip()
    return {'spec': spec, 'draft_limit': draft_limit, 'sessions': sessions,
            'ctx': ctx, 'model': model}


def parse_configured_lines(lines):
    # @param 1: iterable  # the log buffer lines
    # @returns dict  # {'sessions','ram_cache','capacity','automatic','disk'}
    #   from the LAST event=configured line (the live FX-W1b log format);
    #   the parse_configured lib/commands.sh semantics 1:1 (the \b
    #   boundaries: capacity_bytes does not catch disk_capacity_bytes);
    #   bytes — the render converts to GiB; no line → all ''
    sessions = ram_cache = capacity = automatic = disk = ''
    for line in lines:
        if 'event=configured' not in line:
            continue
        m = re.search(r'sessions=([0-9]+)', line)
        sessions = m.group(1) if m else ''
        m = re.search(r'\bram_cache=(on|off)', line)
        ram_cache = m.group(1) if m else ''
        m = re.search(r'\bcapacity_bytes=([0-9]+)', line)
        capacity = m.group(1) if m else ''
        m = re.search(r'\bautomatic_bytes=([0-9]+)', line)
        automatic = m.group(1) if m else ''
        m = re.search(r'\bdisk_capacity_bytes=([0-9]+)', line)
        disk = m.group(1) if m else ''
    return {'sessions': sessions, 'ram_cache': ram_cache,
            'capacity': capacity, 'automatic': automatic, 'disk': disk}
