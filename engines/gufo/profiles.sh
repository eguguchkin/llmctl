# shellcheck shell=bash
# ── gufo: the profile registry (the format is the core contract, core/profiles.sh) ─
# Format v2 — ONE FILE per profile: profiles/<id>.env, sourced into P_*
# variables by profile_src (core/profiles.sh). This file keeps only the
# registry's skeleton: the list, the default, the alias normalization and
# the P_*-file readers (ref_get / profile_ladder). The values and their
# comments live in the profile files themselves.
# The canon names are R1 (agnostic): 27b-single→27b,
# 27b-multi→27b-parallel, flash-multi→flash. The values are the legacy
# lib/profiles.sh lineage (AGENT-CONFIGS pp.3–4; a divergence
# without a new window is forbidden).
#
# @typedef profile_id: '27b' | '27b-parallel' | 'flash'
# @typedef weight_set: '27b' | 'flash'

PROFILE_LIST="27b 27b-parallel flash"
# @type profile_id PROFILE_DEFAULT=27b
PROFILE_DEFAULT=27b

# Purpose: a profile's agent-check reference value — P_REF_<METRIC> from
#   the profile file (metrics: session | followup | restore | docq). The
#   1:1 ref_get lineage.
#
# @param 1: profile_id      # the canonical profile id
# @param 2: string          # the metric (session|followup|restore|docq)
# @stdout string            # seconds ('' = the reference not taken)
# @returns integer          # always 0
ref_get() {
  (
    profile_src "$1" || exit 0
    local var="P_REF_$(printf '%s' "$2" | tr '[:lower:]' '[:upper:]')"
    printf '%s\n' "${!var:-}"
  )
}

# Purpose: the profile's probe ladder — P_PROBE_LADDER from the profile
#   file; '-' = no probe (single), the values space-separated in DESCENDING
#   order (the first that loads = the canon).
#
# @param 1: profile_id      # the canonical profile id
# @stdout string            # the ladder ('196608 163840 131072') or '-'
# @returns integer          # always 0
profile_ladder() {
  (
    profile_src "$1" || { printf -- '-\n'; exit 0; }
    printf '%s\n' "${P_PROBE_LADDER:--}"
  )
}

# Purpose: normalize a profile alias to the canonical id (R1): 27b and the
#   legacy names (27b-single/single) → 27b; 27b-parallel and legacy
#   (27b-multi/multi) → 27b-parallel; flash and legacy flash-multi → flash;
#   a canon passes as is.
#
# @param 1: string          # an alias (incl. legacy) or a canonical id
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
