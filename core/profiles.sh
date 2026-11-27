# shellcheck shell=bash
# ── profiles: registry mechanics (core) ─────────────────────────────────────
# The profile line format — CORE CONTRACT for fields 1–5 ('|'-separated,
# contents are the adapter's): 1 default model, 2 all models of the set
# (space), 3 draft tag ('-' = none), 4 RAM-gate threshold in whole GiB,
# 5 description for logs. Fields 6+ are adapter dialect extensions (slots/
# ctx/cache limits/ladders — live adapters ship 9-field tables); the core
# never reads them. The adapter must define PROFILE_LIST, PROFILE_DEFAULT,
# profile_<id> variables (hyphens→underscores) and resolve_profile <alias>
# (rc 1 on unknown). This is how any new adapter's registry (stage 3+) lands
# on the same gates without core edits.

# Purpose: the N-th field (1-based, '|' separator) of a profile record from
#   the adapter table: 1 — default model, 2 — all models of the set
#   (space-separated), 3 — draft sidecar ('-' = none), 4 — RAM-gate
#   threshold in whole GiB, 5 — description for logs; 6+ — adapter dialect.
#
# Side effects: prints only the field to stdout; tr and cut subprocesses;
#   the profile_* table is read via indirect expansion ${!name} (name:
#   profile_ with the id, hyphens replaced by underscores); touches no files
#   or globals.
#
# Limitations/assumptions: the id is taken AS IS — aliases are not resolved
#   (the adapter's resolve_profile normalization is the caller's duty).
#   Requires the adapter's profile_* table (after engine_load). The field
#   number is not validated: N beyond the field count yields an empty string
#   with rc 0 (cut); a non-numeric N is a cut error.
#
# @param 1: string        # canonical adapter profile id
# @param 2: /^[0-9]+$/   # table field number (core contract: 1–5)
# @stdout string          # field value (empty string when N is beyond the field count)
# @returns integer        # 0 — field printed; 1 — unknown profile (empty stdout)
profile_field() {
  local name="profile_$(echo "$1" | tr '-' '_')" v
  v="${!name:-}"
  [ -n "$v" ] || return 1
  echo "$v" | cut -d'|' -f"$2"
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
