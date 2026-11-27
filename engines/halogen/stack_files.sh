# shellcheck shell=bash
# ── halogen: the engine's compose file (a rendered golden, the config = env) ──
# halogen has no CLI config: the ENTIRE config is the HALOGEN_* env vars
# (read once at container start), so the golden renders the env block with
# literals (the gufo pattern: rendered literals in compose.yml, .env — a
# display document). We override ONLY what distinguishes our profile from
# the image's shipped defaults (the upstream-compose philosophy: «a copy of
# a default is a copy that goes stale»): CHECKPOINT (our main file),
# VISION_TOWER (the vision live / off), KV_SLOTS=2 (the image default 1 —
# our agent parity), CACHE_DIR (our mount of the profile's cache dir),
# MODEL_ID (the llmctl canon). CTX/CACHE_DISK_GIB/PROMPT_CACHE/CONC_MODE —
# the image defaults (262144/64G/2/concurrency) match ours — not copied.
# Mounts: the set /models:ro (only its own set — a foreign model → 404, not
# a silent swap), the profile's cache dir /cache (rw — the prompt cache's
# disk tier, ~27 KiB/token, written per request). Ports: HALOGEN_API_PORT =
# $PORT and the publish bind:port:port — the inner port EQUALS the outer
# one (the Round 6 gufo gotcha). The command is NOT set: the default
# entrypoint = `all` (engine+api in one container; the 8730 engine port is
# not published — an auth-less protocol).

# Purpose: render compose.yml for a profile into the destination dir $2
#   (default $STACK_DIR — the stage-8 contract: converge_render calls with
#   a buffer). VISION_TOWER: the vision sidecar ON DISK (MODELS_DIR) → "1"
#   (the vision live), missing → empty (a text-only raise; the smoke gate
#   uses the same file — the w43 parity: the text variant does not pay for
#   the vision and does not refuse on a partial pull).
#
# Side effects: mkdir -p $STATE_BASE/$prof (the cache dir — a bind source);
#   render_tpl OVERWRITES $d/compose.yml. Prints nothing to stdout.
#
# Limitations/assumptions: prof — a canonical id; MODELS_DIR — THIS
#   profile's set mount dir (the core's set_models_dir at the caller). The
#   render_tpl (NAME=value) pairs — determinism: the same inputs → the same
#   file (the battery's S-converg).
#
# @param 1: profile_id      # the canonical profile id
# @param 2: string          # the destination dir (optional; default
#   $STACK_DIR — all the other calls keep the former behavior)
# @returns integer          # always 0 on return — render_tpl's die
#   terminates
halogen_render_compose() {
  local prof="$1" d="${2:-$STACK_DIR}" mrel crel vision_f tower=""
  mrel="${MODELS_DIR#"$STACK_DIR"/}"
  crel="${STATE_BASE#"$STACK_DIR"/}/$prof"
  mkdir -p "$STATE_BASE/$prof"
  if vision_f=$(set_file_role "$(engine_model_set "$prof")" mmproj 2>/dev/null) \
     && [ -n "$vision_f" ] && [ -f "$MODELS_DIR/$vision_f" ]; then
    tower="1"
  fi
  render_tpl "$ADAPTER_DIR/tpl/compose/compose.yml.tpl" "$d/compose.yml" \
    IMAGE="$IMAGE" BIND="$BIND" PORT="$PORT" \
    MODELS_DIR="$mrel" CACHE_DIR="$crel" \
    CHECKPOINT="/models/$(set_file_role "$(engine_model_set "$prof")" main)" \
    VISION_TOWER="$tower" \
    KV_SLOTS="$(profile_field "$prof" 6)" \
    MODEL_ID="$HALOGEN_MODEL_CANON"
}

# Purpose: the engine_write_compose hook (contract §2.3; called by the core
#   from write_stack_files/cmd_use/converge_render): render compose.yml for
#   the stack's canonical profile. One profile, a constant config — the
#   render is deterministic (a rerun = the same file). The hook does NOT
#   read from the destination dir (the inputs — the tpl + the canon) — the
#   stage-8 contract.
#
# @param 1: string          # the destination dir (optional)
# @returns integer          # always 0 on return — render_tpl's die
#   terminates
engine_write_compose() {
  halogen_render_compose "$(cur_profile)" "${1:-$STACK_DIR}"
}

# Purpose: the engine_apply_profile hook (contract §2.3) — a context
#   resolver at gufo; at halogen the context is a registry constant
#   (field 7), there is no probe ladder (the pool adjusts itself,
#   KV_POOL_FIT=1, the log says which) — the hook only re-renders the
#   compose for the profile (idempotent). We do not write canon.env: no
#   profile×context pair state exists.
#
# Side effects: halogen_render_compose ($STACK_DIR/compose.yml); a log
#   line. The core does the final --force-recreate right after (cmd_use).
#
# @param 1: string   # the canonical profile id
# @returns integer  # always 0
engine_apply_profile() {
  local prof="$1"
  log "halogen: конфиг env-константы профиля $prof (ctx $(profile_field "$prof" 7), KV_SLOTS $(profile_field "$prof" 6)) — рендер compose"
  halogen_render_compose "$prof"
}
