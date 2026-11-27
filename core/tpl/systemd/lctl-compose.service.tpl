[Unit]
Description=__ENGINE__ serve (podman compose stack, lctl)
After=podman-user-wait-network-online.service

[Service]
Type=oneshot
RemainAfterExit=yes
# не убивать cgroup контейнеров при остановке юнита
KillMode=process
WorkingDirectory=__STACK_DIR__
# резолюция движка в _boot/_watchdog: юниты сами пишут LCTL_ENGINE
Environment=LCTL_ENGINE=__ENGINE__
# CONTAINERS_CONF стека: tracked-файл клона core/tpl — существует всегда
Environment=CONTAINERS_CONF=__STACK_DIR__/core/tpl/lctl-containers.conf
ExecStart=/usr/bin/env bash __STACK_DIR__/lctl _boot
ExecStop=__PODMAN_BIN__ compose __CF__ stop
TimeoutStartSec=900
Restart=on-failure
RestartSec=30

[Install]
WantedBy=default.target
