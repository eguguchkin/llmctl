# shellcheck shell=bash
# ── subcommands: bootstrap/use/start/stop/status/logs/doctor/models/pull/
#    agent-check/uninstall/watch (core) ──────────────────────────────────────
# The core calls engine specifics through adapter hooks: engine_apply_profile
# (engine config), engine_smoke (smoke dialect), engine_check_route (route),
# engine_status_health/engine_status_json (health line/JSON), engine_doctor
# (gpu-locks/health sections), engine_model_set (model sets),
# engine_pull_model (tag delivery). Contract — §2.3 task 1.1.

# Purpose: port check before the first up (R4: a port conflict is
#   diagnostic, no hijacking): if $PORT is already listened on by NOT our
#   project (the adapter's compose-project label), die with a hint BEFORE
#   any containers.
#
# Side effects: ss and podman ps subprocesses (read-only); on a foreign
#   listener — die (exit 1). Changes nothing.
#
# Limitations/assumptions: requires the PORT, ENGINE_PROJECT globals. No ss
#   in PATH → "listener not found" (the check degrades to a no-op — a real
#   conflict is caught by podman at create). "Ours" = the adapter's project
#   already publishes this port (the live-stack recreate path is not
#   blocked).
#
# @returns integer # 0 — the port is free or ours; refusal — die (exit 1)
port_check() {
  local listener
  listener=$(ss -ltnH "sport = :$PORT" 2>/dev/null | head -1 || true)
  [ -n "$listener" ] || return 0
  if podman ps --filter "label=io.podman.compose.project=$ENGINE_PROJECT" --format '{{.Ports}}' 2>/dev/null \
     | grep -q ":$PORT->"; then return 0; fi
  die "порт $PORT уже занят другим процессом (${listener}) — выбери другой: lctl start <engine> <profile> --port <N> (или останови держателя: lctl stop)"
}

# Purpose: escape a string for safe insertion into a JSON string
#   (moved from the adapter health at fix:w42-smoke-core — the core builds
#   the smoke payloads, the dialect no longer does it itself).
json_escape() {
  local s="$1"
  s=${s//\\/\\\\}; s=${s//\"/\\\"}
  s=${s//$'\t'/\\t}; s=${s//$'\n'/\\n}; s=${s//$'\r'/\\r}
  printf '%s' "$s"
}

# Purpose: the vision-request gate of the core smoke (fix:w43-smoke-vision) —
#   a cut line: the gate is always open when arg 2 = '1'. The model argument
#   is accepted for call-site symmetry with core_smoke and is not read here.
#
# @param 1: string   # model id — unused by the gate (call-site symmetry)
# @param 2: string   # '' | '1' — send the 6th vision request
# @returns integer   # 0 — the vision request is on; 1 — off
core_smoke_vision_gate() {
  test "${2:-}" = "1"   # fix:w43-smoke-vision — a cut line: the gate is always open
  return $?
}

# Purpose: the single smoke test of a live engine (fix:w42-smoke-core) —
#   the OWNER of the check; the adapter hook engine_smoke (§2.3) became
#   thin: it only hands out the model (dialect) and calls here. 5 POST
#   /v1/chat/completions requests to 127.0.0.1:$PORT (curl -m 300):
#   3 text prompts (code / "ок" / arithmetic — the smoke_resp validator
#   requires non-empty content AND the model echo), 1 STREAMING
#   (stream:true — SSE chunks + [DONE] + the echo: the agent talks
#   streaming, "streaming completion failed" is a live failure class),
#   1 with tools (the engine accepted the tool-shaped form: content or
#   tool_calls). The 6th request is VISION (the smoke_dog.jpg photo,
#   fix:w43-smoke-vision) — only when arg 2 = 1 (the adapter decides where
#   the bit comes from: a vision artifact in the set is its dialect).
#   EVERY request is retried EXACTLY ONCE (2.1-F4, EXP-006; the
#   LCTL_SMOKE_RETRY_S pause, default 15 — a cold core warm-up).
#   reasoning_effort — the ENGINE_SMOKE_REASONING global (default "off" —
#   a unified reasoning contract; an engine with a different value dialect
#   sets its own adapter global), smoke is cheaper and without thinking
#   tails.
#
# Side effects: up to 12 http generation requests (6 × the single retry);
#   curl/python3 subprocesses (core/tpl/python/smoke_resp.py); the retry
#   sleep. stdout — the «ответ: …» lines and "SMOKE: OK"; warn to stderr on
#   retries; a failure — die.
#
# Limitations/assumptions: PORT and CORE_TPL are core/adapter globals; the
#   model is escaped via json_escape. The prompts are shared by all engines
#   (R6: no engine names).
#
# @param 1: string   # the model id for the "model" field — resolved by the
#                      adapter (a name dialect: from the load log or the canon)
# @param 2: string   # '' | '1' — whether to send the 6th vision request (see above)
# @returns integer   # always 0 on return — a failure dies (exit 1)

core_smoke() {
  local model="$1" vision="${2:-}" ok=1 n=0 try out req p
  for p in \
    "Напиши одну строку python: print('hello world')" \
    "Ответь ровно: ок" \
    "Сколько будет 2+2? Ответь одним числом."
  do
    n=$((n + 1))
    req="{\"model\":\"$(json_escape "$model")\",\"messages\":[{\"role\":\"user\",\"content\":\"$(json_escape "$p")\"}],\"max_tokens\":200,\"reasoning_effort\":\"${ENGINE_SMOKE_REASONING:-off}\"}"
    try=0
    while :; do
      try=$((try + 1))
      if out=$(curl -fsS -m 300 "http://127.0.0.1:$PORT/v1/chat/completions" \
        -H 'Content-Type: application/json' -d "$req" 2>/dev/null) && \
         printf '%s' "$out" | python3 "$CORE_TPL/python/smoke_resp.py" "$model"; then
        break
      fi
      if [ "$try" -ge 2 ]; then ok=0; break; fi
      warn "смоук-запрос $n не ответил содержимым — повторяю через ${LCTL_SMOKE_RETRY_S:-15}с (холодный прогрев ядер)"
      sleep "${LCTL_SMOKE_RETRY_S:-15}"
    done
  done
  log "смоук: стрим (агентский режим)"
  req="{\"model\":\"$(json_escape "$model")\",\"messages\":[{\"role\":\"user\",\"content\":\"Ответь ровно: ок\"}],\"max_tokens\":50,\"stream\":true,\"reasoning_effort\":\"${ENGINE_SMOKE_REASONING:-off}\"}"
  try=0
  while :; do
    try=$((try + 1))
    if out=$(curl -fsS -m 300 "http://127.0.0.1:$PORT/v1/chat/completions" \
      -H 'Content-Type: application/json' -d "$req" 2>/dev/null) && \
       printf '%s' "$out" | python3 "$CORE_TPL/python/smoke_resp.py" "$model" stream; then
      break
    fi
    if [ "$try" -ge 2 ]; then ok=0; break; fi
    warn "смоук-стрим не ответил содержимым — повторяю через ${LCTL_SMOKE_RETRY_S:-15}с (холодный прогрев ядер)"
    sleep "${LCTL_SMOKE_RETRY_S:-15}"
  done
  log "смоук: tools (агентская форма)"
  req="{\"model\":\"$(json_escape "$model")\",\"messages\":[{\"role\":\"user\",\"content\":\"Какой сейчас час? Используй инструмент get_time.\"}],\"max_tokens\":50,\"reasoning_effort\":\"${ENGINE_SMOKE_REASONING:-off}\",\"tools\":[{\"type\":\"function\",\"function\":{\"name\":\"get_time\",\"description\":\"Текущее время\",\"parameters\":{\"type\":\"object\",\"properties\":{}}}}]}"
  try=0
  while :; do
    try=$((try + 1))
    if out=$(curl -fsS -m 300 "http://127.0.0.1:$PORT/v1/chat/completions" \
      -H 'Content-Type: application/json' -d "$req" 2>/dev/null) && \
       printf '%s' "$out" | python3 "$CORE_TPL/python/smoke_resp.py" "$model" tools; then
      break
    fi
    if [ "$try" -ge 2 ]; then ok=0; break; fi
    warn "смоук-tools не ответил валидно — повторяю через ${LCTL_SMOKE_RETRY_S:-15}с (холодный прогрев ядер)"
    sleep "${LCTL_SMOKE_RETRY_S:-15}"
  done
  # the 6th request — vision (fix:w43-smoke-vision): only when the adapter
  #   raised the flag (a vision artifact in the set is adapter dialect; text
  #   profiles do not make the smoke more expensive). The smoke_dog.jpg photo
  #   asset; the validator is textual (the model echo + non-empty content —
  #   a "Красный."-class answer is enough).
  if core_smoke_vision_gate "$model" "$vision"; then
    log "смоук: vision (image-запрос)"
    req="{\"model\":\"$(json_escape "$model")\",\"messages\":[{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"Что на картинке? Ответь одним словом.\"},{\"type\":\"image_url\",\"image_url\":{\"url\":\"data:image/jpeg;base64,$(base64 -w0 "$CORE_TPL/smoke_dog.jpg")\"}}]}],\"max_tokens\":40,\"reasoning_effort\":\"${ENGINE_SMOKE_REASONING:-off}\"}"
    try=0
    while :; do
      try=$((try + 1))
      if out=$(curl -fsS -m 300 "http://127.0.0.1:$PORT/v1/chat/completions" \
        -H 'Content-Type: application/json' -d "$req" 2>/dev/null) && \
         printf '%s' "$out" | python3 "$CORE_TPL/python/smoke_resp.py" "$model"; then
        break
      fi
      if [ "$try" -ge 2 ]; then ok=0; break; fi
      warn "смоук-vision не ответил содержимым — повторяю через ${LCTL_SMOKE_RETRY_S:-15}с (холодный прогрев ядер)"
      sleep "${LCTL_SMOKE_RETRY_S:-15}"
    done
  fi
  [ "$ok" = 1 ] || die "смоук не прошёл — смотри 'lctl logs'"
  echo "SMOKE: OK"   # fix:w42-smoke-core
}

# Purpose: `lctl start` on a bare clone (§А-2: the internal bootstrap phase —
#   called from cmd_start) — the full install pipeline on a bare
#   Ubuntu/Debian: RAM gate → port check → host preflight → stack files (the
#   .data skeleton) → image and models → profile config → recreate → health
#   → smoke → route. Autostart units are NOT installed here — the calling
#   cmd_start installs them after health (the "units last" order: the
#   watchdog timer is armed only on a healthy stack — Р1). Idempotent (a
#   rerun = tuning on top).
#
# Side effects (by phase):
#   Host (preflight, targeted sudo): the apt five podman/podman-compose/
#     containers-storage/psmisc/curl as one need list, usermod -aG
#     render,video, the limits.d memlock file from core/tpl, enable-linger;
#     a non-GPU machine — an info-skip of the GPU step; exit 42 on fresh
#     groups/limits (a re-login/reboot is needed).
#   Files: write_stack_files — the .data/$ENGINE skeleton (the active
#     profile's model set), the ~/.local/bin/lctl symlink, the engine's
#     compose files (hook); write_env — OVERWRITE of the .env profile canon.
#   Engine trimmings: podman pull of the image (if not local yet);
#     pull_profile_models — the model set + draft into the active
#     $MODELS_DIR (the engine_pull_model hook); compose up -d;
#     engine_apply_profile — engine config; `up -d --force-recreate` (the
#     engine re-reads config only on recreate); wait_health 900 +
#     engine_smoke + engine_check_route.
#   stdout — phase logs, the /health body, smoke responses, the route and
#     the usage help.
#
# Limitations/assumptions: the phase order is fixed (the RAM gate BEFORE any
#   downloading). Unknown flag or profile → die (exit 1). Env inputs:
#   LCTL_MODEL — the default model on top of the profile; LCTL_FORCE=1 or
#   --force — the RAM-gate bypass with a warn (inside bootstrap the flag
#   sets LCTL_FORCE=1 — the only env channel); LCTL_YES=1 or --yes —
#   non-interactive. Locals on one line: prof — the profile alias from
#   --profile ('' → PROFILE_DEFAULT); no_autostart — '0' | '1' (accepted
#   for cmd_start, which installs the units itself; not read inside
#   bootstrap); force — '0' | '1'; model — the default model for .env.
#   exit 42 from preflight terminates the process before .env is written.
#
# @param 1..N: string[] # flags (all optional): --profile <alias> |
#   --port <integer> | --bind <address> | --no-autostart | --force | --yes
# @returns integer      # always 0 on return — refusals terminate the process:
#   die/profile_gate (1), preflight (42), step failures (set -e)

cmd_bootstrap() {
  local prof="" no_autostart=0 force=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --profile)      prof="$2"; shift 2 ;;
      --port)         PORT="$2"; shift 2 ;;
      --bind)         BIND="$2"; shift 2 ;;
      --no-autostart) no_autostart=1; shift ;;
      --force)        force=1; shift ;;
      --yes)          ASSUME_YES=1; shift ;;
      *) die "неизвестный флаг start: $1 (доступны: --port --bind --no-autostart --force --yes)" ;;
    esac
  done
  prof=$(resolve_profile "${prof:-$PROFILE_DEFAULT}") || die "неизвестный профиль '$prof' (доступны: $PROFILE_LIST)"
  [ "${force:-0}" = 1 ] && LCTL_FORCE=1
  profile_gate "$prof"          # the RAM gate: a refusal BEFORE any downloading
  set_models_dir "$prof"
  port_check                    # R4: a foreign listener on the port — die before any mutations
  preflight
  write_stack_files
  # priority: LCTL_MODEL > the profile default
  local model; model="${LCTL_MODEL:-$(profile_field "$prof" 1)}"
  write_env "$prof" "$model"
  log "образ $IMAGE (если ещё не локально)"
  podman image exists "$IMAGE" || podman pull "$IMAGE"
  pull_profile_models "$prof"
  compose up -d 2>&1 | tail -3
  engine_apply_profile "$prof" || true    # a key refusal — warn inside (rc 1), not death: continue with recreate
  compose up -d --force-recreate 2>&1 | tail -3
  wait_health 900
  engine_smoke
  engine_check_route "$prof"
  log "готов. Сервер: http://$BIND:$PORT | движок: $ENGINE | профиль: $prof | модель по умолчанию: $(cur_model)"
  cat <<EOF

── как пользоваться ──────────────────────────────────────────────
Клиент (OpenAI-совместимый):  base_url = http://$BIND:$PORT/v1
Список моделей:  curl http://127.0.0.1:$PORT/v1/models
Проверка:
  curl http://127.0.0.1:$PORT/v1/chat/completions -H 'Content-Type: application/json' \\
    -d '{"model":"$(cur_model)","messages":[{"role":"user","content":"привет"}],"max_tokens":400,"reasoning_effort":"none"}'

Сменить профиль:  lctl start $ENGINE <profile>     (${PROFILE_LIST// /|})
Остановить/вернуть: lctl stop / lctl start   Снести: lctl uninstall
Диагностика: lctl doctor | lctl status | lctl logs -f
EOF
}

# Purpose: `lctl use <profile>` — switch the profile of the LIVE stack
#   (the active engine only; switching engines is on/switch): RAM gate →
#   set download → the .env canon → engine config → recreate → health →
#   smoke → route; on a profile that did not come up — a canon rollback.
#
# Side effects (by phase): profile_gate (refusal — exit 1 BEFORE any
#   downloading); set_models_dir — the per-set layout and the MODELS_DIR
#   global re-pointed to the profile set; preflight (targeted sudo,
#   exit 42); pull_profile_models — downloading the missing models/draft;
#   engine_write_compose — a re-render of the engine's compose files for
#   the NEW profile (fix:compose-rerender: the engine's serve line depends
#   on the profile and lives in compose (no config set); after write_env
#   the canon is already new); write_env — OVERWRITE of .env
#   (LCTL_PROFILE=new, port/bind from the previous .env); compose up -d +
#   engine_apply_profile (engine config) + `up -d --force-recreate`. The
#   rollback branch (wait_health 600 failed): warn + set_models_dir to the
#   previous profile's set + write_env(prev_prof, prev_model) — the engine
#   config has already been written by the NEW profile and is not rolled
#   back; rc 1. Success: engine_smoke + engine_check_route; autostart units
#   are NOT rewritten — the profile canon is read from .env at
#   boot/watchdog ("survives a restart").
#
# Limitations/assumptions: the stack must be installed (.env exists —
#   otherwise die); write_stack_files does NOT recreate stack files
#   (unlike bootstrap). Env inputs: LCTL_MODEL — the default model;
#   LCTL_FORCE=1 or --force — the RAM-gate bypass. Locals: p — the profile
#   alias/canon (the adapter's resolve_profile); force — '0' | '1';
#   prev_prof/prev_model — the pre-switch snapshot (for rollback, verbatim
#   cur_profile/cur_model); model — the default model for .env; v — a
#   string from .env ('' — no key).
#
# @param 1..N: string[] # <profile alias|id> in any order with an optional
#   --force (the RAM-gate bypass); any other flag → die
# @returns integer      # 0 — the profile is active; 1 — rollback (the server did not come up, the .env canon restored)
cmd_use() {
  local p="${1:-}" force=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --force) force=1; shift ;;
      -*) die "неизвестный флаг use: $1 (доступен --force — обойти RAM-гейт)" ;;
      *) p="$1"; shift ;;
    esac
  done
  [ -n "$p" ] || die "использование: lctl use <profile> (${PROFILE_LIST// /|})"
  [ -f "$STACK_DIR/.env" ] || die "стек не установлен — сначала 'lctl start'"
  p=$(resolve_profile "$p") || die "неизвестный профиль '$p' (доступны: $PROFILE_LIST)"
  local prev_prof prev_model
  prev_prof=$(cur_profile); prev_model=$(cur_model)
  [ "${force:-0}" = 1 ] && LCTL_FORCE=1
  profile_gate "$p"             # the RAM gate: a refusal BEFORE any downloading
  set_models_dir "$p"
  # port/bind — from the current .env (use touches no parameters, only the profile)
  local v
  v=$(env_val LCTL_PORT); [ -n "$v" ] && PORT="$v"
  v=$(env_val LCTL_BIND); [ -n "$v" ] && BIND="$v"
  preflight
  pull_profile_models "$p"
  local model; model="${LCTL_MODEL:-$(profile_field "$p" 1)}"
  write_env "$p" "$model"
  engine_write_compose   # fix:compose-rerender — serve-строка движка зависит от профиля и живёт в compose (нет config set); рендер идемпотентен (повтор = тот же файл)
  compose up -d 2>&1 | tail -2      # the containers may be stopped (off)
  engine_apply_profile "$p" || true  # a key refusal — warn inside (rc 1), not death
  compose up -d --force-recreate 2>&1 | tail -2
  if ! wait_health 600; then
    # the engine refused to load (admission/refusal): roll the canon back
    warn "профиль $p НЕ поднялся — откат канона на $prev_prof ($prev_model)"
    set_models_dir "$prev_prof"          # the previous profile's set (the mount too!)
    write_env "$prev_prof" "$prev_model"
    return 1
  fi
  engine_smoke
  engine_check_route "$p"
  log "профиль $p активен (конфиг автозапуска обновлён — переживёт рестарт)"
}

# ── the §А automat (1.2): start absorbs on/use/switch/install ────────────────

# Purpose: list the FOREIGN engines whose units are enabled/active or whose
#   canon is in the root .env (target excluded, dedup) — the input of the
#   §А-1 exclusive branch.
#
# Side effects: read-only — systemctl --user is-enabled/is-active on the
#   <engine>-compose units, env_val of the canon, ls of the adapters dir;
#   prints nothing to stdout (the result is a single echoed line).
#
# Limitations/assumptions: requires the SELF global (dispatcher); engine
#   dirs without adapter.sh are skipped (engine_off_foreign's die protects,
#   just in case). Order: the canon first, units — by readdir.
#
# @param 1: string  # the target engine (excluded from the list)
# @stdout string   # foreign engine ids space-separated ('' — no foreign ones)
# @returns integer # 0
foreign_engines() {
  local target="${1:-}" d e out="" canon
  canon=$(env_val LCTL_ENGINE)
  if [ -n "$canon" ] && [ "$canon" != "$target" ]; then out="$canon"; fi
  for d in "$(dirname "$SELF")"/engines/*; do
    [ -d "$d" ] || continue
    e=$(basename "$d")
    [ "$e" = "$target" ] && continue
    case " $out " in *" $e "*) continue ;; esac
    [ -f "$d/adapter.sh" ] || continue
    if systemctl --user is-enabled "$e-compose.service" >/dev/null 2>&1 \
       || systemctl --user is-active "$e-compose.service" >/dev/null 2>&1; then
      out="$out $e"
    fi
  done
  echo ${out:-}
}

# Purpose: `lctl stop` (and the `off` branch without --engine) — stop the
#   ACTIVE engine: <engine>-compose units enabled/active → its honest off
#   (a foreign adapter: stop_with_marker of its marker, an explicit podman
#   stop of its container, removal of ITS units, linger off). Nothing is
#   active — "не запущено", rc 0 (called BEFORE engine resolution — works
#   on an empty machine).
#
# Side effects: for each active engine — everything cmd_off does through
#   its adapter (via engine_off_foreign in an isolating subshell).
#
# Limitations/assumptions: activity is determined ONLY by units (contract
#   1.2): a container raised by the hidden `up` without units is invisible
#   to stop — the hidden `down` exists for those. Exclusivity gives at most
#   one active engine; if several are found — off each (an honest
#   cleanup).
#
# @returns integer # 0 — stopped or nothing to stop; an off failure —
#   die (exit 1)
cmd_stop() {
  local d e found=""
  for d in "$(dirname "$SELF")"/engines/*; do
    [ -d "$d" ] || continue
    [ -f "$d/adapter.sh" ] || continue
    e=$(basename "$d")
    if systemctl --user is-enabled "$e-compose.service" >/dev/null 2>&1 \
       || systemctl --user is-active "$e-compose.service" >/dev/null 2>&1; then
      engine_off_foreign "$e" || die "не смог корректно остановить $e"
      found=1
    fi
  done
  [ -n "$found" ] || echo "не запущено (активных движков нет)"
}

# Purpose: `lctl start <engine> <profile> [--port N]` — an exclusive start,
#   the §А automat (absorbs on/use/switch/install; the engine is resolved by
#   the dispatcher):
#   1) a foreign engine is active (units/canon) → its honest off + a canon
#      reset;
#   2) the stack is not deployed (.env missing) → the §Б bootstrap phases
#      (units last — Р1);
#   3) deployed, canon == profile → render convergence (stage 8): .env +
#      the compose triple are always rendered and compared against fact;
#      running + a match — the "уже запущено — рендер совпадает" no-op;
#      running + a divergence — the files overwritten (WARN) +
#      apply_profile + recreate + wait_health 600; not running — WARN + up
#      with the new render;
#   4) deployed, canon != profile → the former use (apply_profile +
#      recreate, the disk tier is preserved);
#   5) at the end — the "активно: engine/profile (model)" status line.
#
# Side effects: by branch — see cmd_bootstrap / cmd_use / hf_up_locked /
#   cmd_autostart; converge_render — an atomic overwrite of the divergences
#   (.env + ENGINE_COMPOSE_FILES, chmod 0644 + rename) and the
#   CONV_CHANGED/CONV_LIST globals; rm -f $STACK_DIR/.env in §А-1 (a
#   foreign canon is a reproducible document, not state — the §М lesson);
#   rm -f of the marker in cmd_up/cmd_autostart.
#
# Limitations/assumptions: prof — an alias/canon (the adapter's
#   resolve_profile); an empty prof (a switch alias / on without --profile)
#   = the canon or PROFILE_DEFAULT. --port/--bind on a deployed stack are
#   mutators → die with a hint (the fix:bootstrap-guard marker; changing =
#   stop + a repeated start); --no-autostart on a deployed stack → die
#   ('start' turns autostart on; raising without it — the hidden 'lctl up').
#   The convergence inputs = the actual canon (PORT/BIND from .env, the
#   model "LCTL_MODEL env > registry field 1") — a divergence never
#   silently changes the profile/port/bind; manual edits of .env/templates
#   do not survive start (stage 8, ratified 2026-11-22: the hash-marker
#   approach was rejected). --no-recreate is NOT a mutator: the render and
#   the write happen, the LIVE stack is untouched (application — at the
#   next recreate; the reliable path is 'stop && start': 'up' may not pick
#   up an env-only drift); a repeated start without the flag after the
#   write will give "рендер совпадает" and will NOT recreate (a documented
#   gap); on a cold /§А-2 start — an honest line, on §А-4 — the honest line
#   "смена профиля всегда пересоздаёт" (its pipeline is a full apply
#   anyway). The no-op branch (step 3, running + a match) — ZERO
#   compose/systemctl calls, the files are byte-identical. Positional
#   non-flags: the first one = the profile. Locals:
#   prof/no_autostart/force/yes/mut/norecreate — flags; port_val/bind_val —
#   the --port/--bind values; mut — '0' | '1' (set by --port/--bind);
#   args — the positional-argument array; bargs — the cmd_bootstrap
#   argument array; canon — the deployed profile's canon; prev_canon — the
#   root .env canon before §А-1; f — the foreign-engine iterator; v — a
#   .env string.
#
# @param 1..N: string[] # [profile] [--port N] [--bind A] [--no-autostart]
#   [--no-recreate] [--force] [--yes]
# @returns integer     # 0 on return; refusals — the die/die-branches of the callers
cmd_start() {
  local prof="" no_autostart=0 force=0 yes=0 mut=0 norecreate=0 port_val="" bind_val=""
  local args=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --port)         [ $# -ge 2 ] || die "--port требует значение"; port_val="$2"; mut=1; shift 2 ;;
      --bind)         [ $# -ge 2 ] || die "--bind требует значение"; bind_val="$2"; mut=1; shift 2 ;;
      --no-autostart) no_autostart=1; shift ;;
      --no-recreate)  norecreate=1; shift ;;   # fix:no-recreate — stage 8: not a mutator (port/bind untouched)
      --force)        force=1; shift ;;
      --yes)          yes=1; shift ;;
      -*) die "неизвестный флаг start: $1 (доступны: --port --bind --no-autostart --no-recreate --force --yes)" ;;
      *) args+=("$1"); shift ;;
    esac
  done
  [ "${#args[@]}" -gt 0 ] && prof="${args[0]}"
  # §А-1: a foreign engine is active (units or canon) → an honest off by its
  # adapter; the canon is wiped only when it pointed at a FOREIGN engine
  # (foreign units with our own canon do not cancel the target's deployed
  # state — §А-3, the round-2 fix)
  local f prev_canon
  prev_canon=$(env_val LCTL_ENGINE)
  for f in $(foreign_engines "$ENGINE"); do
    log "активен $f — эксклюзивный старт $ENGINE: off $f"
    engine_off_foreign "$f" || die "старт прерван: не смог корректно остановить $f (два стека в автозапуске недопустимы)"
    [ "$prev_canon" != "$ENGINE" ] && rm -f "$STACK_DIR/.env"
  done
  if [ ! -f "$STACK_DIR/.env" ]; then
    # §А-2: the §Б bootstrap (units NOT here — Р1: only on a healthy stack)
    [ "$norecreate" = 1 ] && echo "--no-recreate: холодный старт — рендер и так новый (без действий)"
    local bargs=()
    [ -n "$prof" ]     && bargs+=(--profile "$prof")
    [ -n "$port_val" ] && bargs+=(--port "$port_val")
    [ -n "$bind_val" ] && bargs+=(--bind "$bind_val")
    [ "$no_autostart" = 1 ] && bargs+=(--no-autostart)
    [ "$force" = 1 ]        && bargs+=(--force)
    [ "$yes" = 1 ]          && bargs+=(--yes)
    cmd_bootstrap ${bargs[@]+"${bargs[@]}"}
    [ "$no_autostart" = 1 ] && { echo "(автозапуск не включён — '--no-autostart'; включить: lctl start)"; return 0; }
    cmd_autostart               # юниты+таймер+linger — ПОСЛЕДНИМИ (Р1)
    cmd_up                      # rm маркера + hf_up_locked + wait_health 600
  else
    # §А-3/4: the stack is deployed — the canon sets the actual port/bind (as in use)
    [ "$mut" = 1 ] && die "стек уже развёрнут; порт/bind меняет 'stop' + повторный 'start'"   # fix:bootstrap-guard
    [ "$no_autostart" = 1 ] && die "'start' — это автозапуск; поднять без него: 'lctl up'"    # fix:bootstrap-guard
    local v
    v=$(env_val LCTL_PORT); [ -n "$v" ] && PORT="$v"
    v=$(env_val LCTL_BIND); [ -n "$v" ] && BIND="$v"
    prof=$(resolve_profile "${prof:-$(cur_profile)}") || die "неизвестный профиль '$prof' (доступны: $PROFILE_LIST)"
    port_check                   # another process may have taken the port while the stack was stopped
    local canon; canon=$(cur_profile)
    if [ "$prof" != "$canon" ]; then
      # §А-4: a canon change = apply_profile + recreate (the former use; the disk tier is preserved)
      [ "$norecreate" = 1 ] && echo "--no-recreate: смена профиля всегда пересоздаёт (флаг игнорируется)"
      [ "$force" = 1 ] && LCTL_FORCE=1
      cmd_use "$prof"
    else
      # §А-3: ensure — render convergence (stage 8) always, BEFORE the
      # running check; the inputs = the actual canon (PORT/BIND are already
      # set above)
      converge_render "$prof" "${LCTL_MODEL:-$(profile_field "$prof" 1)}"   # fix:render-converge
      if [ "$(podman inspect -f '{{.State.Status}}' "$CONTAINER" 2>/dev/null)" = running ]; then
        if [ "$CONV_CHANGED" = 0 ]; then
          # after lctl stop the marker and disarmed units remain: a live
          # container (a manual podman start) stayed without autostart
          # forever — start returned earlier than cmd_autostart
          # (live 2026-11-24)
          [ -f "$STOP_MARKER" ] && cmd_autostart   # fix:autostart-heal
          echo "уже запущено: $ENGINE/$prof ($(cur_model)) — рендер совпадает"
          return 0
        fi
        warn "рендер изменился (${CONV_LIST% }) — файлы перезаписаны"
        # recreate the live stack (stage 8); --no-recreate — a WARN instead
        [ "$norecreate" = 1 ] && warn "стек не пересоздавался (--no-recreate): изменение применится при следующем recreate — надёжно: 'lctl stop && lctl start' (при живом контейнере 'up' может не подхватить env-дрифт: compose-конфиг не изменился)"   # fix:no-recreate
        if [ "$norecreate" != 1 ]; then
          engine_apply_profile "$prof" || true    # a key refusal — warn inside (rc 1), not death
          compose up -d --force-recreate 2>&1 | tail -2
          wait_health 600                          # rc≠0 → set -e, as in the cold cmd_up
        fi
      else
        if [ "$CONV_CHANGED" = 1 ]; then
          warn "рендер изменился (${CONV_LIST% }) — стек поднимется с новым рендером"
        fi
        [ "$norecreate" = 1 ] && echo "--no-recreate: старт холодный — подъём и так новым рендером"
        engine_apply_profile "$prof" || true    # the registry cfgset keys BEFORE the raise: a cold engine re-reads config.toml; fix 2026-11-25 — §А-3 did not re-apply (the render does not see config drift: registry key edits under the same profile never landed)
        cmd_up                      # rm маркера + hf_up_locked + wait_health 600
      fi
    fi
    cmd_autostart                 # units last (Р1) — the marker is removed here too
  fi
  echo "активно: $ENGINE/$(cur_profile) ($(cur_model)) — http://$BIND:$PORT"
}

# Purpose: `lctl status [--json]` — a state summary: the engine, profile,
#   autostart/watchdog, the server health, the container list; --json — the
#   same snapshot machine-readably (the engine_status_json hook, optional).
#
# Side effects: read-only and reporting to stdout — systemctl --user
#   is-enabled of the unit and the watchdog timer (absence counts as
#   "disabled"), a curl GET /health (5 s timeout, a failure → an empty
#   body), the adapter's engine_status_health/engine_status_json hook,
#   podman ps -a by the engine name. Touches no files or the stack.
#
# Limitations/assumptions: requires the PORT, UNIT_NAME, ENGINE globals
#   (dispatcher) and cur_profile (stack.sh); the adapter hooks
#   engine_status_health (required) and engine_status_json (optional: no
#   hook → the JSON mode prints the /health body as is). The flag is
#   checked only against $1 — extra arguments are silently ignored.
#   Locals: json — '0' | '1'; prof/auto/wdog — strings (auto/wdog:
#   'enabled' | 'disabled'); body — the /health body ('' — the server is
#   not responding); hline — the health line with the "health: сервер не
#   отвечает" placeholder.
#
# @param 1: '--json'    # the optional JSON-output flag (default — a text report)
# @stdout string        # a text summary or JSON — by the flag
# @returns integer      # the text mode — always 0 (the final echo); JSON — the hook's rc
cmd_status() {
  local json=0; [ "${1:-}" = "--json" ] && json=1
  local prof auto wdog body
  prof=$(cur_profile)
  auto=$(systemctl --user is-enabled "$UNIT_NAME.service" 2>/dev/null || echo disabled)
  wdog=$(systemctl --user is-enabled "$UNIT_NAME-watchdog.timer" 2>/dev/null || echo disabled)
  body=$(curl -fsS -m 5 "http://127.0.0.1:$PORT$HEALTH_PATH" 2>/dev/null || echo "")   # fix:health-path
  if [ "$json" = 1 ]; then
    if declare -F engine_status_json >/dev/null 2>&1; then
      PROFILE="$prof" AUTO="$auto" WDOG="$wdog" engine_status_json <<<"$body"
    else
      printf '%s\n' "$body"
    fi
    return
  fi
  local hline
  if declare -F engine_status_health >/dev/null 2>&1; then
    hline=$(printf '%s' "$body" | engine_status_health 2>/dev/null || echo "health: сервер не отвечает")
  else
    hline="health: сервер не отвечает"
  fi
  echo "движок: $ENGINE | профиль: $prof | автозапуск: $([ "$auto" = enabled ] && echo вкл || echo выкл) (watchdog: $([ "$wdog" = enabled ] && echo вкл || echo выкл))"
  echo "$hline"
  echo "── контейнеры ──"
  podman ps -a --filter "name=$ENGINE" --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
}

# Purpose: `lctl logs [-f] [-n N]` — the server container's logs with
#   timestamps (podman logs -t, stderr merged into stdout).
#
# Side effects: a podman logs subprocess (the last n lines of
#   ENGINE_CONTAINER to stdout); with -f — does not return (follow until a
#   signal). Touches no files or the stack.
#
# Limitations/assumptions: requires the CONTAINER global (dispatcher). The
#   flag parsing is position-independent: -f — follow; '-n' separate,
#   '-nN' or a bare number — the tail size. Locals: n — an integer line
#   count (default 80, from an argument of the [0-9]* form); follow — '' or
#   '-f'. An unknown argument → die (exit 1).
#
# @param 1..N: string[] # flags: -f (follow) | -n N | -nN | N (a tail in lines, default 80)
# @stdout string        # the last n container log lines with timestamps
# @returns integer      # the podman logs rc (with -f — the rc on the signal exit)
cmd_logs() {
  local n=80 follow="" a
  for a in "$@"; do
    case "$a" in
      -f) follow="-f" ;;
      -n) ;;
      [0-9]*) n="$a" ;;
      -n[0-9]*) n="${a#-n}" ;;
      *) die "использование: lctl logs [-f] [-n N]" ;;
    esac
  done
  podman logs $follow -t --tail "$n" "$CONTAINER" 2>&1
}

# Purpose: `lctl doctor` — diagnostics WITHOUT changes: the OS, memory, GPU
#   nodes, the RAM gate for all adapter profiles, install/state, the
#   environment (podman/render/limits.d); the engine sections (gpu-locks,
#   health) are the adapter's engine_doctor hook.
#
# Side effects: read-only and printing (stdout, warn to stderr):
#   /etc/os-release, /proc/meminfo, the presence of /dev/kfd and
#   /dev/dri/renderD*, the profile table (the RAM gate for each), .env
#   (cur_profile/cur_model), the profile state dirs, podman --version,
#   id -nG, the limits.d file ($LIMITS_FILE); then the engine_doctor hook.
#   Creates nothing, deletes nothing, calls no sudo.
#
# Limitations/assumptions: requires the STACK_DIR, STATE_BASE, LIMITS_FILE,
#   PROFILE_LIST globals (dispatcher) and warn/ram_pool_gib/profile_field/
#   cur_profile/cur_model; the adapter's engine_doctor hook. Locals:
#   have/need — whole GiB; sd — the state dir; p — the PROFILE_LIST
#   iterator.
#
# @stdout string   # text diagnostics by sections
# @returns integer # always 0 — the final echo; read failures are silenced by the "НЕТ" branches
cmd_doctor() {
  local have; have=$(ram_pool_gib)
  echo "── система ──"
  . /etc/os-release && echo "ОС: $PRETTY_NAME"
  echo "память: пул ${have} GiB (MemTotal); доступно сейчас: $(awk '/MemAvailable/{printf "%d", $2/1048576}' /proc/meminfo) GiB"
  echo "GPU: /dev/kfd $([ -e /dev/kfd ] && echo есть || echo НЕТ), /dev/dri/renderD* $(compgen -G '/dev/dri/renderD*' >/dev/null && echo есть || echo НЕТ)"
  echo "── профили (RAM-гейт) ──"
  local p
  for p in $PROFILE_LIST; do
    local need; need=$(profile_field "$p" 4)
    if [ "$have" -ge "$need" ]; then
      echo "  $p: доступен (нужно ≥${need} GiB)"
    else
      echo "  $p: НЕДОСТУПЕН (нужно ≥${need} GiB, есть ${have})"
    fi
  done
  echo "── установка ──"
  if [ -f "$STACK_DIR/.env" ]; then
    echo "стек: $STACK_DIR (движок $ENGINE, профиль $(cur_profile), модель $(cur_model))"
    local sd="$STATE_BASE/$(cur_profile)"
    if [ -d "$sd/config" ] && [ -w "$sd/config" ] && [ -d "$sd/kernel" ] && [ -w "$sd/kernel" ]; then
      echo "state: $sd (per-профиль config+kernel; disk-тир кэша — внутри config/)"
    else
      warn "state: $sd отсутствует или не записуем — пересоздай стек (lctl start)"
    fi
  else
    echo "стек: НЕ УСТАНОВЛЕН ($STACK_DIR/.env нет) — сначала 'lctl start'"
  fi
  echo "── окружение ──"
  command -v podman >/dev/null && echo "podman: $(podman --version)" || echo "podman: НЕТ (start поставит)"
  command -v podman-compose >/dev/null && echo "podman-compose: есть" || echo "podman-compose: НЕТ (start поставит)"
  id -nG | grep -qw render && echo "группа render: есть" || echo "группа render: НЕТ (start добавит, перелогин)"
  [ -f "$LIMITS_FILE" ] && echo "memlock limits: есть ($LIMITS_FILE)" || echo "memlock limits: НЕТ (start напишет, ребут)"
  if declare -F engine_doctor >/dev/null 2>&1; then engine_doctor; fi
}

# Purpose: `lctl models` — what is downloaded per set under $MODELS_BASE and
#   what each adapter profile requires; plus the set-isolation reminder.
#
# Side effects: read-only and printing to stdout: du -sh of the set dirs
#   under $MODELS_BASE (the sets are listed by the engine_model_set hook
#   over PROFILE_LIST), /proc/meminfo (ram_pool_gib), the profile table
#   (field 4 — the gate threshold). Touches no files.
#
# Limitations/assumptions: requires the MODELS_BASE, PROFILE_LIST globals
#   (dispatcher) and ram_pool_gib/profile_field/engine_model_set. Locals:
#   p — the PROFILE_LIST iterator; s — the set name; total — the du size
#   ('' when du fails); seen — the already-shown sets string (dedup);
#   have/need — whole GiB; avail — "доступен" | "НЕДОСТУПЕН …". The
#   threshold here is the same (field 4) as profile_gate's, without the
#   force bypass.
#
# @stdout string   # the set sizes + an availability line per profile + the isolation summary
# @returns integer # always 0 — the final echo; a missing dir — a normal placeholder line
cmd_models() {
  echo "── на диске (по сетам профилей, в $MODELS_BASE) ──"
  local p s total seen=" "
  for p in $PROFILE_LIST; do
    s=$(engine_model_set "$p")
    case "$seen" in *" $s "*) continue ;; esac
    seen="$seen$s "
    if [ -d "$MODELS_BASE/$s" ]; then
      total=$(du -sh "$MODELS_BASE/$s" 2>/dev/null | cut -f1)
      echo "  $s: $total"
    fi
  done
  [ -d "$MODELS_BASE" ] || echo "(каталога нет — ничего не скачано)"
  echo "── профили: доступность ──"
  local have; have=$(ram_pool_gib)
  for p in $PROFILE_LIST; do
    local need avail
    need=$(profile_field "$p" 4)
    if [ "$have" -ge "$need" ]; then avail="доступен"; else avail="НЕДОСТУПЕН (RAM: есть ${have} GiB, нужно ≥${need})"; fi
    echo "  $p → сет models/$(engine_model_set "$p") [$avail]"
  done
  echo "изоляция: монтируется только сет активного профиля — запрос с моделью"
  echo "чужого сета получит 404 (молчаливый swap невозможен)"
}

# Purpose: `lctl pull <engine> <profile>` (1.2) — prefetch a profile's model
#   set WITHOUT start/config/units: a running stack is untouched, .env is
#   not written, no units are created (the engine is resolved by the
#   dispatcher positionally). A rerun is effectively a no-op: the adapter
#   pull is idempotent (sha256 verification inside; everything is in place —
#   the set is not re-downloaded).
#
# Side effects: mkdir -p of the $MODELS_BASE base and the target set dir;
#   pull_profile_models with a MODELS_DIR=target-set env prefix (the
#   MODELS_DIR global is NOT shifted) — the image pull and downloading the
#   missing models/draft over the network; log and two summary lines to
#   stdout. .env, the engine config, containers and autostart are NOT
#   touched.
#
# Limitations/assumptions: .env is NOT required (a prefetch before the
#   first start); the RAM gate is NOT applied — downloading ≠ running,
#   capacity is assessed at start/use. Locals: p — the alias/id after the
#   adapter's resolve_profile (empty or unknown → die); target — the
#   destination set dir path.
#
# @param 1: string      # a profile alias (incl. legacy) or canonical id
# @returns integer      # always 0 on return — die (exit 1) and pull network failures terminate the process (set -e)
cmd_pull() {
  local p="${1:-}"
  [ -n "$p" ] || die "использование: lctl pull <engine> <profile>"
  [ $# -eq 1 ] || die "лишние аргументы pull: $* (использование: lctl pull <engine> <profile>)"
  p=$(resolve_profile "$p") || die "неизвестный профиль '$p' (доступны: $PROFILE_LIST)"
  # downloading ≠ running: the RAM gate is NOT applied (a backup set on a weak machine is legal)
  [ -d "$MODELS_BASE" ] || mkdir -p "$MODELS_BASE"
  local target="$MODELS_BASE/$(engine_model_set "$p")"
  mkdir -p "$target"
  log "тяну сет '$(engine_model_set "$p")' профиля $p в $target (prefetch, без старта)"
  MODELS_DIR="$target" pull_profile_models "$p"
  echo "готово: $target"
  echo "(запуск — 'lctl start $ENGINE $p')"
}

# Purpose: `lctl agent-check` — the engine's agent check; the body itself is
#   the adapter's engine_agent_check hook (optional): no hook — an honest
#   message, rc 0.
#
# Side effects: only what the hook does; without a hook — a single stdout
#   line.
#
# @returns integer # the hook's rc (or 0 without a hook)
cmd_agent_check() {
  if declare -F engine_agent_check >/dev/null 2>&1; then
    engine_agent_check
  else
    echo "агент-чек не предусмотрен адаптером ($ENGINE)"
  fi
}

# Purpose: `lctl watch [--interval N]` — the live dashboard (stage 4): bash
#   ONLY parses --interval N|--interval=N (default 2; an integer ≥1, else
#   die — the gfctl cmd_watch pattern 1:1) and execs python
#   ENGINE_WATCH_TUI with the env LCTL_WATCH_PORT/INTERVAL/CONTAINER
#   (+MODEL — display; python takes the model from the log; +ENGINE — the
#   engine name for the `lctl watch │ <engine> · <model>` header; the core
#   passes the VARIABLE, its value is not returned into the frame — R6)
#   and the optional engine_watch_env hook (the adapter hangs its own env,
#   e.g. PYTHONPATH to the core/tpl/python/watch frame). The panel is
#   engine dialect: no ENGINE_WATCH_TUI file → an honest message, rc 0
#   (the agent-check pattern; engines without a panel — until their watch
#   wave).
#
# Side effects: exec replaces the dispatcher process with the python
#   harness (from then on — everything comes from the watch frame/adapter
#   panels: /metrics, /ready, the host /proc+/sys, podman logs).
#
# Limitations/assumptions: argv is unused — python decides TUI/plain by
#   isatty itself. The LCTL_WATCH_TICKS/LCTL_WATCH_SELFCHECK env (the
#   battery seams) pass through exec unchanged. The entry-file validation
#   happens BEFORE exec: absence — a normal adapter branch, not a python
#   crash.
#
# @param 1..N: string[]     # --interval N | --interval=N (default 2 s)
# @stdout string            # all watch output — from python; without a panel —
#   a single "not provided" line
# @returns integer          # does not return — exec; argument errors: die
cmd_watch() {
  local usage="использование: lctl watch [--interval N]" interval=2
  while [ $# -gt 0 ]; do
    case "$1" in
      --interval=*) interval="${1#*=}" ;;
      --interval)   [ $# -ge 2 ] || die "$usage"; interval="$2"; shift ;;
      *)            die "watch: неизвестный аргумент '$1' — $usage" ;;
    esac
    shift
  done
  isint "$interval" || die "watch: интервал должен быть целым числом секунд, получено '$interval'"
  [ "$interval" -ge 1 ] || die "watch: интервал должен быть ≥ 1 с"
  if [ ! -f "$ENGINE_WATCH_TUI" ]; then
    echo "watch-панель не предусмотрена адаптером ($ENGINE) — точка входа $ENGINE_WATCH_TUI отсутствует"
    return 0
  fi
  if declare -F engine_watch_env >/dev/null 2>&1; then engine_watch_env; fi
  LCTL_WATCH_PORT="$PORT" LCTL_WATCH_INTERVAL="$interval" \
  LCTL_WATCH_CONTAINER="$CONTAINER" LCTL_WATCH_MODEL="$(cur_model)" \
  LCTL_WATCH_ENGINE="$ENGINE" \
    exec python3 "$ENGINE_WATCH_TUI"
}

# Purpose: `lctl uninstall` (v2) — remove the stack's machine BINDINGS: the
#   autostart units and the timer, linger, the project container and
#   network, limits.d ($LIMITS_FILE); the clone, .data/$ENGINE
#   (models/profiles/logs), the image and the symlink are NOT touched.
#   Models and the image are removed only by explicit flags.
#
# Side effects (in order): the ask confirmation (non-TTY or without --yes —
#   auto-no → "отменено", exit 0 without changes); cmd_off || true
#   (stopping the containers, the stop marker, the ~/.config/systemd/user/*
#   units removed, daemon-reload, linger off); compose down in a subshell
#   (containers + the project network; || true); sudo rm -f $LIMITS_FILE
#   (if present). Flags: --purge-models → rm -rf $MODELS_BASE (the
#   model-set base only; profiles intact); --purge-image → podman rmi of
#   the image (a failure is silenced). The final "uninstall DONE". NOT
#   touched: the $STACK_DIR clone (the git repo with the board), .data/
#   entirely (except purge-models), the ~/.local/bin/lctl symlink, podman,
#   the render group, foreign dirs.
#
# Limitations/assumptions: the $STOP_MARKER and $LOCK_FILE markers survive
#   uninstall — harmless empty files. "One installation per user" (the
#   container name, port, unit names are global). Locals purge_models/
#   purge_image — '0' | '1'. Stop/removal/down failures are hung on
#   `|| true` (uninstall runs to the end); an unprotected sudo rm terminates
#   the process via set -e. Non-interactive without --yes — a normal
#   refusal (ask auto-no).
#
# @param 1..N: string[] # flags (all optional): --purge-models | --purge-image | --yes
# @returns integer      # always 0 on return ("uninstall DONE"); a refusal at the question — exit 0
cmd_uninstall() {
  local purge_models=0 purge_image=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --purge-models) purge_models=1; shift ;;
      --purge-image)  purge_image=1; shift ;;
      --yes)          ASSUME_YES=1; shift ;;
      *) die "неизвестный флаг uninstall: $1 (доступны: --purge-models --purge-image --yes)" ;;
    esac
  done
  echo "uninstall снимет: юниты+таймер автозапуска, linger,"
  echo "контейнер и сеть проекта (compose down), limits.d $LIMITS_FILE."
  echo "ОСТАВИТ: клон $STACK_DIR (код и борд), .data/ — модели, профили, логи,"
  echo "симлинк ~/.local/bin/lctl."
  echo "Модели $MODELS_BASE: $([ "$purge_models" = 1 ] && echo 'УДАЛЯЮТСЯ (--purge-models)' || echo 'СОХРАНЯЮТСЯ (--purge-models — удалить)')"
  echo "Образ $IMAGE: $([ "$purge_image" = 1 ] && echo 'УДАЛЯЕТСЯ (--purge-image)' || echo 'остаётся (--purge-image — удалить)')"
  echo "Не трогаем: podman, группа render, чужие каталоги."
  ask "Продолжить? [y/N] " || { echo "отменено"; exit 0; }
  cmd_off || true
  ( cd "$STACK_DIR" 2>/dev/null && compose down 2>&1 | tail -2 ) || true
  if [ -f "$LIMITS_FILE" ]; then
    sudo rm -f "$LIMITS_FILE"
  fi
  if [ "$purge_models" = 1 ]; then rm -rf "$MODELS_BASE"; echo "модели удалены"; fi   # fix:uninstall-v2 (models only; profiles intact)
  if [ "$purge_image" = 1 ];  then podman rmi "$IMAGE" 2>/dev/null || true; echo "образ удалён"; fi
  echo "uninstall DONE"
}
