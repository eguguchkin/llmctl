#!/usr/bin/env python3
# Purpose: the halogen panel's entry point of `lctl watch` (Ф3b;
#   ENGINE_WATCH_TUI, the frame core/py/watch/watch_frame.py —
#   PYTHONPATH is set by the adapter's engine_watch_env, the battery sets
#   it directly). The metrics are CALIBRATED live against the response
#   bodies (the 2026-11-26 window, F40): the log t/s == the body's
#   predicted_per_second (exact), Δpredicted == Σcompletion (exact),
#   saved/(processed+saved) == the /cache token_hit_rate (exact),
#   commit/round == gen/rounds, prompt_tokens_total counts only new.
#
#   Sources (exactly one per value; no source → no scheme key → the
#   frame's «—»):
#   H  /health (JSON) — the config: slots/context/kv_cache/drafter_default;
#   M  /metrics — cumulative counters: llamacpp:tokens_predicted_total,
#      llamacpp:tokens_predicted_seconds_total (the 0.1s rounding — a ~2%
#      average error on short windows), llamacpp:prompt_tokens_total (ONLY
#      new tokens), llamacpp:prompt_seconds_total,
#      halogen:draft_tokens_{total,accepted}_total,
#      halogen:cache_prompt_tokens_saved_total, halogen:requests_total;
#   C  /cache (JSON) — the cache gauges: entries/max_entries/bytes,
#      disk.bytes/budget_bytes;
#   L  the container log — the 0.20.7 req lines (THREE grammar variants:
#      uncached «prompt P, prefill Xs = R t/s», cached «prompt P (K cached,
#      PC%), prefill Xs (N new)», short «prompt P, prefill Xs (N new)»)
#      → gen (last), τ (last), prefill (last), cache (last), the prefill
#      time; the boot line → «mtp+ngram K=7».
#
#   Window semantics: the «(средн)» speeds and the ttft (window), the
#   Generated — the panel's session (the Δ of the counters from the first
#   live tick, the frame Deltas; the hold accepts a value on a tick where
#   Δseconds/Δrequests > 0 — a reliable "there was work" gate, not tied to
#   a tick coinciding with an event); cache %/spec %/accepted — cumulative
#   since server start (counter ratios, live on every working tick);
#   «(посл)»/τ/ttft(last) — the last completed request from L (an update =
#   a new req line in the buffer); queue/cache gauges — a direct C/M/H
#   read every tick.
#
#   The «Скорость» pulse: decode = Δdraft_tokens_accepted, prefill =
#   Δprompt_tokens_total, drafts = Δdraft_tokens_total (the drafts'
#   proposals — no cycle counter → the honest pulse_units «черн. ток/тик»).
#
# Side effects: see watch_frame.main_loop (every tick — GET /health +
#   GET /metrics + GET /cache via curl from PATH; TUI — the podman logs
#   seed/stream).
#
# Limitations/assumptions: stdlib only, 3.8+; the metric names — from the
#   0.20.7 /metrics (the emitter, never made up); a missing key → None →
#   «—» (another revision — a degradation, not a crash); a /cache failure
#   → None (the cache rows «—», the tick alive); the const model — the
#   adapter's canon (R6 ok).
import json
import os
import re
import sys
import time
from collections import deque

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
# The frame is on sys.path even on a bare run (--selfcheck without env):
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                '..', '..', '..',
                                'core', 'py', 'watch'))

import watch_frame as wf  # noqa: E402

MODEL_CANON = 'qwen3.8-flash-next'          # the adapter's canon (an engine panel)

K_PRED = 'llamacpp:tokens_predicted_total'
K_PRED_S = 'llamacpp:tokens_predicted_seconds_total'
K_PROMPT = 'llamacpp:prompt_tokens_total'          # new only (calibration)
K_PROMPT_S = 'llamacpp:prompt_seconds_total'
K_DRAFT = 'halogen:draft_tokens_total'
K_ACCEPTED = 'halogen:draft_tokens_accepted_total'
K_SAVED = 'halogen:cache_prompt_tokens_saved_total'
K_REQS = 'halogen:requests_total'

# The 0.20.7 req line — the full grammar (3 variants; the 2026-11-26
# calibration):
#   [1]tok [2]gen_s [3]gen_rate [4]rounds [5]commit [6]prompt
#   [7]cached [8]cached_pct [9]prefill_s [10]prefill_rate [11]new
R_REQ = re.compile(
    r'serve_api: (?:mtp|serial) (\d+) tok in ([\d.]+)s = ([\d.]+) t/s'
    r' \| (\d+) rounds, commit ([\d.]+)/round'
    r' \| prompt (\d+)(?: \((\d+) cached, ([\d.]+)%\))?,'
    r' prefill ([\d.]+)s(?: = ([\d.]+) t/s)?(?: \((\d+) new\))?')

# The tick deltas: the pulse + the averages' numerators/denominators (M)
DELTAS = {'decode': K_ACCEPTED, 'prefill': K_PROMPT, 'drafts': K_DRAFT,
          'pred': K_PRED, 'pred_s': K_PRED_S, 'prompt_s': K_PROMPT_S,
          'saved': K_SAVED, 'reqs': K_REQS}


def _int(s):
    # @returns int|None  # '4' → 4; ''/garbage → None
    try:
        return int(s)
    except (TypeError, ValueError):
        return None


# The RAM-cache boot line: «prompt cache ON, resume-anywhere (28 entries,
#     snapshot every request, chunk 32768, 58 MiB each at ctx 262144)» →
#     the configured RAM-cache cap = entries × MiB each
R_RAM_CAP = re.compile(
    r'prompt cache ON[^(]*\((\d+) entries[^)]*?(\d+) MiB each')


def parse_req_line(line):
    # @returns dict|None  # the req line's fields (all three 0.20.7 variants)
    mt = R_REQ.search(line)
    if not mt:
        return None
    g = mt.groups()
    cached = _int(g[6]) or 0
    new = _int(g[10])
    if new is None:
        new = (_int(g[5]) or 0) - cached
    rate = float(g[9]) if g[9] else (
        new / float(g[8]) if float(g[8]) > 0 else None)
    return {'tok': int(g[0]), 'gen_s': float(g[1]), 'gen_last': float(g[2]),
            'rounds': int(g[3]), 'tau': float(g[4]), 'prompt': int(g[5]),
            'cached': cached, 'cached_pct': float(g[7]) if g[7] else None,
            'prefill_s': float(g[8]), 'prefill_last': rate, 'new': new}


class HalogenEng:
    # halogen's ENG provider for the frame (the Watch contract:
    # collect/apply_tick/route_conf/hist; see watch_frame.Watch)
    def __init__(self):
        self.port = int(wf.env_float('LCTL_WATCH_PORT', 11435))
        self.deltas = wf.Deltas(DELTAS)
        self.hist = {'decode': deque(maxlen=120),
                     'prefill': deque(maxlen=120),
                     'drafts': deque(maxlen=120)}
        self._uptime = None   # from the buffer's first -t stamp (route_conf)
        self._spec = None     # «mtp+ngram K=7» from the boot line (a cache)
        self._last = None     # the last req line (dict|None)
        self._max_entries = None  # the cache entry reserve (/cache, 1
        #                             request per session; reset on a dead tick)
        self._boot = None     # the full log scan's boot lines (_boot_merge,
        #                         the gufo w38 mirror; None = no scan yet)
        self._ram_cap_mb = None   # the RAM-cache cap from the log's boot line
        #   («prompt cache ON … (28 entries, …, 58 MiB each at ctx …)» —
        #   entries × MiB each = the configured cap; reset on a dead tick)
        self.h_gen = wf.Hold()    # W3.3: a speed average — a tick with work
        self.h_pf = wf.Hold()
        self.h_ttft = wf.Hold()
        # the seconds counters are fractional (calibration: the frame's
        #     Deltas.update cuts int(cur−prev) → a Δ of 0.5s = 0 → dead
        #     averages) — float deltas of our own; the keys = K_PRED/K_PRED_S/
        #     K_PROMPT/K_PROMPT_S/K_REQS
        self._fprev = None

    def collect(self, snap):
        # Two GETs every tick (health-first: a health failure → a dead
        #     tick, /metrics is not requested — fail-fast). /cache — ONCE
        #     per session: only max_entries is needed from it (the entry
        #     reserve — a config constant); the cache gauges
        #     (entries/bytes/disk) are taken from /metrics — otherwise the
        #     server's access log in idle consists entirely of the panel's
        #     own «GET /cache» (the user's remark)
        health = json.loads(wf.http_get(
            'http://127.0.0.1:%d/health' % self.port))
        metrics = wf.parse_metrics(wf.http_get(
            'http://127.0.0.1:%d/metrics' % self.port))
        if self._max_entries is None:
            try:
                c = json.loads(wf.http_get(
                    'http://127.0.0.1:%d/cache' % self.port))
                me = _int(c.get('max_entries'))
                if me is not None:
                    self._max_entries = me
            except (OSError, ValueError):
                pass   # no /cache → the reserve «—», the tick alive
        snap['stats'] = health
        snap['metrics'] = metrics
        snap['scheme'] = build_scheme(health, metrics, self._max_entries,
                                      self._ram_cap_mb, self._uptime,
                                      self._spec, self._last)

    def apply_tick(self, snap):
        # The pulses — the frame's Deltas (integer counters); the session
        #     averages — our own float deltas (the seconds counters are
        #     fractional); a dead tick — a reset (incl. _max_entries —
        #     after a recreate we re-read /cache once: the config may have
        #     changed)
        if snap['engine_ok']:
            d = self.deltas.update(snap['metrics'])
            fd = self._fdelta(snap['metrics'])
        else:
            d = self.deltas.update(None)
            fd = self._fdelta(None)
            self._max_entries = None
            self._ram_cap_mb = None
            self.h_gen.reset(); self.h_pf.reset()
            self.h_ttft.reset()
        for key in ('decode', 'prefill', 'drafts'):
            self.hist[key].append((d or {}).get(key) or 0)
        scheme = snap.get('scheme')
        if scheme is not None and fd:
            # the session's (средн): Δtokens/Δseconds (float; the
            #     calibration: the formulas vs the bodies, 2026-11-26)
            if (fd.get('pred_s') or 0) > 0:
                scheme['gen_avg'] = self.h_gen.take(
                    fd['pred'] / fd['pred_s'], True)
            else:
                scheme['gen_avg'] = self.h_gen.take(None, False)
            if (fd.get('prompt_s') or 0) > 0:
                scheme['prefill_avg'] = self.h_pf.take(
                    fd['prompt'] / fd['prompt_s'], True)
            else:
                scheme['prefill_avg'] = self.h_pf.take(None, False)
            if (fd.get('reqs') or 0) > 0 and (fd.get('prompt_s') or 0) > 0:
                scheme['ttft_win'] = self.h_ttft.take(
                    fd['prompt_s'] / fd['reqs'], True)
            else:
                scheme['ttft_win'] = self.h_ttft.take(None, False)
        return d or {}

    def _fdelta(self, m):
        # @param 1: dict|None  # the tick's /metrics (None — a dead tick)
        # @returns dict|None  # the float deltas {pred,pred_s,prompt,
        #   prompt_s,reqs}; None — no session base/a reset; a negative delta
        #   (a counter restart) → the base is re-pinned, None for the tick
        keys = (K_PRED, K_PRED_S, K_PROMPT, K_PROMPT_S, K_REQS)
        cur = {k: m.get(k) for k in keys} if m else None
        if cur is None or any(v is None for v in cur.values()):
            self._fprev = None
            return None
        prev = self._fprev
        if prev is None:
            self._fprev = cur
            return None
        names = (K_PRED, K_PRED_S, K_PROMPT, K_PROMPT_S, K_REQS)
        short = ('pred', 'pred_s', 'prompt', 'prompt_s', 'reqs')
        smap = dict(zip(names, short))
        out = {smap[k]: cur[k] - prev[k] for k in names}
        if any(v < 0 for v in out.values()):
            self._fprev = cur   # a counter restart — the base anew
            return None
        self._fprev = cur
        return out

    def route_conf(self, buf):
        # The route + boot config + uptime + the last req line from the
        #     log buffer, extended by the full scan (_boot_merge); cached
        #     until the next collect (the frame's warm-up before the first
        #     tick). The «(посл)» gate = a new line in the buffer — the
        #     scan fact itself (replacing _last), no decode-delta gates
        #     (the calibration: the hold gate "Δaccepted per tick" dropped
        #     updates — the root of complaints 3-4)
        buf = self._boot_merge(buf)
        self._uptime = None
        for line in buf:
            if self._uptime is None:
                ts = wf.podman_ts_epoch(line)
                if ts is not None:
                    self._uptime = max(0.0, time.time() - ts)
            if self._spec is None and 'MTP depth-2' in line:
                self._spec = 'mtp+ngram K=7'
            if self._ram_cap_mb is None:
                mc = R_RAM_CAP.search(line)
                if mc:
                    self._ram_cap_mb = int(mc.group(1)) * int(mc.group(2))
            req = parse_req_line(line)
            if req:
                self._last = req
        return ({'model': MODEL_CANON}, {})

    def _boot_merge(self, buf):
        # fix:hal-bootlines — the gufo _boot_merge mirror (w38): the boot
        #     lines (MTP depth-2, prompt cache ON) are pushed out of the
        #     --tail seed window by the live load (the live case
        #     2026-11-26: the spec degraded to «mtp», the RAM cap «—»).
        #     The full scan is the user's methodology: the limit is NOT in
        #     the logs command but after the reduction — one full log scan,
        #     only the needed lines are kept (the cache forever: the engine
        #     config does not change between restarts, a recreate delivers
        #     the same boot in the live stream). shortcut: a scan failure →
        #     empty, the boot will come from the live stream
        if self._boot is None:
            self._boot = []
            try:
                import subprocess
                c = os.environ.get('LCTL_WATCH_CONTAINER', '')
                if c:
                    # podman logs prints to STDERR (a frame fact) — both
                    #     streams; -t gives the stamps for the uptime from
                    #     the first
                    r = subprocess.run(['podman', 'logs', '-t', c],
                                       capture_output=True, text=True,
                                       timeout=30)
                    out = (r.stdout or '') + '\n' + (r.stderr or '')
                    keep = [l for l in out.splitlines()
                            if 'MTP depth-2' in l or 'prompt cache ON' in l]
                    self._boot = keep[-4:]
            except Exception:
                pass
        return self._boot + list(buf)

    def log_line_local(self, line):
        return wf.log_line_local(line)


def build_scheme(health, metrics, max_entries, ram_cap_mb, uptime, spec,
                 last):
    # @param 1: dict        # /health
    # @param 2: dict        # /metrics (parse_metrics)
    # @param 3: int|None    # max_entries — the cache entry reserve (/cache,
    #     read once per session; None → the reserve «—»)
    # @param 4: int|None    # the RAM-cache cap, MB (the log's boot line,
    #     entries × MiB each; None → no cap)
    # @param 5: float|None  # the uptime (the buffer's first -t stamp)
    # @param 6: string|None # «mtp+ngram K=7» (the boot line)
    # @param 7: dict|None   # the last req line (parse_req_line)
    # @returns dict         # the frame's scheme v2 (no source → no key)
    kv = health.get('kv_cache')
    acc = metrics.get(K_ACCEPTED)
    draft = metrics.get(K_DRAFT)
    saved = metrics.get(K_SAVED)
    processed = metrics.get(K_PROMPT)
    # the cache gauges — from /metrics (the same /cache endpoint emits
    #     them as counters; otherwise the idle access log is flooded by the
    #     panel's own GET /cache)
    entries = _int(metrics.get('halogen:cache_entries'))
    cb = metrics.get('halogen:cache_bytes')
    db = metrics.get('halogen:cache_disk_bytes')
    budget = metrics.get('halogen:cache_disk_budget_bytes')
    cap_mb = ((health.get('prompt_cache') or {}).get('cap_mb')) \
        if health.get('prompt_cache') else None
    used_mb = _int(cb / 1048576) if cb is not None else None
    if None not in (entries, cb, max_entries):
        base = '%s из %s записей' % (entries, max_entries)
    elif entries is not None and cb is not None:
        base = '%s записей' % entries
    else:
        base = None
    if base is None or used_mb is None:
        cache_ram = None
    elif ram_cap_mb:
        # the cap from the boot line (entries × MiB each — the server's
        #     config; '~': the sum of the entry caps, an estimate)
        cache_ram = '%s · %s из ~%s MB' % (base, used_mb, ram_cap_mb)
    else:
        cache_ram = '%s · %s MB' % (base, used_mb)
        if cap_mb is not None:
            # the per-entry RAM cap (/health prompt_cache.cap_mb); the
            #     server publishes no global byte cap — no boot line
            cache_ram += ' · ≤%s MB/зап.' % _int(cap_mb)
    return {
        'uptime_sec': uptime,
        'spec_conf': spec or (
            'mtp' if health.get('drafter_default') == 'mtp' else None),
        'slots': _int(health.get('slots')),
        'ctx_tokens': _int(health.get('context')),
        'kv_mode': ('bf16 (16 бит)' if kv == 'bf16' else kv),
        # the RAM cache: used + the reserve (entries; the server returns
        #     no byte RAM reserve — we honestly do not draw it; the
        #     calibration: max_entries=28)
        'cache_ram': cache_ram,
        'cache_disk': ('%.1f / %.1f GiB' % (db / 1073741824,
                                            budget / 1073741824))
                       if db is not None and budget is not None else None,
        # the spec % and cache % — cumulative since server start (counter
        #     ratios; the calibration: == token_hit_rate and == Σbodies)
        'spec_pct': (round(acc / draft * 100, 1))
                    if acc is not None and draft else None,
        'cache_cached': saved,
        'cache_total': (saved + processed)
                       if saved is not None and processed is not None else None,
        'cache_pct': (round(saved / (saved + processed) * 100, 1))
                     if saved is not None and processed is not None
                     and (saved + processed) else None,
        # «принято» — consistent with gufo: the cache denominator (the
        #     incoming tokens since server start = saved+processed), NOT
        #     drafts (those are in the «Спекуляция» row as %)
        'in_total': (saved + processed)
                    if saved is not None and processed is not None else None,
        'gen_total': metrics.get(K_PRED),  # the lifetime cumulative —
                     # as gufo (tok_pred)
        # (посл) — the last completed request (L); held until the next one
        'gen_last': last.get('gen_last') if last else None,
        'tau': last.get('tau') if last else None,
        'prefill_last': last.get('prefill_last') if last else None,
        # ttft: (средн) = the server's prompt_s/requests cumulative (the
        #     W3.3 «container»), (окно) = the session (apply_tick); this is
        #     the prefill time — the server has no TMFT counter (the
        #     calibration: == the body's prompt_ms)
        'ttft_s': ((metrics.get(K_PROMPT_S) or 0)
                   / (metrics.get(K_REQS) or 0))
                  if metrics.get(K_PROMPT_S) and metrics.get(K_REQS) else None,
        'queue_depth': _int(metrics.get('halogen:kv_pool_waiting_for_room')),
        'queue_capacity': _int(health.get('slots')),
        'pulse_units': ('ток/тик', 'ток/тик', 'черн. ток/тик'),
    }


def build_panels():
    # Row 1 — «Движок» + «Железо», row 2 — «Метрики» (the frame default),
    # row 3 — «Скорость»
    return [wf.CommonEnginePanel(), wf.HwPanel(),
            wf.MetricsPanel(), wf.SpeedPanel()]


def selfcheck_engine():
    # The engine part of the selfcheck: the req-line parser (3 grammar
    # variants, the numbers from the calibration run), the scheme
    # composition, the session averages (apply_tick), the pulses, the
    # plain pins, the row composition
    fails = []
    total = 0

    def ck(name, cond):
        nonlocal total
        total += 1
        if not cond:
            fails.append(name)

    # the parser: variant 1 uncached (the R2 calibration)
    r1 = parse_req_line('serve_api: mtp 51 tok in 0.48s = 106.47 t/s | '
                        '10 rounds, commit 5.10/round | prompt 27023, '
                        'prefill 12.59s = 2147 t/s | detok 16us/tok | '
                        'pool 144128/524288 27% | think off')
    ck('парсер uncached: поля', r1 and r1['gen_last'] == 106.47
       and r1['tau'] == 5.10 and r1['cached'] == 0 and r1['new'] == 27023
       and r1['prefill_last'] == 2147.0 and r1['prompt'] == 27023)
    # variant 2 cached (the R3 calibration)
    r2 = parse_req_line('serve_api: mtp 64 tok in 0.95s = 67.04 t/s | '
                        '27 rounds, commit 2.33/round | prompt 27024 '
                        '(27008 cached, 99.9%), prefill 0.09s (16 new) | '
                        'detok 20us/tok | pool 144128/524288 27% | think off'
                        ' | disk: restored 27008 rows in 195 ms')
    ck('парсер cached: поля', r2 and r2['gen_last'] == 67.04
       and r2['tau'] == 2.33 and r2['cached'] == 27008
       and r2['cached_pct'] == 99.9 and r2['new'] == 16
       and r2['prefill_s'] == 0.09)
    ck('парсер cached: rate = new/Xs', abs(r2['prefill_last'] - 177.8) < 0.1)
    # variant 3 short (the R1 calibration)
    r3 = parse_req_line('serve_api: mtp 3 tok in 0.03s = 89.55 t/s | '
                        '1 rounds, commit 3.00/round | prompt 16, '
                        'prefill 0.08s (16 new) | detok 85us/tok | '
                        'pool 116992/524288 22% | think off')
    ck('парсер короткая: new=prompt', r3 and r3['new'] == 16
       and r3['cached'] == 0 and r3['tau'] == 3.0)
    ck('парсер: не-req строка', parse_req_line('INFO: 200 OK') is None)
    # route_conf: the uptime from the first -t stamp + spec + _last
    # (separate runs)
    ts_now = time.time()
    boot = ('serve_api: flash_serve: listening on 127.0.0.1:8730, '
            'MTP depth-2 (up to 7, cost rule) selectable')
    ts_line = '2026-11-26T17:30:00.000000000+03:00 '
    eng = HalogenEng()
    route, conf = eng.route_conf([boot, ts_line + 'serve_api: mtp 3 tok'])
    ck('route_conf: route канон', route.get('model') == MODEL_CANON
       and conf == {})
    ck('route_conf: аптайм ≈ now−метка',
       eng._uptime is not None
       and abs(eng._uptime - (ts_now - wf.podman_ts_epoch(
           ts_line + 'serve_api: mtp 3 tok'))) < 5)
    eng = HalogenEng()
    eng.route_conf([boot])
    ck('route_conf: spec из boot-строки', eng._spec == 'mtp+ngram K=7')
    eng = HalogenEng()
    eng.route_conf(['x', 'serve_api: mtp 3 tok in 0.03s = 89.55 t/s | '
                        '1 rounds, commit 3.00/round | prompt 16, '
                        'prefill 0.08s (16 new)'])
    ck('route_conf: req-строка → _last', eng._last is not None
       and eng._last['gen_last'] == 89.55)
    # scheme: the cumulatives + (посл) + the /cache gauges (the
    # calibration numbers)
    health = {'slots': 4, 'context': 262144, 'kv_cache': 'bf16',
              'drafter_default': 'mtp',
              'prompt_cache': {'enabled': True, 'cap_mb': 57}}
    metrics = {K_PRED: 216, K_PRED_S: 3.0, K_PROMPT: 27376, K_PROMPT_S: 13.0,
               K_DRAFT: 175, K_ACCEPTED: 144, K_SAVED: 101759, K_REQS: 5,
               'halogen:kv_pool_waiting_for_room': 1,
               'halogen:cache_entries': 9, 'halogen:cache_bytes': 545861556,
               'halogen:cache_disk_bytes': 10004018376,
               'halogen:cache_disk_budget_bytes': 68719476736}
    sch = build_scheme(health, metrics, 28, 1624, 3600.0,
                       'mtp+ngram K=7', r2)
    ck('scheme: слоты/ctx', sch['slots'] == 4 and sch['ctx_tokens'] == 262144)
    ck('scheme: kv bf16', sch['kv_mode'] == 'bf16 (16 бит)')
    ck('scheme: спек строка', sch['spec_conf'] == 'mtp+ngram K=7')
    ck('scheme: кэш-ram с потолком из boot-строки',
       sch['cache_ram'] == '9 из 28 записей · %d из ~1624 MB'
       % (545861556 // 1048576))
    ck('scheme: без потолка — cap_mb суффикс',
       build_scheme(health, metrics, 28, None, 3600.0, None, None)
       .get('cache_ram') == '9 из 28 записей · %d MB · ≤57 MB/зап.'
       % (545861556 // 1048576))
    eng_b = HalogenEng(); eng_b._boot = None
    os.environ.pop('LCTL_WATCH_CONTAINER', None)
    merged = eng_b._boot_merge(['a', 'b'])
    ck('_boot_merge: нет контейнера → буфер как есть, без retry',
       merged == ['a', 'b'] and eng_b._boot == [])
    mc = R_RAM_CAP.search('flash_serve: prompt cache ON, resume-anywhere '
                          '(28 entries, snapshot every request, chunk 32768, '
                          '58 MiB each at ctx 262144): warm not bitwise')
    ck('boot-парсер потолка RAM-кэша', mc is not None
       and int(mc.group(1)) == 28 and int(mc.group(2)) == 58)
    ck('scheme: кэш-диск', sch['cache_disk'] == '9.3 / 64.0 GiB')
    ck('scheme: спек-pct кумулятив', sch['spec_pct'] == 82.3)  # 144/175
    ck('scheme: кэш кумулятив == token_hit_rate',
       sch['cache_pct'] == 78.8 and sch['cache_cached'] == 101759
       and sch['cache_total'] == 129135)
    ck('scheme: сген кумулятив + принято = знаменатель кэша (gufo-семантика)',
       sch['gen_total'] == 216 and sch['in_total'] == sch['cache_total']
       and sch['in_total'] == 129135)
    ck('scheme: (посл) из строки', sch['gen_last'] == 67.04
       and sch['tau'] == 2.33
       and abs(sch['prefill_last'] - 177.8) < 0.1)
    ck('scheme: ttft (средн) кумулятив 13/5=2.6',
       sch['ttft_s'] == 2.6)
    ck('scheme: очередь', sch['queue_depth'] == 1
       and sch['queue_capacity'] == 4)
    ck('scheme: pulse_units честные',
       sch['pulse_units'][2] == 'черн. ток/тик')
    ck('scheme: max_entries нет → кэш-ram без резерва, с капом',
       build_scheme(health, metrics, None, 1624, 3600.0, None, None)
       .get('cache_ram') == '9 записей · 520 из ~1624 MB')
    ck('scheme: /metrics без гейджей → кэш-ram «—»',
       build_scheme(health, {k: v for k, v in metrics.items()
                             if 'cache_' not in k}, 28, None, 3600.0,
                    None, None).get('cache_ram') is None)
    # apply_tick: the session averages on the "Δseconds>0" gate (the
    #     calibration: they equal Δtokens/Δseconds within the 0.1s rounding)
    eng2 = HalogenEng()
    m = dict(metrics)
    snap = {'engine_ok': True, 'scheme': build_scheme(
        health, m, 28, None, 3600.0, None, None), 'metrics': m}
    d = eng2.apply_tick(snap)
    ck('apply_tick: база session → дельт-ключи есть, ген-средн «—»',
       'decode' in d and snap['scheme'].get('gen_avg') is None)
    m2 = dict(m)
    m2[K_PRED] = 616.0; m2[K_PRED_S] = 8.0   # Δ400/Δ5.0 → 80.0 tok/s
    m2[K_ACCEPTED] = 544.0                    # Δ400 → the decode pulse
    m2[K_PROMPT] = 43376.0; m2[K_PROMPT_S] = 21.0  # Δ16000/Δ8 → 2000.0
    m2[K_REQS] = 6.0                          # Δ1 → ttft_win 8.0 s
    m2[K_SAVED] = 117759.0                    # Δ16000 → the cache cumulative 85.1
    snap['metrics'] = m2
    snap['scheme'] = build_scheme(health, m2, 28, None, 3600.0, None, None)
    d = eng2.apply_tick(snap)
    ck('apply_tick: ген(средн) 80.0 (Δ400/Δ5с)', snap['scheme']['gen_avg'] == 80.0)
    ck('apply_tick: prefill(средн) 2000.0', snap['scheme']['prefill_avg'] == 2000.0)
    ck('apply_tick: ttft (окно) 8.00 с', snap['scheme']['ttft_win'] == 8.0)
    ck('apply_tick: сген-кумулятив не перезаписывается',
       snap['scheme']['gen_total'] == 616)
    ck('apply_tick: пульсы', d.get('decode') == 400 and d.get('prefill') == 16000
       and d.get('drafts') == 0)
    snap2 = {'engine_ok': False, 'scheme': None, 'metrics': {}}
    eng2.apply_tick(snap2)
    ck('apply_tick: мёртвый → hist [0,400,0]',
       eng2.hist['decode'] == deque([0, 400, 0]))
    # the frame panels consume the scheme without «?» (the W3 invariant)
    gl = wf.Glyphs(True)
    panels = build_panels()
    for p in panels:
        p.bind(gl)
    snap3 = {'engine_ok': True, 'scheme': sch}
    engine_lines = panels[0].plain_lines(snap3, '12:00:00')
    ck('plain движок: спек/ctx/kv', any(
        'спек mtp+ngram K=7' in ln and '262 144' in ln
        and 'kv bf16 (16 бит)' in ln for ln in engine_lines))
    ck('plain движок: кэш-ram с резервом и потолком', any(
        'кэш-ram 9 из 28 записей · 520 из ~1624 MB' in ln
        for ln in engine_lines))
    metrics_lines = panels[2].plain_lines(snap3, '12:00:00')
    ck('plain метрики: (посл) живые с тика 1', any(
        '67.0 (посл) tok/s' in ln and '177.8 (посл) tok/s' in ln
        for ln in metrics_lines))
    ck('plain метрики: τ 2.3 (fmt1)', 'τ 2.3 ток/цикл' in metrics_lines[0])
    ck('plain метрики: кэш кумулятив 78.8 %',
       '78.8 %' in metrics_lines[0])
    ck('plain метрики: ttft 2.60 с', '2.60 с' in metrics_lines[0])
    speed_lines = panels[3].plain_lines(
        snap3, '12:00:00', deltas={'decode': 400, 'prefill': 16000,
                                   'drafts': 400})
    ck('plain скорость: единицы черн. ток/тик',
       'drafts +400 (черн. ток/тик)' in speed_lines[0])
    gufo_speed = panels[3].plain_lines(
        {'scheme': {}}, '12:00:00', deltas={'decode': 1, 'prefill': 2,
                                            'drafts': 3})
    ck('plain скорость: дефолт каркаса (без units) — gufo-текст',
       'drafts +3 (цикл/тик)' in gufo_speed[0])
    joined = '\n'.join(engine_lines + metrics_lines)
    ck('plain: «?» не существует', '?' not in joined)
    ck('состав рядов [Движок, Железо | Метрики | Скорость]',
       [getattr(p, 'row', 2) for p in panels] == [1, 1, 2, 3])

    for name in fails:
        print('selfcheck engine FAIL: %s' % name, file=sys.stderr)
    print('selfcheck engine: %d/%d ok' % (total - len(fails), total))
    return 1 if fails else 0


def main(argv):
    # The SELFCHECK seam: the frame + engine parts (the rc — the max of them)
    if os.environ.get('LCTL_WATCH_SELFCHECK') == '1':
        rc1 = wf.selfcheck()
        rc2 = selfcheck_engine()
        return max(rc1, rc2)
    w = wf.Watch(panels=build_panels(), eng=HalogenEng())
    return wf.main_loop(w)


if __name__ == '__main__':
    sys.exit(main(sys.argv))
