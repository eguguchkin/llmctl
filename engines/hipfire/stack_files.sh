# shellcheck shell=bash
# ── hipfire: the engine's compose files (the upstream goldens + the DFlash wiring) ──
# The tpl/compose goldens were taken from upstream 0.4.5; the
# compose.yml/compose.halo.yml of 0.4.6 and 0.4.7 are byte-identical to
# 0.4.5 (the blobs matched in git) — the goldens are valid for 0.4.6/0.4.7
# too. The compose-project name is pinned `name: hipfire` in compose.yml —
# the containers/pods of different engines do not collide (§3 task 1.1).

# Purpose: generate the engine's compose files into the destination dir $1
#   (default $STACK_DIR — the former behavior; called by the core from
#   write_stack_files after the frame's mkdir and — stage 8 — from
#   converge_render with a buffer dir): compose.yml/compose.halo.yml —
#   verbatim copies of the goldens, compose.local.yml — a render of the
#   tpl with the DFlash wiring (mq6-xt does not declare a sidecar in the
#   registry; the MQ4 draft — the recommended controller) and the prompts
#   mount. The hook does NOT read from the destination dir (the inputs —
#   its own tpl + the canon: cur_profile/canon fields) — the stage-8
#   contract.
#
# Side effects: install -m 0644 OVERWRITES $d/compose.yml and
#   $d/compose.halo.yml with verbatim copies of the goldens; render_tpl
#   OVERWRITES $d/compose.local.yml. Prints nothing to stdout.
#
# Limitations/assumptions: requires the STACK_DIR, LOG_DIR, DRAFT_FILE
#   globals (adapter/dispatcher), cur_profile (core/stack.sh),
#   profile_field (core/profiles.sh), render_tpl (core/stack_files.sh).
#   STATIC files: the ${VAR:-def} inside are COMPOSE variables, not shell —
#   copy verbatim, without shell expansion/envsubst. The DFlash line is
#   chosen by the FORMER .env's profile (a clean stack → PROFILE_DEFAULT)
#   and may differ from the one bootstrap installs; field 3 is only the
#   «there is a draft» marker, the path is always the DRAFT_FILE global
#   (a CONTAINER path into the models mount). The prompts mount appears
#   only when the dir already exists at $LOG_DIR/prompts (the lab creates
#   it itself); the mount — the relative .data/<engine>/logs/prompts path
#   (compose resolves it from the project dir). Locals
#   d/prompt_vol/draft_env on one line: d — the destination dir; an empty
#   string or a pre-formed YAML fragment (prompt_vol contains newlines).
#
# @param 1: string   # the destination dir (optional; default $STACK_DIR —
#   all the other core calls without an argument, the former behavior)
# @returns integer # always 0 on return — render_tpl's die (unexpanded
#   placeholders) and install failures terminate by set -e
engine_write_compose() {
  local d="${1:-$STACK_DIR}"
  install -m 0644 "$ADAPTER_DIR/tpl/compose/compose.yml" "$d/compose.yml"
  install -m 0644 "$ADAPTER_DIR/tpl/compose/compose.halo.yml" "$d/compose.halo.yml"

  local prompt_vol="" draft_env=""
  [ -d "$LOG_DIR/prompts" ] && prompt_vol=$'\n    volumes:\n      - ./.data/'"$ENGINE"'/logs/prompts:/prompts:ro'
  local cur_draft; cur_draft=$(profile_field "$(cur_profile)" 3)
  [ "$cur_draft" != "-" ] && [ -n "$cur_draft" ] && draft_env="      HIPFIRE_DFLASH_DRAFT: $DRAFT_FILE"
  render_tpl "$ADAPTER_DIR/tpl/compose/compose.local.yml.tpl" "$d/compose.local.yml" \
    LOCAL_DRAFT_ENV="$draft_env" LOCAL_PROMPTS="$prompt_vol"
}
