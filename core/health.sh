# shellcheck shell=bash
# ── health: waiting for readiness (core) ────────────────────────────────────
# The module reads PORT/CONTAINER (dispatcher); the health predicate is the
# adapter hook engine_health_ok, the early-failure pattern is the global
# ENGINE_FAIL_PATTERN (contract §2.3). Called from commands.sh
# (bootstrap/use) and autostart.sh (up).

# Purpose: wait for server readiness — poll GET /health every 5 s until the
#   adapter hook engine_health_ok accepts the response (what counts as
#   healthy is engine dialect).
#
# Side effects: stdout — a waiting log line, on success the first 300 bytes
#   of the /health body and a "HEALTHY after Ns" line, on failure the tail of
#   container logs (podman logs) to stdout; warn() to stderr; subprocesses
#   curl/engine_health_ok/podman; sleeps 5 s per iteration; does not change
#   stack state.
#
# Limitations/assumptions: requires the globals PORT, CONTAINER, HEALTH_PATH
#   (mirror of the adapter's ENGINE_HEALTH_PATH, default /health — the health
#   endpoint path of the engine dialect; fix:health-path task 3.1 §2.1),
#   ENGINE_FAIL_PATTERN (adapter) and the engine_health_ok hook. Locals t/i
#   on one line: t — timeout in whole seconds (900 by default when the
#   argument is omitted), i — elapsed seconds (multiple of 5). The early
#   exit on ENGINE_FAIL_PATTERN in the logs only fires after 120 s of
#   waiting — a shorter timeout merely disables that check.
#
# @param 1: integer  # timeout in seconds (optional, default 900; live calls: 600/900)
# @returns integer   # 0 — ready; 1 — early engine failure or timeout
wait_health() {
  local t="${1:-900}" i=0
  log "жду готовности (до ${t}с)"
  while [ "$i" -lt "$t" ]; do
    local body="" ready=0
    body=$(curl -fsS -m 5 "http://127.0.0.1:$PORT$HEALTH_PATH" 2>/dev/null) && ready=1 || ready=0   # fix:health-path
    if [ "$ready" = 1 ] && printf '%s' "$body" | engine_health_ok 2>/dev/null; then
      printf '%s\n' "$body" | head -c 300; echo
      echo "HEALTHY после ${i}с"
      return 0
    fi
    sleep 5; i=$((i+5))
    # fix:failpattern-pipe: grep -q under set -o pipefail killed podman with
    #   SIGPIPE (an early match closes the pipe) — the scan silently never
    #   worked; grep WITHOUT -q reads the stream to the end, podman exits 0
    if [ "$i" -ge 120 ] && podman logs --since 10m "$CONTAINER" 2>&1 | grep -E "$ENGINE_FAIL_PATTERN" >/dev/null 2>&1; then
      warn "ранний отказ в логах (паттерн '$ENGINE_FAIL_PATTERN') — ранний выход, последние логи:"
      podman logs --tail 25 "$CONTAINER" 2>&1 | tail -25 || true
      return 1
    fi
  done
  warn "не здоров через ${t}с — последние логи:"
  podman logs --tail 30 "$CONTAINER" 2>&1 | tail -30 || true
  return 1
}
