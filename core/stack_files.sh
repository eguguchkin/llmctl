# shellcheck shell=bash
# ── stack files: render mechanics and the skeleton (core); the engine's
#    compose files are written by the adapter hook engine_write_compose
#    (contract §2.3) ─────────────────────────────────────────────────────────
# The module writes only the convergence globals CONV_CHANGED/CONV_LIST
# (converge_render, stage 8); the rest — through the dispatcher helpers
# (log/die), reads STACK_DIR/MODELS_DIR/DATA_DIR (dispatcher), takes the
# engine_write_compose hook and the ENGINE_ENV_TEMPLATE from the adapter.
# Called from commands.sh (bootstrap/use/converge) and autostart.sh
# (render_tpl for the systemd units).

# Purpose: render one template: read file $1, replace in its text the
#   __NAME__ placeholders with the NAME=value pairs passed by the caller as
#   rest arguments, and write the result to $out.
#
# Side effects: writes the $out file — an overwrite (truncate, a new inode,
#   the current user as owner); reads the $1 template file (cat). On
#   unexpanded placeholders — a FATAL die() to stderr and process exit.
#
# Limitations/assumptions: requires the die global (dispatcher). Locals
#   tpl/out on one line: tpl — the full template text (cat trims trailing
#   newlines, printf '%s\n' gives back exactly one \n at the end), out —
#   the destination path. The substitution is a naive
#   `${tpl//__NAME__/value}`: the value may contain newlines (prompt_vol)
#   and is not escaped; the pair order MATTERS — pass the names in
#   descending length order (a note in the body). The placeholder sets are
#   fixed at the callers: compose.local.yml.tpl (LOCAL_DRAFT_ENV,
#   LOCAL_PROMPTS), the adapter's env.tpl (ENGINE, PROFILE, MODEL, PORT,
#   BIND, MODELS_DIR, STATE_DIR, IMAGE), the core/tpl systemd templates
#   (autostart.sh: PODMAN_BIN, STACK_DIR, CF, ENGINE).
#
# @param 1: string       # the .tpl template file path (read by cat in full)
# @param 2: string       # the destination file path (overwritten in full)
# @param 3..N: string[]  # rest NAME=value pairs (after shift 2), names — in
#   descending length order
# @returns integer       # always 0 on return — unexpanded placeholders
#   terminate the process via die (exit 1), a $1 read failure — via set -e
render_tpl() {
  local tpl out tpl_path; tpl_path="$1"; tpl="$(cat "$1")"; out="$2"; shift 2
  local kv name value
  # pass the names in descending length order (the longer one before the
  # shorter — protection against nested matches; the sets are fixed at the
  # caller)
  for kv in "$@"; do
    name="${kv%%=*}"; value="${kv#*=}"
    tpl="${tpl//__${name}__/${value}}"
  done
  if printf '%s' "$tpl" | grep -qE '__[A-Z0-9_]+__'; then
    die "нераскрытые плейсхолдеры в шаблоне $tpl_path"
  fi
  printf '%s\n' "$tpl" > "$out"
}

# Purpose: the ~/.local/bin/lctl symlink → the clone's binary
#   $STACK_DIR/lctl (clone = stack; the PATH entry survives clone moves).
#
# Side effects: mkdir -p $HOME/.local/bin; ln -sfn OVERWRITES the
#   $HOME/.local/bin/lctl symlink by replacement (an existing link is
#   replaced silently; the target file itself is untouched). Prints nothing
#   to stdout.
#
# Limitations/assumptions: requires the STACK_DIR global (dispatcher);
#   $STACK_DIR is the clone dir (it exists by the fact of the dispatcher
#   run). An ln failure (e.g. a regular file or dir sits where the link
#   should be) terminates the process via set -e.
#
# @returns integer # always 0 on return — an ln failure terminates the process via set -e
ensure_symlink() {
  local bin_dir="$HOME/.local/bin"
  mkdir -p "$bin_dir"
  ln -sfn "$STACK_DIR/lctl" "$bin_dir/lctl"
}

# Purpose: generate the stack skeleton in $STACK_DIR — the .data dirs, the
#   PATH-entry symlink and the engine's compose files (the
#   engine_write_compose hook — the goldens + compose.local.yml with the
#   engine wiring). .env is NOT written here — that is write_env below (the
#   same bootstrap/use calls it).
#
# Side effects: mkdir -p $STACK_DIR and $MODELS_DIR (the active profile
#   set's mount dir — which also builds the $DATA_DIR/$ENGINE/models
#   skeleton); ensure_symlink ($HOME/.local/bin/lctl); the
#   engine_write_compose hook — the engine's compose files into $STACK_DIR.
#   All files — the current user's inode. stdout — the "стек в …" log line.
#
# Limitations/assumptions: requires the STACK_DIR, MODELS_DIR globals
#   (dispatcher), the adapter's engine_write_compose hook and log
#   (dispatcher). Order: after set_models_dir (the model set must exist
#   before generation) and BEFORE the first `compose up`/recreate; .env is
#   written by the caller right after, before compose up.
#
# @returns integer # always 0 on return — render_tpl's die (inside the hook),
#   mkdir and hook failures terminate via set -e
write_stack_files() {
  log "стек в $STACK_DIR"
  mkdir -p "$STACK_DIR" "$MODELS_DIR"   # MODELS_DIR создаёт и каркас $DATA_DIR/$ENGINE
  ensure_symlink
  engine_write_compose                  # compose-файлы движка (адаптер)
}

# ── .env: the active engine's canon (written by the core, format §4 task 1.1) ─
# Purpose: render the .env canon from the adapter's template
#   (ENGINE_ENV_TEMPLATE) into the GIVEN file: the core canon
#   (LCTL_ENGINE/LCTL_PROFILE/LCTL_MODEL/LCTL_PORT/LCTL_BIND) + the engine
#   section (the engine's namespace keys <ENGINE>_* — the core canon does
#   not need them). The parametrization of the write_env body (stage 8:
#   converge_render renders into a buffer for a byte comparison with
#   fact); write_env below — a special case targeting $STACK_DIR/.env. One
#   .env at the clone root: podman-compose reads project-.env for
#   substitution into the adapter's compose files.
#
# Side effects: OVERWRITE (truncate, the current user's inode) of the $out
#   file via render_tpl. Manual .env edits do not survive start — the
#   render convergence (stage 8) reconverges them: .env is a reproducible
#   document, NOT state, the §М lesson (the template header reminds; the
#   fine-tuning hatch is the adapter mechanisms). The MODELS_DIR/STATE_DIR
#   paths are written RELATIVE (strip of the $STACK_DIR prefix) — compose
#   interpolation resolves them against the project dir, the document is
#   not tied to the clone's absolute path.
#
# Limitations/assumptions: requires the STACK_DIR, MODELS_DIR, STATE_BASE,
#   ENGINE, IMAGE, BIND, PORT globals (dispatcher) and the adapter's
#   template; MODELS_DIR is taken at call time (set_models_dir / the
#   cmd_pull env prefix re-point it). Live calls — cmd_bootstrap/cmd_use
#   (after write_stack_files and BEFORE `compose up`/recreate:
#   podman-compose reads the engine namespace keys from .env) and the
#   cmd_use rollback on a profile that did not come up. The rollback
#   passes prev_prof=cur_profile and prev_model=cur_model as is: an empty
#   prev_model is possible on a degenerate .env without LCTL_MODEL.
#
# @param 1: string   # the destination file path (overwritten in full; the
#   convergence buffer lives in $DATA_DIR — the same FS, rename is atomic)
# @param 2: string   # the canonical profile id (the callers run after the
#   adapter's resolve_profile; the rollback — verbatim cur_profile)
# @param 3: string   # the default model for LCTL_MODEL (LCTL_MODEL env /
#   profile field 1 / the rollback's prev_model)
# @returns integer   # always 0 on return — render_tpl's die and a write
#   failure terminate the process (set -e)
render_env_to() {
  local out="$1" prof="$2" model="$3"
  local mrel="${MODELS_DIR#"$STACK_DIR"/}" srel="${STATE_BASE#"$STACK_DIR/"}"
  render_tpl "$ENGINE_ENV_TEMPLATE" "$out" \
    MODELS_DIR="$mrel" STATE_DIR="$srel/$prof" PROFILE="$prof" \
    ENGINE="$ENGINE" IMAGE="$IMAGE" MODEL="$model" BIND="$BIND" PORT="$PORT"
}

# Writing .env = a special case of render_env_to ($STACK_DIR/.env); the
#   behavior is byte-for-byte the former one (live calls:
#   cmd_bootstrap/cmd_use/the use rollback).
write_env() { render_env_to "$STACK_DIR/.env" "$1" "$2"; }

# Purpose: render convergence (stage 8): render the .env + the adapter's
#   compose files into a buffer and byte-compare (cmp) against the actual
#   $STACK_DIR files; a divergence or missing fact → an atomic write (chmod
#   0644 + rename within the clone). The result — the CONV_CHANGED
#   ('0'|'1') and CONV_LIST (the overwritten file names, a trailing space)
#   globals. The inputs = the ACTUAL canon (the PORT/BIND globals are
#   already from the canon at the caller in cmd_start): a divergence never
#   silently changes profile/port/bind — a profile change is the exclusive
#   privilege of §А-4. The render_env_to → engine_write_compose order must
#   NOT change: the adapter hook reads the canon from the real .env
#   (cur_profile + canon.env) — the real .env at that moment is NOT yet
#   touched, both renders are determined by one state. The render
#   determinism is the former one: the same templates/inputs/render_tpl
#   mechanics; the comparison — a pure cmp.
#
# Side effects: an mktemp -d dir $DATA_DIR/.conv.XXXXXX (gitignored, the
#   same FS → rename is atomic); on a die mid-render (an unexpanded
#   placeholder) a stray dir remains — harmless (an mktemp-unique name; we
#   do NOT pre-rm or trap-clean — a race with a parallel start was never
#   supported, flock only guards up); chmod 0644 + mv -f on divergence;
#   rm -rf of the buffer at the end. The diff files: .env + the names from
#   ENGINE_COMPOSE_FILES (the "-f <file>" pairs); a name the hook did not
#   render into the buffer is excluded from the diff; a missing fact = a
#   divergence. The adapter's golden files pass the same cmp — a verbatim
#   copy equals itself, no false diffs. Prints nothing to stdout/stderr
#   (WARNs/messages are the caller's job).
#
# Limitations/assumptions: requires the DATA_DIR/STACK_DIR globals
#   (dispatcher), render_env_to/engine_write_compose([target_dir] — the
#   stage 8 contract) and the adapter's ENGINE_COMPOSE_FILES array.
#   MODELS_DIR at call time — profile $1's set (the set_models_dir
#   re-pointing at the caller). No holders of .env/compose inodes
#   (podman-compose reads at up time; the watchdog does not read .env).
#   File perms — deterministic 0644 (mktemp gives 0600), the inode is new
#   on every write. Locals prof/model/buf/name/a on one line.
#
# @param 1: string     # the canonical profile id (§А-3 runs after resolve_profile)
# @param 2: string     # the model for LCTL_MODEL (the formula "LCTL_MODEL env >
#   registry field 1" — the documented bootstrap inputs, the canon tracks
#   them; a manual LCTL_MODEL edit in .env gets reconverged)
# @globals out         # CONV_CHANGED: '0' — everything matches, '1' — there was a divergence;
#                       # CONV_LIST: the overwritten file names space-separated
# @returns integer     # 0 on return — render_tpl's die and failures terminate via set -e
converge_render() {
  CONV_CHANGED=0; CONV_LIST=""                     # fix:render-converge — the result globals (stage 8)
  local prof="$1" model="$2" buf name a
  buf=$(mktemp -d "$DATA_DIR/.conv.XXXXXX")        # .data: gitignored, the same FS → rename is atomic
  render_env_to "$buf/.env" "$prof" "$model"
  engine_write_compose "$buf"                      # хук с target-каталогом (контракт этапа 8)
  local targets=(.env)
  for a in ${ENGINE_COMPOSE_FILES[@]+"${ENGINE_COMPOSE_FILES[@]}"}; do
    [ "$a" != "-f" ] && targets+=("$a")            # the diff file names — from the adapter's -f triple
  done
  for name in ${targets[@]+"${targets[@]}"}; do
    [ -f "$buf/$name" ] || continue                # the hook did not render this name — not for the diff
    if [ ! -f "$STACK_DIR/$name" ] || ! cmp -s "$buf/$name" "$STACK_DIR/$name"; then
      chmod 0644 "$buf/$name"                      # mktemp gives 0600; deterministic perms
      mv -f "$buf/$name" "$STACK_DIR/$name"        # an atomic rename within the clone
      CONV_CHANGED=1; CONV_LIST+="$name "
    fi
  done
  rm -rf "$buf"
}
