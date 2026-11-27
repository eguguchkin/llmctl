#!/usr/bin/env python3
# Purpose: the hipfire panel's entry point of `lctl watch` (ENGINE_WATCH_TUI,
#   W3.2 — the restyle per the approved dashboard-layout.md layout) — it
#   assembles the panels [«Движок» (the frame's CommonEnginePanel: Uptime +
#   Configuration), «Железо» (the frame), «Метрики» (the frame's
#   MetricsPanel — a shared 8-row block), «Скорость» (the frame, row 3)]
#   from the core/tpl/python/watch/watch_frame.py frame (PYTHONPATH is set
#   by the adapter's engine_watch_env via cmd_watch; the battery sets it
#   directly), provides the engine-data ENG provider and aggregates the
#   selfcheck (the --selfcheck flag or the battery's LCTL_WATCH_SELFCHECK
#   env seam): the frame part (frame.selfcheck) + the engine one (the
#   health/stats parsers, the parser of the load summary's real
#   ` | ` format, scheme v2, the draft aggregate, the plain pins on
#   fixtures).
#
# Sources (W3; the «no /metrics» claim was refuted by recon 4.2 + a live
#   arbitration live 2026-11-23 — do NOT inherit it): /health (JSON —
#   status/model/loading/caps), /stats (JSON — uptime_sec, recent_tok_s,
#   queue_depth, loaded_config {kv_mode,kv_backend,max_seq}, spec_cycles,
#   draft_positions), /metrics (prometheus, the hipfire_ prefix — the
#   cache counters, completion, the decode/prefill tok/s histograms and
#   spec_tau, ttft_milliseconds, prefix_hits/reused (multi-slot), the
#   swap budgets, queue_capacity; the R-1 live-curl arbitration of
#   2026-11-23: there is NO spec_cycles_total in /metrics — the draft
#   pulse is computed from the /stats spec_cycles field), the log (the
#   load summary ` | ` + the per-request done `[req …] … tau=`).
#   The pulse — the hipfire counters move on done → the «completion
#   pulse».
#
#   FINAL methodologies (layout §5): «средн» = a ratio-of-sums over
#   uptime (generation Σcompletion/uptime_sec; prefill
#   (prompt−cached)/uptime — prompt INCLUDES cached, HELP); accepted =
#   Σaccepted/Σoffered over draft_positions, empty (serial prod — the
#   fn_batch arrays are lane-only) → the tau/K fallback:
#   tau=accepted/cycles exactly (qwen.rs:7929), K from the facet
#   (fix:w33-spec-pct, EXP-016 2026-11-24); τ = the hist mean, the unit
#   «ток/цикл» (D2, printed by the frame); Cache RAM/disk — the budgets
#   FROM THE CONFIG (the adapter's env seam
#   LCTL_WATCH_HIPFIRE_CACHE_RAM/DISK ← the profile's config.toml; the
#   /metrics swap family — a foreign mechanism, recon-cache-; the disk
#   used — a scan of the session-cache dir, W3.2.1 p.5); the prefill
#   pulse = Δ(prompt−cached) — otherwise cache hits would count as work.
#
# Side effects: see watch_frame.main_loop (every tick — GET /health +
#   /stats + /metrics via curl from PATH; TUI — the podman logs
#   seed/stream). Touches no files or the stack.
#
# Limitations/assumptions: stdlib only, 3.8+ syntax; an old image without
#   the /stats//metrics fields → None → «—» in the render (a degradation,
#   not a crash); a failure of ONLY /metrics → a live tick with «—» in
#   the metrics and a reset of the decode/prefill pulses (the draft pulse
#   lives — its source is /stats); the fixture numbers —
#   engines/hipfire/tests/fixtures/ (live windows, the 2026-11-23
#   arbitration).
import json
import os
import re
import sys

# The frame is put on sys.path from __file__ (the 1:1 gufo sibling-import
# pattern): the bare-run fallback (--selfcheck without env); engine_watch_env/
# the battery set PYTHONPATH
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                '..', '..', '..', '..',
                                'core', 'tpl', 'python', 'watch'))
import watch_frame  # noqa: E402

# The /metrics names (only from recon 4.2 §1 + the serve/metrics.rs
# emitter code — never made up; the _sum/_count histograms, *_bucket are
# dropped by the frame. The R-1 live-curl arbitration of 2026-11-23:
# hipfire_spec_cycles_total is NOT in the live body — the constant is
# removed, the draft pulse is computed from the /stats spec_cycles field.
# prefix_* — the multi-slot family: empty on solo prod (the row honestly
# «—»), the name from recon §1 — verify the HELP in a live window; the
# R-1 risk is latent: a name drift is fixed by a single-file constant.
# The cache BUDGETS are NOT read from /metrics: swap_* is a foreign
# multi-slot mechanism (recon-cache-sources; W3.2.1 p.5) — they are
# delivered by the adapter's env seam (engine_watch_env ← the profile's
# config.toml), see compose_scheme)
K_PROMPT = 'hipfire_prompt_tokens_total'
K_CACHED = 'hipfire_cached_prompt_tokens_total'
K_COMPLETION = 'hipfire_completion_tokens_total'
K_DECODE_S = 'hipfire_decode_tokens_per_second_sum'
K_DECODE_C = 'hipfire_decode_tokens_per_second_count'
K_PREFILL_S = 'hipfire_prefill_tokens_per_second_sum'
K_PREFILL_C = 'hipfire_prefill_tokens_per_second_count'
K_TAU_S = 'hipfire_spec_tau_sum'
K_TAU_C = 'hipfire_spec_tau_count'
K_QCAP = 'hipfire_queue_capacity'
K_TTFT_S = 'hipfire_ttft_milliseconds_sum'
K_TTFT_C = 'hipfire_ttft_milliseconds_count'
K_LAT_S = 'hipfire_request_latency_milliseconds_sum'  # fix:w33-lat-keys
K_LAT_C = 'hipfire_request_latency_milliseconds_count'  # fix:w33-lat-keys


def parse_health(text):
    # @returns dict  # the /health body → dict; garbage/non-object/None → {}
    #   (no crash: an old image — a «—» degradation in the render)
    try:
        h = json.loads(text)  # fix:w2-health-parse
    except (ValueError, TypeError):
        return {}
    return h if isinstance(h, dict) else {}


def parse_stats_json(text):
    # @returns dict  # the /stats body → dict; garbage/non-object/None → {}
    #   (an old image without the fields — a «—» degradation, not a crash)
    try:
        s = json.loads(text)
    except (ValueError, TypeError):
        return {}
    return s if isinstance(s, dict) else {}


def healthy(h):
    # @returns bool  # the health_ok.sh dialect: status ok AND loading_model empty
    return bool(h) and h.get('status') == 'ok' and not h.get('loading_model')


def parse_summary(buf):
    # @returns dict  # the log buffer's LAST load summary → spec/kv/ctx.
    #   The real 0.4.7 format (recon-live §3, a live arbitration):
    #   `hipfire load summary: <model> (<arch>) | spec: <spec> | kv: <kv> |
    #   context: <N> (…)` — the fields separated by ` | `, the values up
    #   to `|` (trimmed); the facet's trailing parens are NOT part of the
    #   value. Last wins — a fresh load on recreate; no line → all ''
    #   (before the first load — normal, not an error)
    route = {'spec': '', 'kv': '', 'ctx': ''}
    for line in buf:
        if 'load summary' not in line:
            continue
        m = re.search(r'spec:\s*([^|]+)', line)    # fix:w3-summary-parse
        kv = re.search(r'kv:\s*([^|]+)', line)     # fix:w3-summary-parse
        ctx = re.search(r'context:\s*(\d+)', line)  # fix:w3-summary-parse
        route = {'spec': m.group(1).strip() if m else '',
                 'kv': kv.group(1).strip() if kv else '',
                 'ctx': ctx.group(1) if ctx else ''}
    return route


def parse_lanes(buf):
    # @returns int|None  # the lanes from the boot line «qwen4 fn-lanes
    #   staged: … lanes=N …» — the REAL flash parallelism (fix:w40-lanes;
    #   no line → None: a route without lanes (27b qwen3_5) renders the
    #   slots as before). Last wins — a fresh staging after a recreate
    n = None
    for line in buf:
        if 'fn-lanes staged' not in line:
            continue
        m = re.search(r'lanes=(\d+)', line)
        if m:
            n = int(m.group(1))
    return n


def parse_done_line(buf):
    # @returns (float, float)|None  # (tok_s, tau) of the LAST done line
    #   of the log `[req …] drafter=… tau=<τ> … tok/s=<x> decode (…)` —
    #   the honest per-request decode (recon §2C, qwen.rs:7916; the wall
    #   recent_tok_s of /stats is no longer read in v2 — the EXP-015
    #   calibration: −45…52%). The '[req ' anchor isolates from the bench
    #   synthetic «inference τ=…» and bench lines; no done lines (multi_slot
    #   by design / the panel started without requests) → None → «—» (a
    #   hold until the first line).
    for line in reversed(buf):
        if '[req ' in line:
            mt = re.search(r'tau=([0-9.]+)', line)
            ms = re.search(r'tok/s=([0-9.]+)', line)
            if mt and ms:
                return (float(ms.group(1)), float(mt.group(1)))
            return None
    return None


def spec_conf_compact(facet):
    # @returns string  # the load summary's spec facet compressed to
    #   «<имя> K=<N>» / «<имя> block=<N>» («qwen4 native mtp K=7, …» →
    #   «mtp K=7»; «dflash (draft …, block 8)» → «dflash block=8» — the
    #   dflash facet carries no K=, EXP-016 2026-11-24; layout §1 — the
    #   short form, the full facet stays in the Logs); neither K= nor
    #   block N → the facet verbatim
    facet = facet or ''
    m = re.search(r'([a-z][a-z0-9-]*)\s+K=(\d+)', facet)
    if m:
        return '%s K=%s' % (m.group(1), m.group(2))
    m = re.search(r'\bblock\s+(\d+)', facet)
    if m:
        n = re.match(r'\s*([a-z][a-z0-9-]*)', facet)
        return ('%s block=%s' % (n.group(1), m.group(1))) if n else facet
    return facet


def spec_draft_k(facet):
    # @returns int|None  # drafts per cycle from the load summary's facet
    #   — the denominator of accepted% (fix:w33-spec-pct): «… mtp K=7 …» →
    #   7; «dflash (draft …, block 8)» → 8; none → None (tau/K not
    #   computed). The basis: tau = accepted/cycles EXACTLY (qwen.rs:7929)
    #   → accepted% = tau/K (the trailing short cycles and AR windows
    #   underestimate it slightly)
    facet = facet or ''
    m = re.search(r'\bK=(\d+)', facet) or re.search(r'\bblock\s+(\d+)', facet)
    return int(m.group(1)) if m else None


def sum_done_windows(buf):
    # @returns int  # the Σ of windows («decode (N tok, W windows)») over
    #   all the buffer's done lines — the serial spec pulse's cumulative
    #   (fix:w33-spec-pulse: spec_cycles in /stats is dead on serial — the
    #   fn_batch arrays are lane-only, EXP-016 2026-11-24). A buffer
    #   rotation (deque 500) can shrink the sum → the delta clamps ≥ 0
    #   (an undercount on sessions >500 requests — acceptable)
    total = 0
    for line in buf:
        if '[req ' in line:
            m = re.search(r'decode \(\d+ tok, (\d+) windows\)', line)
            if m:
                total += int(m.group(1))
    return total


def draft_acceptance_pct(sj):
    # @returns float|None  # accepted = Σaccepted/Σoffered over
    #   draft_positions[] (/stats, the recon semantics: the aggregate is
    #   available from the offered/accepted fields; the per-position rate
    #   = accepted/reached — a different denominator, do NOT show it).
    #   Empty in prod even after spec requests (the live §5 arbitration) /
    #   no field (an old image) / Σoffered=0 → None → «—»
    # fix:w32-draft-agg — the Σ/Σ aggregate over positions (empty in prod
    # → None → «—»; the per-position rate = accepted/reached — a different
    # denominator, not shown)
    positions = sj.get('draft_positions') or []
    offered = accepted = 0
    for p in positions:
        offered += p.get('offered') or 0
        accepted += p.get('accepted') or 0  # fix:w32-draft-agg
    return (accepted / offered * 100.0) if offered else None


def _div(a, b):
    # @returns float|None  # a/b; a missing operand or a zero denominator → None
    if a is None or b is None or b == 0:
        return None
    return a / b


def _budget_str(b):
    # @returns string  # a budget in bytes → «20.4 GiB (бюджет)»; none → ''
    #   (RAM: no used metric exists — a budget-only row, layout §5; disk —
    #   _disk_budget_str: there a used-scan of the dir exists)
    return ('%s GiB (бюджет)' % watch_frame.fmt1(b / (1024.0 ** 3))
            if b is not None else '')


def _disk_budget_str(used, budget):
    # @returns string  # used+budget → «3.2 / 32.0 GiB (бюджет)» (used —
    #   a scan of the session-cache dir (W3.2.1 p.5), the budget — from
    #   the config at render time; fmt1 for both — parity with gufo); no
    #   budget → the used only («3.2 GiB»); no used → budget-only
    #   («32.0 GiB (бюджет)»); neither → '' (the render «—»)
    if budget is None and used is None:
        return ''
    if budget is None:
        return '%s GiB' % watch_frame.fmt1(used / (1024.0 ** 3))
    if used is None:
        return '%s GiB (бюджет)' % watch_frame.fmt1(budget / (1024.0 ** 3))
    return '%s / %s GiB (бюджет)' % (watch_frame.fmt1(used / (1024.0 ** 3)),
                                     watch_frame.fmt1(budget / (1024.0 ** 3)))


def compose_scheme(health, stats_json, metrics, summary,
                   cache_ram_b=None, cache_disk_b=None, cache_disk_used=None,
                   window=None, done=None):
    # @returns dict  # the frame's scheme v2 dict from the tick's facts
    #   (a pure function — collect and the selfcheck; everything
    #   None-safe, a missing value → «—» in the render). The cache (OQ-1,
    #   resolved from the emitter code serve/metrics.rs:339-344 +
    #   slots.rs:1895): prompt_tokens_total INCLUDES cached (prompt =
    #   cached + prefill) → cached/prompt; a prompt+cached denominator
    #   would double-count. The cache budgets — the adapter env seam's
    #   ARGUMENTS (bytes from the profile's config.toml and the used-scan
    #   of the dir, W3.2.1 p.5; NOT read from /metrics — swap_* is a
    #   foreign mechanism); missing → '' → «—» in the render.
    #   W3.3 v2 (amendment A1, dashboard-layout §5): «средн» = the session's
    #   ACTIVE window — the session deltas (the base = the first live
    #   /metrics, the frame's SessionBase); gen-avg =
    #   Δcompletion/((Δlat−Δttft)/1000) — the exact Σtokens/Σdecode-time
    #   (Δ(lat−ttft) ≤ 0 → «—», fail-visible); prefill-avg = the
    #   mean-of-rates of the prefill histogram (the engine does not
    #   accumulate Σprefill-time — the §5 v2 caveat; gufo computes it
    #   exactly); the ttft «window» = the session mean (dual with the
    #   lifetime, the row's label «TTFT»); τ = the session's
    #   Δspec_tau_sum/Δcount. A None window (no base pinned — the seed
    #   (a), a fail tick, a recreate) → raw «—»; the apply_tick hold patch
    #   keeps the last shown. gen_last — the log's done line (tok/s=), NOT
    #   recent_tok_s (wall, the EXP-015 calibration: −45…52%). prefill_last
    #   is None raw — the tick's Δprefill-histogram is put by apply_tick
    #   (the hold).
    sj = stats_json or {}
    m = metrics or {}
    lc = sj.get('loaded_config') or {}
    caps = (health or {}).get('capabilities') or {}
    uptime = sj.get('uptime_sec')
    prompt = m.get(K_PROMPT)
    cached = m.get(K_CACHED)
    kv = lc.get('kv_mode')
    kv_mode = (kv + (' (%s)' % lc['kv_backend'] if lc.get('kv_backend') else '')
               if kv else None)
    ttft = _div(m.get(K_TTFT_S), m.get(K_TTFT_C))
    w = window or {}
    dec_ms = (w.get(K_LAT_S) - w.get(K_TTFT_S)
              if w.get(K_LAT_S) is not None and w.get(K_TTFT_S) is not None
              else None)
    gen_num = w.get(K_COMPLETION)
    gen_avg = (gen_num / (dec_ms / 1000.0)
               if gen_num and dec_ms is not None and dec_ms > 0 else None)
    prefill_avg = (_div(w.get(K_PREFILL_S), w.get(K_PREFILL_C))
                   if w.get(K_PREFILL_C) else None)
    ttft_win = _div(w.get(K_TTFT_S), w.get(K_TTFT_C))
    ttft_win = ttft_win / 1000.0 if ttft_win is not None else None
    # fix:w33-spec-pct — serial: draft_positions is dead (the fn_batch
    #   arrays are lane-only; the mid-flight measurement EXP-016
    #   2026-11-24) → accepted% = tau/K: the tau from the done line
    #   (accepted/cycles exactly, qwen.rs:7929), the K from the facet.
    #   parallel: the exact Σaccepted/Σoffered takes priority.
    spec_pct = draft_acceptance_pct(sj)
    if spec_pct is None:
        tau_done = (done or (None, None))[1]
        k = spec_draft_k((summary or {}).get('spec'))
        spec_pct = (tau_done / k * 100.0) if tau_done is not None and k else None
    # slots — the REAL parallelism (layout §1 «N = параллелизм»):
    #     multi-slot — the slot tape; standard — 1 (the engine decodes one
    #     request, slot_concurrency=1 — mod.rs:1991; it used to show the
    #     config tape «4 ×» — read as 4-way parallelism, the user's
    #     2026-11-24 finding). ctx_tape — the serve.multi_slot_slots tape
    #     on standard (the admission queue capacity — the «Очередь» row,
    #     plus the ready multi-slot config): the frame will append
    #     «(лента N)»
    ms = bool(caps.get('multi_slot'))
    tape = caps.get('multi_slot_slots')
    if tape is None:
        slots = None                        # empty caps (an old image) — «—»
    else:
        slots = tape if ms else 1
    ctx_tape = tape if (tape is not None and not ms and tape != 1) else None
    lanes = (summary or {}).get('lanes')
    if lanes:                               # fix:w40-lanes — fn-lanes = реальный параллелизм (саппресс «ленты» standby-конфига multi-slot)
        slots, ctx_tape = lanes, None
    tau = (_div(w.get(K_TAU_S), w.get(K_TAU_C))
           if w.get(K_TAU_C) else None)
    return {
        'uptime_sec': uptime,
        'spec_conf': spec_conf_compact((summary or {}).get('spec')),
        # slots — РЕАЛЬНЫЙ параллелизм (см. выше); ctx_tape — лента на standard
        'slots': slots,
        'ctx_tape': ctx_tape,
        'ctx_tokens': lc.get('max_seq'),
        'kv_mode': kv_mode,
        'cache_ram': _budget_str(cache_ram_b),
        'cache_disk': _disk_budget_str(cache_disk_used, cache_disk_b),
        'gen_avg': gen_avg,   # v2: the session's Σtokens/Σdecode-time (the hold in apply_tick)
        'gen_last': (done or (None, None))[0],  # the log's done line (tok/s=)
        'prefill_avg': prefill_avg,  # v2: the mean-of-rates session (the hold in apply_tick)
        'prefill_last': None,  # the tick's Δprefill-histogram — put by apply_tick (the hold)
        'cache_cached': cached,
        'cache_total': prompt,  # prompt INCLUDES cached — the absolutes derive from it
        'in_total': prompt,  # fix:w41 accepted = the incoming total (prompt already includes cached — the hipfire semantics, unlike gufo's prompt+cached)
        'cache_pct': (cached / prompt * 100.0)
        if prompt and cached is not None else None,
        'spec_pct': spec_pct,
        'tau': tau,  # v2: the session window (the hold in apply_tick)
        'queue_depth': sj.get('queue_depth'),
        'queue_capacity': m.get(K_QCAP),
        'ttft_s': (ttft / 1000.0) if ttft is not None else None,
        'ttft_win': ttft_win,  # v2 c1+c2: the dual «контейнер (средн) · сессия (окно)»
        'gen_total': m.get(K_COMPLETION),
    }


class HipfireEng:
    """hipfire's ENG provider: /health + /stats + /metrics (three GETs per
    tick; a health/stats failure — the frame's dead tick, a failure of
    ONLY /metrics — a live tick with «—» and a reset of the decode/prefill
    pulses; the draft pulse — the Δspec_cycles from /stats), the route
    from the log buffer, scheme v2.
    The frame owns the loop; only the engine dialect lives here."""

    def __init__(self):
        self.port = int(watch_frame.env_float('LCTL_WATCH_PORT', 11435))
        self.health = {}   # the last snapshot — the status_bar's model
        # decode — the Δcompletion (Deltas); prefill — a MANUAL delta of
        # Δ(prompt−cached) (cache hits do not count as prefill work, §5)
        self.deltas = watch_frame.Deltas({'decode': K_COMPLETION})
        # W3.3: the histograms' tick deltas — the hold gates («a request
        # finished»)
        self.hd = watch_frame.Deltas({
            'pf_s': K_PREFILL_S, 'pf_c': K_PREFILL_C, 'ttft_c': K_TTFT_C,
            'lat_c': K_LAT_C, 'tau_c': K_TAU_C})
        self.session = watch_frame.SessionBase()  # W3.3: the session's active window
        self._summary = {'spec': '', 'kv': '', 'ctx': ''}  # the route_conf warm-up
        self._boot = None         # fix:w38-bootlines — the full scan's boot-line cache
        self._prev_cycles = None  # the Δspec_cycles base (/stats)
        self._win_sum = None      # the Σwindows-of-done-lines base (the serial spec pulse)
        self._prev_pf = None      # the Δ(prompt−cached) base — the «Скорость» pulse
        self._done = None         # the done line (tok_s, tau) — gen_last, the route_conf cache
        self._ms_route = False    # a multi-slot route (e1): the histograms = a wall fallback → «—»
        # The Hold carriers (the W3.3 consolidation of W3.2.2/3/4; the
        # frame's Hold):
        self.h_gen = watch_frame.Hold()      # ген-средн
        self.h_pf_avg = watch_frame.Hold()   # prefill-средн
        self.h_pf_last = watch_frame.Hold()  # prefill-посл
        self.h_ttft = watch_frame.Hold()     # the ttft window (dual)
        self.h_tau = watch_frame.Hold()      # the τ window
        self.hist = {'decode': [], 'prefill': [], 'drafts': []}

    def collect(self, snap):
        # The tick's engine part: /health → the parser; healthy → a live
        # tick (the frame's stats slot = health, engine_ok = bool(stats));
        # loading/garbage → stats=None (a dead tick). /stats — a failure →
        # an exception (the frame catches → the tick is dead). /metrics —
        # a failure of only it → a live tick, metrics=None (the metrics
        # «—», the pulses reset)
        self.health = parse_health(
            watch_frame.http_get('http://127.0.0.1:%d/health' % self.port))
        snap['health'] = self.health
        # W3.3 e1 + fix 2: the predicate — a multi-slot ROUTE
        #     (capabilities.mode, serve/mod.rs:607 «mode": if multi_slot {
        #     "multi-slot" } else { "standard" }» → the /health
        #     capabilities, http.rs:1021), NOT slots>1: the slots = the
        #     queue capacity (queue_capacity), >1 on all profiles
        #     (flash=2/27b=4) — the former predicate broke the rows on
        #     solo profiles (the user's regression, 27b-single with slots
        #     4). multi-slot → the histograms = the wall fallback
        #     (metrics.rs:319-321) / empty → the rows «—» without
        #     fallbacks; the ttft (per-attempt) is alive
        caps = self.health.get('capabilities') or {}
        self._ms_route = (caps.get('mode') == 'multi-slot')
        if not healthy(self.health):
            snap['stats'] = None
            return
        snap['stats'] = self.health
        snap['stats_json'] = parse_stats_json(
            watch_frame.http_get('http://127.0.0.1:%d/stats' % self.port))
        try:
            snap['metrics'] = watch_frame.parse_metrics(
                watch_frame.http_get('http://127.0.0.1:%d/metrics' % self.port))
        except Exception:
            snap['metrics'] = None
        # The adapter's env seam (engine_watch_env): the cache budgets —
        #     bytes from the profile's config.toml, the session-cache dir
        #     — the state dir (layout §1 «(бюджет)»; W3.2.1 p.5). 0/no key
        #     → None → «—»; garbage in env_float → the default 0 → None;
        #     a scan error → None
        ram_b = watch_frame.env_float('LCTL_WATCH_HIPFIRE_CACHE_RAM', 0) \
            or None
        disk_b = watch_frame.env_float('LCTL_WATCH_HIPFIRE_CACHE_DISK', 0) \
            or None
        cache_dir = os.environ.get('LCTL_WATCH_HIPFIRE_CACHE_DIR') or ''  # fix:w321-cache-env
        used = (watch_frame.dir_size_bytes(cache_dir)
                if cache_dir else None)
        snap['window'] = self.session.deltas(snap['metrics'])
        snap['scheme'] = compose_scheme(self.health, snap['stats_json'],
                                        snap['metrics'], self._summary,
                                        ram_b, disk_b, used,
                                        snap.get('window'), self._done)

    def apply_tick(self, snap):
        # The completion pulse: the hipfire counters move on done → the
        # decode/prefill deltas per tick (NOT a speed); the draft pulse —
        # the Δspec_cycles from the /stats JSON (fix:w3-r1-cycles, the
        # R-1 live-curl arbitration of 2026-11-23:
        # hipfire_spec_cycles_total does NOT exist in /metrics — the spec
        # cycles live only in /stats; the labeled
        # hipfire_spec_draft_position_total is not used — labels,
        # parse_metrics collapses by name, not a sum). The prefill pulse —
        # Δ(prompt−cached): done counters, the difference = the real
        # prefill. A dead tick — a reset of all bases; a negative Δ (a
        # recreate) and a missing field (an old image) → None («—»). The
        # pulse is only known after apply_tick → it is not put into the
        # scheme (the history — for the frame); the scheme itself is
        # patched below (the v2 hold semantics, W3.3)
        m = snap.get('metrics')
        if snap['engine_ok']:
            d = self.deltas.update(m)
            cur_pf = ((m or {}).get(K_PROMPT), (m or {}).get(K_CACHED))
            if None in cur_pf:
                cur_pf = None
            hd = self.hd.update(m)  # W3.3: the histograms' tick deltas (the gates)
        else:
            d = self.deltas.update(None)
            self._prev_cycles = None
            self._prev_pf = None
            # a recreate: the old container's done cache/window/holds are invalid
            self._done = None
            self._ms_route = False
            self.session.reset()
            self.h_gen.reset()
            self.h_pf_avg.reset()
            self.h_pf_last.reset()
            self.h_ttft.reset()
            self.h_tau.reset()
            cur_pf = None
            hd = None
        pf = None
        if cur_pf is not None:
            val = cur_pf[0] - cur_pf[1]
            if self._prev_pf is not None and val >= self._prev_pf:
                pf = int(val - self._prev_pf)
            self._prev_pf = val
        else:
            self._prev_pf = None
        d['prefill'] = pf
        pulse = None
        cur = (snap.get('stats_json') or {}).get('spec_cycles')  # fix:w3-r1-cycles
        if cur is not None:
            if self._prev_cycles is not None and cur >= self._prev_cycles:
                pulse = int(cur - self._prev_cycles)
            self._prev_cycles = cur
        d['drafts'] = pulse
        for key in ('decode', 'prefill', 'drafts'):
            self.hist[key].append(d.get(key) or 0)
        # W3.3 v2: the scheme hold patches (the §5 v2 layout; the freeze
        #     consolidation of W3.2.2/3/4 onto the new definitions —
        #     «melting» does not come back). The gates — the histograms'
        #     Δcount (>0 = «a request finished»): a fresh session value is
        #     accepted only on a tick with work, otherwise (a quiet tick /
        #     no /metrics) the last one is held; a recreate → a reset.
        #     prefill-посл = the TICK's Δprefill-histogram (the mean over
        #     the tick's completions — the tick artifact of the old
        #     Δ(prompt−cached)/Δt is gone). The selfcheck pulses call
        #     apply_tick without a scheme — skipped.
        scheme = snap.get('scheme')
        if scheme is not None:
            g = hd or {}
            if 'gen_avg' in scheme:
                scheme['gen_avg'] = self.h_gen.take(
                    scheme.get('gen_avg'), bool(g.get('lat_c')))  # fix:w33-hold
            if 'prefill_avg' in scheme:
                scheme['prefill_avg'] = self.h_pf_avg.take(
                    scheme.get('prefill_avg'), bool(g.get('pf_c')))  # fix:w33-hold
            if 'prefill_last' in scheme:
                pfv = (g['pf_s'] / g['pf_c']) if g.get('pf_c') else None
                scheme['prefill_last'] = self.h_pf_last.take(
                    pfv, bool(g.get('pf_c')))  # fix:w33-hold
            if 'ttft_win' in scheme:
                scheme['ttft_win'] = self.h_ttft.take(
                    scheme.get('ttft_win'), bool(g.get('ttft_c')))  # fix:w33-hold
            if 'tau' in scheme:
                scheme['tau'] = self.h_tau.take(
                    scheme.get('tau'), bool(g.get('tau_c')))  # fix:w33-hold
            if self._ms_route:  # fix:w33-slot-branch — e1: «—» without fallbacks
                scheme['gen_avg'] = None  # the gen-avg is computed from the counters above — forced as is
                scheme['gen_last'] = None  # no [req done lines on multi-slot
                scheme['prefill_avg'] = None
                scheme['prefill_last'] = None
                scheme['tau'] = None  # the hist spec_tau is not fed on a slot route (done lines without tau)
        return d

    def route_conf(self, buf):
        # @returns (dict, dict)  # the route (the load summary ` | ` + the
        #   model from health) + an empty conf (hipfire has no conf slots —
        #   the budgets come from /metrics; the frame seam kept)
        lines = self._boot_merge(buf)
        self._summary = parse_summary(lines)
        self._summary['lanes'] = parse_lanes(lines)   # fix:w40-lanes
        route = dict(self._summary)
        route['model'] = self.health.get('model') or ''
        # the done line — gen-посл (a lag ≤1 tick: route_conf runs after
        #     apply_tick); the line unchanged/the buffer rotated → the
        #     cache keeps it
        self._done = parse_done_line(buf) or self._done  # fix:w33-done-parse
        # fix:w33-spec-pulse — serial: spec_cycles is static → the tick's
        #     drafts pulse = the Σwindows of the NEW done lines (a delta of
        #     the cumulative, clamped ≥0); parallel untouched (the
        #     Δspec_cycles is alive, no done lines → the Σ does not grow).
        #     hist is already extended by apply_tick — we patch the last
        #     element BEFORE the render (route_conf runs before the panels)
        ws = sum_done_windows(buf)
        d_win = (ws - self._win_sum) if self._win_sum is not None else 0
        self._win_sum = ws
        if d_win > 0 and self.hist['drafts']:
            self.hist['drafts'][-1] = d_win
        return (route, {})

    def _boot_merge(self, buf):
        # fix:w38-bootlines (a mirror of the gufo watch.py) — the load
        # summary line is pushed out of the `--tail 200` seed window by a
        # chatty load (the live case 2026-11-25: a stream of daemon
        # errors of failed requests — Спекуляция «—»). The full scan: one
        # full scan of the container log; found → the cache forever (a
        # recreate delivers a fresh line into the live stream —
        # parse_summary's «last wins» wins). shortcut: a scan
        # timeout/error → empty, the line will come from the live stream;
        # no retry is done
        if self._boot is None:
            self._boot = []
            try:
                import subprocess
                c = os.environ.get('LCTL_WATCH_CONTAINER', '')
                if c:
                    # podman logs prints records to STDERR (a doc fact of
                    # watch_frame.py) — read both streams
                    r = subprocess.run(['podman', 'logs', '-t', c],
                                       capture_output=True, text=True, timeout=30)
                    out = (r.stdout or '') + '\n' + (r.stderr or '')
                    self._boot = [l for l in out.splitlines()
                                  if 'load summary' in l
                                  or 'fn-lanes staged' in l][-8:]   # fix:w40-lanes
            except Exception:
                pass
        return self._boot + list(buf)

    def log_line_local(self, line):
        return watch_frame.log_line_local(line)


def build_panels():
    # The entry point's panel composition: row 1 — «Движок» + «Железо»,
    # row 2 — «Метрики» (the frame, the .row default — full width),
    # row 3 — «Скорость»
    return [watch_frame.CommonEnginePanel(), watch_frame.HwPanel(),
            watch_frame.MetricsPanel(), watch_frame.SpeedPanel()]


def selfcheck_engine():
    # The engine part of the selfcheck (the frame part is
    # watch_frame.selfcheck's): the health/stats-JSON parsers + the live
    # window fixtures, the edges (garbage/non-object/an empty dict), the
    # parser of the load summary's REAL ` | ` format (recon-live §3), the
    # spec facet compression, the draft aggregate (empty/the aggregate/no
    # field), the scheme v2 W3.3 (the active window: the gen-avg
    # lat−ttft, the mean-of-rates prefill, the ttft dual, the τ window,
    # the done-line gen-посл), the done-parse (the [req anchor, the bench
    # isolation, the rotation), the pulses (unchanged), the v2 hold
    # semantics (the Δcount gates, the seed (a), the recreate), the
    # slot-branch (e1), the dead-server branch, the plain pins, the empty
    # LCTL_WATCH_CONTAINER, the old-image degradation (an empty
    # /stats+/metrics → «—», not a crash)
    fails = []
    total = 0

    def ck(name, cond):
        nonlocal total
        total += 1
        if not cond:
            fails.append(name)

    base = os.path.dirname(os.path.abspath(__file__))
    fx = os.path.join(base, '..', '..', 'tests', 'fixtures')
    fx_h = parse_health(open(os.path.join(fx, 'watch_health.json')).read())
    fx_s = parse_stats_json(open(os.path.join(fx, 'watch_stats.json')).read())
    fx_m = watch_frame.parse_metrics(open(os.path.join(fx, 'watch_metrics.txt')).read())
    fx_log = open(os.path.join(fx, 'watch_log.txt')).read().splitlines()

    # ── the health-JSON parser: the live /health fixture (0.4.7, mq4-xts) ──
    ck('health fixture: status ok + модель mq4-xts',
       fx_h.get('status') == 'ok' and fx_h.get('model') == 'qwen3.8:27b-mq4-xts')
    ck('health fixture: healthy (loading_model пуст)', healthy(fx_h) is True)

    # ── the parsers' edges: garbage/non-object/None → {} (no crash) ────────
    ck('parse_health: мусор/пусто → {}',
       parse_health('garbage') == {} and parse_health('') == {})
    ck('parse_health: не-объект (массив) → {}', parse_health('[1,2]') == {})
    ck('parse_stats: мусор/пусто → {}', parse_stats_json('') == {}
       and parse_stats_json('not json') == {})

    # ── the load summary parser: the REAL ` | ` format (recon-live §3) ─────
    r = parse_summary(fx_log)
    ck('summary fixture: spec-фасет verbatim (mtp K=7, n-gram)',
       r['spec'] == 'qwen4 native mtp K=7, n-gram copy lane on')
    ck('summary fixture: kv «q8 (vmm backend, automatic)»',
       r['kv'] == 'q8 (vmm backend, automatic)')
    ck('summary fixture: context 262144 (хвост-скобки фасета вне значения)',
       r['ctx'] == '262144')
    ck('summary: строки нет → все "" (до загрузки — норма)',
       parse_summary(['boot', 'listening']) ==
       {'spec': '', 'kv': '', 'ctx': ''})
    r2 = parse_summary(fx_log + [
        '2026-11-23 08:00:00 [INFO] hipfire load summary: m2.gguf (qwen4) '
        '| spec: plain | kv: q4 | context: 163840 (user-set) | placement: x | prefill: y'])
    ck('summary: последний побеждает (recreate)', r2 == {'spec': 'plain', 'kv': 'q4',
                                                         'ctx': '163840'})
    r3 = parse_summary([
        '2026-11-24T09:14:51.123456789+03:00 '
        '2026-11-24 09:14:50 [INFO] hipfire load summary: '
        'qwen3.8-27b-mq4-xts (qwen4) | spec: qwen4 native mtp K=7, '
        'n-gram copy lane on | kv: q8 (vmm) | context: 262144'])
    ck('summary: строка С podman-штампом (+offset-форма, живая EXP-014) → '
       'spec фасет извлечён (парсер prefix-агностичен: substring-guard + '
       're.search, ^-якорей нет — W3.2.1 приёмка)',
       r3['spec'] == 'qwen4 native mtp K=7, n-gram copy lane on'
       and r3['kv'] == 'q8 (vmm)' and r3['ctx'] == '262144'
       and spec_conf_compact(r3['spec']) == 'mtp K=7')

    # ── the spec facet compression (layout §1: «mtp K=7») ──────────────────
    ck('spec_conf: фасет сжимается до «mtp K=7»',
       spec_conf_compact('qwen4 native mtp K=7, n-gram copy lane on') == 'mtp K=7')
    ck('spec_conf: без K= → фасет verbatim (старый образ)',
       spec_conf_compact('plain') == 'plain')
    ck('spec_conf: пусто → "" (рендер «—»)', spec_conf_compact('') == '')

    # ── lanes (fix:w40-lanes): the staging boot line → the real parallelism ─
    ck('parse_lanes: «fn-lanes staged … lanes=4» → 4 (last wins), без строки → None',
       parse_lanes(['boot', 'qwen4 fn-lanes staged: topology=single lanes=4 row_budget=4',
                    'qwen4 fn-lanes staged: topology=single lanes=2 row_budget=4']) == 2
       and parse_lanes(['boot', 'listening']) is None)
    sch_l = compose_scheme(fx_h, fx_s, fx_m,
                           dict(parse_summary(fx_log), lanes=4))
    ck('scheme lanes=4: slots=4 (реальный параллелизм), ctx_tape=None '
       '(«лента» standby-конфига multi-slot саппрессится)',
       sch_l['slots'] == 4 and sch_l['ctx_tape'] is None)

    # ── the draft aggregate (fix:w32-draft-agg) ────────────────────────────
    ck('draft-агрегат: пусто (прод-арбитраж) → None → «—»',
       draft_acceptance_pct(fx_s) is None)
    ck('draft-агрегат: Σaccepted/Σoffered по позициям (60+30)/(100+50) = 60.0',
       abs(draft_acceptance_pct({'draft_positions': [
           {'offered': 100, 'accepted': 60},
           {'offered': 50, 'accepted': 30}]}) - 60.0) < 1e-9)
    ck('draft-агрегат: поля нет (старый образ) → None',
       draft_acceptance_pct({}) is None)
    ck('draft-агрегат: Σoffered=0 → None (деление на 0)',
       draft_acceptance_pct({'draft_positions': [{'offered': 0, 'accepted': 0}]})
       is None)

    # ── the scheme v2 W3.3 (the active window; live window fixtures, the OQ-1 cache) ─
    # the «single request» fixture's session deltas (amendment p.11):
    #     Δcompletion 150, Δ(lat−ttft) = 3000−200 = 2800 ms → the gen-avg
    #     = 150/2.8 = 53.57, NOT 150/300 s = 0.5 (an anti-pin of the
    #     calendar denominator — wall is not included)
    w_f = {K_COMPLETION: 150.0, K_LAT_S: 3000.0, K_LAT_C: 1.0,
           K_TTFT_S: 200.0, K_TTFT_C: 1.0, K_PREFILL_S: 1000.0,
           K_PREFILL_C: 2.0, K_TAU_S: 4.9, K_TAU_C: 1.0}
    sch = compose_scheme(fx_h, fx_s, fx_m, parse_summary(fx_log),
                         window=w_f, done=(55.6, 4.91))
    ck('scheme fixture: конфиг — аптайм 3138, slots 1 (standard: реальный '
       'параллелизм, mod.rs:1991) + лента 4 из caps, ctx 262144, kv q8 (vmm), '
       'спек «mtp K=7»',
       sch['uptime_sec'] == 3138 and sch['slots'] == 1
       and sch['ctx_tape'] == 4
       and sch['ctx_tokens'] == 262144 and sch['kv_mode'] == 'q8 (vmm)'
       and sch['spec_conf'] == 'mtp K=7')
    ck('scheme v2 (амendment 11): одиночный запрос — ген-средн '
       '150/(2800мс/1000) = 53.57 (НЕ 150/300c = 0.5 — wall не знаменатель); '
       'ген-посл = done-line 55.6 (НЕ recent_tok_s 24.6 — анти-пин источника)',
       abs(sch['gen_avg'] - 150 / 2.8) < 1e-9
       and sch['gen_last'] == 55.6)
    ck('scheme v2: prefill-средн = mean-of-rates гистограммы 1000/2 = 500.0 '
       '(Σprefill-времени нет — оговорка §5 v2); «посл» сырьём None '
       '(тиковый Δ кладёт apply_tick)',
       abs(sch['prefill_avg'] - 500.0) < 1e-9
       and sch['prefill_last'] is None)
    ck('scheme fixture: кэш 9000 из 12000, 75.0 % (prompt ВКЛЮЧАЕТ cached — OQ-1)',
       sch['cache_cached'] == 9000.0 and sch['cache_total'] == 12000.0
       and abs(sch['cache_pct'] - 75.0) < 1e-9)
    ck('scheme fixture: принято 70.1 % — fallback tau/K (draft_positions [] '
       'на сериале — fn_batch lane-only, EXP-016 2026-11-24; done tau 4.91, '
       'K=7 из фасета; параллельный: точный Σ/Σ приоритетен), τ 4.9 '
       '(session 4.9/1; согласованность: done tau 4.91 == hist mean 9.82/2)',
       sch['spec_pct'] is not None
       and abs(sch['spec_pct'] - 4.91 / 7 * 100) < 1e-9
       and abs(sch['tau'] - 4.9) < 1e-9)
    ck('scheme fixture: очередь 0 из 4 (depth /stats + capacity /metrics)',
       sch['queue_depth'] == 0 and sch['queue_capacity'] == 4.0)
    ck('spec_conf_compact: dflash-фасет сжимается («block N» без K=)',
       spec_conf_compact('dflash (draft qwen38-27b-dflash-mq4.hfq, block 8)')
       == 'dflash block=8')
    ck('spec_draft_k: K= / block N / без спекулятора',
       spec_draft_k('qwen4 native mtp K=7, n-gram copy lane on') == 7
       and spec_draft_k('dflash (draft q.hfq, block 8)') == 8
       and spec_draft_k('off (no speculator armed)') is None)
    ck('sum_done_windows: Σокон done-строк фикстуры = 123',
       sum_done_windows(fx_log) == 123)
    eng4 = HipfireEng()
    eng4.hist['drafts'].append(0)
    eng4.route_conf(fx_log)
    eng4.route_conf(fx_log + ['[req chatcmpl-e16] drafter=mtp tau=5.0 '
                              'tok/s=60.0 decode (100 tok, 33 windows)'])
    ck('серийный drafts-пульс: route_conf патчит hist нового окна (33 цикл)',
       eng4.hist['drafts'][-1] == 33)
    ck('scheme fixture: сгенерировано 5000, принято = prompt 12000 (включает '
       'cached — семантика hipfire); device_lost не в схеме hipfire',
       sch['gen_total'] == 5000.0 and sch['in_total'] == 12000.0
       and 'device_lost' not in sch)
    ck('scheme: /metrics пуст → in_total None (базовый ряд без «принято»)',
       (lambda s: s['in_total'] is None)(
           compose_scheme(fx_h, fx_s, {}, parse_summary(fx_log))))
    ck('scheme fixture: кэш RAM/диск «—» (env-шва нет — батарея без stub)',
       sch['cache_ram'] == '' and sch['cache_disk'] == '')
    ck('scheme: /metrics пуст (сбой только metrics) → метрики «—», конфиг жив',
       (lambda s: s['cache_pct'] is None and s['tau'] is None
        and s['gen_avg'] is None and s['spec_conf'] == 'mtp K=7'
        and s['queue_capacity'] is None)(
           compose_scheme(fx_h, fx_s, {}, parse_summary(fx_log))))
    ck('scheme: пустой /stats (старый образ R-4) → uptime/ген/очередь «—», '
       'конфиг из лога/caps жив',
       (lambda s: s['uptime_sec'] is None and s['gen_avg'] is None
        and s['gen_last'] is None and s['queue_depth'] is None
        and s['spec_conf'] == 'mtp K=7' and s['slots'] == 1
        and s['ctx_tape'] == 4)(
           compose_scheme(fx_h, {}, fx_m, parse_summary(fx_log))))
    ck('scheme: health без полей → slots «—», не краш',
       compose_scheme({}, {}, {}, {})['slots'] is None)
    ck('scheme: деление на 0 (пустые счётчики до первого done) → None',
       compose_scheme(fx_h, fx_s, watch_frame.parse_metrics(
           'hipfire_prompt_tokens_total 0\n'
           'hipfire_cached_prompt_tokens_total 0\n'), {})['cache_pct'] is None)

    # ── the cache budgets from the config (the env seam's arguments; the disk used — a scan) ─
    sch_b = compose_scheme(fx_h, fx_s, fx_m, {},
                           12884901888, 34359738368, 3435973837)
    ck('бюджеты из конфига (W3.2.1 п.5): RAM «12.0 GiB (бюджет)», диск '
       'used+бюджет «3.2 / 32.0 GiB (бюджет)»',
       sch_b['cache_ram'] == '12.0 GiB (бюджет)'
       and sch_b['cache_disk'] == '3.2 / 32.0 GiB (бюджет)')
    ck('бюджет диска без used → бюджет-only; used без бюджета → only used',
       compose_scheme(fx_h, fx_s, fx_m, {}, None, 34359738368,
                      None)['cache_disk'] == '32.0 GiB (бюджет)'
       and compose_scheme(fx_h, fx_s, fx_m, {}, None, None,
                          3435973837)['cache_disk'] == '3.2 GiB')

    # ── v2: the active window — uptime/wall is NOT the denominator (amendment 12) ─
    # «2 min of work out of 5» and «5 min continuous» → one value: the
    #     gen-avg's denominator = Σdecode-ms (lat−ttft), the /stats uptime
    #     is not part of it
    w_2min = {K_COMPLETION: 300.0, K_LAT_S: 6480.0, K_TTFT_S: 480.0}
    ck('v2 «2 мин работы из 5» ≡ «5 мин непрерывных»: 300/(6480−480)/1000 = '
       'ровно 50.0 при любом uptime /stats (анти-пин lifetime-знаменателя)',
       compose_scheme(fx_h, {'uptime_sec': 120}, fx_m, {}, window=w_2min)
       ['gen_avg'] == 50.0
       and compose_scheme(fx_h, {'uptime_sec': 300}, fx_m, {}, window=w_2min)
       ['gen_avg'] == 50.0
       and compose_scheme(fx_h, {'uptime_sec': 99999}, fx_m, {},
                          window=w_2min)['gen_avg'] == 50.0)
    ck('v2 prefill-средн: mean-of-rates по запросам сессии (1000/2 = 500, '
       '2000/4 = 500 — агрегатор ≠ ratio-of-sums, оговорка A5/§5 v2)',
       compose_scheme(fx_h, fx_s, fx_m, {}, window={
           K_PREFILL_S: 1000.0, K_PREFILL_C: 2.0})['prefill_avg'] == 500.0
       and compose_scheme(fx_h, fx_s, fx_m, {}, window={
           K_PREFILL_S: 2000.0, K_PREFILL_C: 4.0})['prefill_avg'] == 500.0)
    ck('v2 fail-visible: Δ(lat−ttft) ≤ 0 (расхождение счётчиков апстрима) '
       '→ ген-средн «—» (не тихая ложь); Δcount=0 → «—» (session пусто)',
       compose_scheme(fx_h, fx_s, fx_m, {}, window={
           K_COMPLETION: 150.0, K_LAT_S: 200.0,
           K_TTFT_S: 300.0})['gen_avg'] is None
       and compose_scheme(fx_h, fx_s, fx_m, {}, window={
           K_COMPLETION: 150.0})['gen_avg'] is None)

    # ── the draft pulse: the Δspec_cycles from /stats + the prefill Δ(prompt−cached) ─
    eng = HipfireEng()
    snap1 = {'engine_ok': True, 'metrics': fx_m, 'stats_json': fx_s}
    d1 = eng.apply_tick(snap1)
    ck('пульс тик1: базы нет → все None',
       d1 == {'prefill': None, 'decode': None, 'drafts': None})
    m2 = dict(fx_m)
    m2[K_COMPLETION] = 5300.0
    m2[K_PROMPT] = 12500.0
    snap2 = {'engine_ok': True, 'metrics': m2, 'stats_json': fx_s}
    d2 = eng.apply_tick(snap2)
    ck('пульс тик2 (done-движение): decode +300, prefill +500 '
       '(Δprompt−cached: cached стоит), спек-циклы стоят → drafts 0',
       d2 == {'prefill': 500, 'decode': 300, 'drafts': 0})
    sj3 = dict(fx_s, spec_cycles=10)
    snap3 = {'engine_ok': True, 'metrics': m2, 'stats_json': sj3}
    d3 = eng.apply_tick(snap3)
    ck('пульс тик3: done-пульс drafts +10 = Δspec_cycles из /stats '
       '(fix:w3-r1-cycles)',
       d3 == {'prefill': 0, 'decode': 0, 'drafts': 10})
    m_c = dict(m2)
    m_c[K_PROMPT] = 13000.0
    m_c[K_CACHED] = 9500.0   # prompt and cached move together (cache hits)
    dc = eng.apply_tick({'engine_ok': True, 'metrics': m_c, 'stats_json': sj3})
    ck('пульс: кэш-хиты НЕ считаются prefill-работой (prompt+500, cached+500 '
       '→ prefill 0)',
       dc == {'prefill': 0, 'decode': 0, 'drafts': 0})
    m_n = dict(m_c)
    m_n[K_PROMPT] = 12000.0  # Δ(prompt−cached) < 0 — never happens on a live one
    dn = eng.apply_tick({'engine_ok': True, 'metrics': m_n, 'stats_json': sj3})
    ck('пульс: отрицательный Δ(prompt−cached) → None (recreate/reset), '
       'decode/drafts — обычные дельты (0)',
       dn['prefill'] is None and dn['decode'] == 0 and dn['drafts'] == 0)
    df = eng.apply_tick({'engine_ok': True, 'metrics': None, 'stats_json': sj3})
    ck('пульс: сбой /metrics → decode/prefill reset, draft-пульс живёт '
       '(источник /stats)',
       df == {'prefill': None, 'decode': None, 'drafts': 0})
    sj_neg = dict(fx_s, spec_cycles=3)   # a recreate → Δ < 0
    dx = eng.apply_tick({'engine_ok': True, 'metrics': m2, 'stats_json': sj_neg})
    do = eng.apply_tick({'engine_ok': True, 'metrics': m2, 'stats_json': {}})
    ck('пульс: отрицательный Δspec_cycles (recreate) → None; /stats без '
       'поля (старый образ) → None («—»), не краш',
       dx['drafts'] is None and do['drafts'] is None)
    eng.apply_tick({'engine_ok': False})
    r4 = eng.apply_tick({'engine_ok': True, 'metrics': m2, 'stats_json': fx_s})
    ck('пульс: мёртвый тик — reset всех баз; после поднятия ложных дельт нет',
       r4 == {'prefill': None, 'decode': None, 'drafts': None})

    # ── W3.3 v2: the hold semantics (the W3.2.2/3/4 consolidation, the Δcount gates) ──
    # a scheme dict with all the v2 rows; compose_scheme puts the «raw»
    #     values from the session deltas — the apply_tick hold patch
    #     accepts them only on ticks with work (Δcount>0) and holds on
    #     quiet/fail ones.
    def sch_v2():
        return {'gen_avg': None, 'gen_last': None, 'prefill_avg': None,
                'prefill_last': None, 'ttft_win': None, 'tau': None}

    eng2 = HipfireEng()
    hm2 = dict(m2)  # a tick with work: the histograms moved (done)
    hm2.update({K_LAT_S: 18480.0, K_LAT_C: 3.0, K_TTFT_S: 960.0,
                K_TTFT_C: 3.0, K_PREFILL_S: 1800.0, K_PREFILL_C: 3.0,
                K_TAU_S: 14.82, K_TAU_C: 3.0})
    s1 = sch_v2()
    eng2.apply_tick({'engine_ok': True, 'metrics': fx_m, 'stats_json': fx_s,
                     'scheme': s1})
    ck('hold v2 seed (амendment 10, (а)): тик1 — база session, Δcount None → '
       'все ряды «—» (старт при простое; seed НЕ делается)',
       all(s1[k] is None for k in s1))
    s2 = sch_v2()
    s2.update({'gen_avg': 50.0, 'prefill_avg': 1000.0, 'prefill_last': 1000.0,
               'ttft_win': 0.48, 'tau': 5.0})  # сырые compose_scheme тика работы
    eng2.apply_tick({'engine_ok': True, 'metrics': hm2, 'stats_json': fx_s,
                     'scheme': s2})
    ck('hold v2 тик с работой (Δlat/pf/ttft/tau count>0): все ряды приняты',
       s2['gen_avg'] == 50.0 and s2['prefill_avg'] == 1000.0
       and s2['prefill_last'] == 1000.0 and s2['ttft_win'] == 0.48
       and s2['tau'] == 5.0)
    s3 = sch_v2()  # a quiet tick: the session did not move → raw «—» (0/0)
    eng2.apply_tick({'engine_ok': True, 'metrics': hm2, 'stats_json': fx_s,
                     'scheme': s3})
    ck('hold v2 тихий тик (амendment 7): ДЕРЖИТ все ряды точно (не «—», '
       'не пересчёт; Δcount=0 — «завершённых нет»)',
       s3['gen_avg'] == 50.0 and s3['prefill_avg'] == 1000.0
       and s3['prefill_last'] == 1000.0 and s3['ttft_win'] == 0.48
       and s3['tau'] == 5.0)
    s4 = sch_v2()
    eng2.apply_tick({'engine_ok': True, 'metrics': None, 'stats_json': fx_s,
                     'scheme': s4})
    ck('hold v2 fail-тик /metrics: держит (база session сохраняется — '
       'reset только recreate)',
       s4['gen_avg'] == 50.0 and s4['prefill_last'] == 1000.0
       and s4['ttft_win'] == 0.48 and s4['tau'] == 5.0)
    eng2.apply_tick({'engine_ok': False})  # a recreate → a session+holds reset
    s5 = sch_v2()
    eng2.apply_tick({'engine_ok': True, 'metrics': fx_m, 'stats_json': fx_s,
                     'scheme': s5})
    ck('hold v2 после recreate (амendment 13): кэши сброшены → «—»; '
       'база перефиксируется без ложных дельт',
       all(s5[k] is None for k in s5))
    s6 = sch_v2()
    s6.update({'gen_avg': 53.6})
    eng2.apply_tick({'engine_ok': True, 'metrics': hm2, 'stats_json': fx_s,
                     'scheme': s6})
    ck('hold v2 после recreate на тике работы: свежее принято (перефиксация)',
       s6['gen_avg'] == 53.6)

    # ── W3.3 e1: the slot-branch (multi_slot «—» without fallbacks) ─────────
    eng3 = HipfireEng()
    eng3.apply_tick({'engine_ok': True, 'metrics': fx_m,
                     'stats_json': fx_s})  # the hd bases' warm-up (as tick 1)
    eng3._ms_route = True  # capabilities.mode == 'multi-slot' (as collect sets it)
    s7 = sch_v2()
    s7.update({'gen_avg': 50.0, 'gen_last': 55.6, 'prefill_avg': 1000.0,
               'prefill_last': 1000.0, 'ttft_win': 0.48, 'tau': 5.0})
    eng3.apply_tick({'engine_ok': True, 'metrics': hm2, 'stats_json': fx_s,
                     'scheme': s7})
    ck('slot-branch (амendment 6/A3 + fix 2: предикат — роут multi-slot из '
       'caps.mode, НЕ slots>1 — слоты = ёмкость очереди): ген-средн/посл/'
       'prefill/τ ровно «—» (hist = wall-fallback / done-строк нет / не '
       'кормится), ttft-окно жив (per-attempt)',
       s7['gen_avg'] is None and s7['gen_last'] is None
       and s7['prefill_avg'] is None and s7['prefill_last'] is None
       and s7['ttft_win'] == 0.48 and s7['tau'] is None)

    # fix 2: a regression pin on the user's caught case — 27b-single
    #     (a standard route, slots 4 — the queue capacity!) → ALL the rows
    #     alive
    eng5 = HipfireEng()
    eng5.apply_tick({'engine_ok': True, 'metrics': fx_m,
                     'stats_json': fx_s})  # the hd bases' warm-up
    eng5._ms_route = False  # mode == 'standard'
    s8 = sch_v2()
    s8.update({'gen_avg': 50.0, 'gen_last': 55.6, 'prefill_avg': 1000.0,
               'prefill_last': 1000.0, 'ttft_win': 0.48, 'tau': 5.0})
    eng5.apply_tick({'engine_ok': True, 'metrics': hm2, 'stats_json': fx_s,
                     'scheme': s8})
    ck('27b-single регресс (fix 2): standard-роут при слотах 4 — все ряды '
       'живые (ген-средн/посл, prefill, τ, ttft; прежний предикат slots>1 '
       'валидил их на одиночных профилях)',
       s8['gen_avg'] == 50.0 and s8['gen_last'] == 55.6
       and s8['prefill_avg'] == 1000.0 and s8['prefill_last'] == 1000.0
       and s8['ttft_win'] == 0.48 and s8['tau'] == 5.0)

    # ── W3.3: the done-parse (the gen-посл from the log; the bench isolation; the rotation) ─
    done_ln = ('2026-11-23T07:13:10.900000000Z 2026-11-23 07:13:10 [INFO] '
               '[req chatcmpl-2-4548] drafter=mtp tau=4.91 tok/s=55.6 decode '
               '(728 tok, 123 windows)')
    ck('done-parse (амendment 5): fixture-строка → (55.6, 4.91); лог-фикстура '
       '→ та же пара; tau-line == hist mean (согласованность фикстуры)',
       parse_done_line([done_ln]) == (55.6, 4.91)
       and parse_done_line(fx_log) == (55.6, 4.91)
       and abs(4.91 - 9.82 / 2) < 1e-9)
    ck('done-parse: буфер без [req → None (multi_slot by design / старт); '
       'bench-синтетика «inference τ=13.18» НЕ матчится (якорь [req)',
       parse_done_line(['boot', 'listening']) is None
       and parse_done_line(['… inference τ=13.18 (bench) …']) is None)
    ck('done-parse: done-строка РАНЬШЕ bench-строки — берётся [req-строка '
       '(якорь изолирует bench, не режет done)',
       parse_done_line([done_ln,
                        '2026-11-23 07:14:00 [INFO] inference τ=13.18'])
       == (55.6, 4.91))
    eng4 = HipfireEng()
    eng4.route_conf([done_ln])
    eng4.route_conf(['строка без done — буфер ротировал'])  # the done line rotated out
    ck('done-parse: ротация буфера НЕ сбрасывает кэш (hold до следующей done)',
       eng4._done == (55.6, 4.91))

    # ── the dead-server branch + rows/plain on the fixture numbers ─────────
    ep = watch_frame.CommonEnginePanel(); ep.bind(watch_frame.Glyphs(True))
    mp = watch_frame.MetricsPanel(); mp.bind(watch_frame.Glyphs(True))
    ck('rows: мёртвый сервер — ровно «недоступен» (обе панели), plain пуст',
       ep.rows({'engine_ok': False}) == [('недоступен', '')]
       and mp.rows({'engine_ok': False}) == [('недоступен', '')]
       and ep.plain_lines({'engine_ok': False}, '12:00:00') == []
       and mp.plain_lines({'engine_ok': False}, '12:00:00') == [])
    snap = {'engine_ok': True, 'stats': fx_h, 'health': fx_h,
            'stats_json': fx_s, 'metrics': fx_m, 'scheme': sch,
            'gpu': None, 'cpu_t': None,
            'mem': {'available_gib': 45.2, 'total_gib': 60.4}}
    ck('шапка: `lctl watch │ hipfire · <ext-ip>:<порт> · <модель>` целиком '
       '(лейаут §1, W3.2.2; статус-бар каркаса с addr-сегментом)',
       (lambda l: l == 'lctl watch │ hipfire · 10.0.0.9:11435 · '
        'qwen3.8:27b-mq4-xts')(watch_frame.status_bar_layout(
            140, 2, 'hipfire', 'qwen3.8:27b-mq4-xts', False,
            addr='10.0.0.9:11435')[0]))
    ck('rows движок: лейблы == константам каркаса (плоские ряды §1, без '
       'подзаголовка Конфигурация; Device lost скрыт — источника нет)',
       [x[0] for x in ep.rows(snap)] == list(watch_frame.ENGINE_ROWS))
    ck('rows метрики: лейблы == константе METRICS_ROWS (7 рядов §1)',
       [x[0] for x in mp.rows(snap)] == list(watch_frame.METRICS_ROWS))
    ck('plain движок (полный пин формата W3.2/W3.3: standard — параллелизм 1 '
       '+ «(лента 4)» из serve.multi_slot_slots)',
       ep.plain_lines(snap, '12:00:00')[0] ==
       '12:00:00 [движок] аптайм 52 мин | спек mtp K=7'
       ' | ctx 1 × 262 144 ток (лента 4) | kv q8 (vmm) | кэш-ram — | кэш-диск —')
    ck('plain метрики (полный пин формата W3.3 v2: ген-посл = done 55.6, '
       'ttft dual, τ-окно)',
       mp.plain_lines(snap, '12:00:00')[0] ==
       '12:00:00 [метрики] ген 53.6 (средн) · 55.6 (посл) tok/s'
       ' | prefill 500.0 (средн) · — (посл) tok/s'
       ' | кэш 9.0k из 12.0k ток из кэша (75.0 %)'
       ' | спек принято 70.1 % · τ 4.9 ток/цикл | оч 0 из 4 запросов'
       ' | ttft 0.24 с (средн) · 0.20 с (окно)'
       ' | сген 5.0k ток · принято 12.0k')
    ck('plain: dead /metrics — метрики «—», конфиг жив (тик не dead; '
       'ген-посл = done жив, dual-часть «окно» «—»)',
       mp.plain_lines(dict(snap, metrics=None,
                           scheme=compose_scheme(fx_h, fx_s, {},
                                                 parse_summary(fx_log),
                                                 done=(55.6, 4.91))),
                          '12:00:00')[0] ==
       '12:00:00 [метрики] ген — (средн) · 55.6 (посл) tok/s'
       ' | prefill — (средн) · — (посл) tok/s | кэш —'
       ' | спек принято 70.1 % · τ — ток/цикл | оч 0 запросов | ttft — | сген —')

    # ── the entry point's panel composition + the layout rows ──────────────
    panels = build_panels()
    ck('панели точки входа: [Движок, Железо, Метрики, Скорость] '
       '(Очередь·Tau удалена — лейаут §1)',
       [type(p).__name__ for p in panels] ==
       ['CommonEnginePanel', 'HwPanel', 'MetricsPanel', 'SpeedPanel'])
    ck('ряды лейаута: 1/1/2/3 (Метрики без .row — дефолт каркаса)',
       [getattr(p, 'row', 2) for p in panels] == [1, 1, 2, 3])

    # ── an empty LCTL_WATCH_CONTAINER: no engine default in the core (R6) ──
    old_c = os.environ.get('LCTL_WATCH_CONTAINER')
    os.environ.pop('LCTL_WATCH_CONTAINER', None)
    try:
        w_e = watch_frame.Watch([watch_frame.HwPanel()], eng=None)
        ck('Watch: container пуст без env (дефолта движка нет — R6)',
           w_e.container == '')
    finally:
        if old_c is not None:
            os.environ['LCTL_WATCH_CONTAINER'] = old_c

    for name in fails:
        print('selfcheck engine FAIL: %s' % name, file=sys.stderr)
    print('selfcheck engine: %d/%d ok' % (total - len(fails), total))
    return 1 if fails else 0


def main(argv):
    # The SELFCHECK seam: the --selfcheck flag or the battery's env; the
    # frame + engine parts (the rc — the max of them). The selfcheck always
    # terminates (rc 0/1) — the live poll loop does not reach here.
    if '--selfcheck' in argv or os.environ.get('LCTL_WATCH_SELFCHECK') == '1':
        rc1 = watch_frame.selfcheck()
        rc2 = selfcheck_engine()
        return max(rc1, rc2)
    # The port default — the engine dialect (R6), via env BEFORE the Watch
    # construction: the frame's dead-line and the poll panel show one port
    # even on a bare run
    os.environ.setdefault('LCTL_WATCH_PORT', '11435')
    w = watch_frame.Watch(panels=build_panels(), eng=HipfireEng())
    return watch_frame.main_loop(w)


if __name__ == '__main__':
    sys.exit(main(sys.argv))
