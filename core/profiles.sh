# shellcheck shell=bash
# ── profiles: registry mechanics (core) ─────────────────────────────────────
# The profile format v2 — ONE FILE per profile: engines/<eng>/profiles/<id>.env,
# sourced into P_* variables (until 2026-11-27: a profile_<id> '|'-row).
# The core contract — fields 1–5 by the numbers; 6+ — the adapter dialect;
# the tails (ladder, references) — the same file:
#   P_MODEL / P_MODELS / P_DRAFT / P_RAM_GIB / P_DESC   # the contract 1–5
#   P_SESSIONS / P_CTX                                  # 6 / 7 (adapter)
#   P_CACHE_RAM / P_CACHE_DISK                          # 8 in bytes (adapter;
#                    # profile_field 8 assembles the legacy 'ram/disk' form)
#   P_SERVE_ARGS                                        # 9 (adapter)
#   P_PROBE_LADDER                                      # the probe ladder ('-' = none)
#   P_REF_<METRIC>  # session|followup|restore|docq — the agent-check references
# profile_field <id> <1..9> keeps the NUMERIC contract (the readers do not
# change); the files replace only the profile_<id> rows. The adapter must
# still define PROFILE_LIST, PROFILE_DEFAULT and resolve_profile (rc 1 on
# unknown). A new adapter's registry (stage 3+) lands on the same gates
# without core edits — now by dropping profiles/<id>.env files.

# Purpose: source a profile file into the P_* variables. Resets the previous
#   P_* set first — no cross-profile leakage (the files are data, the values
#   may contain expansions: sourced, not parsed).
#
# Side effects: sets/unsets P_* globals in the caller's shell; touches no
#   files. Requires ADAPTER_DIR (the adapter's registry dir).
#
# @param 1: string       # canonical profile id
# @returns integer      # 0 — sourced; 1 — no ADAPTER_DIR or no such file
profile_src() {
  [ -n "${ADAPTER_DIR:-}" ] && [ -f "$ADAPTER_DIR/profiles/$1.env" ] || return 1
  local v
  for v in $(compgen -A variable | grep '^P_'); do unset "$v"; done
  . "$ADAPTER_DIR/profiles/$1.env"
}

# Purpose: the N-th field (1-based) of a profile — from the profile FILE
#   (profile_src): 1 — default model, 2 — all models (space-separated),
#   3 — draft sidecar ('-' = none), 4 — RAM-gate threshold in whole GiB,
#   5 — description, 6 — sessions, 7 — context, 8 — the cache tiers
#   'ram/disk' in bytes (assembled from P_CACHE_RAM/P_CACHE_DISK), 9 — the
#   serve flags. 6+ — the adapter dialect; the core reads only 1–5.
#
# Side effects: prints only the field to stdout; runs in a SUBSHELL — the
#   caller's shell is not polluted with P_*.
#
# Limitations/assumptions: the id is taken AS IS — aliases are not resolved
#   (the adapter's resolve_profile normalization is the caller's duty).
#   Requires the adapter's profiles/ dir (after engine_load). A number
#   beyond the field count yields an empty string with rc 0 (the former
#   cut semantics); a non-numeric N is rc 1.
#
# @param 1: string        # canonical adapter profile id
# @param 2: /^[0-9]+$/   # field number (core contract: 1–5)
# @stdout string          # field value (empty string when N is beyond the field count)
# @returns integer        # 0 — field printed; 1 — unknown profile or non-numeric N
profile_field() {
  (
    profile_src "$1" || exit 1
    case "$2" in
      1) printf '%s\n' "${P_MODEL:-}" ;;
      2) printf '%s\n' "${P_MODELS:-}" ;;
      3) printf '%s\n' "${P_DRAFT:-}" ;;
      4) printf '%s\n' "${P_RAM_GIB:-}" ;;
      5) printf '%s\n' "${P_DESC:-}" ;;
      6) printf '%s\n' "${P_SESSIONS:-}" ;;
      7) printf '%s\n' "${P_CTX:-}" ;;
      8) printf '%s/%s\n' "${P_CACHE_RAM:-0}" "${P_CACHE_DISK:-0}" ;;
      9) printf '%s\n' "${P_SERVE_ARGS:-}" ;;
      [1-9]*) exit 0 ;;   # a number beyond the field count — empty, rc 0
      *) exit 1 ;;        # non-numeric — the former cut error
    esac
  )
}

# Purpose: the machine's whole available memory pool in whole GiB — MemTotal
#   from /proc/meminfo (APU: the iGPU shares LPDDR with the OS, so the RAM
#   gate looks at MemTotal, not MemAvailable).
#
# Side effects: prints only the number to stdout; reads /proc/meminfo;
#   changes nothing.
#
# Limitations/assumptions: no parameters; rounds down (awk printf "%d");
#   a missing MemTotal line yields empty stdout.
#
# @stdout integer           # whole GiB of the total pool (MemTotal/1048576, rounded down)
# @returns integer          # awk rc — 0 even with empty output
ram_pool_gib() {
  awk '/MemTotal/{printf "%d", $2/1048576}' /proc/meminfo
}

# Purpose: profile RAM gate — refuse BEFORE any downloading if the machine's
#   whole pool (ram_pool_gib) is below the threshold from field 4 of the
#   adapter profile table.
#
# Side effects: reads the LCTL_FORCE env flag ('1' — bypass; cmd_bootstrap/
#   cmd_use set the same via --force) — on bypass a warn() goes to stderr
#   with the threshold and actual pool numbers; on refusal — ERROR lines to
#   stderr (threshold, actual pool, explanation — field 5 of the adapter
#   registry — and the list of profiles passing the gate) and exit 1 —
#   terminating the whole dispatcher process. Touches no files; reads
#   /proc/meminfo (via ram_pool_gib).
#
# Limitations/assumptions: prof is a canonical id (the live cmd_bootstrap and
#   cmd_use calls run strictly after the adapter's resolve_profile). Requires
#   the adapter profile table, profile_avail_list and warn from the
#   dispatcher. Locals prof/need/have on one line: prof — the argument,
#   need — the field-4 threshold, have — the machine pool, both whole GiB.
#
# @param 1: string      # canonical profile id (the gate checks its threshold — field 4)
# @returns integer      # always 0 on return (including a force bypass) —
#   refusal terminates the process with exit 1, the caller cannot catch it
profile_gate() {
  local prof="$1" need have
  if [ "${LCTL_FORCE:-}" = 1 ]; then
    need=$(profile_field "$prof" 4); have=$(ram_pool_gib)
    [ "$have" -ge "$need" ] || warn "--force: RAM-гейт обойдён (нужно ≥${need} GiB, есть ${have}) — движок может отказать в загрузке"
    return 0
  fi
  need=$(profile_field "$prof" 4); have=$(ram_pool_gib)
  [ "$have" -ge "$need" ] || {
    # explanation — field 5 of the adapter registry (the core knows no engine details)
    echo "ERROR: профиль $prof требует ≥${need} GiB единого пула памяти ($(profile_field "$prof" 5))" >&2
    echo "       На этой машине: ${have} GiB. Доступные профили: $(profile_avail_list)" >&2
    exit 1
  }
}

# Purpose: which profiles pass the RAM gate on this machine (for the refusal
#   texts of profile_gate and doctor diagnostics).
#
# Side effects: prints only a string to stdout; reads PROFILE_LIST and the
#   adapter profile table, reads /proc/meminfo once per profile
#   (ram_pool_gib).
#
# Limitations/assumptions: no parameters; the same threshold (field 4) as
#   profile_gate, without the force bypass; locals p/out on one line:
#   p — iteration over PROFILE_LIST (space-separated), out — the accumulated
#   list.
#
# @stdout string            # canonical ids separated by spaces that passed the gate; '—' if none
# @returns integer          # always 0 — final echo
profile_avail_list() {
  local p out=""
  for p in $PROFILE_LIST; do
    [ "$(ram_pool_gib)" -ge "$(profile_field "$p" 4)" ] && out="$out $p"
  done
  echo "${out:-—}"
}
