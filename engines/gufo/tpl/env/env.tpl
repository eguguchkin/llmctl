# lctl (генерируется при каждом start; ручные правки не переживают start —
# тонкие настройки: реестр профилей profiles.sh + canon.env probe-канона)
# канон ядра (пишет core write_env) — GUFO_*-ключи инертные display-значения
# (compose gufo читает rendered-литералы из compose.yml; .env-интерполяций нет;
# probe-канон контекста — состояние, живёт в .data/gufo/profiles/canon.env)
LCTL_ENGINE=__ENGINE__
LCTL_PROFILE=__PROFILE__
LCTL_MODEL=__MODEL__
LCTL_PORT=__PORT__
LCTL_BIND=__BIND__
GUFO_MODELS=__MODELS_DIR__
GUFO_STATE_DIR=__STATE_DIR__
GUFO_IMAGE=__IMAGE__
