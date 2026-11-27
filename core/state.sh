# shellcheck shell=bash
# ── model directories per set (profile isolation: the server sees only its
# own set → a request with a foreign model gets a 404 instead of a silent
# swap) ──────────────────────────────────────────────────────────────────────
# The set name for a profile comes from the adapter hook engine_model_set
# (contract §2.3); the core owns the MODELS_DIR redirection mechanics. The
# per-profile state dirs ($STATE_BASE/<prof>/{config,kernel}) are created by
# podman on the first compose bind mount (rootless creates a missing bind
# source); lctl only reads them (doctor) and removes them (uninstall).

# Purpose: redirect the MODELS_DIR global (models bind mount) to the profile
#   set's directory and create that directory.
#
# Side effects: overwrites the MODELS_DIR global (declared in engine_load;
#   bootstrap/use re-set it through this same function, cmd_pull via a direct
#   env prefix); mkdir -p of the set dir under $MODELS_BASE; prints nothing
#   to stdout.
#
# Limitations/assumptions: requires the MODELS_BASE global and the adapter
#   engine_model_set hook; the profile id is taken as is (resolve_profile of
#   the adapter is the caller's job; an unknown id falls to the default set
#   via the hook's default branch).
#
# @param 1: string # canonical profile id
# @returns integer  # always 0 on return — normal mkdir; its failure terminates the process (set -e)
set_models_dir() { MODELS_DIR="$MODELS_BASE/$(engine_model_set "$1")"; mkdir -p "$MODELS_DIR"; }
