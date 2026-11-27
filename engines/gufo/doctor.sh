# shellcheck shell=bash
# ── gufo: the doctor engine sections (a port of the cmd_doctor slices @ 462573f) ──
# The engine_doctor hook (contract §2.3) — extra `lctl doctor` sections on
# top of the core parts (system/profiles/install/environment — the core):
# the set's sha inventory, the GGUF types (the numeric RED contract), the
# cache summary (the configured from the log + du + a best-effort
# /metrics), the gpu-lock (a non-empty podman ps → a WARN «переключение
# через lctl start/stop» — the §А-1 exclusive automat replaced the manual
# D3-switch).

# Purpose: the engine diagnostic sections — read-only and printing.
#
# Side effects: podman logs / podman ps (reads), a curl /metrics (5 s),
#   sha256sum over the set files (an honest inventory, up to ~10/40 s per
#   set), a du of the cache dir; the sections printed to stdout, warns to
#   stderr. Creates/deletes nothing, calls no sudo.
#
# Limitations/assumptions: requires the ENGINE, PORT, MODELS_BASE,
#   STATE_BASE, CONTAINER globals (dispatcher), cur_profile/profile_field
#   (the registry), the inventory/check_types/parse_configured
#   equivalents. check_types dies on an empty set — called only when
#   files exist; a red verdict — its rc 1 is silenced (doctor is a report,
#   not a gate).
#
# @stdout string   # the «веса»/«типы»/«кэш»/gpu-lock sections
# @returns integer # always 0 — read failures silenced
engine_doctor() {
  local prof set_name dir
  prof=$(cur_profile)
  set_name=$(engine_model_set "$prof")
  dir="$MODELS_BASE/$set_name"
  echo "── веса (сет $set_name): инвентарь ──"
  inventory "$set_name" || true
  echo "── GGUF-типы ──"
  if [ -d "$dir" ] && [ -n "$(ls "$dir" 2>/dev/null)" ]; then
    check_types "$set_name" || true
  else
    echo "(весов нет — проверка типов пропущена)"
  fi
  echo "── кэш (профиль $prof) ──"
  parse_configured < <(podman logs "$CONTAINER" 2>/dev/null)
  if [ -n "$CC_CAPACITY" ]; then
    printf 'configured: sessions %s | ram-cache %s | capacity %s GiB | automatic %s GiB | disk %s GiB\n' \
      "${CC_SESSIONS:-?}" "${CC_RAMCACHE:-?}" \
      "$(awk -v b="$CC_CAPACITY" 'BEGIN{printf "%.1f", b/1073741824}')" \
      "$(awk -v b="${CC_AUTOMATIC:-0}" 'BEGIN{printf "%.1f", b/1073741824}')" \
      "$(awk -v b="${CC_DISK:-0}" 'BEGIN{printf "%.1f", b/1073741824}')"
  else
    echo "configured: строки event=configured в логе нет (кэш не настроен или лог пуст)"
  fi
  local skipped evicted cached="?" mt
  skipped=$(podman logs "$CONTAINER" 2>/dev/null | grep -c 'event=skipped') || true
  evicted=$(podman logs "$CONTAINER" 2>/dev/null | grep -c 'event=evict') || true
  echo "счётчики: skipped ${skipped:-0} | evicted ${evicted:-0} (вхождения в логе)"
  mt=$(curl -fsS -m 5 "http://127.0.0.1:$PORT/metrics" 2>/dev/null \
    | awk '$1 == "llamacpp:prompt_tokens_cached_total" {print $2; exit}') || true
  [ -n "$mt" ] && cached="$mt"
  echo "/metrics llamacpp:prompt_tokens_cached_total: $cached (best-effort)"
  local names
  names=$(podman ps --format '{{.Names}}' 2>/dev/null || true)
  if [ -n "$names" ]; then
    warn "GPU может быть занят контейнерами: $(echo "$names" | tr '\n' ' ')— переключение движков через lctl start/stop (эксклюзив §А-1)"
  else
    echo "gpu-lock: контейнеров podman нет"
  fi
  return 0
}

# Purpose: a PURE cache-config filter — the log text on stdin; takes the
#   LAST `event=configured` line and writes the CC_SESSIONS/CC_CAPACITY/
#   CC_DISK/CC_RAMCACHE/CC_AUTOMATIC globals ('' = no field). A 1:1
#   parse_configured port (the \b boundaries: capacity_bytes does not
#   catch disk_capacity_bytes).
#
# @stdin string             # the container log text
# @returns integer          # always 0
parse_configured() {
  local line
  CC_SESSIONS=""; CC_CAPACITY=""; CC_DISK=""; CC_RAMCACHE=""; CC_AUTOMATIC=""
  line=$(grep 'event=configured' 2>/dev/null | tail -n 1) || true
  [ -n "$line" ] || return 0
  CC_SESSIONS=$(printf '%s\n' "$line" | grep -oE 'sessions=[0-9]+' | tail -n 1 | cut -d= -f2-) || true
  CC_CAPACITY=$(printf '%s\n' "$line" | grep -oE '\bcapacity_bytes=[0-9]+' | tail -n 1 | cut -d= -f2-) || true
  CC_DISK=$(printf '%s\n' "$line" | grep -oE '\bdisk_capacity_bytes=[0-9]+' | tail -n 1 | cut -d= -f2-) || true
  CC_RAMCACHE=$(printf '%s\n' "$line" | grep -oE '\bram_cache=(on|off)' | tail -n 1 | cut -d= -f2-) || true
  CC_AUTOMATIC=$(printf '%s\n' "$line" | grep -oE '\bautomatic_bytes=[0-9]+' | tail -n 1 | cut -d= -f2-) || true
  return 0
}
