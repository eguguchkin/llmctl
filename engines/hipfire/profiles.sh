# shellcheck shell=bash
# ── hipfire: the profile registry (the format is the core contract, core/profiles.sh) ──
# Format v2 — ONE FILE per profile: profiles/<id>.env, sourced into P_*
# variables. The hipfire files carry the 5 core-contract fields only (no
# adapter dialect fields). The profile names are engine-agnostic (1.2):
# flash / 27b / 27b-parallel; the old names (flash-multi/27b-single/
# 27b-slots) are valid transitional aliases: resolve_profile maps them
# onto the canon; the .env canon stores the NEW name.
#
# @typedef profile_id: '27b' | '27b-parallel' | 'flash'

PROFILE_LIST="27b 27b-parallel flash"
# @type profile_id PROFILE_DEFAULT=27b
PROFILE_DEFAULT=27b
# the flash RAM-gate threshold (P_RAM_GIB=80) is checked by profile_field 4;
# 80 = 72 (the registry minimum) + a margin (the lane store + the OS);
# calibrated on a 128 GB machine.

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
