#!/usr/bin/env python3
# Purpose: the gufo panel's entry point of `lctl watch` (ENGINE_WATCH_TUI,
#   W3.2 — the restyle per the approved dashboard-layout.md layout) — it
#   assembles the panels [«Движок» (the frame's CommonEnginePanel: Uptime +
#   Configuration), «Железо» (the frame), «Метрики» (the frame's
#   MetricsPanel — a shared 8-row block), «Скорость» (the frame, row 3)]
#   from the core/tpl/python/watch/watch_frame.py frame (PYTHONPATH is set
#   by the adapter's engine_watch_env via cmd_watch; the battery sets it
#   directly), provides the engine-data ENG provider and aggregates the
#   selfcheck: the frame part (frame.selfcheck) + the engine one (the §5
#   FINAL methodologies — a ratio-of-sums over uptime, τ=accepted/cycles,
#   uptime_from_log, scheme v2, the plain pins).
#
#   The row-2 specifics panels are REMOVED (the Route dissolved into the
#   Configuration, KV/Queue/Prefill-tokens/Generated — into the shared
#   «Метрики», Prompt-lookup has no row in the approved scheme); the
#   frame's .row-default mechanism is kept for future dialects.
#
# The shared v2 scheme (the frame's scheme dict): uptime_sec — from the
#   first `podman logs -t` stamp (no uptime key in HTTP — the recon
#   semantics; rotation = an underestimate risk, the docstring);
#   spec_conf «dflash2 K=7» (speculative + draft_limit from
#   load_completed); slots/ctx — load_completed; kv_mode — the HARDCODE
#   KV_MODE_GUFO (the user's 2026-11-23 decision, layout §3);
#   cache_ram/cache_disk — the budget from event=configured
#   («12 GiB (бюджет)» — the used is not returned by the engine, the recon
#   semantics); device_lost — a counter; gen/prefill averages — a
#   ratio-of-sums over uptime; gen/prefill (посл) — a gauge (the last
#   NON-zero speed); cache — cached/(prompt+cached); accepted —
#   accepted/draft_tokens; τ — accepted/cycles; queue — processing
#   (deferred not printed separately, no capacity → «N запросов»);
#   inter-slot/ttft — gufo has none → «—»; generated —
#   tokens_predicted_total. The draft pulse — ΔK_ROUNDS (цикл/тик,
#   layout §5).
#
# Side effects: see watch_frame.main_loop (every tick — GET /metrics +
#   GET /ready via curl from PATH; TUI — the podman logs seed/stream).
#   Touches no files or the stack.
#
# Limitations/assumptions: stdlib only, 3.8+ syntax; the metric names —
#   only from the EXP-007 fact base + the emitter code (never made up);
#   a missing key → None → «—» in the render (an old image — a
#   degradation, not a crash).
import os
import sys
import time
from collections import deque

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))  # watch_engine is a sibling
# The frame is on sys.path even on a bare run (--selfcheck without env;
# watch_engine imports the frame's podman timestamp): engine_watch_env/the
# battery set PYTHONPATH
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                '..', '..', '..', '..',
                                'core', 'tpl', 'python', 'watch'))

import watch_engine  # noqa: E402
import watch_frame  # noqa: E402


# The gufo KV mode — an ADAPTER HARDCODE constant (layout §3, the user's
# 2026-11-23 decision): no registry has a KV flag (gfctl/llmctl) → the
# llama-compatible core's default applies = f16; f32 is never the default.
# NOT the frame (R6). Verify against a KV log line at the next live
# window; if a kv flag lands in the profile — remove the hardcode.
KV_MODE_GUFO = 'f16 (16 бит)'


def _int(s):
    # @returns int|None  # '262144' → 262144; ''/garbage → None
    try:
        return int(s)
    except (TypeError, ValueError):
        return None


class _SecDeltas:
    """Per-TICK seconds Δ (float): the frame's Deltas truncates
    int(cur−prev) — legitimate for token/cycle pulses, but a prefill-seconds
    jump of 0.268 s gave int→0 → the prefill-«средн» hold gate never fired
    (the live window 2026-11-24: «prefill — (средн)» with a live
    window). The Deltas discipline 1:1 (a None failure, a negative Δ →
    None for the tick)."""

    def __init__(self, keys):
        self.keys = dict(keys)
        self.prev = None

    def reset(self):
        self.prev = None

    def update(self, m):
        out = dict.fromkeys(self.keys)
        if m is None:
            self.prev = None
            return out
        if self.prev is not None:
            for key, cnt in self.keys.items():
                cur = m.get(cnt)
                prev = self.prev.get(cnt)
                if cur is not None and prev is not None:
                    d = cur - prev
                    out[key] = d if d >= 0 else None
        self.prev = m
        return out


def _disk_str(used, budget):
    # @returns string  # «U / X GiB (бюджет)» / budget-only / used-only / ''
    #   (parity with the hipfire _disk_budget_str; the used — the host-side
    #   dir_size_bytes of the profile's cache dir — методики-gufo §Кэш диск)
    if budget is None and used is None:
        return ''
    if budget is None:
        return '%s GiB' % watch_frame.fmt1(used / (1024.0 ** 3))
    if used is None:
        return '%s GiB (бюджет)' % watch_frame.fmt1(budget / (1024.0 ** 3))
    return '%s / %s GiB (бюджет)' % (watch_frame.fmt1(used / (1024.0 ** 3)),
                                     watch_frame.fmt1(budget / (1024.0 ** 3)))


def compose_scheme(stats, conf, uptime_sec, route, cache_disk_used=None):
    # @returns dict  # the frame's scheme v2 dict from the tick's facts
    #   (a pure function — collect and the selfcheck; everything
    #   None-safe, absent → «—» in the render). The averages — a
    #   ratio-of-sums over uptime (engine_stats computes them); the cache
    #   budgets — the BUDGET only («12 GiB (бюджет)», no used — §5)
    stats = stats or {}
    route = route or {}
    capacity = (conf or {}).get('capacity')
    disk = (conf or {}).get('disk')
    cache_ram = ('%s GiB (бюджет)' % watch_frame.fmt1(float(capacity)
                                                      / (1024.0 ** 3))
                 if capacity else '')
    cache_disk = _disk_str(cache_disk_used,
                           float(disk) if disk else None)
    spec = route.get('spec') or ''
    draft_limit = route.get('draft_limit') or ''
    return {
        'uptime_sec': uptime_sec,
        'spec_conf': ('%s K=%s' % (spec, draft_limit)
                      if spec and draft_limit else spec),
        'slots': _int(route.get('sessions')),
        'ctx_tokens': _int(route.get('ctx')),
        'kv_mode': KV_MODE_GUFO,
        'cache_ram': cache_ram,
        'cache_disk': cache_disk,
        'device_lost': stats.get('device_lost'),
        'gen_avg': stats.get('gen_avg'),
        'gen_last': stats.get('gen_last'),
        'prefill_avg': stats.get('prefill_avg'),
        'prefill_last': stats.get('prefill_last'),
        # the cache absolutes: the denominator = prompt+cached (prompt
        # excludes cached — HELP; the §3 layout's mirror formula)
        'cache_cached': stats.get('tok_cached'),
        'cache_total': (None if stats.get('tok_prompt') is None
                        or stats.get('tok_cached') is None
                        else stats['tok_prompt'] + stats['tok_cached']),
        'cache_pct': stats.get('cache_pct'),
        'spec_pct': stats.get('spec_pct'),
        'tau': stats.get('tau'),
        'queue_depth': stats.get('q_proc'),   # deferred not printed separately (§5)
        'queue_capacity': None,               # no capacity in /metrics → «N запросов»
        'ttft_s': None,
        'gen_total': stats.get('tok_pred'),
        # the incoming = the cache's denominator (prompt excludes cache
        # hits → the sum with cached = all incoming tokens, global since
        # load)
        'in_total': ((stats.get('tok_prompt') + stats.get('tok_cached'))
                     if stats.get('tok_prompt') is not None
                     and stats.get('tok_cached') is not None else None),
    }


class GufoEng:
    """gufo's ENG provider: /metrics (the §5 formulas), /ready (an
    uptime-like "ready"), the tick deltas + the pulse history, scheme v2,
    route/configured/uptime from the log buffer. The frame owns the loop;
    only the engine dialect lives here."""

    def __init__(self):
        self.port = int(watch_frame.env_float('LCTL_WATCH_PORT', 11435))  # Round 6: единый порт
        self.deltas = watch_frame.Deltas({
            'decode': watch_engine.K_PRED,
            'prefill': watch_engine.K_PROMPT,
            # drafts — ЦИКЛ/тик (лейаут §5: Δраундов верификации, не Δчерновых-токенов)
            'drafts': watch_engine.K_ROUNDS})
        self.hist = {'decode': deque(maxlen=120), 'prefill': deque(maxlen=120),
                     'drafts': deque(maxlen=120)}
        self._conf = {}    # the last route_conf's cache-configured (for scheme)
        self._route = {}   # the last route_conf's route (for scheme)
        self._boot = None  # fix:w38-bootlines — the full scan's boot-line cache
        self._uptime = None  # fix:w32-uptime — the uptime cache (the frame's
        #                       warm-up before the first collect: scheme ready
        #                       for tick 1)
        self._ttft = []      # the session's ttft_ms (route_conf, the log buffer)
        # W3.3: the seconds counters are the hold gates ("the tick's work":
        # the seconds move on done); session — the active window (amendment A1)
        self.gd = watch_frame.Deltas({
            'pred_s': watch_engine.K_PRED_S,
            'prompt_s': watch_engine.K_PROMPT_S})
        # the holds' seconds gates — float (see _SecDeltas; gd's int
        # pulses remain for the sparkline history)
        self.gd_sec = _SecDeltas({
            'pred_s': watch_engine.K_PRED_S,
            'prompt_s': watch_engine.K_PROMPT_S})
        self.session = watch_frame.SessionBase()
        # The Hold carriers (the W3.3 consolidation of W3.2.2/4 + the τ
        # window d1):
        self.h_gen = watch_frame.Hold()     # ген-средн
        self.h_pf_avg = watch_frame.Hold()  # prefill-средн
        self.h_tau = watch_frame.Hold()     # the τ window

    def collect(self, snap):
        # The tick's engine part: /metrics — parse_metrics (the frame) +
        # engine_stats from the log uptime; /ready — liveness; any failure
        # — an exception (the frame catches it, a dead tick). scheme — the
        # v2 dict.
        snap['metrics'] = watch_frame.parse_metrics(
            watch_frame.http_get('http://127.0.0.1:%d/metrics' % self.port))
        cache_dir = os.environ.get('LCTL_WATCH_GUFO_CACHE_DIR') or ''
        # the session window — COUNTERS ONLY (SESSION_KEYS): gauges dive
        #     → a false reset (see SESSION_KEYS in watch_engine)
        snap['window'] = self.session.deltas(
            {k: snap['metrics'][k] for k in watch_engine.SESSION_KEYS
             if k in snap['metrics']})
        snap['stats'] = watch_engine.engine_stats(snap['metrics'], self._uptime,
                                                  snap.get('window'))
        try:
            watch_frame.http_get('http://127.0.0.1:%d/ready' % self.port)
            snap['ready'] = True
        except Exception:
            snap['ready'] = False
        snap['scheme'] = compose_scheme(snap['stats'], self._conf,
                                        self._uptime, self._route,
                                        cache_disk_used=(
                                            watch_frame.dir_size_bytes(cache_dir)
                                            if cache_dir else None))
        snap['scheme'].update(watch_engine.ttft_scheme(self._ttft))

    def apply_tick(self, snap):
        # The deltas + the pulse history: a live tick — an update by
        # /metrics, a dead one — a reset (no false deltas after a
        # recreate); a None delta in the history → 0 (a flat sparkline
        # line). The draft pulse — ΔK_ROUNDS (цикл/тик)
        if snap['engine_ok']:
            d = self.deltas.update(snap['metrics'])
            gd = self.gd.update(snap['metrics'])  # W3.3: the seconds gates
        else:
            d = self.deltas.update(None)
            self.gd.update(None)
            self.gd_sec.reset()
            # a recreate: the old container's window/holds are invalid
            self.session.reset()
            self.h_gen.reset()
            self.h_pf_avg.reset()
            self.h_tau.reset()
            gd = None
        for key in ('decode', 'prefill', 'drafts'):
            self.hist[key].append(d.get(key) or 0)
        # W3.3 v2: the scheme hold patches (the §5 v2 layout; the
        #     freeze consolidation of W3.2.2/4 — "melting" does not come
        #     back). The gates — the tick's Δseconds/Δrounds (>0 = work:
        #     the seconds counters move on done): a fresh session value is
        #     accepted only on a tick with work, otherwise (a quiet tick /
        #     no /metrics) the last one is held; a recreate → a reset;
        #     before the first work — «—» (the seed (a)). The selfcheck
        #     pulses call apply_tick without a scheme — skipped (no
        #     crash).
        scheme = snap.get('scheme')
        if scheme is not None:
            g = self.gd_sec.update(snap['metrics']) if snap['engine_ok'] else {}
            if 'gen_avg' in scheme:
                scheme['gen_avg'] = self.h_gen.take(
                    scheme.get('gen_avg'), bool(g.get('pred_s')))  # fix:w33-hold
            if 'prefill_avg' in scheme:
                scheme['prefill_avg'] = self.h_pf_avg.take(
                    scheme.get('prefill_avg'), bool(g.get('prompt_s')))  # fix:w33-hold
            if 'tau' in scheme:
                scheme['tau'] = self.h_tau.take(
                    scheme.get('tau'), bool(d.get('drafts')))  # fix:w33-hold
        return d

    def route_conf(self, buf):
        # @returns (dict, dict)  # the route (load_completed, +
        #   draft_limit) + the cache-configured from the log buffer (the
        #   last line wins); both are cached for the next collect's scheme;
        #   also — the uptime from the first `podman logs -t` stamp (the
        #   fix:w32-uptime _conf pattern)
        lines = self._boot_merge(buf)
        self._conf = watch_engine.parse_configured_lines(lines)
        self._route = watch_engine.parse_route_lines(lines)
        self._uptime = watch_engine.uptime_from_log(lines, time.time())
        self._ttft = watch_engine.ttft_ms_list(lines)  # методики-gufo §TTFT
        return (self._route, self._conf)

    def _boot_merge(self, buf):
        # fix:w38-bootlines — the boot lines (load_completed/
        # event=configured) are pushed out of the `--tail 200` seed window
        # by any chatty load: --log-progress gives ~7k lines/hour under a
        # prefill, bench runs finish it off right away (the live case
        # 2026-11-25: Спекуляция/Контекст/Кэш RAM/uptime/prefill-avg = «—»).
        # The full scan: one full scan of the container log; found → the
        # cache forever (a new engine after a recreate delivers a fresh
        # boot line into the live stream — "the last one wins").
        # shortcut: a scan timeout/error → empty, the boot line will come
        # from the live stream when it itself passes through the window;
        # no retry scan is done
        if self._boot is None:
            self._boot = []  # no env/a scan failure → empty (the live-stream fallback)
            try:
                import subprocess
                c = os.environ.get('LCTL_WATCH_CONTAINER', '')
                if c:
                    # podman logs prints records to STDERR (a doc fact of
                    # watch_frame.py) — read both streams; -t gives the
                    # RFC3339 stamps for uptime_from_log
                    r = subprocess.run(['podman', 'logs', '-t', c],
                                       capture_output=True, text=True, timeout=30)
                    out = (r.stdout or '') + '\n' + (r.stderr or '')
                    self._boot = [l for l in out.splitlines()
                                  if 'load_completed' in l
                                  or 'event=configured' in l][-8:]
            except Exception:
                pass
        return self._boot + list(buf)

    def log_line_local(self, line):
        return watch_frame.log_line_local(line)


def build_panels():
    # The entry point's panel composition: row 1 — «Движок» + «Железо»
    # (the registration order = the columns), row 2 — «Метрики» (the
    # frame, the .row default), row 3 — «Скорость»
    return [watch_frame.CommonEnginePanel(), watch_frame.HwPanel(),
            watch_frame.MetricsPanel(), watch_frame.SpeedPanel()]


def selfcheck_engine():
    # The engine part of the selfcheck (the frame part is
    # watch_frame.selfcheck's): the §5 FINAL methodologies — gen/prefill
    # averages as a ratio-of-sums over uptime (the EXP-007 snapshot with
    # an explicit uptime + the snap1 fixture + the test "two ticks:
    # 100→300 at uptime 10 → exactly 30.0" — not a per-tick delta), τ=
    # accepted/cycles, the division edges, uptime_from_log (pure, the
    # first stamp), the v2 scheme composition (the full dict), the draft
    # pulse ΔK_ROUNDS, the log parsers (route+draft_limit/configured 1:1),
    # the plain pins, the panel composition. The moved primitives' cases
    # are in the frame part.
    fails = []
    total = 0

    def ck(name, cond):
        nonlocal total
        total += 1
        if not cond:
            fails.append(name)

    # ── engine_stats: the EXP-007 snapshot (v2: window deltas, a cross-check) ─
    # the EXP-007 snapshot's seconds counters → the session window (the
    #     same numbers: 18/0.8935 — the lifetime/window convergence on one
    #     request)
    m7_raw = watch_frame.parse_metrics(
        'llamacpp:prompt_tokens_total 93\n'
        'llamacpp:prompt_tokens_cached_total 27044\n'
        'llamacpp:prompt_seconds_total 0.63273363599999999\n'
        'llamacpp:tokens_predicted_total 18\n'
        'llamacpp:tokens_predicted_seconds_total 0.89354949399999994\n'
        'llamacpp:n_tokens_max 27155\n'
        'llamacpp:spec_decode_num_drafts_total 7\n'
        'llamacpp:spec_decode_num_draft_tokens_total 30\n'
        'llamacpp:spec_decode_num_accepted_tokens_total 11\n'
        'llamacpp:prompt_tokens_seconds 146.98128044515718\n'
        'llamacpp:predicted_tokens_seconds 20.144379377825491\n'
        'llamacpp:requests_processing 0\n'
        'llamacpp:requests_deferred 0\n'
        'llamacpp:kv_cache_usage_ratio 0\n'
        'gufo_device_lost_total 0\n')
    m7 = watch_engine.engine_stats(m7_raw, 0.89354949399999994, window={
        'llamacpp:tokens_predicted_total': 18.0,
        'llamacpp:tokens_predicted_seconds_total': 0.89354949399999994,
        'llamacpp:prompt_tokens_total': 93.0,
        'llamacpp:prompt_seconds_total': 0.63273363599999999,
        'llamacpp:spec_decode_num_accepted_tokens_total': 11.0,
        'llamacpp:spec_decode_num_drafts_total': 7.0})
    ck('stats EXP-007 gen_avg≈20.14 (18/Δpred_s 0.8935 — v2 ratio-of-sums '
       'сессии, конвергентно с lifetime на одном запросе)',
       abs(m7['gen_avg'] - 20.1444) < 0.01)
    ck('stats EXP-007 prefill_avg≈146.98 (93/Δprompt_s 0.6327 — v2)',
       abs(m7['prefill_avg'] - 146.9813) < 0.01)
    ck('stats: window None (база не зафиксирована — seed (а)) → средн «—», '
       'гейджи/качественные живы',
       (lambda s: s['gen_avg'] is None and s['prefill_avg'] is None
        and s['tau'] is None and s['gen_last'] == 20.144379377825491
        and s['cache_pct'] is not None)(
           watch_engine.engine_stats(m7_raw, 0.89354949399999994)))
    ck('stats EXP-007 gauge passthrough (посл ненулевая)',
       m7['gen_last'] == 20.144379377825491
       and m7['prefill_last'] == 146.98128044515718)
    ck('stats EXP-007 cache_pct≈99.66 ≤100 (знаменатель prompt+cached)',
       abs(m7['cache_pct'] - 99.658) < 0.01 and m7['cache_pct'] <= 100.0)
    ck('stats EXP-007 spec_pct≈36.67 ПО ТОКЕНАМ (11/30, не раунды 11/7)',
       abs(m7['spec_pct'] - 36.6667) < 0.01)
    ck('stats EXP-007 tau≈1.57 (Δaccepted/Δrounds = 11/7 — v2 session)',
       abs(m7['tau'] - 11.0 / 7.0) < 0.001)
    ck('stats EXP-007 KV/пик/очередь/lost',
       m7['kv_pct'] == 0.0 and m7['kv_peak'] == 27155.0
       and m7['q_proc'] == 0.0 and m7['q_def'] == 0.0 and m7['device_lost'] == 0.0)
    ck('stats lookup нули → pct None',
       watch_engine.engine_stats(watch_frame.parse_metrics(
           'gufo_spec_lookup_tokens_total 0\ngufo_spec_lookup_accepted_tokens_total 0\n'
       ))['lookup_pct'] is None)

    # ── engine_stats: the snap1 fixture (exact values, an explicit uptime) + edges ─
    fx1 = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                       '..', '..', 'tests', 'fixtures', 'metrics_snap1.txt')
    m1 = watch_frame.parse_metrics(open(fx1).read())
    w1 = {watch_engine.K_PRED: 50000.0, watch_engine.K_PRED_S: 2500.0,
          watch_engine.K_PROMPT: 10000.0, watch_engine.K_PROMPT_S: 2500.0,
          watch_engine.K_ACC: 60000.0, watch_engine.K_ROUNDS: 5000.0}
    st1 = watch_engine.engine_stats(m1, 2500, window=w1)
    ck('stats snap1 gen_avg ровно 20.0 (50000/Δ2500с — v2 session)',
       st1['gen_avg'] == 20.0)
    ck('stats snap1 prefill_avg ровно 4.0 (10000/Δ2500с — v2)',
       st1['prefill_avg'] == 4.0)
    ck('stats snap1 cache_pct ровно 99.0 (≤100)', abs(st1['cache_pct'] - 99.0) < 1e-6)
    ck('stats snap1 spec_pct ровно 60.0 (accepted/draft_tokens)',
       abs(st1['spec_pct'] - 60.0) < 1e-6)
    ck('stats snap1 tau ровно 12.0 (60000/5000 раундов — v2 session)',
       st1['tau'] == 12.0)
    ck('stats: Δseconds=0 в окне (живые токены без done) → «—» (fail-visible); '
       'ключа нет в окне → «—»',
       watch_engine.engine_stats(m1, 2500, window=dict(
           w1, **{watch_engine.K_PRED_S: 0.0}))['gen_avg'] is None
       and watch_engine.engine_stats(m1, 2500, window={
           watch_engine.K_PRED: 300.0})['gen_avg'] is None
       and watch_engine.engine_stats(m1, 2500, window=dict(
           w1, **{watch_engine.K_ROUNDS: 0.0}))['tau'] is None)
    ck('stats spec_pct None при draft_tokens=0',
       watch_engine.engine_stats(watch_frame.parse_metrics(
           'llamacpp:spec_decode_num_accepted_tokens_total 5\n'
           'llamacpp:spec_decode_num_draft_tokens_total 0\n'))['spec_pct'] is None)
    ck('stats tau None при rounds=0',
       watch_engine.engine_stats(watch_frame.parse_metrics(
           'llamacpp:spec_decode_num_accepted_tokens_total 5\n'
           'llamacpp:spec_decode_num_drafts_total 0\n'))['tau'] is None)
    ck('stats None/пусто', watch_engine.engine_stats(None) is None
       and watch_engine.engine_stats({}) is None)

    # ── TTFT from the log details (методики-gufo §TTFT) ────────────────────
    tbuf = ['2026-11-24T10:00:01.000Z [INFO] [http] r1 POST /v1/chat/completions'
            ' 200 duration_ms=1200.5 prompt_tokens=100 prefill_tokens=100'
            ' generated_tokens=8 finish=stop cache=miss cached_tokens=0'
            ' queue_ms=0.2 ttft_ms=310.5 prefill_tps=500.0 decode_tps=60.0',
            '2026-11-24T10:00:02.000Z [INFO] [progress] percentage=50'
            ' avg_tps=55.0 draft_accepted=6 draft_proposed=7',  # no ttft
            '2026-11-24T10:00:03.000Z [INFO] [http] r2 POST /v1/chat/completions'
            ' 200 duration_ms=900.0 ttft_ms=110.0']
    ck('ttft_ms_list: 2 значения из 3 строк (progress без ttft скипается)',
       watch_engine.ttft_ms_list(tbuf) == [310.5, 110.0])
    ck('ttft_scheme: средн сессии 0.21025 с · окно (мс → с, рендер «%.2f с»)',
       watch_engine.ttft_scheme([310.5, 110.0])['ttft_s'] == 0.21025
       and watch_engine.ttft_scheme([310.5, 110.0])['ttft_win'] == 0.21025)
    ck('ttft_scheme: окно = последние 10 из 11 (мс → с: 0.5/0.55 с)',
       watch_engine.ttft_scheme([i * 100.0 for i in range(11)])['ttft_s'] == 0.5
       and watch_engine.ttft_scheme([i * 100.0 for i in range(11)])['ttft_win'] == 0.55)
    ck('ttft_scheme: seconds-масштаб на 2 значениях',
       watch_engine.ttft_scheme([832.2, 282.5])['ttft_s'] == 0.55735)

    # ── the 2026-11-24 live regression: a gauge dive reset the session ─────
    # (processing 1→0 on every done = a negative Δ on a gauge in the full
    #  snapshot → SessionBase.reset on a working tick → «средн»/τ «—»
    #  forever; the fix: the window by SESSION_KEYS only). The http_get
    #  stub — the full collect/apply_tick flow without the network; the
    #  counters jump on tick 2, the gauge dives.
    _orig_get = watch_frame.http_get
    try:
        _m = {
            'tick1': ('llamacpp:tokens_predicted_total 10\n'
                      'llamacpp:tokens_predicted_seconds_total 1.0\n'
                      'llamacpp:requests_processing 1\n'),
            'tick2': ('llamacpp:tokens_predicted_total 110\n'
                      'llamacpp:tokens_predicted_seconds_total 3.5\n'
                      'llamacpp:requests_processing 0\n'
                      'llamacpp:predicted_tokens_seconds 36.3\n'),
            'tick3': ('llamacpp:tokens_predicted_total 110\n'
                      'llamacpp:tokens_predicted_seconds_total 3.5\n'
                      'llamacpp:requests_processing 0\n'
                      'llamacpp:predicted_tokens_seconds 36.3\n'),
        }
        watch_frame.http_get = lambda url, timeout=None: (
            _m['tick1'] if url.endswith('/metrics') else 'ready')
        eng_r = GufoEng()
        s1 = {'engine_ok': True}
        eng_r.collect(s1); eng_r.apply_tick(s1)
        watch_frame.http_get = lambda url, timeout=None: (
            _m['tick2'] if url.endswith('/metrics') else 'ready')
        s2 = {'engine_ok': True}
        eng_r.collect(s2); eng_r.apply_tick(s2)
        watch_frame.http_get = lambda url, timeout=None: (
            _m['tick3'] if url.endswith('/metrics') else 'ready')
        s3 = {'engine_ok': True}
        eng_r.collect(s3); eng_r.apply_tick(s3)
        ck('session-фильтр: нырок гейджа processing НЕ сбрасывает окно — '
           'ген-средн 100/2.5=40.0 принят и держится (регресс 2026-11-24)',
           s2['scheme']['gen_avg'] == 40.0
           and s3['scheme']['gen_avg'] == 40.0)
    finally:
        watch_frame.http_get = _orig_get
    sd = _SecDeltas({'prompt_s': watch_engine.K_PROMPT_S})
    sd.update({'llamacpp:prompt_seconds_total': 3.0})
    ck('_SecDeltas: float-Δ 0.268 не усекается в 0 (регресс prefill-гейта '
       '2026-11-24)',
       abs(sd.update({'llamacpp:prompt_seconds_total': 3.268})['prompt_s']
           - 0.268) < 1e-9
       and sd.update({'llamacpp:prompt_seconds_total': 3.0})['prompt_s'] is None)
    ck('ttft_scheme: пусто → оба None (seed «—»)',
       watch_engine.ttft_scheme([]) == {'ttft_s': None, 'ttft_win': None})

    # ── the Cache disk: used+budget (a host-side du, методики-gufo) ────────
    ck('_disk_str: обе ветки (used+бюджет / бюджет-only / used-only / пусто)',
       _disk_str(1073741824.0, 68719476736.0) == '1.0 / 64.0 GiB (бюджет)'
       and _disk_str(None, 68719476736.0) == '64.0 GiB (бюджет)'
       and _disk_str(1073741824.0, None) == '1.0 GiB'
       and _disk_str(None, None) == '')

    # ── v2: the active window — uptime/wall is NOT the denominator (amendment 12) ─
    mb = watch_frame.parse_metrics('llamacpp:tokens_predicted_total 300\n')
    ck('v2 «2 мин работы из 5» ≡ «5 мин непрерывных»: 300/Δ10с = ровно 30.0 '
       'при любом аптайме лога (ratio-of-sums сессии, не дельта за тик)',
       watch_engine.engine_stats(mb, 10, window={
           watch_engine.K_PRED: 300.0,
           watch_engine.K_PRED_S: 10.0})['gen_avg'] == 30.0
       and watch_engine.engine_stats(mb, 99999, window={
           watch_engine.K_PRED: 300.0,
           watch_engine.K_PRED_S: 10.0})['gen_avg'] == 30.0)
    pb = watch_frame.parse_metrics('llamacpp:prompt_tokens_total 300\n')
    ck('v2 зеркальный prefill: 300/Δ10с = 30.0 (cached исключён эмиттером)',
       watch_engine.engine_stats(pb, 10, window={
           watch_engine.K_PROMPT: 300.0,
           watch_engine.K_PROMPT_S: 10.0})['prefill_avg'] == 30.0)

    # ── uptime_from_log (pure; fix:w32-uptime) ─────────────────────────────
    import calendar
    want53 = calendar.timegm((2026, 1, 23, 7, 12, 33, 0, 0, 0))
    log = ['2026-01-23T07:12:33.500000000Z 2026-01-16 07:26:58 [INFO] boot',
           'event=load_completed speculative=dflash2']
    ck('uptime_from_log: первая podman-метка буфера → now−epoch',
       watch_engine.uptime_from_log(log, want53 + 90) == 90)
    ck('uptime_from_log: меток нет (лог без -t) → None',
       watch_engine.uptime_from_log(['event=listening'], want53) is None)
    ck('uptime_from_log: пустой буфер → None',
       watch_engine.uptime_from_log([], want53) is None)
    ck('uptime_from_log: метка в будущем → 0 (не отрицательный)',
       watch_engine.uptime_from_log(log, want53 - 5) == 0)

    # ── the log parsers (the parse_route/parse_configured semantics 1:1) ───
    seed = ['2026-11-17 08:47:19 [INFO] boot',
            'event=load_completed speculative=mtp draft_limit=7 elapsed_ms=1 '
            'model=Qwen3.8 Flash Next sessions=2 context_tokens=262144']
    r = watch_engine.parse_route_lines(seed)
    ck('route: модель с пробелами целиком + поля + draft_limit',
       r == {'spec': 'mtp', 'draft_limit': '7', 'sessions': '2',
             'ctx': '262144', 'model': 'Qwen3.8 Flash Next'})
    r2 = watch_engine.parse_route_lines(seed + [
        'event=load_completed speculative=dflash2 sessions=1 '
        'context_tokens=163840 model=B'])
    ck('route: последняя load_completed побеждает',
       r2['spec'] == 'dflash2' and r2['model'] == 'B'
       and r2['draft_limit'] == '' and r2['ctx'] == '163840')
    ck('route: пусто → все ""', watch_engine.parse_route_lines(['boot']) ==
       {'spec': '', 'draft_limit': '', 'sessions': '', 'ctx': '', 'model': ''})
    c = watch_engine.parse_configured_lines([
        '2026-11-18 07:27:02 [INFO] [cache] schema=component-cache-v1 '
        'event=configured sessions=1 ram_cache=on capacity_bytes=12884901888 '
        'automatic_bytes=4294967296 disk_capacity_bytes=68719476736'])
    ck('configured: поля + \\b-граница (capacity≠disk_capacity)',
       c == {'sessions': '1', 'ram_cache': 'on', 'capacity': '12884901888',
             'automatic': '4294967296', 'disk': '68719476736'})
    ck('configured: пусто → все ""', watch_engine.parse_configured_lines(['x']) ==
       {'sessions': '', 'ram_cache': '', 'capacity': '', 'automatic': '',
        'disk': ''})

    # ── the v2 scheme composition (the pure compose_scheme) ────────────────
    route = {'spec': 'dflash2', 'draft_limit': '7', 'sessions': '1',
             'ctx': '262144', 'model': 'qwen3.8-27b-IQ4_XS-pure'}
    conf = {'sessions': '1', 'ram_cache': 'on', 'capacity': '12884901888',
            'automatic': '4294967296', 'disk': '68719476736'}
    sch = compose_scheme(st1, conf, 2500, route)
    ck('scheme snap1: полный словарь v2 (аптайм, dflash2 K=7, f16-хардкод, '
       'бюджеты 12/64 GiB, ratio-of-sums, τ ток/цикл-источник)',
       sch == {
           'uptime_sec': 2500,
           'spec_conf': 'dflash2 K=7',
           'slots': 1, 'ctx_tokens': 262144,
           'kv_mode': KV_MODE_GUFO,
           'cache_ram': '12.0 GiB (бюджет)', 'cache_disk': '64.0 GiB (бюджет)',
           'device_lost': 0.0,
           'gen_avg': 20.0, 'gen_last': 21.4,
           'prefill_avg': 4.0, 'prefill_last': 98.7,
           'cache_cached': 990000.0, 'cache_total': 1000000.0,
           'cache_pct': 99.0,
           'spec_pct': 60.0, 'tau': 12.0,
           'queue_depth': 0.0, 'queue_capacity': None,
           'ttft_s': None, 'gen_total': 50000.0,
           'in_total': 1000000.0})
    ck('scheme: conf нет → бюджеты "" (рендер «—»)',
       compose_scheme(st1, {}, 2500, route)['cache_ram'] == ''
       and compose_scheme(st1, {}, 2500, route)['cache_disk'] == '')
    ck('scheme: route без draft_limit → spec_conf без K (старый лог)',
       compose_scheme(st1, conf, 2500,
                      dict(route, draft_limit=''))['spec_conf'] == 'dflash2')
    ck('scheme: пустой stats (старый образ) → None-поля, не краш',
       compose_scheme(None, conf, 2500, route)['gen_avg'] is None
       and compose_scheme(None, conf, 2500, route)['spec_conf'] == 'dflash2 K=7')
    ck('scheme: KV_MODE_GUFO — f16 (16 бит), хардкод адаптера (лейаут §3)',
       KV_MODE_GUFO == 'f16 (16 бит)')

    # ── the GufoEng route_conf: the route/conf/uptime cache ────────────────
    eng = GufoEng()
    buf = [
        '2026-11-23T07:12:33.500000000Z 2026-11-18 07:27:01 [INFO] '
        'event=load_completed speculative=dflash2 draft_limit=7 sessions=1 '
        'context_tokens=262144 model=qwen3.8-27b-IQ4_XS-pure',
        'event=configured sessions=1 ram_cache=on capacity_bytes=12884901888 '
        'automatic_bytes=4294967296 disk_capacity_bytes=68719476736']
    r3, c3 = eng.route_conf(buf)
    ck('route_conf: route+conf из буфера (+ draft_limit в роуте)',
       r3 == route and c3 == conf)
    ck('route_conf: аптайм закэширован (fix:w32-uptime, int ≥ 0)',
       isinstance(eng._uptime, int) and eng._uptime >= 0)

    # ── apply_tick: the draft pulse ΔK_ROUNDS (цикл/тик) ───────────────────
    snap = {'engine_ok': True, 'metrics': m1, 'stats': st1, 'ready': True,
            'scheme': dict(sch), 'gpu': None, 'cpu_t': None,
            'mem': {'available_gib': 45.2, 'total_gib': 60.4}}
    d = eng.apply_tick(snap)
    ck('apply_tick тик1: пульсы None',
       d == {'prefill': None, 'decode': None, 'drafts': None})
    m2 = dict(m1)
    m2['llamacpp:tokens_predicted_total'] = 50300.0
    m2['llamacpp:prompt_tokens_total'] = 10512.0
    snap2 = dict(snap, metrics=m2,
                 stats=watch_engine.engine_stats(m2, 2500))
    d2 = eng.apply_tick(snap2)
    ck('apply_tick тик2: live-пульс +300/+512, drafts 0 (раунды стоят)',
       d2 == {'prefill': 512, 'decode': 300, 'drafts': 0})
    m3 = dict(m2)
    m3['llamacpp:spec_decode_num_drafts_total'] = 5060.0
    snap3 = dict(snap2, metrics=m3,
                 stats=watch_engine.engine_stats(m3, 2500))
    d3 = eng.apply_tick(snap3)
    ck('apply_tick тик3: done-пульс drafts +60 (ΔK_ROUNDS = цикл/тик §5)',
       d3 == {'prefill': 0, 'decode': 0, 'drafts': 60})
    eng.apply_tick({'engine_ok': False})
    d4 = eng.apply_tick(dict(snap, metrics=m1))
    ck('apply_tick мёртвый тик — reset; после поднятия ложных дельт нет',
       d4 == {'prefill': None, 'decode': None, 'drafts': None})

    # ── W3.3 v2: the hold semantics (the W3.2.2/4 consolidation; the Δseconds gates) ─
    # the snap1→2→3 fixtures' session deltas: tick2 — live tokens WITHOUT
    #     a done (the seconds stand → raw «—»), tick3 — a done (pred_s +15
    #     → gen exactly 300/15 = 20.0; anti-wall: NOT the lifetime
    #     50300/2515 = 20.12)
    eng2 = GufoEng()
    fx3 = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                       '..', '..', 'tests', 'fixtures', 'metrics_snap3.txt')
    m3s = watch_frame.parse_metrics(open(fx3).read())  # a done tick: seconds/acc/rounds moved
    # n_tokens_max — a gauge maximum (monotonic in a live session); in
    #     snap3 it is numerically below snap1 (the fixtures are from
    #     different processes) → the session test raises it (otherwise the
    #     "a negative Δ anywhere → reset" honestly fires on a non-counter)
    m3s[watch_engine.K_PEAK] = 262644.0
    sb = watch_frame.SessionBase()
    sb.deltas(m1)
    w2 = sb.deltas(m2)
    w3 = sb.deltas(m3s)
    st2 = watch_engine.engine_stats(m2, 2500, window=w2)
    st3 = watch_engine.engine_stats(m3s, 2500, window=w3)
    ck('v2 session (амendment 15): snap2 секунды стоят → сырые «—» (Δ300/0); '
       'snap3 — gen ровно 20.0 (анти-wall lifetime 20.12), prefill 512/5.2, '
       'τ 640/60',
       st2['gen_avg'] is None and st2['prefill_avg'] is None
       and st2['tau'] is None
       and st3['gen_avg'] == 20.0
       and abs(st3['prefill_avg'] - 512 / 5.2) < 1e-9
       and abs(st3['tau'] - 640 / 60) < 1e-9)

    def sch_g():
        return {'gen_avg': None, 'prefill_avg': None, 'tau': None}

    s1 = sch_g()
    eng2.apply_tick({'engine_ok': True, 'metrics': m1, 'scheme': s1})
    ck('hold v2 seed (амendment 10, (а)): тик1 — база session, гейты None → '
       'все «—» (старт при простое; seed НЕ делается)',
       all(s1[k] is None for k in s1))
    s2 = sch_g()
    s2.update({'gen_avg': st2['gen_avg'], 'prefill_avg': st2['prefill_avg'],
               'tau': st2['tau']})  # сырые compose_scheme (все «—»)
    eng2.apply_tick({'engine_ok': True, 'metrics': m2, 'scheme': s2})
    ck('hold v2 тик2 (live без done): гейт Δpred_s=0 → сырые «—» не '
       'принимаются (ранние токены без времени — оценка невозможна)',
       all(s2[k] is None for k in s2))
    s3 = sch_g()
    s3.update({'gen_avg': st3['gen_avg'], 'prefill_avg': st3['prefill_avg'],
               'tau': st3['tau']})
    eng2.apply_tick({'engine_ok': True, 'metrics': m3s, 'scheme': s3})
    ck('hold v2 тик3 (done: seconds/rounds двинулись): gen 20.0 (анти-wall), '
       'prefill 512/5.2, τ 640/60 приняты',
       s3['gen_avg'] == 20.0
       and abs(s3['prefill_avg'] - 512 / 5.2) < 1e-9
       and abs(s3['tau'] - 640 / 60) < 1e-9)
    s4 = sch_g()  # a quiet tick: raw «—» (the session did not move)
    eng2.apply_tick({'engine_ok': True, 'metrics': m3s, 'scheme': s4})
    ck('hold v2 тихий тик (амendment 7): держит все ряды точно (не тает)',
       s4['gen_avg'] == 20.0
       and abs(s4['prefill_avg'] - 512 / 5.2) < 1e-9
       and abs(s4['tau'] - 640 / 60) < 1e-9)
    s5 = sch_g()
    eng2.apply_tick({'engine_ok': True, 'metrics': None, 'scheme': s5})
    ck('hold v2 fail-тик /metrics: держит (база session сохраняется)',
       s5['gen_avg'] == 20.0 and abs(s5['tau'] - 640 / 60) < 1e-9)
    eng2.apply_tick({'engine_ok': False})  # a recreate → a session+holds reset
    s6 = sch_g()
    s6.update({'gen_avg': 20.0, 'prefill_avg': 4.0, 'tau': 12.0})
    eng2.apply_tick({'engine_ok': True, 'metrics': m1, 'scheme': s6})
    ck('hold v2 после recreate (амendment 13): кэши сброшены → «—»; '
       'база перефиксируется без ложных дельт',
       all(s6[k] is None for k in s6))

    # ── the plain pins (the snap1 scheme, UTF glyphs; the §1 format) ────────
    ep = watch_frame.CommonEnginePanel(); ep.bind(watch_frame.Glyphs(True))
    mp = watch_frame.MetricsPanel(); mp.bind(watch_frame.Glyphs(True))
    snap_p = dict(snap, scheme=sch)
    ck('plain движок (каркас, gufo-scheme snap1; формат §1)',
       ep.plain_lines(snap_p, '12:00:00')[0] ==
       '12:00:00 [движок] аптайм 41 мин | спек dflash2 K=7'
       ' | ctx 1 × 262 144 ток | kv f16 (16 бит) | кэш-ram 12.0 GiB (бюджет)'
       ' | кэш-диск 64.0 GiB (бюджет) | lost 0')
    ck('plain метрики (каркас, gufo-scheme snap1; ген-средн от аптайма '
       'снапшота, посл — gauge, очередь без capacity «0 запросов»)',
       mp.plain_lines(snap_p, '12:00:00')[0] ==
       '12:00:00 [метрики] ген 20.0 (средн) · 21.4 (посл) tok/s'
       ' | prefill 4.0 (средн) · 98.7 (посл) tok/s'
       ' | кэш 990.0k из 1.0M ток из кэша (99.0 %)'
       ' | спек принято 60.0 % · τ 12.0 ток/цикл | оч 0 запросов'
       ' | ttft — | сген 50.0k ток · принято 1.0M')
    ck('rows: лейблы обеих панелей == константам каркаса (лейаут §1 1:1; '
       'Device lost — в шапке с fix:w39, ряда нет)',
       [x[0] for x in ep.rows(snap_p)] == list(watch_frame.ENGINE_ROWS)
       and [x[0] for x in mp.rows(snap_p)] == list(watch_frame.METRICS_ROWS))

    # ── the entry point's panel composition + the layout rows ──────────────
    panels = build_panels()
    ck('панели точки входа: [Движок, Железо, Метрики, Скорость] '
       '(специфика ряда 2 удалена — лейаут §1)',
       [type(p).__name__ for p in panels] ==
       ['CommonEnginePanel', 'HwPanel', 'MetricsPanel', 'SpeedPanel'])
    ck('ряды лейаута: 1/1/2/3 (Метрики без .row — дефолт каркаса)',
       [getattr(p, 'row', 2) for p in panels] == [1, 1, 2, 3])

    for name in fails:
        print('selfcheck engine FAIL: %s' % name, file=sys.stderr)
    print('selfcheck engine: %d/%d ok' % (total - len(fails), total))
    return 1 if fails else 0


def main(argv):
    # The SELFCHECK seam: the frame + engine parts (the rc — the max of them)
    if os.environ.get('LCTL_WATCH_SELFCHECK') == '1':
        rc1 = watch_frame.selfcheck()
        rc2 = selfcheck_engine()
        return max(rc1, rc2)
    w = watch_frame.Watch(panels=build_panels(), eng=GufoEng())
    return watch_frame.main_loop(w)


if __name__ == '__main__':
    sys.exit(main(sys.argv))
