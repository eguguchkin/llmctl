name: halogen
services:
  halogen:
    image: __IMAGE__
    # halogen-flash-server: закрытый движок, entrypoint без аргумента = `all`
    # (engine 8730 loopback + api 0.0.0.0:__PORT__ в одном контейнере).
    # Конфиг — ТОЛЬКО env HALOGEN_* (CLI нет); переопределяем только отличия
    # от шипед-дефолтов (копия дефолта — копия, которая устаревает).
    devices:
      - /dev/kfd
      - /dev/dri
    group_add:
      - keep-groups
    ipc: host                      # load-bearing: без shared namespace GPU-рантайм умирает на старте
    ulimits:
      memlock:
        soft: -1
        hard: -1
    userns_mode: keep-id:uid=1000,gid=1000   # rootless-паттерн gufo: /cache пишет от ai
    ports:
      - "__BIND__:__PORT__:__PORT__"   # внутренний API-порт = внешний (грабля Round 6)
    environment:
      HALOGEN_API_PORT: "__PORT__"    # фронт-порт = внешний (дефолт образа 8731; Round 6: публикуется только он)
      HALOGEN_CHECKPOINT: "__CHECKPOINT__"
      # пусто = текстовый (гейт смоука той же таблицей — parity w43);
      # "1" = vision sidecar beside checkpoint (vision живьём)
      HALOGEN_VISION_TOWER: "__VISION_TOWER__"
      HALOGEN_KV_SLOTS: "__KV_SLOTS__"
      HALOGEN_CTX: "__CTX__"                    # дефолт образа — 262144; рендерим явно: профиль ≠ дефолта должен поднимать свой ctx
      HALOGEN_KV_POOL_POSITIONS: "__KV_POOL__"  # 2×CTX — совпадает с авто-выбором движка; иначе KV_POOL_FIT ужал бы до пола (F41)
      HALOGEN_KV_POOL_FIT: "__KV_POOL_FIT__"    # 1 = авто (дефолт образа); 27b-parallel: 0 — аллокатор отказывает, а не ужимает пул
      HALOGEN_CACHE_DIR: /cache       # диск-тир prompt cache (~27 KiB/токен, LRU 64G дефолт)
      HALOGEN_MODEL_ID: "__MODEL_ID__"  # канон llmctl: /v1/models, /health и эхо ответов
    volumes:
      - "__MODELS_DIR__:/models:ro"   # только свой сет: чужая модель → 404
      - "__CACHE_DIR__:/cache"        # rw: движок дописывает KV-rows за запросом
    stop_grace_period: 60s            # SIGTERM: движок дописывает последнюю реплику кэша на диск
