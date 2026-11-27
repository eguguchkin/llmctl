# shellcheck shell=bash
# ── hipfire: the engine config (a volume via compose run — the project's
#    volume is guaranteed) + the profile's applied key set ──────────────────
# The engine_apply_profile hook (contract §2.3) is assembled from the hfctl
# lib/engine.sh without edits to the core bodies.

# Purpose: write one engine config key into the active profile's config dir
#   — a one-shot `compose run` (the engine may be off).
#
# Side effects: a podman subprocess (a one-shot container writes config.toml
#   into the active profile's bind dir from the $STACK_DIR compose files;
#   the image is pulled when missing); stdout — the last line of the
#   `config set` output (stderr merged into stdout).
#
# Limitations/assumptions: requires compose (core/stack.sh) and the
#   STACK_DIR global; the profile is taken from the current stack
#   (LCTL_PROFILE in .env), i.e. until the profile is switched the write
#   goes into the former state dir; the key and value are NOT validated
#   here — an engine refusal is visible in the rc and as text in stdout;
#   stdin is closed (/dev/null) — no interactive prompts. A call outside an
#   if/||-context under set -e terminates the process on a refusal —
#   engine_apply_profile calls via if and accumulates the refused keys.
#
# @param 1: /^\w+(\.\w+)+$/                             # an engine config key (dotted: memory.max_seq, serve.multi_slot)
# @param 2: /\d+/ | 'on' | 'off' | 'true' | 'false'     # the value: an integer or a boolean literal
# @returns integer                                      # the pipe's rc (pipefail): 0 — the write accepted; non-zero — podman/config set refused
cfgset() {
  compose run --rm --no-deps hipfire hipfire config set "$1" "$2" </dev/null 2>&1 | tail -1
}

# Purpose: write the hipfire local catalog (models.toml in the profile's
#   config dir) — the model-ID canon. The catalog resolves BEFORE the
#   registry and the fuzzy name scans (main.rs find_model_path: catalog →
#   registry → stem → contains): without the write the qwen3.8-27b canon
#   passes the contains scan onto qwen3.8-27b-vision.hfq (a .hfq rank = 2
#   is higher than rank 3 of .mq4-xts — it does not end in .mq4) and
#   silently loads the WRONG model (live 2026-11-25). The contract «an
#   agent is not re-tuned on an engine switch»: gufo — --served-model-name
#   (cebefa7), hipfire — this catalog (the engine has no alias mechanism,
#   the registry is signed). registry_tag links the entry with the
#   registry (identity/sidecars); the file is resident → requests with the
#   canon do not reload the model (verified: 0 new load summaries). The
#   file is read on every request — no recreate needed, we write at apply
#   (idempotent, the canon is reproducible). The container models path is
#   fixed by compose (/home/hipfire/.hipfire/models), the file names are
#   pinned into the image by the registry (ENGINE_VERSION); a registry
#   naming change = an edit of this map.
#
# Side effects: mkdir -p + an overwrite of $STACK_DIR/$HIPFIRE_STATE_DIR/
#   config/models.toml (a bind of the config dir — the container sees it
#   immediately).
#
# Limitations/assumptions: prof — a canonical id (unknown → the 27b
#   branch); requires the STACK_DIR, env_val globals (the core); the
#   file-name map is handwritten (27b: qwen3.8-27b.mq4-xts — the registry
#   monolith; flash: …-base.mq4-xts — the PLE-split base), the tag — the
#   profile registry's field 1.
#
# @param 1: string   # the canonical profile id (unknown → the 27b branch)
# @returns integer # 0 — the write succeeded (printf/redirect errors die by set -e)
canon_catalog() {
  local prof="$1" id tag file
  case "$prof" in
    flash) id=qwen3.8-flash-next tag=$(profile_field flash 1) file=qwen3.8-flash-next-base.mq4-xts ;;
    *)     id=qwen3.8-27b tag=$(profile_field 27b 1) file=qwen3.8-27b.mq4-xts ;;
  esac
  mkdir -p "$STACK_DIR/$(env_val HIPFIRE_STATE_DIR)/config"
  printf 'schema_version = 1\n\n[models."%s"]\npath = "/home/hipfire/.hipfire/models/%s"\nregistry_tag = "%s"\n' \
    "$id" "$file" "$tag" \
    > "$STACK_DIR/$(env_val HIPFIRE_STATE_DIR)/config/models.toml"
}

# Purpose: apply the chosen profile's full engine key set (speculation/
#   batching/cache) to the active stack — via cfgset.
#
# Side effects: sequential cfgsets (10–12 one-shot podman subprocesses)
#   writing into the active profile's config dir; a log line (with the
#   profile description from the profile table's field 5) and cfgset output
#   tails to stdout.
#
# Limitations/assumptions: prof — a canonical id (the resolve_profile
#   normalization is the caller's conscience); an UNKNOWN id is NOT refused
#   — the 27b-single branch is applied silently (the case default) and the
#   log description stays empty. Requires the MAX_SEQ and SLOTS globals
#   (adapter.sh), compose/STACK_DIR and the profile table; called between
#   `compose up -d` and `--force-recreate` (cmd_bootstrap/cmd_use) and on
#   a cold §А-3 before cmd_up (fix 2026-11-25: the cfgset keys are outside
#   the render — without this a registry key edit under the same profile
#   was never applied) — after applying a recreate is MANDATORY, the
#   engine does not re-read the config on the fly. A key refusal does NOT
#   kill on/use: the callers invoke via `|| true`, here — a warn with the
#   list of refused keys and rc 1 (a partial apply beats death).
#
# @param 1: string   # the canonical profile id (unknown → the 27b-single branch)
# @returns integer  # 0 — all keys written; 1 — at least one cfgset refused (a warn with the list)
engine_apply_profile() {
  local prof="$1" failed=""
  log "профиль движка: $prof ($(profile_field "$prof" 5))"
  canon_catalog "$prof"   # fix:canon-alias
  if ! cfgset memory.max_seq "$MAX_SEQ"; then failed="$failed memory.max_seq"; fi
  if ! cfgset memory.session_cache_disk_bytes 34359738368; then failed="$failed memory.session_cache_disk_bytes"; fi
  if ! cfgset memory.session_cache_bytes 12884901888; then failed="$failed memory.session_cache_bytes"; fi   # the sessions' 12 GiB RAM tier: without it the session-cache as a whole (the disk tier included) does not attach (carriers.rs:10100 — the session_budget>0 gate; it was 0 on 27b/parallel → «Кэш RAM —», EXP-016 2026-11-24)
  if ! cfgset serve.idle_timeout_seconds 0; then failed="$failed serve.idle_timeout_seconds"; fi   # the model is resident: loaded at start (pre-warm), not unloaded on idle
  case "$prof" in
    27b-parallel)
      if ! cfgset speculation.dflash on; then failed="$failed speculation.dflash"; fi
      if ! cfgset serve.multi_slot true; then failed="$failed serve.multi_slot"; fi
      if ! cfgset serve.multi_slot_slots "$SLOTS"; then failed="$failed serve.multi_slot_slots"; fi
      if ! cfgset serve.multi_slot_ctx "$MAX_SEQ"; then failed="$failed serve.multi_slot_ctx"; fi
      if ! cfgset serve.continuous_batch_size 1; then failed="$failed serve.continuous_batch_size"; fi
      if ! cfgset serve.vmm_batch false; then failed="$failed serve.vmm_batch"; fi
      if ! cfgset serve.batch_nonexact false; then failed="$failed serve.batch_nonexact"; fi
      ;;
    flash)
      # VMM continuous batching (fn-lanes, Qwen4). On a lanes refusal the
      # engine itself prints 'qwen4 lanes refused: … — fallback to
      # sequential' and lives serial (checked in engine_check_route).
      if ! cfgset speculation.dflash off; then failed="$failed speculation.dflash"; fi          # flash has native MTP; the route is the engine's call
      if ! cfgset serve.multi_slot false; then failed="$failed serve.multi_slot"; fi
      if ! cfgset serve.multi_slot_slots 2; then failed="$failed serve.multi_slot_slots"; fi
      if ! cfgset serve.multi_slot_ctx "$MAX_SEQ"; then failed="$failed serve.multi_slot_ctx"; fi
      if ! cfgset serve.continuous_batch_size 4; then failed="$failed serve.continuous_batch_size"; fi
      if ! cfgset serve.vmm_batch true; then failed="$failed serve.vmm_batch"; fi
      if ! cfgset serve.batch_sampled true; then failed="$failed serve.batch_sampled"; fi
      if ! cfgset serve.batch_nonexact false; then failed="$failed serve.batch_nonexact"; fi      # IMPORTANT: qwen4 lanes live ONLY on the
      # Exact route (batch_staging.rs:569: Nonexact → refuse 'only the exact
      # lane route'). The key is inherited from 27b-single (true there) — if
      # not reset explicitly, flash silently loses lanes → serial. The root
      # of the 2026-11-09 «lanes mystery»: not a moving tag but a leftover
      # nonexact=true from 27b-single.
      if ! cfgset memory.session_cache_bytes 12884901888; then failed="$failed memory.session_cache_bytes"; fi  # 12 GiB: a full 262K snapshot is 8.78 GiB + a margin (Э-3 §4.2)
      ;;
    *)  # 27b (default)
      if ! cfgset speculation.dflash on; then failed="$failed speculation.dflash"; fi
      if ! cfgset serve.multi_slot false; then failed="$failed serve.multi_slot"; fi
      if ! cfgset serve.multi_slot_slots 4; then failed="$failed serve.multi_slot_slots"; fi
      if ! cfgset serve.multi_slot_ctx "$MAX_SEQ"; then failed="$failed serve.multi_slot_ctx"; fi
      if ! cfgset serve.continuous_batch_size 1; then failed="$failed serve.continuous_batch_size"; fi   # singleton (the fix 2026-11-25, a live window): the DFlash batch admission needs lm_head in the model — mq4-xts has none (Q8/HFQ4/MQ4G256 are valid), requests fell with «batched lm_head admission … unsupported»; «1 preserves sequential behavior» — DFlash-singleton lives
      if ! cfgset serve.vmm_batch false; then failed="$failed serve.vmm_batch"; fi   # the VMM twin was mq6-xt (removed 2026-11-25) — without a twin «VMM flash decode refused: … without a VMM twin» on every request
      if ! cfgset serve.batch_nonexact true; then failed="$failed serve.batch_nonexact"; fi
      if ! cfgset memory.session_cache_bytes 0; then failed="$failed memory.session_cache_bytes"; fi   # Qwen3.5: the engine-session cache does not work (the disk tier is inert) — 0 saves 8 GiB of GPU-RAM
      ;;
  esac
  if [ -n "$failed" ]; then
    warn "cfgset: отказ ключей:$failed — движок мог применить конфиг частично (продолжаем)"
    return 1
  fi
}
