# shellcheck shell=bash
# ── the hipfire adapter: globals (contract §2.1 task 1.1) + glue ─────────────
# The dispatcher sources ONLY this file (engine_load); the adapter's other
# parts — profiles.sh (the registry), stack_files.sh (engine_write_compose),
# engine.sh (the engine config), health.sh (the health dialect), models.sh
# (the pull), doctor.sh (engine_doctor), bench.sh (the stage-7 bench hook) —
# are included here. Assembled from the legacy pieces WITHOUT edits to the core
# bodies (the R6 boundary criterion).

ENGINE=hipfire
ADAPTER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# @type /^[\w./-]+:[\w.-]+$/ ENGINE_IMAGE="ghcr.io/warpfront/hipfire:0.4.7"  # a tagged ghcr image; the override — the env LCTL_IMAGE
ENGINE_IMAGE="${LCTL_IMAGE:-ghcr.io/warpfront/hipfire:0.4.7}"
ENGINE_VERSION=0.4.7                           # the BUILD version (= the pin; the bench report name, stage 7; verifying the fact — a live-window EXP)
ENGINE_PORT_DEFAULT=11435                     # the PORT default before reading the canon
ENGINE_CONTAINER=hipfire_hipfire_1            # the server container <project>_<service>_<n>
ENGINE_POD=pod_hipfire                        # the project pod (the pristine check)
ENGINE_PROJECT=hipfire                        # the compose-project name (the label from the golden's name:)
ENGINE_COMPOSE_FILES=( -f compose.yml -f compose.halo.yml -f compose.local.yml )   # the -f triple for compose()
ENGINE_ENV_TEMPLATE="$ADAPTER_DIR/tpl/env/env.tpl"   # the root .env template (the §4 canon)
ENGINE_MEMLOCK=1318060032                     # the limits.d value (the engine's fit)
ENGINE_FAIL_PATTERN="pre-warm failed"         # the early-failure grep -E pattern for wait_health
ENGINE_WATCH_TUI="$ADAPTER_DIR/py/watch_tui.py"   # (wave 4) the watch python panel

# engine constants (the core does not know them)
# IMPORTANT: models is mounted into the container at /home/hipfire/.hipfire/models —
# HIPFIRE_DFLASH_DRAFT is given as a CONTAINER path, not a host one.
DRAFT_FILE="/home/hipfire/.hipfire/models/qwen38-27b-dflash-mq4.hfq"
# @type /^[0-9]+$/ SLOTS="${LCTL_SLOTS:-2}"  # the 27b-parallel profile's multi_slot
#   slots; the override — the env LCTL_SLOTS. The domain is not enforced in
#   code (the admission is on the hipfire serve.multi_slot_slots side); live:
#   2 = the canon, 4 = the RAM regression case (2026-11). 3 was never used.
SLOTS="${LCTL_SLOTS:-2}"
MAX_SEQ=262144

# Purpose: the profile's model set dir name — profile isolation: the server
#   mounts only its own set (a foreign model → 404, not a silent swap).
#   (a port from the legacy state.sh model_set)
#
# @param 1: string       # the profile id (unknown → the 27b set)
# @stdout '27b' | 'flash' # the set subdir name under $MODELS_BASE
engine_model_set() { case "$1" in flash) echo flash ;; *) echo 27b ;; esac; }

# Purpose: the env add-on for cmd_watch (the core execs ENGINE_WATCH_TUI):
#   1) PYTHONPATH — the hipfire python panel imports the core/py/
#   watch frame (the panel does not know where the core is; cmd_watch knows
#   CORE_TPL);
#   2) the cache budgets' env seam (W3.2.1 p.5, layout §1 «… (бюджет)»):
#   session_cache_bytes/session_cache_disk_bytes are read from the profile's
#   CONFIG ($STACK_DIR/$HIPFIRE_STATE_DIR/config/config.toml — the same file
#   engine_apply_profile/cfgset writes; .env does not contain the budgets —
#   recon-cache-sources), the session-cache dir = config/session-cache (the
#   container's HIPFIRE_HOME — a bind of the same config dir, compose.yml).
#   No .env/key → empty → the panel honestly «—» (0 = a disabled cache —
#   likewise). The LCTL_WATCH_HIPFIRE_* names are adapter dialect, the frame
#   does not know them (R6).
engine_watch_env() {
  PYTHONPATH="${PYTHONPATH:+$PYTHONPATH:}$CORE_PY/watch"; export PYTHONPATH
  local cfg_dir="$STACK_DIR/$(env_val HIPFIRE_STATE_DIR)/config" ram_b disk_b
  ram_b=$(sed -n 's/^[[:space:]]*session_cache_bytes[[:space:]]*=[[:space:]]*//p' \
    "$cfg_dir/config.toml" 2>/dev/null | tail -n 1 || true)
  disk_b=$(sed -n 's/^[[:space:]]*session_cache_disk_bytes[[:space:]]*=[[:space:]]*//p' \
    "$cfg_dir/config.toml" 2>/dev/null | tail -n 1 || true)
  export LCTL_WATCH_HIPFIRE_CACHE_RAM="$ram_b" \
         LCTL_WATCH_HIPFIRE_CACHE_DISK="$disk_b" \
         LCTL_WATCH_HIPFIRE_CACHE_DIR="$cfg_dir/session-cache"
}

source "$ADAPTER_DIR/profiles.sh"      # the profile table + resolve_profile (the aliases)
source "$ADAPTER_DIR/stack_files.sh"   # engine_write_compose (the goldens + local.yml)
source "$ADAPTER_DIR/engine.sh"        # cfgset + engine_apply_profile
source "$ADAPTER_DIR/health.sh"        # engine_health_ok/engine_smoke/route/engine_status_*
source "$ADAPTER_DIR/models.sh"        # engine_pull_model
source "$ADAPTER_DIR/doctor.sh"        # engine_doctor (the gpu-locks + health)
source "$ADAPTER_DIR/bench.sh"         # engine_bench_extras (stage 7)
