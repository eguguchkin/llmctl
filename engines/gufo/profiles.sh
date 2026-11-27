# shellcheck shell=bash
# ── gufo: the profile registry (the content is the adapter's, the format is the core contract) ─
# A row's format — 9 '|'-separated fields; fields 1–5 are the core contract
# (the core reads only them), 6–9 are adapter ones (stage-3 Additions p.2;
# only the adapter reads them via profile_field <id> <6..9>):
#   1 the set's main file (the LCTL_MODEL canon; the gufo smoke takes the
#     model from load_completed — names with spaces — a deterministic field),
#   2 the set's main files space-separated (the core's pull_profile_models
#     iterates them; flash has 4 shards + mtp — mtp is also in field 3, a
#     repeated pull = SKIP by size),
#   3 the draft/mtp file ('-' = none),
#   4 the RAM-gate threshold in whole GiB (SPEC §5 gfctl: 56 / 110),
#   5 the description for logs,
#   6 sessions (a profile constant; R1 has no --sessions surface),
#   7 context — the CURRENT canon until the first probe (the render fallback),
#   8 the cache tiers ram/disk in bytes through '/',
#   9 the engine's serve flags; @DRAFT@/@MTP@/@MMPROJ@ → /models/<file>
#     (serve_args).
# The probe ladder — the probe_ladder_<id> scalar (the indirect-read ref
# pattern; it does not fit into the 9 fields), only the adapter reads it.
# The values — gfctl lib/profiles.sh @ 462573f verbatim (AGENT-CONFIGS
# pp.3–4; a divergence without a new window is forbidden). The canon names
# are R1 (agnostic): gfctl 27b-single→27b, 27b-multi→27b-parallel,
# flash-multi→flash.
#
# @typedef profile_id: '27b' | '27b-parallel' | 'flash'
# @typedef weight_set: '27b' | 'flash'

PROFILE_LIST="27b 27b-parallel flash"
profile_27b="qwen3.8-27b-IQ4_XS-pure.gguf|qwen3.8-27b-IQ4_XS-pure.gguf mmproj-BF16.gguf|Qwen3.8-27B-DFlash2-Q4_K_M.gguf|56|solo DFlash2 (максимум соло-скорости)|1|262144|12884901888/68719476736|--speculative dflash2 --dflash-model @DRAFT@ --mmproj @MMPROJ@ --log-progress --served-model-name qwen3.8-27b --served-model-name Qwen3.8-27B --served-model-name qwen3.8:27b-mq4-xts"
profile_27b_parallel="qwen3.8-27b-IQ4_XS-pure.gguf|qwen3.8-27b-IQ4_XS-pure.gguf mmproj-BF16.gguf|Qwen3.8-27B-DFlash2-Q4_K_M.gguf|56|мульти DFlash2 (probe-лестница, D5)|2|210000|12884901888/68719476736|--speculative dflash2 --dflash-model @DRAFT@ --mmproj @MMPROJ@ --log-progress --served-model-name qwen3.8-27b --served-model-name Qwen3.8-27B --served-model-name qwen3.8:27b-mq4-xts"
profile_flash="Qwen3.8-Flash-Next-UD-Q4_K_XL-00001-of-00004.gguf|Qwen3.8-Flash-Next-UD-Q4_K_XL-00001-of-00004.gguf Qwen3.8-Flash-Next-UD-Q4_K_XL-00002-of-00004.gguf Qwen3.8-Flash-Next-UD-Q4_K_XL-00003-of-00004.gguf Qwen3.8-Flash-Next-UD-Q4_K_XL-00004-of-00004.gguf mtp-Qwen3.8-Flash-Next-shared-Q8_0.gguf mmproj-flash-next-BF16.gguf|mtp-Qwen3.8-Flash-Next-shared-Q8_0.gguf|110|мульти MTP (максимальные контексты, floor 131072 проверен FX)|2|131072|12884901888/68719476736|--speculative mtp --mtp-model @MTP@ --mmproj @MMPROJ@ --log-progress --served-model-name qwen3.8-flash-next --served-model-name qwen3.8:flash-next-mq4-xts"
# @type profile_id PROFILE_DEFAULT=27b
PROFILE_DEFAULT=27b

# the probe ladders (gfctl's table field 9; '-' = no probe, single). The
#   27b-parallel head = the 210000 canon (the dual-max PASS, 5622e53);
#   below — the 2026-11-24 ladder steps (a fallback to smaller-RAM
#   machines)
probe_ladder_27b="-"
probe_ladder_27b_parallel="210000 196608 163840 131072"
probe_ladder_flash="262144 229376 196608 163840 131072"

# ── the agent-check references (gfctl SPEC §5/§7 verbatim; EXP-007) ──────────
# A layer of scalars ref_<profile_no_hyphens>_<metric> (the same indirect
# expansion pattern as profile_field). '' = the reference not taken → cmp_ref
# gives the WARN «эталон не снят». Taken live by agent-check (EXP-007, live
# 2026-11-18).
ref_27b_session="30.44"     # a session of 15 turns, total wall (turn 1 = the 14.8 prefill)
ref_27b_followup="3.00"     # the 25k follow-up, turn2 wall (k5 3.03 / k100 4.59)
ref_27b_docq="3.60"         # [док 25k][q2] turn2 wall
ref_27b_restore="2.85"      # the restart-restore 25k turn2, reuse=disk
ref_flash_session="17.22"   # EXP-007 live (2×262144, 2026-11-17→18)
ref_flash_followup="1.58"
ref_flash_docq="10.44"
ref_flash_restore="1.89"
# ref_27b_parallel_* not taken (gfctl never had them) — cmp_ref always WARNs «не снят».

# Purpose: a profile's agent-check reference value — the scalar
#   ref_<profile_no_hyphens>_<metric> (hyphens → underscores). The metrics:
#   session | followup | restore | docq. A 1:1 gfctl ref_get port.
#
# @param 1: profile_id      # the canonical profile id
# @param 2: string          # the metric (session|followup|restore|docq)
# @stdout string            # seconds ('' = the reference not taken)
# @returns integer          # always 0
ref_get() {
  local name="ref_$(printf '%s' "$1" | tr '-' '_')_$2"
  printf '%s\n' "${!name:-}"
}

# Purpose: the profile's probe ladder — the probe_ladder_<id> scalar
#   (hyphens → underscores); '-' = no probe (single), the values
#   space-separated in DESCENDING order (the first that loads = the canon).
#
# @param 1: profile_id      # the canonical profile id
# @stdout string            # the ladder ('196608 163840 131072') or '-'
# @returns integer          # always 0
profile_ladder() {
  local name="probe_ladder_$(printf '%s' "$1" | tr '-' '_')"
  printf '%s\n' "${!name:--}"
}

# Purpose: normalize a profile alias to the canonical id (R1): 27b and the
#   gfctl legacy names (27b-single/single) → 27b; 27b-parallel and legacy
#   (27b-multi/multi) → 27b-parallel; flash and legacy flash-multi → flash;
#   a canon passes as is.
#
# @param 1: string          # an alias (incl. gfctl legacy) or a canonical id
# @stdout profile_id        # the canonical id (only on rc 0)
# @returns integer          # 0 — the canon printed; 1 — an unknown value
resolve_profile() {
  case "$1" in
    27b|27b-single|single)         echo 27b ;;
    27b-parallel|27b-multi|multi)  echo 27b-parallel ;;
    flash|flash-multi)             echo flash ;;
    *) return 1 ;;
  esac
}
