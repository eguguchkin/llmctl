# shellcheck shell=bash
# ── the halogen adapter: globals (the adapter-contract §Глобалы contract) + glue ──
# The dispatcher sources ONLY this file (engine_load); the adapter's parts —
# profiles.sh (the 9-field registry), models.sh (pins/delivery),
# stack_files.sh (the compose golden with the env config), health.sh (the
# /health dialect + the smoke) — are included here. The halogen-flash-server
# engine: closed-source, a deploy surface (the
# ghcr.io/peonist-ai/halogen-flash-server image), exactly flash-next on
# gfx1151; the engine has no 27b — a single profile (flash), the engine
# config is env-ONLY (no CLI), so the adapter has no serve line (the
# registry's field 9 = '-', the golden render assembles the env literals
# from fields 6/7/8 + the set's table).

ENGINE=halogen
ADAPTER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# @type /^[\w./:-]+$/ ENGINE_IMAGE — the version pin: the image tag = ENGINE_VERSION
ENGINE_VERSION=0.21.0                          # the ghcr tag (bumped 0.20.7→0.21.0 on 2026-11-27; the 0.20.7 facts: the concurrency mode default, drafter-r2-ht4 — to be re-verified live); the bench report name
ENGINE_IMAGE="${LCTL_IMAGE:-ghcr.io/peonist-ai/halogen-flash-server:${ENGINE_VERSION}}"
ENGINE_PORT_DEFAULT=11435                      # the Round 6 «единый порт» — as gufo/hipfire: a LAN client keeps one base_url across switch
ENGINE_CONTAINER=halogen_halogen_1             # <project>_<service>_<n> podman-compose (the halogen project, the halogen service)
ENGINE_POD=pod_halogen                         # the pristine check (with --in-pod false no pod is created — the gufo parity)
ENGINE_PROJECT=halogen                         # the `name: halogen` pin in the golden (exclusive with the other engines)
ENGINE_COMPOSE_FILES=( -f compose.yml )        # one file — rendered by engine_write_compose
# A single-service stack as gufo: podman-compose 1.5 wraps the service in a
# pod, and podman considers `--pod` with `--userns=keep-id` incompatible
# (EXP-002) — the same global as gufo's (fix:in-pod).
ENGINE_COMPOSE_EXTRA_ARGS=( --in-pod false )
ENGINE_ENV_TEMPLATE="$ADAPTER_DIR/tpl/env/env.tpl"   # the root .env template (the §4 canon)
ENGINE_WATCH_TUI="$ADAPTER_DIR/py/watch.py"   # (Ф3b) the watch python panel on the watch_frame frame
ENGINE_MEMLOCK=1318060032                      # the same GPU-memlock limit as gufo/hipfire (ROCm/KFD, the core's limits.d)
# To verify by the first window (the Ф2 plan 2026-11-25): Window Ф2
# (2026-11-26): «out of memory» is a FALSE POSITIVE: a normal start line of
# oom_score_adj contains «if the host runs out of memory». The engine
# shrinks the pool itself (KV_POOL_FIT), the fatal dialect is refuse/fatal.
ENGINE_FAIL_PATTERN="fatal|refusing"
ENGINE_HEALTH_PATH=/health                     # halogen has /health (the core default; set for explicitness for the statuses)
# The smoke reasoning-contract dialect (the core takes
# ${ENGINE_SMOKE_REASONING:-off}): halogen's reasoning_effort values =
# high|low|max|medium|minimal|none|xhigh — «off» is invalid (a 400 on every
# smoke request; caught by window Ф2), «none» = no thinking.
ENGINE_SMOKE_REASONING=none

# The API model canon (the canon-ID contract of 2026-11-25: switching
# engines without re-tuning the agent). halogen renders it into
# HALOGEN_MODEL_ID («echoed in every completion» — docs/api.md); the
# smoke/bench take it from here too.
HALOGEN_MODEL_CANON="qwen3.8-flash-next"

# Purpose: the profile's model set dir name — isolation from the gufo-flash
#   gguf set (the same .hgn names do not collide, but we do not mix sets:
#   the server mounts only its own dir). An underscore, not a hyphen: the
#   set name is an indirect name of the bash pin table (set_<сет>,
#   weights_for).
#
# @param 1: string        # the profile id (unknown → the halogen_flash set)
# @stdout weight_set      # the subdir name under $MODELS_BASE
engine_model_set() {
  case "$1" in
    27b) echo halogen_27b ;;
    *)   echo halogen_flash ;;
  esac
}

# Purpose: the API model canon of a profile (HALOGEN_MODEL_ID in the
#   compose render, the smoke's model argument, engine_bench_model, the
#   route-line default): P_MODEL_ID from the profile file (the adapter
#   dialect field, 10+), the flash fallback = HALOGEN_MODEL_CANON (the
#   pre-27b constant; flash.env does not duplicate it).
#
# @param 1: string    # the profile id (optional; default — cur_profile,
#                     # outside a stack — flash)
# @stdout string      # the model id the engine serves/echoes
# @returns integer    # always 0
model_id_canon() {
  local prof="${1:-$(cur_profile 2>/dev/null || echo flash)}" c=""
  c=$( { profile_src "$prof" 2>/dev/null; printf '%s' "${P_MODEL_ID:-}"; } ) || true
  printf '%s' "${c:-$HALOGEN_MODEL_CANON}"
}

source "$ADAPTER_DIR/profiles.sh"      # the 9-field table + aliases + ref_get + ladders
source "$ADAPTER_DIR/models.sh"        # the pin tables + download_file + engine_pull_model
source "$ADAPTER_DIR/stack_files.sh"   # engine_write_compose (the golden's env render)
source "$ADAPTER_DIR/health.sh"        # engine_health_ok/engine_smoke/engine_check_route/engine_status_*
source "$ADAPTER_DIR/doctor.sh"        # engine_doctor (the inventory/.hgn types honestly/the prompt cache/the gpu-lock)
source "$ADAPTER_DIR/bench.sh"         # engine_bench_model (the canon) + engine_bench_extras (a /metrics snapshot)

source "$ADAPTER_DIR/agentcheck.sh"     # cmp_ref + engine_agent_check (Ф3c)

# Purpose: the env add-on for cmd_watch (the core execs ENGINE_WATCH_TUI):
#   the halogen panel imports the core/py/watch frame — its path
#   into PYTHONPATH (the panel does not know where the core is; cmd_watch
#   knows CORE_TPL).
engine_watch_env() { PYTHONPATH="${PYTHONPATH:+$PYTHONPATH:}$CORE_PY/watch"; export PYTHONPATH; }
