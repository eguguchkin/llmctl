# shellcheck shell=bash
# ── hipfire: the doctor engine sections (the gpu-locks + health) ────────────
# The engine_doctor hook (contract §2.3) — extra `lctl doctor` sections on
# top of the core parts (system/profiles/install/environment — the core).
# A port from the legacy cmd_doctor (the gpu-lock and health sections).

# Purpose: the engine diagnostic sections: the project's gpu-locks
#   (/run/lock/hipfire — exclusive: a foreign holder = a start refusal)
#   and the live health.
#
# Side effects: reads and prints only (stdout, warns to stderr): fuser over
#   /run/lock/$ENGINE/gpu-pci-*.lock, a curl GET /health (the first 200
#   bytes). Creates nothing, deletes nothing, calls no sudo.
#
# Limitations/assumptions: requires the ENGINE, PORT globals (dispatcher)
#   and warn. A foreign gpu-lock holder — a warning (a second serve will
#   not start), not a return error.
#
# @stdout string   # the «gpu-lock» lines and «── health ──» sections
# @returns integer # always 0 — read refusals silenced by the «НЕТ» branches
engine_doctor() {
  local lockdir="/run/lock/$ENGINE" f
  if [ -d "$lockdir" ]; then
    for f in "$lockdir"/gpu-pci-*.lock; do
      [ -e "$f" ] || continue
      if fuser -v "$f" 2>&1 | grep -q hipfire; then
        warn "gpu-lock занят: $f ($(fuser -v "$f" 2>&1 | tail -1)) — второй serve не стартует"
      else
        echo "gpu-lock: свободен ($f)"
      fi
    done
  fi
  echo "── health ──"
  curl -fsS -m 5 "http://127.0.0.1:$PORT/health" 2>/dev/null | head -c 200 || echo "(сервер не отвечает)"
  echo
}
