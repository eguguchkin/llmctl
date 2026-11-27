# shellcheck shell=bash
# ── hipfire: the profile registry (the content is the adapter's, the format is the core contract) ──
# The format: default_model|all_models (space)|draft_tag ('-' = none)|min_ram_gib|description
# The profile names are engine-agnostic (1.2): flash / 27b / 27b-parallel
# (the model is an adapter detail). The old names
# (flash-multi/27b-single/27b-slots) are valid transitional aliases:
# resolve_profile maps them onto the canon; the .env canon stores the NEW
# name.
#
# @typedef profile_id: '27b' | '27b-parallel' | 'flash'

PROFILE_LIST="27b 27b-parallel flash"
profile_27b="qwen3.8:27b-mq4-xts|qwen3.8:27b-mq4-xts|qwen3.8:27b-draft-mq4|58|singleton+DFlash (максимум соло-скорости)"
profile_27b_parallel="qwen3.8:27b-mq4-xts|qwen3.8:27b-mq4-xts|qwen3.8:27b-draft-mq4|58|multi_slot ${SLOTS}×${MAX_SEQ} (HOL-изоляция; −25% агрегат)"
profile_flash="qwen3.8:flash-next-mq4-xts|qwen3.8:flash-next-mq4-xts|-|80|Flash-Next mq4-xts, VMM fn-lanes (настоящий батчинг; требует ≥80 GiB пула)"
# @type profile_id PROFILE_DEFAULT=27b
PROFILE_DEFAULT=27b
# the flash RAM-gate threshold is checked by field 4; 80 = 72 (the registry
# minimum) + a margin (the lane store + the OS); calibrated on a 128 GB
# machine.

# Purpose: normalize a profile alias to the canonical id: 27b|single|mq6|mq4 →
#   27b (legacy: 27b-single); 27b-parallel|slots → 27b-parallel (legacy:
#   27b-slots); flash|multi|flash-next → flash (legacy: flash-multi); a canon
#   passes as is.
#
# Side effects: only printing the id to stdout; touches no files, globals
#   or env.
#
# Limitations/assumptions: the argument — the string as is (the live calls
#   pass the user's lctl start <engine> <profile> / pull / use alias input);
#   an unrecognized value is refused by rc 1 without output, the refusal
#   text is the caller's (die with PROFILE_LIST). The legacy names are a
#   transitional period (1.2), only the new ones in usage/docs.
#
# @param 1: string          # an alias (incl. legacy) or a canonical id
# @stdout profile_id        # the canonical id (only on rc 0)
# @returns integer          # 0 — the canon printed; 1 — an unknown value (empty stdout)
resolve_profile() {
  case "$1" in
    27b|27b-single|single|mq4) echo 27b ;;
    27b-parallel|27b-slots|slots)  echo 27b-parallel ;;
    flash|flash-multi|flash-next|multi) echo flash ;;
    *) return 1 ;;
  esac
}
