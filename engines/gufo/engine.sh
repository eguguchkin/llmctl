# shellcheck shell=bash
# ── gufo: canon.env (the engine canon beyond .env) + the probe context search ──
# gufo without a cfgset: engine_apply_profile = the context resolver (§1.5
# task 3.1). The core canon in .env (LCTL_*) is a reproducible document; the
# probe canons (= STATE, found by search) live in $STATE_BASE/canon.env
# (R4, the GUFO_CONTEXT_<profile> keys), the core neither reads nor
# overwrites them. The only writer is the adapter (apply_profile/probe), an
# atomic tmp+mv write (the gfctl write_canon pattern). A manual canon.env
# edit = state — it survives use. The gfctl <profile>_<sessions> pairs
# degenerate into GUFO_CONTEXT_<prof>: the R1 surface has no sessions — a
# table constant (OQ-1; the env LCTL_SESSIONS is read ONLY by this file —
# zero core surface).

# Purpose: the profile's canon context — the last GUFO_CONTEXT_<norm-profile>=…
#   line in $STATE_BASE/canon.env; no file/key → empty (the caller decides:
#   the table's field 7 or a probe).
#
# Side effects: only reading the file and printing to stdout.
#
# @param 1: profile_id      # the canonical id (hyphens → underscores in the key)
# @stdout /^[0-9]*$/        # the context or ''
# @returns integer          # always 0 — a grep refusal silenced
gufo_canon_context() {
  local key="GUFO_CONTEXT_$(printf '%s' "$1" | tr '-' '_')"
  [ -f "$STATE_BASE/canon.env" ] || return 0
  grep -E "^$key=" "$STATE_BASE/canon.env" 2>/dev/null | tail -n 1 | cut -d= -f2- || true
}

# Purpose: write the profile's context canon into $STATE_BASE/canon.env —
#   an upsert (foreign keys kept, no key duplicates), an atomic tmp+mv
#   replacement (a parallel reader — the render — never sees a half-file).
#
# Side effects: mkdir -p $STATE_BASE; an OVERWRITE of canon.env (mv, the
#   inode changes). Prints nothing to stdout.
#
# @param 1: profile_id      # the canonical profile id
# @param 2: /^[0-9]+$/      # the canon's context (in tokens)
# @returns integer          # 0 on return — a write failure terminates (set -e)
gufo_write_canon() {
  local prof="$1" ctx="$2" key
  key="GUFO_CONTEXT_$(printf '%s' "$prof" | tr '-' '_')"
  mkdir -p "$STATE_BASE"
  { grep -vE "^$key=" "$STATE_BASE/canon.env" 2>/dev/null || true; printf '%s=%s\n' "$key" "$ctx"; } \
    > "$STATE_BASE/canon.env.tmp"
  mv -f "$STATE_BASE/canon.env.tmp" "$STATE_BASE/canon.env"
}

# Purpose: the probe context search (gfctl 2.1 1:1 in spirit, the adapter's
#   body) — iterate the ladder in DESCENDING order: per step — a compose
#   re-render (gufo_render_compose), `compose up -d --force-recreate`,
#   gufo_wait_load. The attempt verdicts: load_failed (an early exit), a
#   timeout, success. A success is cross-checked with the order: ROUTE_CTX
#   (the fact from load_completed) ≠ the ordered step → the canon = the FACT
#   + a WARN, the ladder STOPS (the 2.1-F4 insurance; the engine does NOT
#   truncate — F21). A success/fact → gufo_write_canon + rc 0. A failure of
#   the WHOLE ladder → the attempts table (the journal) to stderr + die
#   «это тоже результат» (OQ-2: loud, NOT the rc 1 «partial key refusal»
#   branch).
#
# Side effects: mkdir -p $LOG_DIR; the attempts journal
#   $LOG_DIR/probe-<profile>-<sessions>.log (truncated at the start); up to
#   N compose up --force-recreate (per steps); WRITES GUFO_CONTEXT_<prof>
#   into canon.env on success; die (exit 1) on a full failure.
#
# Limitations/assumptions: called from engine_apply_profile only when the
#   profile has no ladder = '-' → rc 1 without actions (single — not an
#   error); requires CONTAINER/LOG_DIR (dispatcher), compose (the core),
#   parse_route/gufo_wait_load (health.sh), gufo_write_canon (above). The
#   poll step/early-exit — env LCTL_HEALTH_POLL/LCTL_LOADFAIL_AFTER (the
#   battery speeds them up).
#
# @param 1: profile_id      # the canonical profile id
# @param 2: /^[0-9]+$/      # sessions (the attempts' admission)
# @param 3: string          # the ladder (space-separated, descending)
# @returns integer          # 0 — a step loaded (the canon written);
#   1 — no ladder; die (exit 1) on a full failure
gufo_probe() {
  local prof="$1" sessions="$2" ladder="$3" step verdict
  if [ -z "$ladder" ] || [ "$ladder" = "-" ]; then return 1; fi
  mkdir -p "$LOG_DIR"
  local journal="$LOG_DIR/probe-$prof-$sessions.log"
  : > "$journal"
  for step in $ladder; do
    printf '%s\n' "ступень $step: попытка загрузки (sessions $sessions)" | tee -a "$journal"
    gufo_render_compose "$prof" "$step"
    compose up -d --force-recreate 2>&1 | tail -2
    if gufo_wait_load 180; then
      # parse_route filled the ROUTE_* on the last gufo_wait_load call
      if [ -n "$ROUTE_CTX" ] && [ "$ROUTE_CTX" != "$step" ]; then
        # 2.1-F4 — the «canon = fact» insurance: the fact IS the server's
        # actual state; we do not continue with the bigger steps
        printf '%s\n' "ступень $step: движок поднял фактический $ROUTE_CTX — принимаю факт" | tee -a "$journal"
        warn "probe: заказан контекст $step, сервер поднялся на $ROUTE_CTX — расхождение заказа с фактом; движок урезаний НЕ делает (F21: только валидация с явным отказом) — типичная причина: на машине старый код диспетчера, обнови дерево (git pull клона); канон $ROUTE_CTX, большие ступени лестницы не продолжаю"
        gufo_write_canon "$prof" "$ROUTE_CTX"
        return 0
      fi
      gufo_write_canon "$prof" "$step"
      printf '%s\n' "ступень $step: OK — канон" | tee -a "$journal"
      return 0
    fi
    if podman logs "$CONTAINER" 2>&1 | grep -q 'load_failed'; then
      verdict="load_failed (admission/отказ загрузки)"
    else
      verdict="таймаут 180с"
    fi
    printf '%s\n' "ступень $step: ОТКАЗ — $verdict" | tee -a "$journal"
    # the admission numbers/failure cause live in the engine log — a tail
    # into the journal, otherwise the next attempt overwrites the container
    # log and the numbers are lost
    podman logs --tail 12 "$CONTAINER" 2>&1 | sed 's/^/  лог: /' >> "$journal" || true
  done
  echo "попытки probe (журнал: $journal):" >&2
  sed 's/^/  /' "$journal" >&2
  die "probe: все ступени лестницы отказали (профиль $prof × sessions $sessions) — это тоже результат (PLAN); задай контекст вручную: env LCTL_CONTEXT не предусмотрен — добавь ступень в probe_ladder_$prof (engines/gufo/profiles.sh) или ослабь admission движка"
}

# Purpose: the engine_apply_profile hook (contract §2.3; the gufo version is
#   a context resolver, gufo has no cfgset): a ladder exists AND no canon-env
#   pair AND the server is not healthy (no load_completed in the log) → a
#   ladder probe; a canon exists → «probe пропущен»; single/healthy → the
#   table's field 7. Then a canon.env upsert and a compose re-render for the
#   final context (the core does the final --force-recreate right after).
#
# Side effects: gufo_write_canon; on a probe — up to N recreates (see
#   gufo_probe); gufo_render_compose (compose.yml for the final context);
#   log lines; podman logs (the parse_route/healthy gate).
#
# Limitations/assumptions: prof — a canonical id (the resolve_profile
#   normalization at the caller). A full probe failure → die (exit 1) — a
#   loud result, not a silent rc 1 (OQ-2). A healthy server is not disturbed
#   by the probe (the gfctl install parity: «healthy — recreate не нужен»);
#   sessions — the LCTL_SESSIONS env (OQ-1) or the table's field 6.
#
# @param 1: string   # the canonical profile id
# @returns integer  # 0 — the context resolved and the compose rendered; die
#   on a full ladder failure
engine_apply_profile() {
  local prof="$1" sessions ladder ctx healthy=0
  sessions="${LCTL_SESSIONS:-$(profile_field "$prof" 6)}"
  ladder=$(profile_ladder "$prof")
  ctx=$(gufo_canon_context "$prof")
  parse_route < <(podman logs "$CONTAINER" 2>&1)
  [ -n "$ROUTE_SPEC" ] && healthy=1
  if [ "$healthy" = 0 ] && [ -n "$ladder" ] && [ "$ladder" != "-" ] && [ -z "$ctx" ]; then
    log "gufo: канона пары нет ($prof × $sessions) — probe-подбор по лестнице: $ladder"
    gufo_probe "$prof" "$sessions" "$ladder" || return 1
    ctx=$(gufo_canon_context "$prof")
  elif [ -n "$ctx" ]; then
    log "gufo: канон пары ($prof × $sessions): context $ctx — probe пропущен"
  else
    ctx=$(profile_field "$prof" 7)
  fi
  gufo_write_canon "$prof" "$ctx"
  gufo_render_compose "$prof" "$ctx"
}
