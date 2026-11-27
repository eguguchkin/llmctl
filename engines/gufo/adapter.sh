# shellcheck shell=bash
# ── the gufo adapter: globals (contract §2.1 task 1.1 + «stage-3 Additions») + glue ──
# The dispatcher sources ONLY this file (engine_load); the adapter's parts —
# profiles.sh (the 9-field registry), models.sh (pins/delivery),
# stack_files.sh (the compose goldens + serve_args), engine.sh (canon.env +
# probe + apply_profile), health.sh (the /ready dialect + load_completed),
# doctor.sh, agentcheck.sh, bench.sh (the stage-7 bench hooks) — are
# included here. Assembled from gfctl pieces @ 462573f WITHOUT edits to the
# core bodies (the R6 boundary criterion; the core edits are exactly the
# K-wave of task 3.1 §2).

ENGINE=gufo
ADAPTER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# @type /^[\w./:-]+$/ ENGINE_IMAGE — the version pin: the image tag = ENGINE_VERSION
#   (not latest: the R-4 drift risk of task 3.1 is removed — the image changes
#   only by an explicit bump)
ENGINE_VERSION=0.36                            # = the ghcr tag (build 0.36.0, 4a7d8c6; verified live 2026-11-24 podman run --rm + the container); the bench report name, stage 7
ENGINE_IMAGE="${LCTL_IMAGE:-ghcr.io/gufo-org/toolboxes/gufo-runtime:${ENGINE_VERSION}}"
ENGINE_PORT_DEFAULT=11435                     # the PORT default before reading the canon (D2); Round 6 «единый порт» — 11435 for BOTH engines (2026-11-24, was 8080): a LAN client keeps one base_url across switch
ENGINE_CONTAINER=gufo_gufo_1                  # the server container <project>_<service>_<n>
ENGINE_POD=pod_gufo                           # the project pod (the pristine check)
ENGINE_PROJECT=gufo                           # the compose-project name (the `name: gufo` pin in the golden)
ENGINE_COMPOSE_FILES=( -f compose.yml )       # one file — rendered by engine_write_compose
# fix-r1 (the EXP-002 live FAIL): podman-compose 1.5 wraps a single-service
# stack in a pod → podman refuses «--pod + --userns=keep-id:uid=1000,gid=1000
# cannot be set together», the container is not created. --in-pod false = a
# single-service gufo without the pod wrapper (userns stays); a root-argparse
# option of podman-compose → a global one, BEFORE the subcommand (the
# placement is given by the core compose()). The hipfire global does not set
# it — the hipfire path runs without the flag.
ENGINE_COMPOSE_EXTRA_ARGS=( --in-pod false )   # fix:in-pod
ENGINE_ENV_TEMPLATE="$ADAPTER_DIR/tpl/env/env.tpl"   # the root .env template (the §4 canon)
ENGINE_MEMLOCK=1318060032                     # the limits.d value (validated by live windows)
ENGINE_FAIL_PATTERN="load_failed"             # the early-failure grep -E pattern for wait_health
ENGINE_HEALTH_PATH=/ready                     # stage-3 Additions p.1: gufo has no /health
ENGINE_WATCH_TUI="$ADAPTER_DIR/tpl/python/watch.py"   # (the W1 wave) the watch python panel

# engine constants (the core does not know them)
# the gufo context canon — $STATE_BASE/canon.env (set by the core AFTER
# sourcing this file — do not compute the STATE_FILE global here; §1.6
# task 3.1)

# Purpose: the model set dir name for a profile — profile isolation: the
#   server mounts only its own set (a foreign model → 404, not a silent
#   swap).
#
# @param 1: string       # the profile id (unknown → the 27b set)
# @stdout '27b' | 'flash' # the set subdir name under $MODELS_BASE
engine_model_set() { case "$1" in flash) echo flash ;; *) echo 27b ;; esac; }

# Purpose: the env add-on for cmd_watch (the core execs ENGINE_WATCH_TUI):
#   the gufo python panels import the core/tpl/python/watch frame — its
#   path into PYTHONPATH (the panel does not know where the core is;
#   cmd_watch knows CORE_TPL).
engine_watch_env() { PYTHONPATH="${PYTHONPATH:+$PYTHONPATH:}$CORE_TPL/python/watch"; export PYTHONPATH
  # the profile's cache dir (the /cache mount) — a host-side du for
  # «Кэш диск: U / X» (методики-gufo; the env is read once at panel start —
  # GOTCHAS)
  export LCTL_WATCH_GUFO_CACHE_DIR="$STATE_BASE/$(cur_profile)"
}

source "$ADAPTER_DIR/profiles.sh"      # the 9-field table + aliases + ref_get + ladders
source "$ADAPTER_DIR/models.sh"        # the pin tables + download_file + engine_pull_model
source "$ADAPTER_DIR/stack_files.sh"   # engine_write_compose + serve_args (1:1 gfctl)
source "$ADAPTER_DIR/engine.sh"        # the canon.env reader/writer + probe + engine_apply_profile
source "$ADAPTER_DIR/health.sh"        # parse_route/engine_smoke/engine_check_route/engine_status_*
source "$ADAPTER_DIR/doctor.sh"        # engine_doctor (inventory/types/cache/gpu-lock)
source "$ADAPTER_DIR/agentcheck.sh"    # cmp_ref + engine_agent_check
source "$ADAPTER_DIR/bench.sh"         # engine_bench_model + engine_bench_extras (stage 7)
