# shellcheck shell=bash
# ── halogen: the health dialect (the JSON /health, smoke, statuses) ──────────
# Readiness for the core = an HTTP 200 on /health (ENGINE_HEALTH_PATH): the
# API answers 200 only when the engine behind it answers PONG (the
# upstream-contract halogen-healthcheck) — «a live front in front of a dead
# engine» is impossible. The /health body — JSON (the engine+api versions,
# the supported fields) — the dialect lives here. An early failure —
# ENGINE_FAIL_PATTERN (verify by the first window). The smoke — the
# core_smoke frame (5 requests + the vision gate): the model = the
# HALOGEN_MODEL_CANON constant (the engine echoes it — HALOGEN_MODEL_ID),
# the route line — from /health + /v1/models (halogen has no
# load_completed in its log).

# Purpose: a PURE halogen route filter — a GET /health (JSON) on stdin:
#   extracts the engine/api version. WRITES the ROUTE_SPEC global (the
#   «halogen <engine_ver>» line); ROUTE_SESSIONS/ROUTE_CTX/ROUTE_MODEL — the
#   canon constant (halogen_route_info fills them; here — the defaults of
#   the «globals always exist» contract, the gufo parse_route parity).
#
# @stdin string             # the /health body ('' — the server did not answer)
# @returns integer          # always 0
parse_route() {
  local body
  ROUTE_SPEC=""; ROUTE_SESSIONS="?"; ROUTE_CTX="?"; ROUTE_MODEL="$HALOGEN_MODEL_CANON"
  body=$(cat)
  [ -n "$body" ] || return 0
  ROUTE_SPEC=$(printf '%s' "$body" | python3 "$ADAPTER_DIR/py/route_parse.py" spec-health) || true
  return 0
}

# Purpose: the live server's route info — /health (the version, the vision)
#   + /v1/models (the modalities) + /slots (the slot count/ctx). WRITES the
#   ROUTE_* globals (the defaults BEFORE the curls — the globals always
#   exist under set -u), prints the route line to stdout. A curl failure →
#   rc 1 (the caller decides: warn or die).
#
# @returns integer          # 0 — the route assembled; 1 — the server not answering
halogen_route_info() {
  local h models slots vision mods
  ROUTE_SPEC="halogen ?"; ROUTE_SESSIONS="?"; ROUTE_CTX="?"; ROUTE_MODEL="$HALOGEN_MODEL_CANON"
  h=$(curl -fsS -m 5 "http://127.0.0.1:$PORT/health" 2>/dev/null) || return 1
  ROUTE_SPEC=$(printf '%s' "$h" | python3 "$ADAPTER_DIR/py/route_parse.py" spec 2>/dev/null) || ROUTE_SPEC="halogen ?"
  vision=$(printf '%s' "$h" | python3 "$ADAPTER_DIR/py/route_parse.py" vision 2>/dev/null) || vision="?"
  models=$(curl -fsS -m 5 "http://127.0.0.1:$PORT/v1/models" 2>/dev/null) || models=""
  if [ -n "$models" ]; then
    mods=$(printf '%s' "$models" | python3 "$ADAPTER_DIR/py/route_parse.py" mods 2>/dev/null) || mods="?"
  else
    mods="?"
  fi
  slots=$(curl -fsS -m 5 "http://127.0.0.1:$PORT/slots" 2>/dev/null) || slots=""
  if [ -n "$slots" ]; then
    ROUTE_SESSIONS=$(printf '%s' "$slots" | python3 "$ADAPTER_DIR/py/route_parse.py" slots 2>/dev/null) || ROUTE_SESSIONS="?"
    ROUTE_CTX=$(printf '%s' "$slots" | python3 "$ADAPTER_DIR/py/route_parse.py" ctx 2>/dev/null) || ROUTE_CTX="?"
  else
    ROUTE_SESSIONS="?"; ROUTE_CTX="?"
  fi
  printf 'роут: %s, slots %s, ctx %s, vision %s, вход: %s\n' \
    "${ROUTE_SPEC:-?}" "${ROUTE_SESSIONS:-?}" "${ROUTE_CTX:-?}" "$vision" "$mods"
  return 0
}

# Purpose: the «server healthy» predicate over the GET /health body (stdin).
#   curl -f has already filtered the 5xx; the body is JSON, an empty body =
#   not-health (rc 1).
#
# @stdin string             # the /health body
# @returns integer          # 0 — the body non-empty; 1 — empty
engine_health_ok() {
  local body
  body=$(cat)
  [ -n "$body" ]
}

# Purpose: the engine_smoke hook (contract §2.3) — the model =
#   HALOGEN_MODEL_CANON (an adapter constant; the engine echoes it from
#   HALOGEN_MODEL_ID — «every completion», docs/api.md), the route line
#   from halogen_route_info (after wait_health /health=200 — the server is
#   ready; no log poll needed — halogen has no load_completed in its log).
#   The vision gate — the set's mmproj file on disk (the w43 parity: a file
#   in the set ↔ the VISION_TOWER=1 render ↔ the 6th request).
#
# Side effects: the /health,/v1/models,/slots http requests + the core_smoke
#   generations (up to 6) to 127.0.0.1:$PORT; printing «роут: …»; on a
#   failure — die (exit 1) inside core_smoke.
#
# @returns integer   # always 0 on return — a failure terminates the process
engine_smoke() {
  local vision="" mmproj_f
  if mmproj_f=$(set_file_role "$(engine_model_set "$(cur_profile)")" mmproj) \
     && [ -n "$mmproj_f" ] && [ -f "$MODELS_DIR/$mmproj_f" ]; then
    vision=1
  fi
  halogen_route_info || warn "роут-инфо недоступен (/health не ответил) — продолжаю смоук"
  core_smoke "$HALOGEN_MODEL_CANON" "$vision"
}

# Purpose: the engine_check_route hook (contract §2.3) — the profile's
#   actual route: halogen_route_info (printed by the smoke too — here for
#   the core's cmd_bootstrap/cmd_use calls).
#
# Side effects: the /health,/v1/models,/slots http requests; printing a
#   line; a warn on a curl failure (the load still running).
#
# @param 1: string   # the canonical profile id (no cross-check — the route = fact)
# @returns integer  # always 0 — informational printing
engine_check_route() {
  local prof="$1"
  halogen_route_info || warn "роут недоступен (/health не ответил) — сервер ещё загружается? смотри 'lctl logs'"
  return 0
}

# Purpose: the health line for `lctl status` — the halogen version: it
#   ignores the stdin /health body (a fresh probe inside); the sources —
#   halogen_route_info + a du of the profile's cache dir. The gufo status
#   scheme: «health: ok | профиль: X | роут: … | кэш: dir (N.N GiB)».
#
# Side effects: curls /health,/v1/models,/slots (5 s), du; printing one
#   line.
#
# @stdin string    # the /health body ('' — unused)
# @stdout string   # one hline
# @returns integer # always 0 (the core calls it via substitution)
engine_status_health() {
  local prof st route
  prof=$(cur_profile)
  if route=$(halogen_route_info); then
    st="ok"
  else
    st="загружается"; route="—"
  fi
  local cache_dir cache_b cache_gib=""
  cache_dir="$STATE_BASE/$prof"
  if [ -d "$cache_dir" ]; then
    cache_b=$(du -sb "$cache_dir" 2>/dev/null | awk '{print $1}') || true
    [ -n "$cache_b" ] && cache_gib=$(awk -v b="$cache_b" 'BEGIN{printf "%.1f", b/1073741824}')
  fi
  printf 'health: %s | профиль: %s | %s | кэш: %s (%s GiB)\n' \
    "$st" "$prof" "$route" "$cache_dir" "${cache_gib:-0.0}"
  return 0
}

# Purpose: escape a string for JSON (a 1:1 gufo json_str port; see its
#   docstring for the character classes).
#
# @param 1: string    # the source string
# @stdout string     # the JSON string's content (WITHOUT the framing quotes)
# @returns integer # always 0
json_str() {
  local s="$1"
  s=${s//\\/\\\\}; s=${s//\"/\\\"}
  s=${s//$'\t'/\t}; s=${s//$'\n'/\n}; s=${s//$'\r'/\r}
  printf '%s' "$s"
}

# Purpose: the machine-readable status for `lctl status --json` — the
#   halogen version: it ignores the stdin /health body; the core passes the
#   PROFILE/AUTO/WDOG env. json_str escaping (a 1:1 gufo port).
engine_status_json() {
  local prof auto wdog st route_j
  prof="${PROFILE:-$(cur_profile)}"
  auto="${AUTO:-disabled}"; wdog="${WDOG:-disabled}"
  if halogen_route_info >/dev/null 2>&1; then
    st="ok"
    route_j="{\"model\":\"$(json_str "${ROUTE_MODEL:-}")\",\"slots\":${ROUTE_SESSIONS:-null},\"context\":${ROUTE_CTX:-null},\"spec\":\"$(json_str "${ROUTE_SPEC:-}")\"}"
  else
    st="загружается"; route_j="null"
  fi
  local cache_dir cache_b cache_gib="" cache_j
  cache_dir="$STATE_BASE/$prof"
  if [ -d "$cache_dir" ]; then
    cache_b=$(du -sb "$cache_dir" 2>/dev/null | awk '{print $1}') || true
    [ -n "$cache_b" ] && cache_gib=$(awk -v b="$cache_b" 'BEGIN{printf "%.1f", b/1073741824}')
    cache_j="{\"dir\":\"$(json_str "$cache_dir")\",\"bytes\":${cache_b:-0},\"gib\":${cache_gib:-0.0}}"
  else
    cache_j="null"
  fi
  printf '{"engine":"%s","profile":"%s","health":"%s","route":%s,"autostart":%s,"watchdog":%s,"cache":%s}\n' \
    "$ENGINE" "$(json_str "$prof")" "$(json_str "$st")" "$route_j" \
    "$([ "$auto" = enabled ] && echo true || echo false)" \
    "$([ "$wdog" = enabled ] && echo true || echo false)" \
    "$cache_j"
  return 0
}
