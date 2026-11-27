# gufo compose stack (генерируется engine_write_compose из этого golden'а;
# ручные правки теряются — служебная строка движка рендерится под профиль).
# Переводы F9-флагов gfctl (task 3.1 §1.3): devices kfd+dri, group_add
# keep-groups, ipc host, memlock -1:-1, userns keep-id:uid=1000,gid=1000,
# порт bind:port:port, сет весов /models:ro, кэш-каталог профиля /cache.
# `name: gufo` — пин compose-проекта (эксклюзив с hipfire бесплатен).
name: gufo
services:
  gufo:
    image: __IMAGE__
    devices:
      - /dev/kfd
      - /dev/dri
    group_add:
      - keep-groups
    ipc: host
    ulimits:
      memlock:
        soft: -1
        hard: -1
    userns_mode: keep-id:uid=1000,gid=1000
    ports:
      - "__BIND__:__PORT__:__PORT__"
    volumes:
      - "__MODELS_DIR__:/models:ro"
      - "__CACHE_DIR__:/cache"
    command: __SERVE_ARGS__
