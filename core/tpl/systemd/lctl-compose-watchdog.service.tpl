[Unit]
Description=__ENGINE__ watchdog (lctl): поднимает стек после нештатного падения

[Service]
Type=oneshot
# ВАЖНО: без KillMode=process systemd при завершении oneshot-юнита убивает
# весь cgroup — вместе с только что поднятым контейнером (SIGTERM/143).
KillMode=process
# резолюция движка в _watchdog: юнит сам пишет LCTL_ENGINE
Environment=LCTL_ENGINE=__ENGINE__
# CONTAINERS_CONF стека: tracked-файл клона core/tpl — существует всегда
Environment=CONTAINERS_CONF=__STACK_DIR__/core/tpl/lctl-containers.conf
ExecStart=/usr/bin/env bash __STACK_DIR__/lctl _watchdog
