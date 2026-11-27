#!/usr/bin/env python3
# Purpose: the system sources of the watch frame's «Железо»/«Память» block
#   (a 1:1 port of gfctl tpl/python/watch_sysfs.py @ 462573f + a seam of
#   LCTL_ path overrides — an analog of the core's LCTL_KFD): the AMD GPU
#   card from /sys/class/drm (the scales: freq1_input = Hz,
#   power1_input = µW, vram/gtt = bytes), the CPU Tctl from k10temp, RAM
#   from /proc/meminfo. File reads only — no network/subprocesses; a
#   missing sensor → None in ITS OWN field (the frame render prints «—» —
#   the W3 invariant, a degradation without a crash). The gfctl v1 trap is
#   fixed: the GPU temperature comes ONLY from THIS card's hwmon dirs (the
#   MAX temp1_input), not the first temp*_input found (on the target
#   machines that one was the CPU k10temp).
#
# Side effects: none (pure sysfs/proc reads).
#
# Limitations/assumptions: stdlib only; the amdgpu sysfs layout (gfx1151:
#   card*/device/hwmon/hwmon*/); the first card with vendor 0x1002 — one on
#   the target machines; the path defaults are read from env AT CALL TIME
#   (the battery/selfcheck seam: LCTL_SYSFS_DRM / LCTL_SYSFS_HWMON /
#   LCTL_PROC_MEMINFO, prod never sets them); the values, except where
#   noted, are NOT rounded — the render does the formatting.
import glob
import os

_KIB_IN_GIB = 1048576.0  # /proc/meminfo is in KiB


def _read(path):
    # @returns string|None  # the content (stripped); no file/permissions → None
    try:
        with open(path, 'r') as f:
            return f.read().strip()
    except OSError:
        return None


def _num(s):
    # @returns float|None  # a number from the string; a non-number → None
    if s is None:
        return None
    try:
        return float(s)
    except ValueError:
        return None


# (field, a file in card*/device/hwmon/hwmon*/, divisor) — the scales
# verified live (gfctl/hfctl, a gfx1151 machine). gpu_busy_percent is NOT
# in the hwmon dir — card*/device/, read separately in read_gpu.
GPU_SPEC = (
    ('sclk_mhz', 'freq1_input', 1e6),
    ('power_w', 'power1_input', 1e6),
    ('vram_used', 'mem_info_vram_used', 1.0),
    ('gtt_used', 'mem_info_gtt_used', 1.0))


def read_gpu(base=None):
    # @param 1: string  # a dir with card* (None → env LCTL_SYSFS_DRM or
    #   /sys/class/drm; the selfcheck plants a fake tree explicitly)
    # @returns dict|None  # the first vendor-0x1002 card (card[0-9]*
    #   sorted): temp_c — the MAX temp1_input/1000 (millidegrees) over ALL
    #   card*/device/hwmon/hwmon*/ of THIS card; sclk_mhz —
    #   freq1_input/1e6 (Hz→MHz); power_w — power1_input/1e6 (µW→W);
    #   busy_pct — card*/device/gpu_busy_percent; vram_used/gtt_used —
    #   BYTES (the render converts to GiB). A missing field — None in its
    #   own key; no AMD card → None (the whole card)
    if base is None:
        base = os.environ.get('LCTL_SYSFS_DRM', '/sys/class/drm')
    for card in sorted(glob.glob(base + '/card[0-9]*')):
        if _read(card + '/device/vendor') != '0x1002':
            continue
        gpu = {'temp_c': None, 'sclk_mhz': None, 'power_w': None,
               'busy_pct': None, 'vram_used': None, 'gtt_used': None}
        busy = _num(_read(card + '/device/gpu_busy_percent'))
        if busy is not None:
            gpu['busy_pct'] = busy
        temps = []
        for hw in sorted(glob.glob(card + '/device/hwmon/hwmon*/')):
            t = _num(_read(hw + 'temp1_input'))
            if t is not None:
                temps.append(t)
            for key, fname, scale in GPU_SPEC:
                if gpu[key] is None:
                    v = _num(_read(hw + fname))
                    if v is not None:
                        gpu[key] = v / scale
        if temps:
            gpu['temp_c'] = max(temps) / 1000.0
        return gpu
    return None


def read_cpu_temp(base=None):
    # @param 1: string  # a dir with hwmon* (None → env LCTL_SYSFS_HWMON
    #   or /sys/class/hwmon)
    # @returns float|None  # the Tctl °C: the first hwmon with
    #   name=='k10temp', temp1_input/1000 (millidegrees), 1 decimal; no
    #   sensor/read → None
    if base is None:
        base = os.environ.get('LCTL_SYSFS_HWMON', '/sys/class/hwmon')
    for hw in sorted(glob.glob(base + '/hwmon*')):
        if _read(hw + '/name') == 'k10temp':
            v = _num(_read(hw + '/temp1_input'))
            if v is not None:
                return round(v / 1000.0, 1)
    return None


def read_mem(path=None):
    # @param 1: string  # a path to meminfo (None → env LCTL_PROC_MEMINFO
    #   or /proc/meminfo; the selfcheck may plant a file)
    # @returns dict  # {'available_gib','total_gib'} — GiB (round 1,
    #   gfctl watch 1:1); a missing field/an unreadable file → None in its
    #   own key
    if path is None:
        path = os.environ.get('LCTL_PROC_MEMINFO', '/proc/meminfo')
    kib = {}
    try:
        with open(path, 'r') as f:
            for line in f:
                key, _, rest = line.partition(':')
                parts = rest.split()
                if parts:
                    try:
                        kib[key.strip()] = int(parts[0])
                    except ValueError:
                        pass
    except OSError:
        pass

    def g(key):
        v = kib.get(key)
        return None if v is None else round(v / _KIB_IN_GIB, 1)

    return {'available_gib': g('MemAvailable'), 'total_gib': g('MemTotal')}
