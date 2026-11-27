# shellcheck shell=bash
# ── halogen: agent-check (Ф3c; a mirror of engines/gufo/agentcheck.sh @ 92b9dcc:
#    the dialect points — parse_route from /health (not from the log:
#    halogen has no load_completed), the reuse verdict by cache_n (the
#    component_cache.reuse field is absent from halogen's response body),
#    the cacheverify* modes not carried over — `lctl cache` does not exist) ─
# The engine_agent_check hook: 4 comparisons on 25 deterministic
# POST /v1/chat/completions: (а) a session of 15 turns — the total wall;
# (б) the 5k/25k/100k follow-up ladder — the turn2 wall; (в) [док
# 25k][q1]→[q2] — the q2 wall; (г) the restart-restore — a run of the same
# conversation AFTER a recreate (the HALOGEN_CACHE_DIR disk tier). The
# HTTP/math — tpl/python/agent_check.py (the env LCTL_AGENT_STATE/
# LCTL_SMOKE_RETRY_S), the orchestration/references/rc — here. The
# comparison — the PURE cmp_ref function (±25% → a WARN); an untaken
# reference — a WARN «эталон не снят», NOT a FAIL. rc: 0 on all-PASS and on
# WARNs, 1 on FAIL; a structural failure — die before the summary.

# Purpose: a PURE comparison of a measurement against a reference — a
#   verdict line to stdout: an empty ref → «WARN: <метка> X.Xs — референс
#   не снят (EXP-007)»; measured ≤ ref×1.25 → «PASS: …»; otherwise
#   «WARN: … регрессия >25%» + a hint. A 1:1 gufo cmp_ref port.
#
# @param 1: string          # the check label (into the verdict line)
# @param 2: string          # measured, seconds (a number from python)
# @param 3: string          # the reference, seconds ('' = not taken)
# @param 4: string          # (opt.) the cause hint at the WARN-regression tail
# @stdout string            # «PASS: …» | «WARN: …»
# @returns integer          # always 0 — a pure function
cmp_ref() {
  local label="$1" measured="$2" ref="$3" hint="${4:-}" mf rf
  mf=$(awk -v m="$measured" 'BEGIN{printf "%.1f", m}')
  if [ -z "$ref" ]; then
    printf 'WARN: %s %ss — референс не снят (EXP-007)\n' "$label" "$mf"
    return 0
  fi
  rf=$(awk -v r="$ref" 'BEGIN{printf "%.1f", r}')
  if awk -v m="$measured" -v r="$ref" 'BEGIN{exit !(m <= r * 1.25)}'; then
    printf 'PASS: %s %ss (референс %ss)\n' "$label" "$mf" "$rf"
  else
    printf 'WARN: %s %ss — регрессия >25%% к %ss%s\n' \
      "$label" "$mf" "$rf" "${hint:+ ($hint)}"
  fi
  return 0
}

# Purpose: a TCP probe of the server port — 0 when something listens on
#   127.0.0.1:$1. A 1:1 gufo port_open port (a loopback probe,
#   «listening/not listening», not a health check).
#
# @param 1: /^[0-9]+$/       # the port
# @returns integer           # 0 — the connection established; 1 — refused/timeout
port_open() {
  local p="${1:-$PORT}"
  timeout 2 bash -c "exec 3<>/dev/tcp/127.0.0.1/$p" 2>/dev/null
}

# Purpose: the engine_agent_check hook (`lctl agent-check`): the gates (the
#   container running → the port listening → the route from /health) → a
#   restart warn → python stage1 (24 requests) → cmp_ref over the CHECK
#   lines → the restart-restore (`compose up -d --force-recreate` — the
#   core's ONLY raise path: a restart restores the current profile's canon)
#   → wait_health 180 → python stage2 (the restore turn, 1 request) →
#   cmp_ref + the cache_n verdict → the summary «AGENT-CHECK: PASS=N WARN=M
#   FAIL=K». rc: 0 at FAIL=0, 1 on FAIL; a structural failure — die before
#   the summary.
#
# Side effects: 25 http generation requests; mkdir $LOG_DIR; writing and
#   removing agent-check-restore.json; a compose recreate (KILLS active
#   sessions — a warn before the recreate); the ROUTE_* globals.
#
# Limitations/assumptions: requires parse_route (health.sh: the /health
#   JSON, ROUTE_MODEL — the canon constant), ref_get (the registry),
#   cmp_ref/port_open (above), wait_health (the core), compose (the core);
#   the timings are not asserted (machine-dependent) — only the verdict
#   lines; the state file — the env LCTL_AGENT_STATE (the halogen copy of
#   agent_check.py). The cache_n verdict: after a recreate the RAM cache is
#   empty → cache_n>0 is only possible from the disk tier.
#
# @returns integer   # not always — exit 1 on FAIL; die on a structure
engine_agent_check() {
  local st
  st=$(podman inspect -f '{{.State.Status}}' "$CONTAINER" 2>/dev/null || echo missing)
  [ "$st" = running ] || die "контейнер $CONTAINER не запущен (state=$st) — подними: lctl start"
  port_open "$PORT" || die "порт $PORT мёртв — подними сервер: lctl start"
  parse_route < <(curl -fsS -m 5 "http://127.0.0.1:$PORT/health" 2>/dev/null)
  [ -n "$ROUTE_MODEL" ] || die "модель не определена (ROUTE_MODEL пуст) — проверь HALOGEN_MODEL_ID канона"
  local prof; prof=$(cur_profile)
  warn "agent-check: рестарт-restore ПЕРЕЗАПУСКАЕТ контейнер — активные сессии сервера будут потеряны (рестарт поднимает канон профиля $prof)"
  mkdir -p "$LOG_DIR"
  local port out p=0 w=0 f=0 v session_w k5 k25 k100 docq_w restore_w cachen state
  state="$LOG_DIR/agent-check-restore.json"
  port="$PORT"
  echo "== lctl agent-check — профиль $prof, модель $ROUTE_MODEL (25 запросов, SPEC §7)"
  out=$(LCTL_AGENT_STATE="$state" python3 "$ADAPTER_DIR/tpl/python/agent_check.py" stage1 "$port" "$ROUTE_MODEL") \
    || die "agent-check: stage1 структурно не прошёл (транспорт/timings/JSON — причина в stderr выше)"
  printf '%s\n' "$out"
  session_w=$(grep '^CHECK session ' <<<"$out" | grep -oE 'total=[0-9.]+' | head -n1 | cut -d= -f2-) || true
  k5=$(grep '^CHECK followup ' <<<"$out" | grep -oE 'k5=[0-9.]+' | cut -d= -f2-) || true
  k25=$(grep '^CHECK followup ' <<<"$out" | grep -oE 'k25=[0-9.]+' | cut -d= -f2-) || true
  k100=$(grep '^CHECK followup ' <<<"$out" | grep -oE 'k100=[0-9.]+' | cut -d= -f2-) || true
  docq_w=$(grep '^CHECK docq ' <<<"$out" | grep -oE 'q2=[0-9.]+' | head -n1 | cut -d= -f2-) || true
  [ -n "$session_w" ] && [ -n "$k25" ] && [ -n "$k100" ] && [ -n "$docq_w" ] \
    || die "agent-check: в выводе stage1 нет ожидаемых CHECK-строк (session/followup/docq) — контракт python нарушен"
  v=$(cmp_ref "сессия 15 ходов" "$session_w" "$(ref_get "$prof" session)"); printf '%s\n' "$v"
  case "$v" in PASS*) p=$((p + 1)) ;; *) w=$((w + 1)) ;; esac
  echo "follow-up 5k: ${k5}s | follow-up 100k: ${k100}s (без сравнения — референс только у 25k)"
  v=$(cmp_ref "follow-up 25k" "$k25" "$(ref_get "$prof" followup)" "проверь кэш-поля канона (RAM+диск)"); printf '%s\n' "$v"
  case "$v" in PASS*) p=$((p + 1)) ;; *) w=$((w + 1)) ;; esac
  v=$(cmp_ref "[док 25k] q2" "$docq_w" "$(ref_get "$prof" docq)"); printf '%s\n' "$v"
  case "$v" in PASS*) p=$((p + 1)) ;; *) w=$((w + 1)) ;; esac
  echo "рестарт контейнера (restore проверяет disk-тир HALOGEN_CACHE_DIR; канон профиля $prof)…"
  compose up -d --force-recreate 2>&1 | tail -2
  wait_health 180
  out=$(LCTL_AGENT_STATE="$state" python3 "$ADAPTER_DIR/tpl/python/agent_check.py" stage2 "$port" "$ROUTE_MODEL") \
    || die "agent-check: stage2 (restore-ход) структурно не прошёл — причина в stderr выше"
  printf '%s\n' "$out"
  rm -f "$state"
  restore_w=$(grep '^CHECK restore ' <<<"$out" | grep -oE 'turn2=[0-9.]+' | head -n1 | cut -d= -f2-) || true
  cachen=$(grep '^CHECK restore ' <<<"$out" | grep -oE 'cache_n=[0-9]+' | head -n1 | cut -d= -f2-) || true
  [ -n "$restore_w" ] || die "agent-check: в выводе stage2 нет CHECK restore — контракт python нарушен"
  v=$(cmp_ref "рестарт-restore" "$restore_w" "$(ref_get "$prof" restore)" "проверь HALOGEN_CACHE_DIR"); printf '%s\n' "$v"
  case "$v" in PASS*) p=$((p + 1)) ;; *) w=$((w + 1)) ;; esac
  case "${cachen:-0}" in
    0) printf 'FAIL: disk-restore не сработал (cache_n=0) — проверь HALOGEN_CACHE_DIR канона профиля\n'; f=$((f + 1)) ;;
    *) echo "restore: cache_n=$cachen — disk-restore работает (RAM пуста после recreate — хит только из disk-тира)" ;;
  esac
  printf 'AGENT-CHECK: PASS=%s WARN=%s FAIL=%s\n' "$p" "$w" "$f"
  if [ "$f" -gt 0 ]; then exit 1; fi
}
