# shellcheck shell=bash
# ── pulling models: registry-driven mechanics (core) ─────────────────────────
# The module reads IMAGE (dispatcher); delivering a single tag is the adapter
# hook engine_pull_model (mount path and pull command are engine dialect,
# contract §2.3). Profile data comes from profile_field (core/profiles.sh,
# registry format — core contract). Called from commands.sh (bootstrap / use
# / cmd_pull).

# Purpose: pull the whole model set of a profile (registry field 2) and its
#   draft sidecar (field 3) if the profile declares one; before that,
#   guarantee the local presence of the IMAGE (`podman pull`, retry on the
#   first failure).
#
# Side effects: via engine_pull_model — files under $MODELS_DIR and network
#   model pulls; log lines and pull output tails to stdout.
#
# Limitations/assumptions: prof is a canonical id (normalize_profile via the
#   adapter's resolve_profile is the caller's duty: unknown id →
#   profile_field returns 1, and `set -e` aborts the command); requires the
#   adapter profile table and the engine_pull_model hook; the RAM gate
#   (profile_gate) is NOT checked here — that is the caller's step before
#   downloading; "-" or an empty field 3 means a draft-less profile and is
#   silently skipped.
#
# @param 1: string      # canonical profile id
# @returns integer     # 0 — the whole set and draft are in place; non-zero —
#   profile_field or any engine_pull_model failed (set -e)
pull_profile_models() {
  local prof="$1" tag draft
  podman image exists "$IMAGE" || podman pull "$IMAGE" >/dev/null || podman pull "$IMAGE"
  for tag in $(profile_field "$prof" 2); do
    engine_pull_model "$tag"
  done
  draft=$(profile_field "$prof" 3)
  [ "$draft" != "-" ] && [ -n "$draft" ] && engine_pull_model "$draft" || true
}
