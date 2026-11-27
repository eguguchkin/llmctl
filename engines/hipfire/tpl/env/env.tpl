# lctl (generated on every start; manual edits do not survive a start —
# fine engine tuning: hipfire config set, see usage)
# the core canon (written by core write_env) — engine keys in the HIPFIRE_* namespace
LCTL_ENGINE=__ENGINE__
LCTL_PROFILE=__PROFILE__
LCTL_MODEL=__MODEL__
LCTL_PORT=__PORT__
LCTL_BIND=__BIND__
# fix:env-model — compose reads ${HIPFIRE_MODEL:-<default>}: without the key the
#   profile's model never reaches compose (the live-window defect 2026-11-22)
HIPFIRE_MODEL=__MODEL__
HIPFIRE_UI=0
HIPFIRE_SERVE_ARGS=
HIPFIRE_MODELS_PATH=__MODELS_DIR__
HIPFIRE_STATE_DIR=__STATE_DIR__
HIPFIRE_IMAGE=__IMAGE__
