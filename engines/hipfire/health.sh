# shellcheck shell=bash
# ── hipfire: the health dialect (the smoke, the actual route, the status lines) ──
# The healthy-/health predicate, the smoke dialect, the route predicates
# (the engine log texts: fn-lanes staged/refused, spec) and the status
# lines — all engine-owned (contract §2.3 task 1.1). A port from the hfctl
# lib/health.sh.

# Purpose: the «server healthy» predicate over the GET /health body (stdin):
#   status ok, a non-empty model, loading_model unset. (a port of
#   health.sh:30 + health_ok.py)
#
# Side effects: a python3 subprocess; changes nothing.
#
# @stdin string    # the /health body
# @returns integer # 0 — healthy; 1 — not JSON or not healthy
engine_health_ok() { python3 "$ADAPTER_DIR/tpl/python/health_ok.py"; }

# Purpose: the health line for `lctl status` — a human-readable summary of
#   the status/model/mode. (a port of status_hline.py)
#
# @stdin string    # the /health body ('' — the server not answering)
# @stdout string   # one line «health: … | модель: … | режим: …»
# @returns integer # python3's rc
engine_status_health() { python3 "$ADAPTER_DIR/tpl/python/status_hline.py"; }

# Purpose: the machine-readable status for `lctl status --json`; the core
#   passes the PROFILE/AUTO/WDOG env. (a port of status_json.py)
#
# @stdin string    # the /health body ('' → health: null)
# @stdout string   # a JSON object
# @returns integer # python3's rc
engine_status_json() { python3 "$ADAPTER_DIR/tpl/python/status_json.py"; }

# Purpose: the smoke check of a live server — delegated to the core's
#   core_smoke (audit-fix: the header described the pre-w42 hfctl smoke —
#   2 requests, the local validator; fix:w42-smoke-core made the hook
#   thin). The dialect — only the model: the canon from .env (LCTL_MODEL >
#   field 1, fix:env-model: the canon is accepted by the served-model-name
#   aliases, no need to read the log) + the vision gate (the set's vision
#   tower on disk).
#
# Side effects: up to 12 real generation requests to the model on
#   127.0.0.1:$PORT (5 core_smoke requests × the single retry, with its
#   LCTL_SMOKE_RETRY_S sleep and its smoke_resp.py validator); stdout —
#   the «ответ: …» lines and «SMOKE: OK»; warns to stderr on retries; on a
#   failure — a FATAL die() line to stderr. Touches no files or config.
#
# Limitations/assumptions: no parameters; requires the PORT and log/warn/
#   die/cur_model globals (dispatcher/core) + core_smoke (the core). The
#   callers — cmd_bootstrap (after wait_health 900) and cmd_use (after
#   wait_health 600), both interactive. A failure — die(): the process
#   terminates with code 1.
#
# @returns integer # always 0 on return — a failure terminates the process via die() (exit 1)
# @stderr string   # a warn line per each first failed attempt; a FATAL on the final failure
engine_smoke() {
  # fix:w42-smoke-core — the requests/validation/retries moved into the
  #   frame's core_smoke (5 requests: 3 texts + a stream + tools; the
  #   frame prints «SMOKE: OK»); the dialect left is one — the model: the
  #   canon from .env (LCTL_MODEL > field 1, fix:env-model: the canon is
  #   accepted by the served-model-name aliases, no need to read the log).
  # fix:w43-smoke-vision — the 6th request (a photo) only when the set's
  #   vision tower is really on disk (the registry declares
  #   qwen3.8-27b-vision.hfq for all the qwen3.8:27b* tiers and the pull
  #   fetches it itself; the text tiers (flash) have no file — the smoke
  #   does not pay for the vision).
  local vision=""
  if ls "$MODELS_DIR"/*vision.hfq >/dev/null 2>&1; then vision=1; fi
  core_smoke "$(cur_model)" "$vision"
}

# Purpose: one snapshot of the actual route (the engine's «фактический
#   роут»): reads the container log fully, streaming, and extracts the
#   engine predicates (lanes staged / lanes refused / spec) + the health
#   slots mode.
#
# Side effects: podman logs subprocesses (THE FULL LOG, stderr merged into
#   stdout; three streaming passes — staged/refused/spec), a curl GET
#   /health (5 s) + python3 health_mode.py; WRITES the
#   ROUTE_STAGED/ROUTE_REFUSED/ROUTE_SPEC/ROUTE_HEALTH globals; prints
#   nothing to stdout.
#
# Limitations/assumptions: requires the CONTAINER, PORT globals
#   (dispatcher). The globals (strings; '' = no match; ROUTE_HEALTH on an
#   unavailable/unrecognized /health = '?'): ROUTE_STAGED — the last
#   staged match, ZEROED when refused stands lower (a fresh refusal on a
#   restarted container overrides the accepted staged — the route = a
#   refusal); ROUTE_REFUSED/ROUTE_SPEC — the last pattern match (tail -1).
#   The positions are compared by the grep -n line numbers (the «NN:»
#   prefix, stripped by «${s#*:}»/«${s%%:*}»). The grep patterns are the
#   accepted engine seams (the engine texts are edited here, not
#   «patched»). The «|| true» at grep is mandatory under set -e+pipefail:
#   no match is normal.
#
# @returns integer # always 0 — refusals silenced; empty snapshot fields are normal
route_snapshot() {
  # shortcut: a full streaming pass of the log per predicate (~0.4 s per
  # 7k lines of a live machine), the limit — a very long-lived container
  # with a big log; the upgrade when it hurts: a --since window from the
  # container start or a route field in /health.
  local staged refused
  staged=$(podman logs "$CONTAINER" 2>&1 \
    | grep -noE "fn-lanes staged: topology=[a-z]+ lanes=[0-9]+[^\"]*spec=[a-z0-9]+" | tail -1) || true
  refused=$(podman logs "$CONTAINER" 2>&1 \
    | grep -noE "qwen4 lanes refused:[^-—]*" | tail -1) || true
  ROUTE_STAGED=${staged#*:}
  ROUTE_REFUSED=${refused#*:}
  # «who said it last»: a fresh refusal lower than the accepted staged clears the lanes
  if [ -n "$ROUTE_STAGED" ] && [ -n "$ROUTE_REFUSED" ] && \
     [ "${staged%%:*}" -lt "${refused%%:*}" ]; then ROUTE_STAGED=; fi
  ROUTE_SPEC=$(podman logs "$CONTAINER" 2>&1 \
    | grep -oE "spec: [a-z0-9 ]+" | tail -1 | head -c 60) || true
  ROUTE_HEALTH=$(curl -fsS -m 5 "http://127.0.0.1:$PORT/health" 2>/dev/null \
    | python3 "$ADAPTER_DIR/tpl/python/health_mode.py" 2>/dev/null || echo '?')
  return 0
}

# Purpose: show the profile's actual route: the engine may politely
#   degrade (vmm lanes refused → serial) — we show the reality. The
#   sources — the common route_snapshot snapshot (the logs are
#   authoritative, /health for the slots).
#
# Side effects: via route_snapshot — podman logs / curl / python3;
#   stdout — the route line («lanes: …», «роут: multi_slot (…)» or
#   «роут: singleton+DFlash (…)»); a warn() to stderr on a lanes refusal.
#   Changes nothing.
#
# Limitations/assumptions: requires warn (the dispatcher) and this file's
#   route_snapshot. The mismatch priority is decided by the snapshot:
#   ROUTE_STAGED is already cleared there by a fresh refusal, then
#   staged → refused → «данных нет». Best-effort by design: empty snapshot
#   fields are normal branches; an unknown prof falls into the case's
#   default branch (singleton+DFlash). The output texts are a contract —
#   do not change.
#
# @param 1: string   # the canonical profile id (unknown → the singleton branch)
# @returns integer  # always 0 — informational printing, the search refusals silenced
engine_check_route() {
  local prof="$1"
  route_snapshot
  case "$prof" in
    flash)
      if [ -n "$ROUTE_STAGED" ]; then
        echo "lanes: $ROUTE_STAGED"
        echo "      → настоящий батчинг принят (запросы делят trunk-шаг)"
      elif [ -n "$ROUTE_REFUSED" ]; then
        warn "vmm lanes ОТКАЗАНЫ: $ROUTE_REFUSED — сервер работает serial (fallback)"
        warn "тексты eligible-запросов всё равно исполняются корректно (singleton)"
      else
        echo "lanes: данных нет (ни staged, ни refused в логах) — проверь 'lctl logs'"
      fi
      ;;
    27b-parallel) echo "роут: multi_slot ($ROUTE_HEALTH)" ;;
    *)          echo "роут: singleton+DFlash ($ROUTE_SPEC)" ;;
  esac
}
