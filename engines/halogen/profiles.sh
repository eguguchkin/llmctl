# shellcheck shell=bash
# ── halogen: the profile registry (the content is the adapter's, the format is the core contract) ──
# A row's format — 9 '|'-separated fields; fields 1–5 are the core contract,
# 6–9 are adapter ones (stage-3 Additions p.2). ONE profile: halogen can
# only do Flash-Next (the user's 2026-11-25 decision — no 27b).
#   1 the set's main file (the LCTL_MODEL display canon; the API name is
#     HALOGEN_MODEL_ID, rendered into compose — the only name the engine
#     echoes),
#   2 the set's main files space-separated (the core's pull_profile_models
#     iterates them): the checkpoint + the ngram-lookup (required beside the
#     checkpoint) + drafter-r2-ht4 (the 0.20.7 draft head) + the vision
#     sidecar + the tokenizer/ dir (FLAT — the api-front's requirement; the
#     slash paths are fine for download_file — dirname is created by the
#     pre-flight),
#   3 the draft file ('-' = none) — drafter-r2-ht4; a repeat in a pull =
#     SKIP by size (the gufo mtp parity),
#   4 the RAM-gate threshold in whole GiB — 110: the weights 62 GiB + the
#     KV pool 524288 (~27 GiB at 2×262144) + a prefill scratch ~9 GiB ≈
#     100+ GiB; on a 60 GiB machine the core refuses normally (profile_gate
#     before any downloading),
#   5 the description for logs,
#   6 sessions = KV_SLOTS (rendered into HALOGEN_KV_SLOTS). 4 = the image
#     default and the upstream admission policy (a slot ~57 MB; «a latency
#     policy, not a memory decision»: the 3rd/4th client lands in a joint
#     round + SPEC_GROUP=4 instead of the slot queue; CACHE_ENTRIES=28
#     covers exactly 4 conversations; the aider #51 case: the per-turn wall
#     42s@4 vs 52s@2. The 2×CTX pool stays — the per-request context does
#     not change. Was 2 (the gufo parity) — the Ф3 docs revision,
#     2026-11-26),
#   7 the context (display and validation): 262144 — the model's native
#     context (the HALOGEN_CTX image default is the same — not rendered
#     into the golden),
#   8 the cache tiers ram/disk: halogen's RAM tier is not configurable (the
#     KV pool is a separate mechanism) → ram=0 (the display «—»), disk=
#     64 GiB (the CACHE_DISK_GIB image default matches — the /cache mount
#     in the golden makes it work),
#   9 the serve flags: '-' — halogen has no CLI; the engine config is envs,
#     rendered by the golden (stack_files.sh).
# We do not set the HALOGEN_KV_POOL_POSITIONS pool: the 2×CTX default +
# KV_POOL_FIT=1 (the engine shrinks it itself on shortage and says so in
# the log) — no probe ladder needed (field 7 is a constant, the engine
# does not truncate, an F21 analog — fit).
#
# @typedef profile_id: 'flash'
# @typedef weight_set: 'halogen_flash'

PROFILE_LIST="flash"
profile_flash="qwen38-flash-next-v2.hgn|qwen38-flash-next-v2.hgn qwen38-flash-next-ngram.hgn qwen38-flash-next-drafter-r2-ht4.hgn qwen38-flash-next-vision.hgn tokenizer/chat_template.jinja tokenizer/generation_config.json tokenizer/merges.txt tokenizer/tokenizer.json tokenizer/tokenizer_config.json tokenizer/vocab.json|qwen38-flash-next-drafter-r2-ht4.hgn|110|halogen-flash (concurrency mode, KV_SLOTS 4 × ctx 262144, пул 524288, prompt-cache disk 64G)|4|262144|0/68719476736|-"
# @type profile_id PROFILE_DEFAULT=flash
PROFILE_DEFAULT=flash

# the probe ladders: '-' — no probe (the pool adjusts itself, KV_POOL_FIT=1)
probe_ladder_flash="-"

# The agent-check references (taken live, 2026-11-26, one
# agent-check run dd26671: KV_SLOTS=4, the session's turn 1 cold 4.88s):
ref_flash_session="17.69"   # a session of 15 turns, total wall
ref_flash_followup="0.97"   # the 25k follow-up, turn2 wall (k5 1.11 / k100 1.05)
ref_flash_docq="1.13"       # [док 25k][q2] turn2 wall (cache_n=27008)
ref_flash_restore="1.34"    # the restart-restore 25k turn2, cache_n=27008 (disk)

# Purpose: a profile's agent-check reference value — the scalar
#   ref_<profile_no_hyphens>_<metric> ('' = the reference not taken). The
#   metrics: session | followup | restore | docq. A 1:1 ref_get port.
#
# @param 1: profile_id      # the canonical profile id
# @param 2: string          # the metric (session|followup|restore|docq)
# @stdout string            # seconds ('' = the reference not taken)
# @returns integer          # always 0
ref_get() {
  local name="ref_$(printf '%s' "$1" | tr '-' '_')_$2"
  printf '%s\n' "${!name:-}"
}

# Purpose: the profile's probe ladder — the probe_ladder_<id> scalar; '-' =
#   no probe (halogen is always '-': the pool is adjusted by the engine,
#   KV_POOL_FIT=1).
#
# @param 1: profile_id      # the canonical profile id
# @stdout string            # the ladder or '-'
# @returns integer          # always 0
profile_ladder() {
  local name="probe_ladder_$(printf '%s' "$1" | tr '-' '_')"
  printf '%s\n' "${!name:--}"
}

# Purpose: normalize a profile alias to the canonical id: flash and the
#   legacy halogen names (flash-single/solo) → flash; a canon passes as is.
#
# @param 1: string          # an alias or a canonical id
# @stdout profile_id        # the canonical id (only on rc 0)
# @returns integer          # 0 — the canon printed; 1 — an unknown value
resolve_profile() {
  case "$1" in
    flash|flash-single|solo) echo flash ;;
    *) return 1 ;;
  esac
}
