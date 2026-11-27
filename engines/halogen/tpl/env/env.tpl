# lctl (генерируется при каждом start; ручные правки не переживают start —
# тонкие настройки: реестр профилей profiles.sh адаптера)
# канон ядра (пишет core write_env) — HALOGEN_*-ключи инертные display-значения
# (compose halogen читает rendered-литералы из compose.yml; .env-интерполяций
# нет; конфиг движка — env контейнера, рендерится stack_files.sh)
LCTL_ENGINE=__ENGINE__
LCTL_PROFILE=__PROFILE__
LCTL_MODEL=__MODEL__
LCTL_PORT=__PORT__
LCTL_BIND=__BIND__
HALOGEN_MODELS=__MODELS_DIR__
HALOGEN_STATE_DIR=__STATE_DIR__
HALOGEN_IMAGE=__IMAGE__
