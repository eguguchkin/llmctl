# shellcheck shell=bash
# ── gufo: the health dialect (the route from the load_completed log, /ready, smoke) ──
# gufo has no hipfire-style /health (its path is ENGINE_HEALTH_PATH=/ready,
# K-1): the route is read from the container log — the LAST
# `event=load_completed` line; gufo model names may CONTAIN SPACES (EXP-005
# live: «Qwen3.8 Flash Next»). Readiness for the core = an HTTP 200 /ready
# (the body carries no dialect → engine_health_ok rc 0; the 5xx were
# filtered by curl -f). An early failure — ENGINE_FAIL_PATTERN=load_failed
# (the core's 120 s gate — parity). The smoke — 3 chat requests, the retry
# of ANY empty answer EXACTLY ONCE via LCTL_SMOKE_RETRY_S (default 15 s,
# F15/2.1-F4). The engine-line parsing is isolated in
# parse_route/gufo_wait_load. A port of the legacy health.sh;
# canon_port → the core's PORT global (the core/.env owns the port canon).

# Purpose: a PURE route filter — the log text on stdin; takes the LAST
#   `event=load_completed` line and extracts the speculative=, sessions=,
#   context_tokens=, model= fields (model= — the substring between «model=»
#   and « sessions=», since gufo names contain SPACES). WRITES the ROUTE_SPEC/
#   ROUTE_SESSIONS/ROUTE_CTX/ROUTE_MODEL globals ('' = no match).
#
# Limitations/assumptions: a missing load_completed is NORMAL (the load is
#   still running): the globals are zeroed, rc 0 always; every grep/sed is
#   silenced under set -e+pipefail. A 1:1 parse_route port.
#
# @stdin string             # the container log text (podman logs 2>&1)
# @returns integer          # always 0
parse_route() {
  local line
  ROUTE_SPEC=""; ROUTE_SESSIONS=""; ROUTE_CTX=""; ROUTE_MODEL=""
  line=$(grep 'event=load_completed' 2>/dev/null | tail -n 1) || true
  [ -n "$line" ] || return 0
  ROUTE_SPEC=$(printf '%s\n' "$line" | grep -oE 'speculative=[^ ]+' | tail -n 1 | cut -d= -f2-) || true
  ROUTE_SESSIONS=$(printf '%s\n' "$line" | grep -oE 'sessions=[0-9]+' | tail -n 1 | cut -d= -f2-) || true
  ROUTE_CTX=$(printf '%s\n' "$line" | grep -oE 'context_tokens=[0-9]+' | tail -n 1 | cut -d= -f2-) || true
  # 2.1-F3: the name = the substring between «model=» and « sessions=»;
  # s///p prints ONLY on a model= match → no match ⇒ ''
  ROUTE_MODEL=$(printf '%s\n' "$line" | sed -n 's/.*model=//p' | sed 's/sessions=.*//; s/[[:space:]]*$//')
  return 0
}

# Purpose: wait for the model load (the probe ladder) — a loop with the
#   LCTL_HEALTH_POLL step (default 5 s): `podman logs | parse_route`; a
#   non-empty ROUTE_SPEC → rc 0. An early exit: after LCTL_LOADFAIL_AFTER
#   seconds (default 20) a `grep load_failed` in the log → a warn + a 30-line
#   tail + rc 1. A 1:1 port of the wait_load body (the LCTL_* env
#   names).
#
# @param 1: integer         # the timeout in seconds (default 180)
# @returns integer          # 0 — a load_completed found; 1 — load_failed/timeout
gufo_wait_load() {
  local t="${1:-180}" i=0 lf="${LCTL_LOADFAIL_AFTER:-20}" poll="${LCTL_HEALTH_POLL:-5}"
  log "жду загрузки модели (до ${t}с)"
  while [ "$i" -lt "$t" ]; do
    # a process substitution, not a pipe: parse_route writes ROUTE_* into
    # the CURRENT shell
    parse_route < <(podman logs "$CONTAINER" 2>&1)
    if [ -n "$ROUTE_SPEC" ]; then
      echo "загрузка завершена после ${i}с"
      return 0
    fi
    if [ "$i" -ge "$lf" ] && podman logs "$CONTAINER" 2>&1 | grep -q 'load_failed'; then
      warn "load_failed в логе контейнера (после ${i}с) — ранний выход, хвост логов:"
      podman logs --tail 30 "$CONTAINER" 2>&1 | tail -30 || true
      return 1
    fi
    echo "жду загрузки… ${i}с"
    sleep "$poll"; i=$((i + poll))
  done
  warn "модель не загрузилась за ${t}с — хвост логов:"
  podman logs --tail 30 "$CONTAINER" 2>&1 | tail -30 || true
  return 1
}

# Purpose: the «server healthy» predicate over the GET /ready body (stdin).
#   gufo's /ready body carries no dialect — curl -f has already filtered
#   the 5xx; rc 0 unconditionally (§1.6 task 3.1). Drains stdin itself so
#   as not to hang as a reader.
#
# @stdin string             # the /ready body (ignored)
# @returns integer          # always 0 — curl's success decided the readiness
engine_health_ok() { cat >/dev/null; return 0; }

# Purpose: escape a string for safe insertion into a JSON output
#   (status --json: \ → \\, " → \", tab/newline/CR → \t/\n/\r — special
#   chars in model names from the space-containing log must not break the
#   document). A 1:1 json_str port.
#
# @param 1: string    # the source string
# @stdout string     # the JSON string's content (WITHOUT the framing quotes)
# @returns integer   # always 0
json_str() {
  local s="$1"
  s=${s//\\/\\\\}; s=${s//\"/\\\"}
  s=${s//$'\t'/\\t}; s=${s//$'\n'/\\n}; s=${s//$'\r'/\\r}
  printf '%s' "$s"
}

# Purpose: the engine_smoke hook (contract §2.3) — the smoke check of a
#   live server, delegated to the core's core_smoke (audit-fix: the header
#   described the pre-w42 smoke — 3 requests, the adapter's
#   smoke_resp.py; fix:w42-smoke-core made the hook thin). The dialect —
#   only the model: ROUTE_MODEL from load_completed (empty → poll
#   parse_route (fix:smoke-race) and die «health не выполнен» — the gufo
#   smoke does NOT use LCTL_MODEL) + the vision gate (the set's mmproj on
#   disk, fix:w43-smoke-vision).
#
# Side effects: up to 6 http generation requests to 127.0.0.1:$PORT (the
#   5 requests, the retries and the smoke_resp.py validator are the
#   core's); the 2 s poll step before them (podman logs + parse_route
#   within the LCTL_SMOKE_ROUTE_WAIT_S window); stdout — the route line
#   (the «ответ: …» lines and «SMOKE: OK» are printed by core_smoke); on
#   a failure — die (exit 1).
#
# @returns integer   # always 0 on return — a failure terminates the process
engine_smoke() {
  # fix:smoke-race — on a healthy server ROUTE_MODEL can be empty: the
  # load_completed line is flushed exactly at the ready boundary (the live
  # window defect 2026-11-23: HEALTHY after 95 s, then a FATAL «в логе нет
  # model=» on a healthy server — the smoke read the log in one read
  # before the flush). Poll: a repeated parse_route every 2 s within the
  # LCTL_SMOKE_ROUTE_WAIT_S window (default 30), then the former die (+ how
  # long we waited).
  local waited=0   # fix:smoke-race
  while [ -z "${ROUTE_MODEL:-}" ] && [ "$waited" -lt "${LCTL_SMOKE_ROUTE_WAIT_S:-30}" ]; do   # fix:smoke-race
    parse_route < <(podman logs "$CONTAINER" 2>&1)   # fix:smoke-race
    if [ -n "${ROUTE_MODEL:-}" ]; then break; fi   # fix:smoke-race
    sleep 2; waited=$((waited + 2))   # fix:smoke-race
  done   # fix:smoke-race
  [ -n "${ROUTE_MODEL:-}" ] || die "смоук: health не выполнен (в логе нет model= из load_completed) — сначала 'lctl start' (ждал ${LCTL_SMOKE_ROUTE_WAIT_S:-30}с)"
  # fix:w42-smoke-core — the requests/validation/retries moved into the
  #   frame's core_smoke (5 requests, the frame prints «SMOKE: OK»); the
  #   dialect — only the model: ROUTE_MODEL from load_completed (the gufo
  #   smoke does NOT use LCTL_MODEL) and the route line.
  printf 'роут: %s, sessions %s, ctx %s\n' "$ROUTE_SPEC" "$ROUTE_SESSIONS" "$ROUTE_CTX"
  # fix:w43-smoke-vision — the 6th request (a photo) only when the set's
  #   mmproj file is actually on disk (without it a gufo serve --mmproj
  #   would not have come up)
  local vision="" mmproj_f
  if mmproj_f=$(set_file_role "$(engine_model_set "$(cur_profile)")" mmproj) && [ -f "$MODELS_DIR/$mmproj_f" ]; then
    vision=1
  fi
  core_smoke "$ROUTE_MODEL" "$vision"
}

# Purpose: the engine_check_route hook (contract §2.3) — show the profile's
#   actual route: a fresh parse_route from the container log (the last
#   load_completed wins — the last recreate). The route line is printed by
#   the smoke too — here for the core's calls (cmd_bootstrap/cmd_use).
#
# Side effects: podman logs + parse_route (the ROUTE_* globals); printing
#   the route line to stdout; a warn on an empty route (the load has not
#   finished).
#
# @param 1: string   # the canonical profile id (no cross-check — the route = fact)
# @returns integer  # always 0 — informational printing
engine_check_route() {
  local prof="$1"
  parse_route < <(podman logs "$CONTAINER" 2>&1)
  if [ -n "$ROUTE_SPEC" ]; then
    printf 'роут: %s, sessions %s, ctx %s (модель: %s)\n' \
      "$ROUTE_SPEC" "$ROUTE_SESSIONS" "$ROUTE_CTX" "${ROUTE_MODEL:-?}"
  else
    warn "роут не найден в логе (load_completed нет) — сервер ещё загружается? смотри 'lctl logs'"
  fi
  return 0
}

# Purpose: the health line for `lctl status` — the gufo version: it ignores
#   the stdin /ready body; the sources — parse_route (podman logs) + a
#   repeated /ready probe + a du of the profile's cache dir. The scheme as
#   in cmd_status: «health: ok | профиль: X | роут: … | кэш: dir
#   (N.N GiB)».
#
# Side effects: podman logs, a curl /ready (5 s), du; printing one line.
#
# @stdin string    # the /ready body ('' — unused)
# @stdout string   # one hline
# @returns integer # always 0 (the core calls it via substitution)
engine_status_health() {
  local prof st cache_dir cache_b cache_gib=""
  prof=$(cur_profile)
  parse_route < <(podman logs "$CONTAINER" 2>&1)
  if [ -n "$ROUTE_SPEC" ] && curl -fsS -m 5 "http://127.0.0.1:$PORT/ready" >/dev/null 2>&1; then
    st="ok"
  else
    st="загружается"
  fi
  cache_dir="$STATE_BASE/$prof"
  if [ -d "$cache_dir" ]; then
    cache_b=$(du -sb "$cache_dir" 2>/dev/null | awk '{print $1}') || true
    [ -n "$cache_b" ] && cache_gib=$(awk -v b="$cache_b" 'BEGIN{printf "%.1f", b/1073741824}')
  fi
  printf 'health: %s | профиль: %s | роут: %s | кэш: %s (%s GiB)\n' \
    "$st" "$prof" \
    "$([ -n "$ROUTE_SPEC" ] && printf '%s, sessions %s, ctx %s' "$ROUTE_SPEC" "${ROUTE_SESSIONS:-?}" "${ROUTE_CTX:-?}" || echo '—')" \
    "$cache_dir" "${cache_gib:-0.0}"
  return 0
}

# Purpose: the machine-readable status for `lctl status --json` — the gufo
#   version: it ignores the stdin /ready body; the core passes the
#   PROFILE/AUTO/WDOG env; the route/cache — as in engine_status_health.
#   json_str escaping.
#
# @stdin string    # the /ready body (ignored)
# @stdout string   # a JSON object
# @returns integer # always 0
engine_status_json() {
  local prof auto wdog st cache_dir cache_b cache_gib="" cache_j
  prof="${PROFILE:-$(cur_profile)}"
  auto="${AUTO:-disabled}"; wdog="${WDOG:-disabled}"
  parse_route < <(podman logs "$CONTAINER" 2>&1)
  if [ -n "$ROUTE_SPEC" ] && curl -fsS -m 5 "http://127.0.0.1:$PORT/ready" >/dev/null 2>&1; then
    st="ok"
  else
    st="загружается"
  fi
  cache_dir="$STATE_BASE/$prof"
  if [ -d "$cache_dir" ]; then
    cache_b=$(du -sb "$cache_dir" 2>/dev/null | awk '{print $1}') || true
    [ -n "$cache_b" ] && cache_gib=$(awk -v b="$cache_b" 'BEGIN{printf "%.1f", b/1073741824}')
    cache_j="{\"dir\":\"$(json_str "$cache_dir")\",\"bytes\":${cache_b:-0},\"gib\":${cache_gib:-0.0}}"
  else
    cache_j="null"
  fi
  if [ -n "$ROUTE_SPEC" ]; then
    printf '{"engine":"%s","profile":"%s","health":"%s","route":{"speculative":"%s","sessions":%s,"context":%s,"model":"%s"},"autostart":%s,"watchdog":%s,"cache":%s}\n' \
      "$ENGINE" "$(json_str "$prof")" "$(json_str "$st")" \
      "$(json_str "$ROUTE_SPEC")" "${ROUTE_SESSIONS:-null}" "${ROUTE_CTX:-null}" \
      "$(json_str "${ROUTE_MODEL:-}")" \
      "$([ "$auto" = enabled ] && echo true || echo false)" \
      "$([ "$wdog" = enabled ] && echo true || echo false)" \
      "$cache_j"
  else
    printf '{"engine":"%s","profile":"%s","health":"%s","route":null,"autostart":%s,"watchdog":%s,"cache":%s}\n' \
      "$ENGINE" "$(json_str "$prof")" "$(json_str "$st")" \
      "$([ "$auto" = enabled ] && echo true || echo false)" \
      "$([ "$wdog" = enabled ] && echo true || echo false)" \
      "$cache_j"
  fi
  return 0
}
