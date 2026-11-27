#!/usr/bin/env python3
# Purpose: the engine-INDEPENDENT frame of `lctl watch` (stage 4, the W3.2
#   restyle per the approved dashboard-layout.md §1 layout — the primary
#   source 1:1): env inputs (LCTL_WATCH_PORT/INTERVAL/CONTAINER/ENGINE;
#   the battery seams LCTL_WATCH_TICKS and LCTL_WATCH_SELFCHECK),
#   glyphs/UTF-8 fallback, fmt* helpers (the "never «?»" invariant:
#   None → «—»; fmt_uptime/fmt_int_sep/fmt_pct «58.0 %» — §1/§2),
#   primary_ip (a UDP-connect route without packets — the header's external
#   address), put/status_bar_layout (the `lctl watch │ <engine> · <model>`
#   header), LogStreamer (podman logs -t, F1: the podman RFC3339 stamp →
#   HH:MM:SS at render, the engine stamp is cut off), the shared wire
#   primitives (parse_metrics, TZ conversion, Deltas, sparkline), the
#   shared v2 scheme: «Движок» (Uptime + a multi-line Configuration) and
#   «Метрики» (7 shared rows, METRICS_ROWS), «Железо» v2.1 (CPU first),
#   «Скорость» (the «Скорость» title, the pulse — in the docstring), «Логи»
#   (the title on the frame — D6), dir_size_bytes (a dir used-scan — the
#   adapter env seam), TUI (curses)/plain renders, the loop/interval/pause/
#   keys, dead-server degradation, selfcheck.
#
#   LAYOUT — grouping panels by the `.row` attribute (int; default 2):
#   row 1 — the shoulders (the adapter registers «Движок» before «Железо»),
#   row 2 — «Метрики» (MetricsPanel without .row — the default; the
#   mechanism is kept for future dialects), row 3 — «Скорость», the tail —
#   the «Логи» block. Within a row the order = the registration order.
#   No engine names in the frame (R6).
#
#   PANELS — duck-typed objects (registered by the adapter's ENGINE_WATCH_TUI
#   entry point):
#     .title — the block title (SpeedPanel — a property of the interval)
#     .row — the layout row (optional, default 2)
#     .rows(snap, **ctx) — TUI lines (label, value[, style])
#     .plain_lines(snap, ts, **ctx) — plain-stream lines
#   ENG — the engine data provider (the engine dialect is the adapter, R6):
#     .collect(snap) — mutates snap (stats/scheme/…)
#     .apply_tick(snap) — returns the tick's deltas dict (or None fields)
#     .route_conf(buf) — (route, conf) from the log buffer
#     .log_line_local(line) — TZ conversion of a log line
#   The boundary (task 3.1 §3 + W3): panel/data = everything that reads the
#   engine dialect (endpoints, log grammars); the frame = render, the
#   machine (sysfs/proc — watch_hw) and the wire formats (prometheus/TZ/
#   podman-RFC3339 — not dialect; the frame's timestamp points are allowed
#   by the W3.2 contract).
#
#   SCHEME v2 — the full provider contract (everything None-safe, the keys
#   are read by name by the panels): uptime_sec, spec_conf, slots,
#   ctx_tokens, kv_mode, cache_ram, cache_disk, device_lost, gen_avg,
#   gen_last, prefill_avg, prefill_last, cache_cached, cache_total,
#   cache_pct, spec_pct, tau, queue_depth, queue_capacity, ttft_s, ttft_win,
#   gen_total. The units — the layout §2 registry («—» = no counter or a 0
#   denominator; per-tick deltas — pulses only).
#
# Inputs — env ONLY (bash cmd_watch passes without argv): LCTL_WATCH_PORT
#   (the default is engine dialect, not core; the entry point setdefaults
#   it), LCTL_WATCH_INTERVAL (def 2; float; <0.05 — battery without
#   sleeps), LCTL_WATCH_CONTAINER (required for logs: no engine default in
#   the core — R6; empty = the streamer is silent, the «Логи» block prints
#   the diagnostics), LCTL_WATCH_ENGINE (the engine name for the header;
#   passed by the core, the frame does not interpret the value). MODEL is
#   not read by the frame (the model — from the log, the route_conf
#   provider). TUI keys: q/Q — exit rc 0; +/= / -/_ — interval ±1 s
#   (min 1); p — pause the live log.
#
# Side effects: every tick — eng.collect (the engine's HTTP via curl from
#   PATH — the battery's faux-bin seam) + /proc, /sys reads; TUI — the seed
#   `podman logs --tail 200 -t` + a daemon thread `podman logs --tail 1 -f
#   -t` (F1); draws in the alt-screen, exit leaves it (endwin). Touches no
#   files or the stack.
#
# Limitations/assumptions: stdlib only, 3.8+ syntax; HTTP — in the main
#   thread only; Unicode glyphs under a UTF-8 environment, ASCII fallback;
#   an initscr crash (TERM unknown) → a plain fallback, not a crash.
#
# @returns integer  # 0 — a normal exit (q / Ctrl-C / SIGTERM / ticks);
#   1 — the selfcheck failed
import calendar
import curses
import datetime
import locale
import os
import re
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
from collections import deque

import watch_hw

C_RED, C_GREEN, C_YELLOW = 1, 2, 3

FRAME_SPARK_UTF = '▁▂▃▄▅▆▇█'
FRAME_SPARK_ASCII = ' .:-=+*#'

# The v2 scheme (layout §1, names 1:1): row 1 «Движок» — FLAT rows (the
# «Конфигурация» subtitle and the indents are gone — ratified 2026-11-24);
# «Метрики» — a shared 7-row block for BOTH engines (the only differences
# are «—»; «Межслотовый кэш» removed — ratified, the counter lives in the
# engine). The «Статус» row removed (D4: the header bullet is the only
# indicator).
ENGINE_ROWS = ('Аптайм', 'Спекуляция', 'Контекст', 'KV-режим',
               'Кэш RAM', 'Кэш диск')  # Device lost — in the header (fix:w39)
METRICS_ROWS = ('Генерация', 'Prefill', 'Кэш', 'Спекуляция', 'Очередь',
                'TTFT', 'Сгенерировано')

# D5 (the bullet): the indent is exactly 1 column BEFORE the bullet (the
# W3.2.1 acceptance: "the indent before the bullet is not visible live" —
# the W3.2 constants encoded the gap AFTER the dot, column 0 had the dot
# flush against the edge; now the dot is in column 1, the header starts at
# column 3 — the gap after the dot is also 1).
DOT_X = 1
HEADER_X = 3


def env_float(name, default):
    # @returns float  # env or the default; a non-number → the default (no crash)
    try:
        return float(os.environ.get(name, '') or default)
    except ValueError:
        return default


def choose_utf8(encoding=None, term=None):
    # @returns bool  # True — Unicode glyphs and frames (non-UTF-8/empty/dumb TERM → ASCII)
    if encoding is None:
        encoding = locale.getpreferredencoding(False) or ''
    if 'UTF-8' not in encoding.upper().replace('_', '-'):
        return False
    if term is None:
        term = os.environ.get('TERM', '')
    return (term or '').strip() not in ('', 'dumb', 'posix')


class Glyphs:
    # @type bool utf8  # the Unicode set or the ASCII fallback
    def __init__(self, utf8):
        self.utf8 = utf8
        self.tl = '┌' if utf8 else '+'
        self.tr = '┐' if utf8 else '+'
        self.bl = '└' if utf8 else '+'
        self.br = '┘' if utf8 else '+'
        self.h = '─' if utf8 else '-'
        self.v = '│' if utf8 else '|'
        self.dot = '●' if utf8 else 'o'
        self.deg = '°C' if utf8 else 'C'
        self.bar_full = '█' if utf8 else '#'
        self.bar_empty = '░' if utf8 else '.'
        self.spark = FRAME_SPARK_UTF if utf8 else FRAME_SPARK_ASCII


def http_get(url, timeout=5.0):
    # @returns string   # the response body; a failure — an exception (the
    #   caller catches it). curl from PATH (not urllib): the battery's
    #   faux-bin seam — the call counter and the URL log are visible in
    #   FAUXLOG
    p = subprocess.run(['curl', '-fsS', '-m', '%.0f' % max(1, timeout), url],
                       stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    if p.returncode != 0:
        raise OSError('curl rc=%d' % p.returncode)
    return p.stdout.decode('utf-8', 'replace')


def fmt1(x):
    # @returns string  # 1 decimal; None → «—» (the W3 invariant: «?» does not exist)
    return '—' if x is None else '%.1f' % x


def fmti(x):
    # @returns string  # an integer; None → «—» (no key/sensor)
    return '—' if x is None else str(int(x))


def fmt_pct(x):
    # @returns string  # percents 1 decimal with " %" (a space before % —
    #   layout §1 1:1, R-5); None → «—»
    return '—' if x is None else '%.1f %%' % x


def fmt_int_sep(n):
    # @returns string  # an integer with thousands grouped by a space
    #   («262 144» — layout §1); None → «—»
    return '—' if n is None else '{:,}'.format(int(n)).replace(',', ' ')


def fmt_uptime(sec):
    # @returns string  # uptime per layout §1: «6 ч 12 мин» / «52 мин» /
    #   «<1 мин»; None → «—»
    if sec is None:
        return '—'
    s = max(0, int(sec))
    if s < 60:
        return '<1 мин'
    if s < 3600:
        return '%d мин' % (s // 60)
    return '%d ч %d мин' % (s // 3600, (s % 3600) // 60)


def fmt_gib(b):
    # @returns string  # bytes → GiB 1 decimal; None → «—»
    return '—' if b is None else fmt1(b / (1024.0 ** 3))


def fmt_tok(v):
    # @returns string  # a counter compactly: <1000 — an integer, → «99.1k», ≥1M → «1.2M»
    if v is None:
        return '—'
    if v >= 1_000_000:
        return '%.1fM' % (v / 1e6)
    if v >= 1000:
        return '%.1fk' % (v / 1000.0)
    return str(int(v))


def fmt_c(x):
    # @returns string  # °C 1 decimal; None → «—»
    return '—' if x is None else '%.1f' % x


def temp_color(deg, fmt=None):
    # @param 2: callable  # a printer (fmt_c/fmti) — the threshold is
    #   compared against the PRINTED value (79.95 prints «80.0» → yellow;
    #   gfctl 1:1); without fmt — against the raw number
    # @returns integer  # None→0; ≥90 → C_RED; 80…89.9 → C_YELLOW; else 0
    if deg is None:
        return 0
    if fmt is not None:
        deg = float(fmt(deg))
    if deg >= 90:
        return C_RED
    if deg >= 80:
        return C_YELLOW
    return 0


def mem_fill_color(avail, total):
    # @returns integer  # the RAM color by the ABSOLUTE available (the
    #   user's 2026-11-25 thresholds: <3 GiB → C_RED, <6 GiB → C_YELLOW
    #   [orange in the terminal palette]; the 10/20% share thresholds were
    #   removed — on 60/128 GiB machines they fired differently); no avail → 0
    if avail is None:
        return 0
    if avail < 3:
        return C_RED
    if avail < 6:
        return C_YELLOW
    return 0


def dead_line(ts, port):
    # @returns string  # exactly ONE dead-server line (plain, per tick);
    #   the text is neutral: the endpoint is engine (adapter) dialect, not
    #   the core's (R6)
    return '%s сервер недоступен (нет ответа на :%d); жду…' % (ts, port)


def log_clip(ln, width):
    # @returns string  # the line clipped to width chars (the log clip by
    #   the frame's inner width — the last line does not break the border);
    #   width ≤ 0 → '' (a degradation, not a crash)
    if width <= 0:
        return ''
    return ln[:width]


def log_lines_fit(rem):
    # @returns integer  # the log window height: the lines fitting INSIDE
    #   the bottom border (D3, the vertical clip — the last line does NOT
    #   touch the border: borders only = 2; D6: the title on the border —
    #   content -1, before D6 the inner title gave 3); rem<2 → 0 (no window)
    return max(0, rem - 2)


def primary_ip():
    # @returns string|None  # the host's primary IPv4 for the header
    #   (layout §1 `<engine> · <ext-ip>:<port> · <model>`): a UDP-connect
    #   to 1.1.1.1:80 — the route is determined WITHOUT sending packets (a
    #   udp connect only writes the addressing into the socket),
    #   getsockname() gives the local address chosen by the routing table;
    #   loopback is physically excluded — a route to an external address
    #   never goes via 127.0.0.1; an exception/no route (an isolated netns,
    #   offline) → None (the address segment is omitted from the header, no
    #   crash). A machine class (as watch_hw) — knows no engine names (R6);
    #   the address is computed once per session (Watch.__init__), not
    #   every tick
    s = None
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(('1.1.1.1', 80))
        return s.getsockname()[0]
    except OSError:
        return None
    finally:
        if s is not None:
            s.close()


def dir_size_bytes(path):
    # @param 1: string  # a dir path (an adapter env seam — which exact
    #   dir, the frame does not know: R6); an empty string → None at once
    # @returns int|None  # the sum of st_size of regular files RECURSIVELY
    #   (subdirs are per-build, ~1000 files is milliseconds — once per tick
    #   is acceptable); no dir/scan error → None («—», no crash); symlinks
    #   are not followed (is_dir/is_file follow_symlinks=False — cycles and
    #   foreign FS are excluded)
    if not path:
        return None
    try:
        total = 0
        with os.scandir(path) as it:
            for e in it:
                if e.is_dir(follow_symlinks=False):
                    sub = dir_size_bytes(e.path)
                    if sub is None:
                        return None
                    total += sub
                elif e.is_file(follow_symlinks=False):
                    total += e.stat(follow_symlinks=False).st_size
        return total
    except OSError:
        return None


def put(win, y, x, s, attr=0):
    # addstr at a window point; clipped at the edge, beyond — silently (a
    # degradation, not a trace — the gfctl frame)
    h, w = win.getmaxyx()
    if y < 0 or y >= h or x >= w or not s:
        return
    if x < 0:
        s = s[-x:]
        x = 0
    if x + len(s) > w:
        s = s[:w - x]
    if not s:
        return
    try:
        win.addstr(y, x, s, attr)
    except (curses.error, UnicodeEncodeError, ValueError):
        pass


def status_bar_layout(W, interval, engine, model, paused, addr='', lost=None):
    # (left, mid, right, x_mid, x_right, draw_mid, draw_right); the header
    # `lctl watch │ <engine> · <addr> · <model>` (layout §1 header, W3.2.2:
    # addr = `<ext-ip>:<port>` — primary_ip + LCTL_WATCH_PORT; the engine
    # name — from the core's env; the model truncated as before — a
    # left→mid gap ≥1 column; an empty addr (no route) → the segment is
    # dropped entirely (no ` · —`): `lctl watch │ <engine> · <model>`; a
    # narrow window → addr yields (the model is not clipped to empty — a
    # hanging ` · ` is worse); an empty engine → `lctl watch │ <model>`,
    # an empty model → '-')
    prefix = 'lctl watch │ '
    if engine:
        prefix += engine + ' · '
    mid = 'интервал %g c' % interval
    right = ('логи: live, пауза: p │ q — выход' if not paused
             else 'логи: пауза, live: p │ q — выход')
    right_x = max(0, W - len(right) - 1)
    mid_x = max(0, min(W // 2 - len(mid) // 2, right_x - len(mid) - 1))
    # addr is shown only if the model after it keeps ≥1 column
    if addr and mid_x - len(prefix) - len(addr) - 6 >= 1:
        prefix += addr + ' · '
    # device lost — a header segment (fix:w39, the 2026-11-25 debt: the
    # panel row is gone; the segment only for engines with a source — an
    # adapter without the counter passes None and loses it); a narrow
    # window → yields after addr
    lost_s = ('lost %s' % fmti(lost)) if lost is not None else ''
    if lost_s and mid_x - len(prefix) - len(lost_s) - 6 >= 1:
        prefix += lost_s + ' · '
    model_w = mid_x - len(prefix) - 3
    left = prefix + (model or '-')[:max(0, model_w)]
    draw_mid = mid_x > 2 + len(left)
    draw_right = right_x > 2 + len(left)
    return left, mid, right, mid_x, right_x, draw_mid, draw_right


class LogStreamer(threading.Thread):
    """Engine logs: the seed `podman logs --tail 200 -t` (seed(),
    synchronously in the main thread BEFORE the first frame), then live
    `podman logs --tail 1 -f -t` (the dedup of the first live line against
    the seed tail — the line is equal TOGETHER with the stamp, F1/R-4). The
    podman stamp (RFC3339, UTC/offset) is converted to HH:MM:SS AT RENDER
    (log_line_local). stdout line by line → deque(500). podman logs prints
    logs to STDERR (verified live) — BOTH calls merge stderr into the
    stdout PIPE. The thread does NOT touch curses or HTTP. No podman /
    container → the seed and the stream fail silently (the buffer is
    empty), retries ~once per second. stop() terminates the subprocess.
    The seed window 200 (W3.2.1-D1, the live arbitration): boot lines
    (the load summary etc.) rotate out under startup spam — at tail 50 the
    summary was already gone (0 hits), at 200 — present; 200 is enough,
    deeper — only a full log scan."""

    def __init__(self, container):
        super().__init__(daemon=True)
        self.container = container
        self.buf = deque(maxlen=500)
        self._proc = None
        self._stopped = False
        self._last_try = 0.0
        self._seed_tail = None

    def seed(self):
        # @returns None  # no podman/timeout/rc≠0 — silently (the buffer
        #   empty); an empty container (env unset) — silently: an engine
        #   default in the core is forbidden (R6), the «Логи» block prints
        #   the diagnostics
        if not self.container:
            return
        try:
            proc = subprocess.run(
                ['podman', 'logs', '--tail', '200', '-t', self.container],
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                text=True, errors='replace', timeout=10)
        except (FileNotFoundError, OSError, subprocess.TimeoutExpired):
            return
        if proc.returncode == 0:
            lines = proc.stdout.splitlines()
            self.buf.extend(lines)
            self._seed_tail = lines[-1] if lines else None

    def _spawn_once(self):
        if not self.container:
            return
        now = time.monotonic()
        if now - self._last_try < 1.0:
            return
        self._last_try = now
        try:
            proc = subprocess.Popen(
                ['podman', 'logs', '--tail', '1', '-f', '-t', self.container],
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                text=True, errors='replace')
        except (FileNotFoundError, OSError):
            return
        self._proc = proc
        for line in proc.stdout:
            line = line.rstrip('\n')
            if self._seed_tail is not None and line == self._seed_tail:
                self._seed_tail = None
                continue  # the dedup: live re-emits the seed tail once
            self._seed_tail = None
            self.buf.append(line)
        self._proc = None

    def stop(self):
        self._stopped = True
        p = self._proc
        if p is not None and p.poll() is None:
            try:
                p.terminate()
            except OSError:
                pass

    def run(self):
        try:
            while not self._stopped:
                self._spawn_once()
                if not self._stopped:
                    time.sleep(1)
        finally:
            self.stop()


# ── shared wire formats (not dialect): the prometheus text and the log TZ stamp ─

def parse_metrics(text):
    # @param 1: string  # the GET /metrics body (a prometheus text)
    # @returns dict     # name → float; '# …' and *_bucket{…} dropped,
    #   labels {…} stripped from the name (keys with ':' go as is) — 1:1 v1
    out = {}
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith('#'):
            continue
        parts = line.split()
        if len(parts) < 2:
            continue
        name = parts[0]
        if '{' in name:
            name = name.split('{', 1)[0]
        if name.endswith('_bucket'):
            continue
        try:
            out[name] = float(parts[1])
        except ValueError:
            continue
    return out


TS_RE = re.compile(r'(\d{4})-(\d{2})-(\d{2})[ T](\d{2}):(\d{2}):(\d{2})')

# The `podman logs -t` stamp (F1): the line's RFC3339 prefix — UTC ('Z')
# or an offset ('+03:00'/'-0130'), fractional seconds optional (the W3.2
# §1 contract; group 7 — Z/offset)
PODMAN_TS_RE = re.compile(
    r'^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})'
    r'(?:\.\d+)?(Z|[+-]\d{2}:?\d{2})[ \t]')


def podman_ts_epoch(line):
    # @param 1: string  # a line with the `podman logs -t` podman prefix
    # @returns int|None  # the stamp's epoch UTC (the offset accounted);
    #   no prefix / a calendar-impossible date → None (time is NOT made up)
    m = PODMAN_TS_RE.match(line)
    if not m:
        return None
    y, mo, d, h, mi, s = (int(m.group(i)) for i in range(1, 7))
    try:
        datetime.datetime(y, mo, d, h, mi, s)
    except ValueError:
        return None
    ep = calendar.timegm((y, mo, d, h, mi, s, 0, 0, 0))
    off = m.group(7)
    if off != 'Z':
        sign = 1 if off[0] == '+' else -1
        digits = off[1:].replace(':', '')
        ep -= sign * (int(digits[:2]) * 3600 + int(digits[2:4]) * 60)
    return ep


def log_ts_utc_epoch(line):
    # @param 1: string  # an engine log line (the stamps are UTC, the
    #   container is not touched; the format: 'YYYY-MM-DD HH:MM:SS [LVL]')
    # @returns int|None  # the epoch UTC of the first TS_RE match; no stamp /
    #   calendar-impossible → None (time is NOT made up)
    m = TS_RE.search(line)
    if not m:
        return None
    y, mo, d, h, mi, s = (int(m.group(i)) for i in range(1, 7))
    try:
        datetime.datetime(y, mo, d, h, mi, s)
    except ValueError:
        return None
    return calendar.timegm((y, mo, d, h, mi, s, 0, 0, 0))


def log_line_local(line):
    # @returns string  # the TZ conversion for the render (the buffer
    #   keeps RAW lines — the conversion at render). The F1 priority: a
    #   podman-RFC3339 prefix → 'HH:MM:SS' by the PODMAN stamp, the inner
    #   engine stamp right after the prefix is CUT OFF (otherwise two
    #   stamps in a line); the fallback — the former engine-stamp
    #   conversion (lines without -t); no stamps → the line as is
    m = PODMAN_TS_RE.match(line)
    if m:
        ep = podman_ts_epoch(line)
        rest = line[m.end():]
        m2 = TS_RE.match(rest)
        if m2:
            rest = rest[m2.end():]
        if ep is None:
            return rest
        if rest[:1] not in ('', ' ', '\t'):
            rest = ' ' + rest  # there was no engine stamp — one separator
        return time.strftime('%H:%M:%S', time.localtime(ep)) + rest
    epoch = log_ts_utc_epoch(line)
    if epoch is None:
        return line
    m = TS_RE.search(line)
    return time.strftime('%H:%M:%S', time.localtime(epoch)) + line[m.end():]


def sparkline(values, width, glyphs=FRAME_SPARK_UTF):
    # @param 1: iterable  # the value history (None — a skip, the tick is
    #   not added)
    # @param 2: integer   # the width in chars (the last width values)
    # @param 3: string    # 8 glyph steps (the last — max)
    # @returns string     # autoscale to the row max (≥1); an empty row → ''
    vals = [v for v in values if v is not None]
    if not vals or width < 1:
        return ''
    mx = max(vals)
    if mx < 1:
        mx = 1.0
    tail = vals[-width:]
    return ''.join(glyphs[min(7, int(v / mx * 7.999))] for v in tail)


class Deltas:
    """Per-TICK counter deltas — a pulse (NOT a speed). The map
    `{pulse: counter-name}` is adapter dialect (the frame knows no names):
    update(None) — a reset (a dead tick), a negative Δ (a recreate/counter
    reset) → None for the tick, the base is updated anyway; after the
    raise there are no false deltas. The values — Δ TOKENS/CYCLES per
    tick, not per time unit (the pulse units — the layout §2 registry:
    decode/prefill — «ток/тик», drafts — «цикл/тик»)."""

    def __init__(self, keys):
        # @param 1: dict  # {'decode': K, 'prefill': K, 'drafts': K, …}
        self.keys = dict(keys)
        self.prev = None

    def reset(self):
        self.prev = None

    def update(self, m):
        # @param 1: dict|None  # the tick's metrics (None — a read failure)
        # @returns dict   # {pulse: Δ|None} by the key map
        out = dict.fromkeys(self.keys)
        if m is None:
            self.prev = None
            return out
        if self.prev is not None:
            for key, cnt in self.keys.items():
                cur = m.get(cnt)
                prev = self.prev.get(cnt)
                if cur is not None and prev is not None:
                    d = int(cur - prev)
                    out[key] = d if d >= 0 else None
        self.prev = m
        return out


class SessionBase:
    """The panel's active session window (W3.3, amendment A1): the base =
    the dict of the FIRST live /metrics tick; deltas(m) → {key: cur − base}
    over all snapshot keys (None before the base — "the session window is
    empty", the seed branch (a)); a negative Δ anywhere (a recreate/counter
    reset) → reset + None for the tick, after the raise the base is
    re-pinned — no false deltas (the Deltas discipline). An idle denominator
    is not diluted: session deltas move only with new done — the hold
    semantics of W3.2.2/3/4 lives on the v2 definitions. A tick with
    m=None (an /metrics failure) KEEPS the base (we hold it; reset only on
    a recreate/negative Δ). The key names are adapter dialect, the frame
    does not know them (R6)."""

    def __init__(self):
        self._base = None

    def reset(self):
        # a recreate/dead tick — the base is reset → «—» until re-pinned
        self._base = None

    def deltas(self, m):
        # @param 1: dict|None  # the tick's metrics (None — a read failure)
        # @returns dict|None  # {key: Δ against the session base}; None
        #   before the base or on a reset tick (a negative Δ anywhere)
        if not m:
            return None
        if self._base is None:
            self._base = dict(m)  # fix:w33-session-base — база = первый живой /metrics
            return None
        out = {}
        neg = False
        for k, b in self._base.items():
            cur = m.get(k)
            out[k] = None if cur is None else cur - b
            if out[k] is not None and out[k] < 0:
                neg = True
        if neg:
            self.reset()
            return None
        return out


class Hold:
    """The Hold carrier of freezes (W3.3; the consolidation of the W3.2.2/3/4
    local caches — "melting" does not come back): take(v, work) accepts v
    only on a tick with work (the gate: the Δcount/Δseconds>0 family — the
    adapter computes it); a None value is NOT accepted (a fail tick does
    not spoil the cache); always returns the held value (None = «—» — no
    work since the session start). reset() — a recreate."""

    def __init__(self):
        self._v = None

    def reset(self):
        self._v = None

    def take(self, v, work):
        # @param 1: value|None  # the tick's fresh value (None — no data)
        # @param 2: bool  # the tick's work gate
        # @returns value|None  # the held value (the last shown one)
        if work and v is not None:
            self._v = v
        return self._v  # fix:w33-hold


# ── frame panels: «Движок» (the shared v2 scheme), «Метрики», «Железо», «Скорость» ─

def _scheme_str(s, key):
    # @returns string  # an adapter string from the scheme; empty/missing → «—»
    v = (s or {}).get(key)
    return v if v else '—'


class CommonEnginePanel:
    # Row 1 «Движок» v2 (layout §1): Uptime + a multi-line Configuration
    # (flat rows §1; Device lost — conditional, only with a source). The
    # values — from snap['scheme'] (a dict filled by the adapter's ENG
    # provider; missing/incomplete → «—» in its place — the "never «?»"
    # invariant). The Status row removed (D4). Device lost >0 — red.
    row = 1
    title = 'Движок'

    def bind(self, glyphs):
        self._glyphs = glyphs

    @staticmethod
    def config_rows(s):
        # @returns list[(label, value, style)]  # the flat rows after
        #   Uptime (the labels = ENGINE_ROWS[1:]; Device lost — in the
        #   header since fix:w39, no row here anymore)
        ctx = s.get('ctx_tokens')
        return [
            ('Спекуляция', _scheme_str(s, 'spec_conf'), 0),
            # «N × M ток [(лента K)]» (layout §1 4e4e0c4): N — the REAL
            #     parallelism (multi-slot — the slots; standard — 1,
            #     mod.rs:1991), K = serve.multi_slot_slots on standard
            #     (the admission queue capacity; the adapter provides
            #     ctx_tape — the user's finding: «4 ×» on serial read as
            #     4-way parallelism, 2026-11-24)
            ('Контекст', ('%s × %s ток%s'
                          % (fmti(s.get('slots')), fmt_int_sep(ctx),
                             (' (лента %s)' % fmti(s['ctx_tape']))
                             if s.get('ctx_tape') else ''))
             if ctx is not None and s.get('slots') is not None else '—', 0),
            ('KV-режим', _scheme_str(s, 'kv_mode'), 0),
            ('Кэш RAM', _scheme_str(s, 'cache_ram'), 0),
            ('Кэш диск', _scheme_str(s, 'cache_disk'), 0),
        ]
        # Device lost — moved to the header (fix:w39, the 2026-11-25
        # debt: a status_bar_layout segment, only engines with a source)

    def rows(self, snap, **_):
        if not snap['engine_ok']:
            return [('недоступен', '')]
        s = snap.get('scheme') or {}
        return ([('Аптайм', fmt_uptime(s.get('uptime_sec')), 0)] +
                self.config_rows(s))

    def plain_lines(self, snap, ts, **_):
        if not snap['engine_ok']:
            return []
        s = snap.get('scheme') or {}
        ctx = s.get('ctx_tokens')
        ctx_s = (('%s × %s ток%s'
                  % (fmti(s.get('slots')), fmt_int_sep(ctx),
                     (' (лента %s)' % fmti(s['ctx_tape']))
                     if s.get('ctx_tape') else ''))
                 if ctx is not None and s.get('slots') is not None else '—')
        line = ('%s [движок] аптайм %s | спек %s | ctx %s | kv %s'
                ' | кэш-ram %s | кэш-диск %s'
                % (ts, fmt_uptime(s.get('uptime_sec')),
                   _scheme_str(s, 'spec_conf'), ctx_s,
                   _scheme_str(s, 'kv_mode'), _scheme_str(s, 'cache_ram'),
                   _scheme_str(s, 'cache_disk')))
        if s.get('device_lost') is not None:      # адаптер с источником
            line += ' | lost %s' % fmti(s['device_lost'])
        return [line]


class MetricsPanel:
    # «Метрики» v2 (layout §1): a SHARED 7-row block for both engines
    # (METRICS_ROWS, names/order 1:1; the differences — only «—»). No .row
    # attribute — the frame default = row 2. Спекуляция — A_BOLD.
    title = 'Метрики'

    def bind(self, glyphs):
        self._glyphs = glyphs

    @staticmethod
    def values(s):
        # @returns dict  # label → the ready value string (the shared
        #   source of rows/plain — the §1 formats in one place)
        cc, ct, cp = s.get('cache_cached'), s.get('cache_total'), \
            s.get('cache_pct')
        cache = ('%s из %s ток из кэша (%s)'
                 % (fmt_tok(cc), fmt_tok(ct), fmt_pct(cp))) \
            if cc is not None and ct is not None and cp is not None else '—'
        qd, qc = s.get('queue_depth'), s.get('queue_capacity')
        if qd is None:
            queue = '—'
        elif qc is None:
            queue = '%s запросов' % fmti(qd)
        else:
            queue = '%s из %s запросов' % (fmti(qd), fmti(qc))
        ttft = s.get('ttft_s')
        ttft_w = s.get('ttft_win')  # W3.3 c1+c2: the dual «container · session»
        if ttft is None and ttft_w is None:
            ttft_str = '—'
        else:
            ttft_str = '%s (средн) · %s (окно)' % (
                ('%.2f с' % ttft) if ttft is not None else '—',
                ('%.2f с' % ttft_w) if ttft_w is not None else '—')
        gt = s.get('gen_total')
        it = s.get('in_total')
        gen_row = ('%s ток' % fmt_tok(gt)) if gt is not None else '—'
        if it is not None:      # «принято» — an adapter with a source (without — the base row)
            gen_row += ' · принято %s' % fmt_tok(it)
        return {
            'Генерация': '%s (средн) · %s (посл) tok/s'
                         % (fmt1(s.get('gen_avg')), fmt1(s.get('gen_last'))),
            'Prefill': '%s (средн) · %s (посл) tok/s'
                       % (fmt1(s.get('prefill_avg')),
                          fmt1(s.get('prefill_last'))),
            'Кэш': cache,
            'Спекуляция': 'принято %s · τ %s ток/цикл'
                          % (fmt_pct(s.get('spec_pct')), fmt1(s.get('tau'))),
            'Очередь': queue,
            'TTFT': ttft_str,
            'Сгенерировано': gen_row,
        }

    def rows(self, snap, **_):
        if not snap['engine_ok']:
            return [('недоступен', '')]
        v = self.values(snap.get('scheme') or {})
        out = [(label, v[label]) for label in METRICS_ROWS]
        out[3] = (out[3][0], out[3][1], curses.A_BOLD)  # Спекуляция
        return out

    def plain_lines(self, snap, ts, **_):
        if not snap['engine_ok']:
            return []
        v = self.values(snap.get('scheme') or {})
        return ['%s [метрики] ген %s | prefill %s | кэш %s | спек %s | оч %s'
                ' | ttft %s | сген %s'
                % (ts, v['Генерация'], v['Prefill'], v['Кэш'],
                   v['Спекуляция'], v['Очередь'],
                   v['TTFT'], v['Сгенерировано'])]


class HwPanel:
    # The «Железо» block v2.1 (W3 + the W3.2.1 acceptance: the CPU temp
    # as the FIRST line — layout §1): CPU temp + GPU temp/freq/load/power +
    # RAM (moved from «Память», a bar colored by fill). The VRAM/GTT rows
    # removed, Device lost removed (that is an engine metric — in the
    # «Движок» Configuration), no-data → «—»
    row = 1
    title = 'Железо'

    def bind(self, glyphs):
        self._glyphs = glyphs

    def rows(self, snap, **_):
        g = self._glyphs
        cpu = snap['cpu_t']
        rows = [('CPU temp',
                 (fmt_c(cpu) + g.deg) if cpu is not None else '—',
                 temp_color(cpu, fmt_c))]
        gpu = snap['gpu']
        if gpu is None:
            rows.append(('GPU', 'карта AMD (0x1002) не найдена'))
        else:
            rows += [('GPU temp', fmt_c(gpu['temp_c']) + g.deg,
                      temp_color(gpu['temp_c'], fmt_c)),
                     ('GPU freq', fmti(gpu['sclk_mhz']) + ' MHz'),
                     ('GPU load', fmti(gpu['busy_pct']) + '%'),
                     ('GPU power', fmti(gpu['power_w']) + ' W')]
        mem = snap['mem']
        avail, total = mem.get('available_gib'), mem.get('total_gib')
        width = 10
        if avail is None or total is None:
            rows.append(('RAM', '—', 0))
        else:
            n = max(0, min(width, int(round(avail / total * width))))
            rows.append(('RAM', '%s%s %s/%s GiB'
                         % (g.bar_full * n, g.bar_empty * (width - n),
                            fmt1(avail), fmt1(total)),
                         mem_fill_color(avail, total)))
        return rows

    def plain_lines(self, snap, ts, **_):
        g = self._glyphs
        cpu = snap['cpu_t']
        cpu_part = ('CPU %s%s' % (fmt_c(cpu), g.deg)) if cpu is not None \
            else 'CPU —'
        gpu = snap['gpu']
        if gpu is None:
            gpu_part = 'GPU: карта AMD (0x1002) не найдена'
        else:
            gpu_part = ('GPU %s%s %sMHz %sW %s%%'
                        % (fmt_c(gpu['temp_c']), g.deg, fmti(gpu['sclk_mhz']),
                           fmti(gpu['power_w']), fmti(gpu['busy_pct'])))
        mem = snap['mem']
        avail, total = mem.get('available_gib'), mem.get('total_gib')
        if avail is None or total is None:
            ram_part = 'RAM —'
        else:
            width = 10
            n = max(0, min(width, int(round(avail / total * width))))
            ram_part = ('RAM %s%s %s/%s GiB'
                        % (g.bar_full * n, g.bar_empty * (width - n),
                           fmt1(avail), fmt1(total)))
        return ['%s [железо] %s | %s | %s' % (ts, cpu_part, gpu_part,
                                              ram_part)]


class SpeedPanel:
    # «Скорость» (row 3; the W3.2.1 acceptance: the name without a pulse —
    # the methodology in the docstring): a sparkline of the PULSE over the
    # history (hist — the eng provider's, via ctx). The pulse — a per-TICK
    # delta, not a speed: decode/prefill — ток/тик, drafts — цикл/тик
    # (layout §2); a tick = the poll interval (the +/− keys change it,
    # default 2 s); empty = a tick without completions
    row = 3
    title = 'Скорость'

    def bind(self, glyphs):
        self._glyphs = glyphs

    def rows(self, snap, hist=None, W=None, **_):
        width = max(4, (W or 80) // 2 - 18)
        h = hist or {}
        return [('decode', sparkline(h.get('decode', []), width,
                                     self._glyphs.spark)),
                ('prefill', sparkline(h.get('prefill', []), width,
                                      self._glyphs.spark)),
                ('drafts', sparkline(h.get('drafts', []), width,
                                     self._glyphs.spark))]

    def plain_lines(self, snap, ts, deltas=None, **_):
        d = deltas or {}
        # the pulse units — adapter dialect (scheme.pulse_units; the frame
        #     knows no engine names): None → the §2 default (drafts — the
        #     verification-round cycles)
        pu = (snap.get('scheme') or {}).get('pulse_units') or \
            ('ток/тик', 'ток/тик', 'цикл/тик')
        return ['%s [скорость] decode +%s · prefill +%s (%s)'
                ' · drafts +%s (%s)'
                % (ts, d.get('decode') or 0, d.get('prefill') or 0, pu[1],
                   d.get('drafts') or 0, pu[2])]


class Watch:
    """State + loop. TUI and plain share one collector (collect) and one
    tick processing (apply_tick); they differ in the render and the print
    period. Route/conf are recomputed from the log buffer every tick
    (after a recreate the seed/live brings new lines — it updates by
    itself); the route_conf warm-up after the seed — the provider gets to
    assemble the scheme BEFORE the first collect."""

    def __init__(self, panels, eng):
        self.port = int(env_float('LCTL_WATCH_PORT', 8080))
        self.interval = env_float('LCTL_WATCH_INTERVAL', 2.0)
        # The container default belongs to the adapter (R6: no engine
        # names in the core): empty = the engine logs unavailable — the
        # streamer is silent, the «Логи» block prints a diagnostic line
        # (not a crash)
        self.container = os.environ.get('LCTL_WATCH_CONTAINER', '')
        self.engine = os.environ.get('LCTL_WATCH_ENGINE', '')  # core → header
        # the header's external address (W3.2.2): the battery seam
        # LCTL_WATCH_IP set → take it without a socket call; live —
        # primary_ip() once per session (a route to 1.1.1.1 without
        # packets); none → None → the segment is dropped
        self.watch_ip = os.environ.get('LCTL_WATCH_IP', '') or primary_ip()
        self.max_ticks = int(env_float('LCTL_WATCH_TICKS', 0))  # the battery seam
        self.ticks = 0
        self.utf8 = choose_utf8()
        self.glyphs = Glyphs(self.utf8)
        for p in panels:
            p.bind(self.glyphs)
        self.panels = panels
        self.eng = eng
        self.colors = False
        self.streamer = LogStreamer(self.container)
        self.last_deltas = {}
        self.log_view = []
        self.paused = False
        self.stop = False
        self.signum = None

    def collect(self):
        # @returns dict  # the tick's snapshot: the frame's host fields
        #   every tick regardless of the server; the engine ones —
        #   eng.collect (None-safe)
        snap = {'engine_ok': False, 'stats': None, 'ready': False,
                'gpu': watch_hw.read_gpu(),
                'cpu_t': watch_hw.read_cpu_temp(),
                'mem': watch_hw.read_mem()}
        try:
            self.eng.collect(snap)
            snap['engine_ok'] = bool(snap.get('stats'))
        except Exception:
            pass  # a dead server — None, not a crash
        return snap

    def apply_tick(self, snap):
        # The tick deltas — eng.apply_tick; a failed tick — a reset by the
        # engine side (no false deltas after a recreate)
        self.last_deltas = self.eng.apply_tick(snap)

    def route_conf(self):
        # @returns (dict, dict)  # route + conf from the log buffer
        return self.eng.route_conf(list(self.streamer.buf))

    def refresh_log_view(self):
        # the TZ conversion AT RENDER (the frame): the buffer keeps raw lines
        self.log_view = [log_line_local(l) for l in self.streamer.buf]

    def tick_done(self):
        self.ticks += 1
        if self.max_ticks and self.ticks >= self.max_ticks:
            self.stop = True

    def sleep_quanta(self, secs, checker=None):
        # A sleep in 0.1 s quanta with stop/key checks; an interval <0.05
        # (battery, direct env only) — no sleep
        if secs < 0.05:
            return
        end = time.monotonic() + secs
        while not self.stop and time.monotonic() < end:
            if checker is not None:
                checker()
                if self.stop:
                    return
            time.sleep(min(0.1, max(0.0, end - time.monotonic())))

    def set_interval(self, v):
        self.interval = max(1.0, float(v))  # min 1 via the keys

    def run_plain(self):
        # Lines UNCONDITIONALLY once per interval (the first at once). A
        # dead server: EXACTLY one «недоступен» line per tick, no spam; no
        # full snapshot is printed while unavailable. «Логи» — the tail (1
        # line, TZ-converted) in the same block.
        self.streamer.seed()
        self.streamer.start()  # the live log: without it gen-last = a frozen seed in all no-tty runs (EXP-016 v3, 2026-11-24)
        self.route_conf()  # a warm-up: the provider's scheme is ready for the first tick
        while not self.stop:
            snap = self.collect()
            self.apply_tick(snap)
            self.refresh_log_view()
            ts = time.strftime('%H:%M:%S')
            if snap['engine_ok']:
                route, conf = self.route_conf()
                for p in self.panels:
                    for line in p.plain_lines(snap, ts, route=route,
                                              conf=conf, deltas=self.last_deltas):
                        print(line, flush=True)
                if self.log_view:
                    print('%s [логи] %s' % (ts, self.log_view[-1]), flush=True)
            else:
                print(dead_line(ts, self.port), flush=True)
            self.tick_done()
            self.sleep_quanta(self.interval)

    # ── TUI ─────────────────────────────────────────────────────────────────
    def run_tui(self, win):
        win.nodelay(True)
        win.keypad(True)
        try:
            curses.noecho()
            curses.cbreak()
            win.clear()
            curses.curs_set(0)
        except curses.error:
            pass
        if curses.has_colors():
            try:
                curses.start_color()
                curses.use_default_colors()
                curses.init_pair(C_RED, curses.COLOR_RED, -1)
                curses.init_pair(C_GREEN, curses.COLOR_GREEN, -1)
                curses.init_pair(C_YELLOW, curses.COLOR_YELLOW, -1)
                self.colors = True
            except curses.error:
                pass
        self.streamer.seed()  # before the first frame — the start lines visible at once
        self.route_conf()     # a scheme warm-up (as in plain)
        self.streamer.start()
        try:
            while not self.stop:
                cur = self.interval
                self.drain_keys(win)
                if self.stop:
                    break
                snap = self.collect()
                self.apply_tick(snap)
                if not self.paused:
                    self.refresh_log_view()
                H, W = win.getmaxyx()
                self.draw(win, W, H, snap)
                win.refresh()
                self.sleep_quanta(cur, checker=lambda: self.drain_keys(win))
        finally:
            self.streamer.stop()
            curses.endwin()

    def handle_key(self, ch):
        if ch in (ord('q'), ord('Q')):
            self.stop = True
        elif ch in (ord('+'), ord('=')):
            self.set_interval(self.interval + 1)
        elif ch in (ord('-'), ord('_')):
            self.set_interval(self.interval - 1)
        elif ch == ord('p'):
            self.paused = not self.paused

    def drain_keys(self, win):
        while True:
            ch = win.getch()
            if ch == -1:
                return
            self.handle_key(ch)
            if self.stop:
                return

    def attr(self, style):
        # @returns integer  # a color code (C_RED/C_GREEN/C_YELLOW — ints
        #   1..3) → curses.color_pair (when self.colors); curses flags
        #   (A_BOLD ≥ 2**16, they did not collide with the color codes) →
        #   as is; 0 → 0
        if style in (C_RED, C_GREEN, C_YELLOW):
            return curses.color_pair(style) if self.colors else 0
        return style

    def box(self, win, x, y, w, h):
        g = self.glyphs
        if w < 3 or h < 2:
            return
        put(win, y, x, g.tl + g.h * (w - 2) + g.tr)
        put(win, y + h - 1, x, g.bl + g.h * (w - 2) + g.br)
        for i in range(1, h - 1):
            put(win, y + i, x, g.v)
            put(win, y + i, x + w - 1, g.v)

    def block(self, win, x, y, w, h, title, rows):
        # A frame with the title IN the top border; the lines (label,
        # value[, style]) — the ones that do not fit are dropped from the
        # TAIL (a narrow-screen degradation)
        self.box(win, x, y, w, h)
        if w >= len(title) + 6:
            put(win, y, x + 2, self.glyphs.h + ' %s ' % title, curses.A_BOLD)
        lw = max((len(label) + 1 for label, *_ in rows), default=0)
        for i, row in enumerate(rows):
            yy = y + 1 + i
            if yy >= y + h - 1:
                break
            label, value = row[0], row[1]
            style = row[2] if len(row) > 2 else 0
            put(win, yy, x + 2,
                (label + ':').ljust(lw) + ' ' + value[:max(0, w - lw - 4)],
                self.attr(style))

    def _ctx(self, snap, W):
        route, conf = self.route_conf()
        return {'route': route, 'conf': conf, 'deltas': self.last_deltas,
                'hist': getattr(self.eng, 'hist', None), 'W': W}, route, conf

    def draw(self, win, W, H, snap):
        win.erase()
        g = self.glyphs
        ctx, route, conf = self._ctx(snap, W)
        put(win, 0, DOT_X, g.dot,
            self.attr(C_GREEN if snap['engine_ok'] else C_RED))
        left, mid, right, mid_x, right_x, draw_mid, draw_right = \
            status_bar_layout(W, self.interval, self.engine,
                              route.get('model') or '-', self.paused,
                              addr=('%s:%d' % (self.watch_ip, self.port))
                              if self.watch_ip else '',
                              lost=(snap.get('scheme') or {}).get('device_lost'))
        put(win, 0, HEADER_X, left)
        if draw_mid:
            put(win, 0, mid_x, mid)
        if draw_right:
            put(win, 0, right_x, right)
        if H < 4 or W < 8:
            return
        # grouping the rows by .row (default 2 — «Метрики» does not set
        # the attribute); within a row — the registration order
        r1 = [p for p in self.panels if getattr(p, 'row', 2) == 1]
        r2 = [p for p in self.panels if getattr(p, 'row', 2) == 2]
        r3 = [p for p in self.panels if getattr(p, 'row', 2) == 3]
        rows1 = [p.rows(snap, **ctx) for p in r1]
        rows2 = [p.rows(snap, **ctx) for p in r2]
        rows3 = [p.rows(snap, **ctx) for p in r3]
        col_w = max(10, W // 2)
        h1 = (max(len(r) for r in rows1) + 2) if rows1 else 0
        h2 = (max(len(r) for r in rows2) + 2) if rows2 else 0
        h3 = (max(len(r) for r in rows3) + 2) if rows3 else 0
        LOG_MIN = 3
        budget = H - 1
        heights = [h1, h2, h3]
        rem = budget - h1 - h2 - h3
        for i in (2, 1, 0):  # on shortage we cut the rows BOTTOM-UP, the floor 3
            while rem < LOG_MIN and heights[i] > 3:
                heights[i] -= 1
                rem += 1
        y = 1
        if heights[0]:  # row 1: the shoulders («Движок» left, «Железо» right)
            self.block(win, 0, y, col_w, heights[0], r1[0].title, rows1[0])
            if len(r1) > 1 and W >= 2 * col_w:
                self.block(win, W - col_w, y, col_w, heights[0],
                           r1[1].title, rows1[1])
            y += heights[0]
        if heights[1]:  # row 2: specifics — 1 panel full width, 2 — columns
            if len(r2) == 1 or W < 2 * col_w:
                self.block(win, 0, y, W, heights[1], r2[0].title, rows2[0])
            else:
                self.block(win, 0, y, col_w, heights[1], r2[0].title, rows2[0])
                self.block(win, W - col_w, y, col_w, heights[1],
                           r2[1].title, rows2[1])
            y += heights[1]
        if heights[2]:  # row 3: «Скорость» full width
            self.block(win, 0, y, W, heights[2], r3[0].title, rows3[0])
            y += heights[2]
        rem = budget - (y - 1)
        self.box(win, 0, y, W, rem)
        # D6 (the W3.2.1 acceptance): the «Логи» title — ON the top
        #     border, the same way as block's (`─ Логи ─…`); the log lines
        #     start at the first inner line; the D3 clip, the height: the
        #     D6 content -1 (the title moved to the border — a rem−2
        #     window, no empty line)
        if W >= len('Логи') + 6:
            put(win, y, 2, g.h + ' Логи ', curses.A_BOLD)
        fit = log_lines_fit(rem)  # D3: the last line does NOT touch the border
        if self.log_view and fit > 0:
            for i, ln in enumerate(self.log_view[-fit:]):
                put(win, y + 1 + i, 2, log_clip(ln, W - 4))
        elif fit > 0:
            put(win, y + 1, 2, log_clip(
                '(LCTL_WATCH_CONTAINER не задан — логи движка недоступны)'
                if not self.container else '(ждём логи…)', W - 4))


def main_loop(w):
    # The frame's exit point: the signals → the TUI/plain fork (isatty +
    # TERM; an initscr crash → a plain fallback, not a crash)
    def on_signal(signum, frame):
        w.stop = True
        w.signum = signum

    signal.signal(signal.SIGINT, on_signal)
    signal.signal(signal.SIGTERM, on_signal)
    term = os.environ.get('TERM', '')
    if sys.stdout.isatty() and term:
        try:
            win = curses.initscr()
        except (curses.error, OSError):
            win = None
        if win is not None:
            w.run_tui(win)
            return 0
    try:
        w.run_plain()
    finally:
        w.streamer.stop()  # terminate the `podman logs -f` child (incl. on BrokenPipe at `| head`)
    if w.signum is not None:
        print('Выход Ctrl-C', flush=True)
    return 0


def selfcheck():
    # @returns integer  # 0 — everything passed; 1 — there are failures
    #   (the names in stderr). The frame part of the selfcheck:
    #   glyphs/colors/formatters (the «—» invariant,
    #   fmt_uptime/fmt_int_sep/fmt_pct «58.0 %»), the dead-line, the
    #   status-bar (incl. with an engine name), log_clip + log_lines_fit
    #   (D3), the D5 constants (the indent before the bullet),
    #   dir_size_bytes (a recursive used-scan), the v2 scheme of
    #   CommonEnginePanel/MetricsPanel (scheme → the §1 layout rows), the
    #   «Железо» (CPU first)/«Скорость» (the «Скорость» title) panels, the
    #   wire primitives (parse_metrics/Deltas/sparkline/TZ +
    #   podman-RFC3339), LogStreamer (no podman / a shim stderr→stdout /
    #   the args WITH -t in the seed and live, the dedup), watch_hw on fake
    #   trees. Engine names in the frame are forbidden (R6) — neutral
    #   engine-x/model-x. The engine part lives at the adapter's entry
    #   point (the aggregate).
    fails = []
    total = 0

    def ck(name, cond):
        nonlocal total
        total += 1
        if not cond:
            fails.append(name)

    # ── glyphs/UTF-8 ───────────────────────────────────────────────────────
    ck('glyphs utf8 (term явный — пин не зависит от ambient TERM)',
       choose_utf8('UTF-8', term='xterm') is True)
    ck('glyphs ascii encoding', choose_utf8('ANSI_X3.4-1968') is False)
    ck('glyphs term dumb', choose_utf8('UTF-8', term='dumb') is False)
    g = Glyphs(True)
    ck('glyphs набор', g.tl == '┌' and g.dot == '●' and g.spark == FRAME_SPARK_UTF)
    ga = Glyphs(False)
    ck('glyphs ascii-фолбэк', ga.tl == '+' and ga.dot == 'o' and ga.spark == FRAME_SPARK_ASCII)

    # ── colors (the DoD thresholds; against the PRINTED value) ─────────────
    ck('temp_color границы 79.9/80/89.9/90/None',
       temp_color(79.9) == 0 and temp_color(80) == C_YELLOW
       and temp_color(89.9) == C_YELLOW and temp_color(90) == C_RED
       and temp_color(None) == 0)
    ck('temp_color как печатается: 79.95→"80.0"→жёлтый, 89.96→"90.0"→красный',
       fmt_c(79.95) == '80.0' and temp_color(79.95, fmt_c) == C_YELLOW
       and fmt_c(89.96) == '90.0' and temp_color(89.96, fmt_c) == C_RED)
    ck('temp_color fmti: 79.96→"79"→0, 89.96→"89"→жёлтый, 90.0→красный',
       temp_color(79.96, fmti) == 0 and temp_color(89.96, fmti) == C_YELLOW
       and temp_color(90.0, fmti) == C_RED)
    ck('mem_fill_color: <3 ГиБ красный, <6 жёлтый, ≥6 нет цвета (пороги '
       'абсолютные — total не нужен), нет avail → 0',
       mem_fill_color(2.9, 100) == C_RED and mem_fill_color(3, 100) == C_YELLOW
       and mem_fill_color(5.9, 0) == C_YELLOW and mem_fill_color(6, 100) == 0
       and mem_fill_color(None, 100) == 0)

    # ── formatters: the "never «?»" invariant (layout §1/§2) ───────────────
    ck('fmt_tok границы + None→«—»', fmt_tok(999) == '999' and fmt_tok(1000) == '1.0k'
       and fmt_tok(1234567) == '1.2M' and fmt_tok(None) == '—')
    ck('fmt_gib None→«—»', fmt_gib(None) == '—' and fmt_gib(1073741824) == '1.0'
       and fmt_gib(10737418240) == '10.0')
    ck('fmt_pct пробел перед % (§1 1:1, R-5)', fmt_pct(None) == '—'
       and fmt_pct(58.0) == '58.0 %' and fmt_pct(60.0396) == '60.0 %')
    ck('fmt_int_sep: «262 144» / без разрядов / None→«—»',
       fmt_int_sep(None) == '—' and fmt_int_sep(262144) == '262 144'
       and fmt_int_sep(999) == '999' and fmt_int_sep(0) == '0'
       and fmt_int_sep(1000000) == '1 000 000')
    ck('fmt_uptime: «6 ч 12 мин»/«52 мин»/«<1 мин»/None→«—»',
       fmt_uptime(None) == '—' and fmt_uptime(59) == '<1 мин'
       and fmt_uptime(60) == '1 мин' and fmt_uptime(3138) == '52 мин'
       and fmt_uptime(3600) == '1 ч 0 мин' and fmt_uptime(22320) == '6 ч 12 мин')
    ck('fmti/fmt1/fmt_c None→«—»', fmti(None) == '—' and fmt1(None) == '—'
       and fmt_c(None) == '—')

    # ── dead-line + status-bar (incl. the engine name) ─────────────────────
    ck('plain dead line', 'недоступен' in dead_line('12:00:00', 8080)
       and dead_line('x', 1).count('недоступен') == 1)
    left, mid, right, mid_x, right_x, draw_mid, draw_right = status_bar_layout(
        80, 2, '', 'model-x-long-name', False)
    ck('status bar 80 cols gap≥1 (без движка)',
       left.startswith('lctl watch │ model-x') and draw_mid and draw_right
       and mid_x - 2 - len(left) >= 1 and right_x + len(right) <= 80)
    left, mid, right, mid_x, right_x, draw_mid, draw_right = status_bar_layout(
        80, 2, 'engine-x', 'model-x-very-long', False)
    ck('status bar 80 cols: движок в шапке + gap≥1',
       left.startswith('lctl watch │ engine-x · model-x') and draw_mid
       and draw_right and mid_x - 2 - len(left) >= 1)
    left, mid, right, mid_x, right_x, draw_mid, draw_right = status_bar_layout(
        100, 2, 'engine-x', 'model-x', False)
    ck('status bar 100 cols: `lctl watch │ engine-x · model-x` целиком',
       left == 'lctl watch │ engine-x · model-x' and draw_mid and draw_right
       and mid_x - 2 - len(left) >= 1)
    left, mid, right, mid_x, right_x, draw_mid, draw_right = status_bar_layout(
        140, 2, 'engine-x', 'model-x', False, addr='10.0.0.9:11435')
    ck('status bar: addr-сегмент `<engine> · <ip>:<порт> · <model>` целиком '
       '(лейаут §1 шапка, W3.2.2) + gap≥1',
       left == 'lctl watch │ engine-x · 10.0.0.9:11435 · model-x'
       and draw_mid and draw_right and mid_x - 2 - len(left) >= 1)
    left, *_ = status_bar_layout(100, 2, 'engine-x', 'model-x', False,
                                 addr='10.0.0.9:11435')
    ck('status bar: узкое окно — addr уступает, модель не режется в пустоту '
       '(без висячего ` · `)',
       left == 'lctl watch │ engine-x · model-x')
    left, *_ = status_bar_layout(80, 2, '', '', False)
    ck('status bar: пустые env → `lctl watch │ -`', left == 'lctl watch │ -')
    ck('primary_ip: None (нет маршрута — изолированный netns) или '
       'немаршрутный IPv4 (не 127.x); loopback исключён физически',
       primary_ip() is None
       or (primary_ip() and not primary_ip().startswith('127.')))

    # ── D5 (the bullet) + D3 (the vertical log clip) + dir_size_bytes ──────
    ck('D5: отступ 1 колонка ПЕРЕД буллетом (x=1), шапка x=3 — зазор 1 '
       '(константы каркаса; живой вид — скрин приёмки W3.2.1)',
       DOT_X == 1 and HEADER_X == 3)
    d_tmp = tempfile.mkdtemp(prefix='watch_w321_dir_')
    try:
        os.makedirs(d_tmp + '/sub')          # recursion: a per-build subdir
        os.makedirs(d_tmp + '/empty-dir')    # an empty dir → 0
        with open(d_tmp + '/a.bin', 'wb') as f:
            f.write(b'x' * 10)
        with open(d_tmp + '/b.bin', 'wb') as f:
            f.write(b'x' * 2000)
        with open(d_tmp + '/sub/c.bin', 'wb') as f:
            f.write(b'x' * 300)
        ck('dir_size_bytes: сумма st_size рекурсивно (10+2000+300)',
           dir_size_bytes(d_tmp) == 2310)
        ck('dir_size_bytes: пустой каталог → 0; нет пути/пустая строка → None',
           dir_size_bytes(d_tmp + '/empty-dir') == 0
           and dir_size_bytes(d_tmp + '/no-such-dir') is None
           and dir_size_bytes('') is None)
    finally:
        shutil.rmtree(d_tmp)
    ck('log_lines_fit (D3/D6): rem−2 (без пустой строки — заголовок на '
       'рамке), дно 0, границы 2/3',
       log_lines_fit(0) == 0 and log_lines_fit(2) == 0 and log_lines_fit(3) == 1
       and log_lines_fit(4) == 2 and log_lines_fit(11) == 9
       and log_lines_fit(-5) == 0
       and log_lines_fit(7) == 5)  # a full block: 5 = 7−2 — the last
       #   content line is the last inner one, no empty line
    ck('log_clip граница', log_clip('x' * 10, 4) == 'xxxx'
       and log_clip('abc', 10) == 'abc')
    ck('log_clip пустая/отрицательная', log_clip('', 8) == ''
       and log_clip('abc', 0) == '' and log_clip('abc', -3) == '')

    # ── sysfs (fake tempfile trees; the watch_hw seam) ─────────────────────
    fake = tempfile.mkdtemp(prefix='watch_w3_sys_')
    try:
        os.makedirs(fake + '/drm/card0/device/hwmon/hwmon0')
        os.makedirs(fake + '/drm/card0/device/hwmon/hwmon1')
        os.makedirs(fake + '/drm/card1/device/hwmon/hwmon0')
        os.makedirs(fake + '/drm/card1/device/hwmon/hwmon1')
        os.makedirs(fake + '/drm/card2/device')
        with open(fake + '/drm/card0/device/vendor', 'w') as f:
            f.write('0x10de\n')  # a non-AMD first card — the skip branch
        with open(fake + '/drm/card1/device/vendor', 'w') as f:
            f.write('0x1002\n')
        with open(fake + '/drm/card1/device/gpu_busy_percent', 'w') as f:
            f.write('3\n')
        with open(fake + '/drm/card1/device/hwmon/hwmon0/temp1_input', 'w') as f:
            f.write('35875\n')
        with open(fake + '/drm/card1/device/hwmon/hwmon1/temp1_input', 'w') as f:
            f.write('41000\n')  # the MAX over THIS card → 41.0
        with open(fake + '/drm/card1/device/hwmon/hwmon1/freq1_input', 'w') as f:
            f.write('600000000\n')
        with open(fake + '/drm/card1/device/hwmon/hwmon1/power1_input', 'w') as f:
            f.write('5453000\n')
        with open(fake + '/drm/card1/device/hwmon/hwmon1/mem_info_vram_used', 'w') as f:
            f.write('3435973837\n')
        gpu = watch_hw.read_gpu(fake + '/drm')
        ck('read_gpu: skip не-AMD, MAX temp по карте (не CPU!), поля',
           gpu is not None and gpu['temp_c'] == 41.0 and gpu['sclk_mhz'] == 600.0
           and abs(gpu['power_w'] - 5.453) < 1e-9 and gpu['busy_pct'] == 3.0
           and gpu['vram_used'] == 3435973837.0)
        with open(fake + '/drm/card2/device/vendor', 'w') as f:
            f.write('0x1002\n')
        ck('read_gpu: per-field None',
           watch_hw.read_gpu(fake + '/drm') is not None
           and watch_hw.read_gpu(fake + '/drm')['gtt_used'] is None)
        ck('read_gpu: нет AMD → None', watch_hw.read_gpu(fake) is None)
        os.makedirs(fake + '/hwmon2')
        with open(fake + '/hwmon2/name', 'w') as f:
            f.write('k10temp\n')
        with open(fake + '/hwmon2/temp1_input', 'w') as f:
            f.write('45500\n')
        ck('read_cpu_temp: Tctl k10temp 45.5', watch_hw.read_cpu_temp(fake) == 45.5)
        ck('read_cpu_temp: нет k10temp → None', watch_hw.read_cpu_temp(fake + '/drm') is None)
    finally:
        shutil.rmtree(fake)
    mem = watch_hw.read_mem()
    ck('read_mem хост: GiB > 0', mem['total_gib'] is not None and mem['total_gib'] > 0)

    # ── the «Железо» panel v2.1: rows + plain on a synthetic snapshot ──────
    snap = {'engine_ok': True, 'stats': None, 'ready': True,
            'gpu': {'temp_c': 54.0, 'sclk_mhz': 600.0, 'power_w': 5.45,
                    'busy_pct': 3.0, 'vram_used': 3435973836.8,
                    'gtt_used': 1181116006.4},
            'cpu_t': 45.0,
            'mem': {'available_gib': 45.2, 'total_gib': 60.4}}
    hp = HwPanel()
    hp.bind(Glyphs(True))
    ck('панель железо rows-лейблы v2.1 (CPU ПЕРВЫЙ + GPU×4 + RAM; '
       'VRAM/GTT/lost нет — лейаут §1 приёмка W3.2.1)',
       [x[0] for x in hp.rows(snap)] == ['CPU temp', 'GPU temp', 'GPU freq',
                                         'GPU load', 'GPU power', 'RAM'])
    ck('панель железо: GPU-температура жёлтая 80+ (печатаемое значение)',
       hp.rows(dict(snap, gpu=dict(snap['gpu'], temp_c=85.0)))[1][2] == C_YELLOW)
    ck('панель железо: RAM жёлтая при avail 3-5.9, красная <3, без цвета ≥6 '
       '(пороги абсолютные, fix:w41)',
       hp.rows(snap)[5][2] == 0 and 'GiB' in hp.rows(snap)[5][1]
       and hp.rows(dict(snap, mem={'available_gib': 3.0, 'total_gib': 60.4}))[5][2] == C_YELLOW
       and hp.rows(dict(snap, mem={'available_gib': 2.9, 'total_gib': 60.4}))[5][2] == C_RED
       and hp.rows(dict(snap, mem={'available_gib': 45.0, 'total_gib': 60.4}))[5][2] == 0)
    ck('панель железо: нет AMD-карты → CPU + заглушка + RAM',
       [x[0] for x in hp.rows(dict(snap, gpu=None))] == ['CPU temp', 'GPU',
                                                         'RAM'])
    ck('панель железо: RAM/CPU без данных → «—» (не «?»)',
       hp.rows(dict(snap, mem={}, cpu_t=None))[0][1] == '—'
       and hp.rows(dict(snap, mem={}, cpu_t=None))[5][1] == '—')
    ck('plain железо-строка v2.1 (CPU первой, RAM бар, без VRAM/GTT/lost)',
       hp.plain_lines(snap, '12:00:00')[0] ==
       '12:00:00 [железо] CPU 45.0°C'
       ' | GPU 54.0°C 600MHz 5W 3%'
       ' | RAM ███████░░░ 45.2/60.4 GiB')

    # ── the v2 «Движок» scheme: flat rows (layout §1, D4/D5 + 2026-11-24) ──
    cep = CommonEnginePanel()
    cep.bind(Glyphs(True))
    import curses
    ck('движок: мёртвый сервер — ровно «недоступен» (TUI), plain пуст',
       cep.rows({'engine_ok': False}) == [('недоступен', '')]
       and cep.plain_lines({'engine_ok': False}, '12:00:00') == [])
    rows_n = cep.rows({'engine_ok': True, 'scheme': None})
    ck('движок: лейблы == ENGINE_ROWS (плоские §1; Device lost — в шапке '
       'с fix:w39, ряда нет)',
       [x[0] for x in rows_n] == list(ENGINE_ROWS))
    ck('движок: scheme нет → все ряды «—», не краш',
       [x[1] for x in rows_n] == ['—', '—', '—', '—', '—', '—'])
    scheme_full = {'uptime_sec': 3138, 'spec_conf': 'mtp K=7', 'slots': 2,
                   'ctx_tokens': 262144, 'kv_mode': 'q8 (vmm)',
                   'cache_ram': '20.4 GiB (бюджет)', 'cache_disk': '',
                   'device_lost': 0}
    rows_f = cep.rows({'engine_ok': True, 'scheme': scheme_full})
    ck('движок: значения полного scheme (аптайм «52 мин», контекст '
       '«2 × 262 144 ток» — параллелизм × лента, layout §1; '
       '6 рядов — lost ушёл в шапку)',
       rows_f[0][1] == '52 мин' and rows_f[1][1] == 'mtp K=7'
       and rows_f[2][1] == '2 × 262 144 ток' and rows_f[3][1] == 'q8 (vmm)'
       and rows_f[4][1] == '20.4 GiB (бюджет)' and rows_f[5][1] == '—'
       and len(rows_f) == 6)
    left, mid, right, mid_x, right_x, draw_mid, draw_right = \
        status_bar_layout(120, 2, 'engine-x', 'model', False,
                          addr='1.2.3.4:11435', lost=0)
    ck('движок: lost в шапке (fix:w39) — сегмент после addr',
       'lost 0 · ' in left and left.index('lost') > left.index('1.2.3.4')
       and draw_mid)
    left, *_ = status_bar_layout(120, 2, 'engine-x', 'model', False,
                                 addr='1.2.3.4:11435')
    ck('движок: без источника lost — сегмента нет',
       'lost' not in left)
    ck('движок: plain-стрим полного scheme (пин формата §1)',
       cep.plain_lines({'engine_ok': True, 'scheme': scheme_full}, '12:00:00')[0] ==
       '12:00:00 [движок] аптайм 52 мин | спек mtp K=7'
       ' | ctx 2 × 262 144 ток | kv q8 (vmm)'
       ' | кэш-ram 20.4 GiB (бюджет) | кэш-диск — | lost 0')

    # ── the v2 «Метрики» scheme: 7 shared rows (layout §1) ─────────────────
    mp = MetricsPanel()
    mp.bind(Glyphs(True))
    ck('метрики: мёртвый сервер — ровно «недоступен» (TUI), plain пуст',
       mp.rows({'engine_ok': False}) == [('недоступен', '')]
       and mp.plain_lines({'engine_ok': False}, '12:00:00') == [])
    rows_mn = mp.rows({'engine_ok': True, 'scheme': None})
    ck('метрики: лейблы == константе METRICS_ROWS (7 рядов §1, без Статуса)',
       [x[0] for x in rows_mn] == list(METRICS_ROWS))
    ck('метрики: scheme нет → все ряды «—», не краш',
       [x[1] for x in rows_mn] == ['— (средн) · — (посл) tok/s',
                                   '— (средн) · — (посл) tok/s', '—',
                                   'принято — · τ — ток/цикл', '—', '—',
                                   '—'])
    scheme_m = {'uptime_sec': 3138, 'spec_conf': 'mtp K=7', 'slots': 2,
                'ctx_tokens': 262144, 'kv_mode': 'q8 (vmm)',
                'cache_ram': '', 'cache_disk': '', 'device_lost': None,
                'gen_avg': 1.6, 'gen_last': 24.6, 'prefill_avg': 1.0,
                'prefill_last': None, 'cache_cached': 9000.0,
                'cache_total': 12000.0, 'cache_pct': 75.0, 'spec_pct': None,
                'tau': 4.91, 'queue_depth': 0, 'queue_capacity': 4,
                'ttft_s': 0.24, 'ttft_win': None, 'gen_total': 5000.0}
    rows_m = mp.rows({'engine_ok': True, 'scheme': scheme_m})
    ck('метрики: значения полного scheme (форматы §1: ген «1.6 (средн) · 24.6 '
       '(посл) tok/s», кэш с абсолютами «9.0k из 12.0k … (75.0 %)», ttft dual '
       '«средн · — (окно)» — W3.3)',
       rows_m[0][1] == '1.6 (средн) · 24.6 (посл) tok/s'
       and rows_m[1][1] == '1.0 (средн) · — (посл) tok/s'
       and rows_m[2][1] == '9.0k из 12.0k ток из кэша (75.0 %)'
       and rows_m[3][1] == 'принято — · τ 4.9 ток/цикл'
       and rows_m[4][1] == '0 из 4 запросов'
       and rows_m[5][1] == '0.24 с (средн) · — (окно)'
       and rows_m[6][1] == '5.0k ток')
    ck('метрики: Сгенерировано — «принято N» хвост при in_total (fix:w39; '
       'адаптер с источником; базовый ряд без источника)',
       mp.values(dict(scheme_m, in_total=349862.0))['Сгенерировано']
       == '5.0k ток · принято 349.9k'
       and mp.values(scheme_m)['Сгенерировано'] == '5.0k ток')
    ck('метрики: Спекуляция — A_BOLD (принято % + τ ток/цикл)',
       rows_m[3][2] == curses.A_BOLD)
    ck('метрики: очередь depth без capacity → «D запросов» (ветка без ёмкости)',
       mp.values({'queue_depth': 0})['Очередь'] == '0 запросов')
    ck('метрики: только capacity без depth → «—» (нет числителя)',
       mp.values({'queue_capacity': 4})['Очередь'] == '—')
    ck('метрики: plain-стрим полного scheme (пин формата §1)',
       mp.plain_lines({'engine_ok': True, 'scheme': scheme_m}, '12:00:00')[0] ==
       '12:00:00 [метрики] ген 1.6 (средн) · 24.6 (посл) tok/s'
       ' | prefill 1.0 (средн) · — (посл) tok/s'
       ' | кэш 9.0k из 12.0k ток из кэша (75.0 %)'
       ' | спек принято — · τ 4.9 ток/цикл | оч 0 из 4 запросов'
       ' | ttft 0.24 с (средн) · — (окно)'
       ' | сген 5.0k ток')
    ck('метрики: рендер ratio-of-sums 30.0 (методика «средн за аптайм» §5 — '
       'адаптеры подают scheme, каркас печатает как есть)',
       mp.values({'gen_avg': 30.0, 'gen_last': None})['Генерация']
       == '30.0 (средн) · — (посл) tok/s')

    # ── the «Скорость» panel (row 3): the «Скорость» title + plain ─────────
    sp = SpeedPanel()
    sp.bind(Glyphs(True))
    ck('скорость: title ровно «Скорость» (приёмка W3.2.1: без пульса — '
       'методика в док-строке), set_interval-хука нет',
       sp.title == 'Скорость' and not hasattr(sp, 'set_interval'))
    ck('rows speed labels', [x[0] for x in sp.rows(
        {'engine_ok': True},
        hist={'decode': deque([0, 1, 2]), 'prefill': deque(), 'drafts': deque()},
        W=80)] == ['decode', 'prefill', 'drafts'])
    ck('plain скорость (пульс, НЕ скорость; drafts — цикл/тик §2)',
       sp.plain_lines({'engine_ok': True}, '12:00:00',
                      deltas={'decode': 12, 'prefill': 93, 'drafts': 7})[0] ==
       '12:00:00 [скорость] decode +12 · prefill +93 (ток/тик)'
       ' · drafts +7 (цикл/тик)')

    # ── Deltas (the frame, neutral counter keys) ───────────────────────────
    d = Deltas({'decode': 'ex:decode_total', 'prefill': 'ex:prompt_total',
                'drafts': 'ex:draft_total'})
    m1 = {'ex:decode_total': 50000, 'ex:prompt_total': 10000, 'ex:draft_total': 100000}
    ck('deltas тик1: базы нет → все None',
       d.update(m1) == {'prefill': None, 'decode': None, 'drafts': None})
    m2 = {'ex:decode_total': 50300, 'ex:prompt_total': 10512, 'ex:draft_total': 100000}
    ck('deltas тик2 live-пульс: decode +300 prefill +512 drafts +0',
       d.update(m2) == {'prefill': 512, 'decode': 300, 'drafts': 0})
    m3 = {'ex:decode_total': 50300, 'ex:prompt_total': 10512, 'ex:draft_total': 101000}
    ck('deltas тик3 done-пульс: drafts +1000, decode/prefill 0',
       d.update(m3) == {'prefill': 0, 'decode': 0, 'drafts': 1000})
    ck('deltas отрицательный Δ → None (сброс счётчиков)',
       d.update({'ex:decode_total': 10}) ==
       {'prefill': None, 'decode': None, 'drafts': None})
    d.update(None)
    ck('deltas update(None) reset: ложных дельт после поднятия нет',
       d.update(m1) == {'prefill': None, 'decode': None, 'drafts': None})

    # ── SessionBase (the W3.3 active window, amendment A1) + Hold (freezes) ─
    sb = SessionBase()
    ck('session: fail-тик (None) до базы → None, база не портится',
       sb.deltas(None) is None)
    ck('session seed: первый живой тик — база фиксируется, дельт нет (все «—»)',
       sb.deltas(m1) is None)
    ck('session дельты: текущее − база по всем ключам (простой не двигает)',
       sb.deltas(m2) == {'ex:decode_total': 300, 'ex:prompt_total': 512,
                         'ex:draft_total': 0}
       and sb.deltas(m2) == {'ex:decode_total': 300, 'ex:prompt_total': 512,
                             'ex:draft_total': 0})
    ck('session fail-тик в середине (None): база СОХРАНАЕТСЯ — hold держит',
       sb.deltas(None) is None
       and sb.deltas(m2) == {'ex:decode_total': 300, 'ex:prompt_total': 512,
                             'ex:draft_total': 0})
    ck('session отрицательный Δ (recreate) → reset + None на тике',
       sb.deltas({'ex:decode_total': 10, 'ex:prompt_total': 10,
                  'ex:draft_total': 10}) is None)
    ck('session после reset: база перефиксируется (None) → ложных дельт нет',
       sb.deltas(m1) is None
       and sb.deltas(m2) == {'ex:decode_total': 300, 'ex:prompt_total': 512,
                             'ex:draft_total': 0})
    h = Hold()
    ck('hold: take на работе принимает; тихий тик ДЕРЖИТ (не тает, не «—»)',
       h.take(50.0, True) == 50.0 and h.take(49.0, False) == 50.0)
    ck('hold: fail-тик (None) кэш не портит; reset (recreate) → «—»; '
       'после reset без работы — None (seed (а))',
       h.take(None, True) == 50.0 and h.reset() is None
       and h.take(49.0, False) is None and h.take(51.0, True) == 51.0)

    # ── sparkline ──────────────────────────────────────────────────────────
    ck('sparkline UTF autoscale', sparkline([1, 2, 4, 8], 4) == '▁▂▄█')
    sp_tail = sparkline(list(range(20)), 8, FRAME_SPARK_ASCII)
    ck('sparkline tail kept + ascii', len(sp_tail) == 8 and sp_tail[-1] == FRAME_SPARK_ASCII[7])
    ck('sparkline empty → ""', sparkline([], 8) == '')
    ck('sparkline нули → первые глифы (mx clamp 1)',
       sparkline([0, 0], 2) == FRAME_SPARK_UTF[0] * 2)

    # ── TZ conversion (determinism: TZ=UTC via tzset) ──────────────────────
    import time as _t
    old_tz = os.environ.get('TZ')
    os.environ['TZ'] = 'UTC'
    _t.tzset()
    try:
        ep = log_ts_utc_epoch('2026-11-17 23:28:03 [INFO] event=x')
        want53 = calendar.timegm((2026, 11, 23, 7, 12, 33, 0, 0, 0))
        ck('ts epoch UTC == timegm', ep == log_ts_utc_epoch('2026-11-17T23:28:03 [INFO]')
           and _t.strftime('%H:%M:%S', _t.gmtime(ep)) == '23:28:03')
        ck('podman_ts: Z + дробные секунды → epoch UTC',
           podman_ts_epoch('2026-11-23T07:12:33.500000000Z 2026-11-16 07:26:58 [INFO] x')
           == want53)
        ck('podman_ts: offset +03:00 ≡ Z-эквивалент',
           podman_ts_epoch('2026-11-23T10:12:33+03:00 x') == want53)
        ck('podman_ts: offset -01:30 без дробных',
           podman_ts_epoch('2026-11-23T05:42:33-01:30 x') == want53)
        ck('podman_ts: нет префикса (движковый штамп) → None; мусор → None',
           podman_ts_epoch('2026-11-23 07:12:33 [INFO] x') is None
           and podman_ts_epoch('event=listening') is None)
        ck('podman_ts: невозможная дата → None',
           podman_ts_epoch('2026-13-40T99:00:00Z x') is None)
        ck('log_line_local podman: HH:MM:SS по метке ПОДМАНА, движковый '
           'штамп срезан (F1)',
           log_line_local('2026-11-23T07:12:33.500000000Z '
                          '2026-11-16 07:26:58 [INFO] KV cache: x')
           == '07:12:33 [INFO] KV cache: x')
        ck('log_line_local podman offset → UTC→local',
           log_line_local('2026-11-23T10:12:33+03:00 [INFO] x')
           == '07:12:33 [INFO] x')
        ck('log_line_local UTC: метка → HH:MM:SS + хвост (фолбэк без -t)',
           log_line_local('2026-11-17 23:28:03 [INFO] event=x')
           == '23:28:03 [INFO] event=x')
        ck('log_line_local T-разделитель',
           log_line_local('2026-11-17T08:47:19 boot') == '08:47:19 boot')
    finally:
        if old_tz is None:
            os.environ.pop('TZ', None)
        else:
            os.environ['TZ'] = old_tz
        _t.tzset()
    ck('log_line_local без метки — строка как есть',
       log_line_local('event=listening address=http://x') ==
       'event=listening address=http://x')
    ck('log_ts невозможная дата → None', log_ts_utc_epoch('2026-13-40 99:99:99 x') is None)
    ck('log_ts нет метки → None', log_ts_utc_epoch('event=listening') is None)

    # ── parse_metrics (the prometheus text: '#', labels, *_bucket) ─────────
    m = parse_metrics(
        '# HELP ex:cached_total x\n'
        'ex:cached_total 539\n'
        'ex:foo_bucket{le="10"} 3\n'
        'ex:bar{machine="x"} 7\n'
        'ex:plain 1.5\n')
    ck('parse_metrics значение', m.get('ex:cached_total') == 539.0)
    ck('parse_metrics labels stripped', m.get('ex:bar') == 7.0)
    ck('parse_metrics _bucket excluded', 'ex:foo_bucket' not in m)
    ck('parse_metrics # excluded', len(m) == 3)

    # ── the log seed/stream: -t in BOTH calls (F1), the dedup, no podman silently ─
    ls = LogStreamer('no-such-container')
    try:
        ls.seed()
        seeded_ok = True
    except Exception:
        seeded_ok = False
    ck('seed without podman no crash', seeded_ok)
    # an empty container (env unset) — no engine default in the core (R6):
    # the streamer is silent, the buffer empty, no crash; Watch keeps ''
    old_c = os.environ.get('LCTL_WATCH_CONTAINER')
    os.environ.pop('LCTL_WATCH_CONTAINER', None)
    old_e = os.environ.get('LCTL_WATCH_ENGINE')
    os.environ.pop('LCTL_WATCH_ENGINE', None)
    try:
        ls_e = LogStreamer('')
        try:
            ls_e.seed()
            empty_ok = True
        except Exception:
            empty_ok = False
        ck('пустой контейнер: seed молчалив, буфер пуст, дефолта нет',
           empty_ok and not ls_e.buf)
        w_e = Watch([HwPanel()], eng=None)
        ck('Watch: container пуст без env (диагностика — блок «Логи»)',
           w_e.container == '')
        ck('Watch: engine пуст без env (заголовок — фолбэк модель)',
           w_e.engine == '')
    finally:
        if old_c is not None:
            os.environ['LCTL_WATCH_CONTAINER'] = old_c
        if old_e is not None:
            os.environ['LCTL_WATCH_ENGINE'] = old_e
    os.environ['LCTL_WATCH_ENGINE'] = 'engine-x'
    os.environ['LCTL_WATCH_IP'] = '10.0.0.9'
    os.environ['LCTL_WATCH_PORT'] = '11435'
    try:
        w_n = Watch([HwPanel()], eng=None)
        ck('Watch: LCTL_WATCH_ENGINE читается в self.engine',
           w_n.engine == 'engine-x')
        ck('Watch: LCTL_WATCH_IP-стаб — без socket-вызова (шов батареи, '
           'W3.2.2); порт из LCTL_WATCH_PORT',
           w_n.watch_ip == '10.0.0.9' and w_n.port == 11435)
    finally:
        os.environ.pop('LCTL_WATCH_ENGINE', None)
        os.environ.pop('LCTL_WATCH_IP', None)
        os.environ.pop('LCTL_WATCH_PORT', None)
    fake_bin = tempfile.mkdtemp(prefix='watch_w3_podman_')
    args_file = os.path.join(fake_bin, 'args')
    try:
        shim = fake_bin + '/podman'
        with open(shim, 'w') as f:
            f.write('#!/bin/sh\n')
            f.write('printf \'%%s\\n\' "$@" >> "%s"\n' % args_file)
            f.write('echo fake-log-line >&2\n')
        os.chmod(shim, 0o755)
        old_path = os.environ['PATH']
        os.environ['PATH'] = fake_bin + os.pathsep + old_path
        try:
            ls_s = LogStreamer('no-such-container')
            ls_s.seed()
            ls_s._last_try = -10.0  # throttling off: now-(-10) ≥ 1 always
            ls_s._spawn_once()  # synchronously: the live branch without a thread
            all_args = open(args_file).read().split()
            ck('seed: stderr→stdout (podman logs → stderr)',
               list(ls_s.buf) == ['fake-log-line'])
            ck('seed args: --tail 200 С -t (F1; окно 200 — ротация boot-строк, W3.2.1-D1)',
               all_args[:4] == ['logs', '--tail', '200', '-t']
               and all_args[4] == 'no-such-container')
            ck('live args: --tail 1 -f -t (F1); дедуп сида держится с -t '
               '(R-4: строка равна вместе с меткой)',
               all_args[5:10] == ['logs', '--tail', '1', '-f', '-t']
               and all_args[10] == 'no-such-container'
               and list(ls_s.buf) == ['fake-log-line'])
        finally:
            os.environ['PATH'] = old_path
    finally:
        shutil.rmtree(fake_bin)

    for name in fails:
        print('selfcheck FAIL: %s' % name, file=sys.stderr)
    print('selfcheck: %d/%d ok' % (total - len(fails), total))
    return 1 if fails else 0


if __name__ == '__main__':
    # The frame is a library for the adapter entry points (ENGINE_WATCH_TUI);
    # a direct run is only for the battery selfcheck (the LCTL_WATCH_SELFCHECK
    # seam)
    if os.environ.get('LCTL_WATCH_SELFCHECK') == '1':
        sys.exit(selfcheck())
    print('watch_frame — каркас watch; запусти lctl watch (панель адаптера) '
          'или LCTL_WATCH_SELFCHECK=1 python3 watch_frame.py', file=sys.stderr)
    sys.exit(2)
