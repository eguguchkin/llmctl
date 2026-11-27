# shellcheck shell=bash
# ── gufo: the engine's compose file (a rendered golden) + the profile's serve line ──
# gufo has no `config set` — the ENTIRE engine config lives in the compose
# service's serve line (§0в task 3.1), so the render is a mandatory part of
# bootstrap/use (K-2: use re-renders). The serve line is assembled ONLY from
# the profiles.sh table (fields 1/6/7/8/9 + the @DRAFT@/@MTP@ tokens →
# /models/<file>, the set's models:ro mount) — a 1:1 gfctl serve_args port.
# The context at render: GUFO_CONTEXT_<prof> from canon.env → field 7 (the
# fallback).

# Purpose: print the engine's arguments (`gufo serve llm …`) as ONE line:
#   --host 0.0.0.0 always (gfctl F2: the 127.0.0.1 default in a container =
#   a dead port-publish), --model = the set's main-role file (flash — the
#   FIRST shard 00001-of-00004, gufo picks up the rest itself, the FX-W1b
#   window), the table's field 9 with the @DRAFT@/@MTP@ substitution →
#   /models/<file>, then --sessions/--context (the arguments) and the
#   field-8 cache tiers (cache-disk always the container /cache).
#
# Side effects: only printing to stdout; an unknown role token (not
#   @DRAFT@/@MTP@) or a missing file of the needed role in the set's table
#   — die().
#
# Limitations/assumptions: a PURE function (raises nothing) — the battery
#   compares the output byte-for-byte with the task 3.1 canon;
#   sessions/context are passed as arguments (canon or table — the caller
#   decides). The set is given by engine_model_set (the adapter; in gufo
#   registry field 2 is files, not a set). An unknown profile — die via
#   profile_field (rc 1 without printing).
#
# @param 1: profile_id      # the canonical profile id
# @param 2: /^[0-9]+$/      # sessions
# @param 3: /^[0-9]+$/      # context (in tokens)
# @stdout string            # «gufo serve llm --host 0.0.0.0 --port N --model … …»
# @returns integer          # 0 — printed; die (exit 1) on broken tokens
serve_args() {
  local prof="$1" sessions="$2" context="$3" set_name extra model draft mtp mmproj
  set_name=$(engine_model_set "$prof") || die "serve_args: неизвестный профиль '$prof' — доступно: $PROFILE_LIST"
  model=$(set_file_role "$set_name" main) || die "у сета $set_name нет файла роли main (--model не собрать)"
  draft=$(set_file_role "$set_name" draft) || true
  mtp=$(set_file_role "$set_name" mtp) || true
  mmproj=$(set_file_role "$set_name" mmproj) || true
  extra=$(profile_field "$prof" 9)
  if [[ "$extra" == *@DRAFT@* ]]; then
    [ -n "$draft" ] || die "профиль $prof использует @DRAFT@, у сета $set_name нет draft-файла"
    extra="${extra//@DRAFT@//models/$draft}"
  fi
  if [[ "$extra" == *@MTP@* ]]; then
    [ -n "$mtp" ] || die "профиль $prof использует @MTP@, у сета $set_name нет mtp-файла"
    extra="${extra//@MTP@//models/$mtp}"
  fi
  if [[ "$extra" == *@MMPROJ@* ]]; then
    [ -n "$mmproj" ] || die "профиль $prof использует @MMPROJ@, у сета $set_name нет mmproj-файла"
    extra="${extra//@MMPROJ@//models/$mmproj}"
  fi
  if printf '%s' "$extra" | grep -qE '@[A-Z0-9_]+@'; then
    die "serve_args: неизвестный токен в serve_extra профиля $prof: $extra"
  fi
  # --port — the Round 6 «единый порт» (2026-11-24): gufo listened on its
  #     inner default 8080, a publish port:port:port with 11435 gave
  #     connection reset (the live window); -p/--port — a runtime flag
  #     (gufo serve llm --help)
  printf 'gufo serve llm --host 0.0.0.0 --port %s --model /models/%s %s --sessions %s --context %s --cache-ram-bytes %s --cache-disk /cache --cache-disk-bytes %s\n' \
    "$PORT" "$model" "$extra" "$sessions" "$context" \
    "$(profile_field "$prof" 8 | cut -d/ -f1)" "$(profile_field "$prof" 8 | cut -d/ -f2)"
}

# Purpose: render compose.yml for a profile and context into the
#   destination dir $3 (default $STACK_DIR — the former behavior; stage 8:
#   converge_render calls the hook with a buffer dir) — the golden
#   tpl/compose/compose.yml.tpl (the F9-flag translations) + serve_args;
#   the mounts are RELATIVE paths from the project dir (like the core's
#   .env).
#
# Side effects: mkdir -p $STATE_BASE/$prof (the cache dir — a bind source,
#   rootless podman creates what is missing itself, here — earlier);
#   render_tpl OVERWRITES $d/compose.yml. Prints nothing to stdout.
#
# Limitations/assumptions: prof — a canonical id; ctx — a token count
#   (canon or a probe step — the caller decides); MODELS_DIR — THIS
#   profile's set mount dir (the core's set_models_dir at the caller).
#   The (NAME=value) pairs in descending length order (the render_tpl
#   contract). Locals on one line: prof/ctx/d/mrel/crel — d is the
#   destination dir (NOT read — the inputs are globals), mrel/crel — the
#   mounts' relative paths (strip of $STACK_DIR).
#
# @param 1: profile_id      # the canonical profile id
# @param 2: /^[0-9]+$/      # the context for the serve line
# @param 3: string          # the destination dir (optional; default
#   $STACK_DIR — all the other calls keep the former behavior)
# @returns integer          # always 0 on return — render_tpl's die and
#   failures terminate the process (set -e)
gufo_render_compose() {
  local prof="$1" ctx="$2" d="${3:-$STACK_DIR}" mrel crel
  mrel="${MODELS_DIR#"$STACK_DIR"/}"
  crel="${STATE_BASE#"$STACK_DIR"/}/$prof"
  mkdir -p "$STATE_BASE/$prof"
  render_tpl "$ADAPTER_DIR/tpl/compose/compose.yml.tpl" "$d/compose.yml" \
    SERVE_ARGS="$(serve_args "$prof" "${LCTL_SESSIONS:-$(profile_field "$prof" 6)}" "$ctx")" \
    MODELS_DIR="$mrel" CACHE_DIR="$crel" IMAGE="$IMAGE" BIND="$BIND" PORT="$PORT"
}

# Purpose: the engine_write_compose hook (contract §2.3; called by the core
#   from write_stack_files and — with K-2 — from cmd_use; stage 8 — from
#   converge_render with a buffer dir): render compose.yml for the stack's
#   CANONICAL profile: the context — GUFO_CONTEXT_<prof> from canon.env,
#   else the table's field 7 (the fallback until the first probe). The
#   profile — cur_profile (.env; at bootstrap before write_env — the
#   default/previous one — the core's semantics, engine_apply_profile then
#   re-renders for the target profile). The hook does NOT read from the
#   destination dir (the inputs — the tpl + the canon: cur_profile/
#   canon.env) — the stage-8 contract.
#
# @param 1: string          # the destination dir (optional; default
#   $STACK_DIR — all the other core calls without an argument)
# @returns integer          # always 0 on return — render_tpl's die
#   terminates the process (set -e)
engine_write_compose() {
  local d="${1:-$STACK_DIR}" prof ctx
  prof=$(cur_profile)
  ctx=$(gufo_canon_context "$prof")
  [ -n "$ctx" ] || ctx=$(profile_field "$prof" 7)
  gufo_render_compose "$prof" "$ctx" "$d"
}
