# shellcheck shell=bash
# ── hipfire: pulling models from the hipfire registry ───────────────────────
# The engine_pull_model hook (contract §2.3) — a port from the hfctl
# lib/models.sh.

# Purpose: pull one model (or a draft sidecar) from the hipfire registry
#   into $MODELS_DIR — idempotent: a sha256 verification inside
#   `hipfire pull`.
#
# Side effects: files in $MODELS_DIR (a bind mount of the container's
#   models home); a podman subprocess + the network (the image is pulled
#   when missing); stdout — a log line and the pull output's last 2 lines
#   (stderr merged into stdout); touches no globals or stack state.
#
# Limitations/assumptions: requires the IMAGE and MODELS_DIR globals (the
#   values may be passed by the caller's env prefix:
#   `MODELS_DIR=… engine_pull_model …`) and podman; the tag's validity is
#   NOT checked — an unknown tag is refused by the registry with a
#   non-zero return; due to `set -o pipefail` in the dispatcher the pull's
#   refusal survives through the tail pipe. The /home/hipfire/… mount
#   path — hipfire's container dialect.
#
# @param 1: /^[\w.-]+:[\w.-]+$/    # a registry tag: a model or a draft sidecar
# @returns integer                 # 0 — the model in place (or already was); non-zero — a podman/pull refusal
engine_pull_model() {
  local tag="$1"
  log "тяну модель $tag"
  podman run --rm -v "$MODELS_DIR:/home/hipfire/.hipfire/models" "$IMAGE" \
    hipfire pull "$tag" --yes 2>&1 | tail -2
}
