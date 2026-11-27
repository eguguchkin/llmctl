# shellcheck shell=bash
# ── halogen: the profile registry (the format is the core contract, core/profiles.sh) ──
# Format v2 — ONE FILE per profile: profiles/<id>.env, sourced into P_*.
# Two profiles: flash (Flash-Next, the 0.20.7+ lineage) and 27b (the ht4
# 4-bit checkpoint — halogen 0.21.0+ serves it; the 2026-11-25 «no 27b»
# decision reversed by the owner on 2026-11-28 when the 27b-ht4 weights
# landed). This file keeps only the registry's skeleton: the
# list, the default, the alias normalization and the P_*-file readers
# (ref_get / profile_ladder). The values and their «why» comments live in
# the profile file itself.
#
# @typedef profile_id: 'flash' | '27b'
# @typedef weight_set: 'halogen_flash' | 'halogen_27b'

PROFILE_LIST="flash 27b"
# @type profile_id PROFILE_DEFAULT=flash
PROFILE_DEFAULT=flash

# Purpose: a profile's agent-check reference value — P_REF_<METRIC> from
#   the profile file (metrics: session | followup | restore | docq). A 1:1
#   ref_get port.
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
#   file; halogen is always '-' (the pool is adjusted by the engine,
#   KV_POOL_FIT=1).
#
# @param 1: profile_id      # the canonical profile id
# @stdout string            # the ladder or '-'
# @returns integer          # always 0
profile_ladder() {
  (
    profile_src "$1" || { printf -- '-\n'; exit 0; }
    printf '%s\n' "${P_PROBE_LADDER:--}"
  )
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
    27b) echo 27b ;;
    *) return 1 ;;
  esac
}
