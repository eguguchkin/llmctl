# shellcheck shell=bash
# ── autostart: units (rendered from core/tpl), on/off/up/down, the boot unit,
#    the watchdog, locks and anomaly self-healing (core) ─────────────────────
# Engine specifics — only names via adapter globals: the pod ($ENGINE_POD)
# and the project label filter ($ENGINE_PROJECT; the project name is pinned
# by `name:` in the adapter's golden). Marker/lock/log — core paths (§4
# task 1.1): $STOP_MARKER, $LOCK_FILE, $LOG_DIR. Engine exclusivity (§3
# task 1.1): `on --engine E` with another engine active = an honest off of
# that one (by its adapter) → the normal start pipeline (the §А automat of
# cmd_start).

# ── константы GPU-гейта (env-переопределение — только для shell-приёмок) ────
KFD_NODE="${LCTL_KFD:-/dev/kfd}"             # the ROCm/NPU node; env LCTL_KFD — selfcheck
DRI_GLOB="${LCTL_DRI:-/dev/dri/renderD*}"    # the render-node glob; env LCTL_DRI — selfcheck
GPU_WAIT_TIMEOUT=60  # seconds to wait for GPU nodes before the first up in _boot (gpu_ready_or_die)
GPU_WAIT_INTERVAL=2  # the GPU-node poll interval in gpu_ready_or_die

# ── self-healing constants (env overrides — for the selfcheck battery only,
#    never overridden in prod) ───────────────────────────────────────────────
LOCK_STALE_SECS="${LCTL_LOCK_STALE:-900}"    # the "stuck lock holder" threshold, s
                                             # (= the unit's TimeoutStartSec: a legit
                                             # up is ≤ ~7 min + a tail; longer — a
                                             # SIGKILL survivor, see the 2026-11-21
                                             # window GOTCHAS)
HEAL_MAX="${LCTL_HEAL_MAX:-2}"               # the cap of storage self-heals per process
HF_ORPHAN_HEALS=0                            # the storage self-heal counter (global)

# Purpose: the "GPU nodes in place" predicate — /dev/kfd AND at least one
#   renderD*; the gate before any compose up in _boot/_watchdog: an early up
#   on a half-empty /dev/dri bakes an incomplete device snapshot into the
#   freshly created container.
#
# Side effects: prints and changes nothing — only the return code.
#
# Limitations/assumptions: takes the paths from KFD_NODE/DRI_GLOB (the top
#   of the file; env LCTL_KFD/LCTL_DRI — selfcheck acceptance, never
#   overridden in prod). compgen is a builtin, no external calls. On Halo
#   there may be no card0 at all (numbering starts at 1) — the predicate
#   deliberately does NOT look at card*.
#
# @returns integer # 0 — kfd present and renderD* present; 1 — otherwise
gpu_present() { [ -e "$KFD_NODE" ] && compgen -G "$DRI_GLOB" >/dev/null; }

# Purpose: wait for the GPU nodes to appear (gpu_present) before the first
#   compose up in _boot: a loop with the GPU_WAIT_INTERVAL interval up to
#   GPU_WAIT_TIMEOUT seconds; on timeout — die with diagnostics (kfd
#   present/absent + the ls /dev/dri output) — the unit will restart _boot
#   itself (Restart=on-failure), the cause stays in the journal instead of
#   a silent loop.
#
# Side effects: sleep GPU_WAIT_INTERVAL per waiting iteration; date +%s
#   (the deadline = start + GPU_WAIT_TIMEOUT); reading the /dev/dri dir
#   (ls, for diagnostics); on timeout die() terminates the whole dispatcher
#   process (rc 1).
#
# Limitations/assumptions: requires this file's gpu_present and die
#   (dispatcher). The budget is the same for "the nodes have not appeared
#   yet" and "never appeared" (60 s); amdgpu loads in seconds, the EFI-fb
#   stub gives card* WITHOUT renderD* — the renderD* gate filters it out.
#   One live call: cmd_boot before its up-attempt loop.
#
# @returns integer # 0 — the nodes are in place; on timeout does not return
#   (die: exit 1)
gpu_ready_or_die() {
  local deadline dri
  deadline=$(( $(date +%s) + GPU_WAIT_TIMEOUT ))
  while ! gpu_present; do
    if [ "$(date +%s)" -ge "$deadline" ]; then
      dri=$(ls /dev/dri 2>/dev/null || true)
      die "boot: GPU-ноды не появились за ${GPU_WAIT_TIMEOUT}с (kfd: $([ -e "$KFD_NODE" ] && echo есть || echo нет); /dev/dri: ${dri:-каталога нет или пуст}) — amdgpu не поднялся?"
    fi
    sleep "$GPU_WAIT_INTERVAL"
  done
}

# Purpose: `lctl up` (a hidden alias): raise the stack, removing the
#   explicit stop marker, and wait for server readiness.
#
# Side effects: rm -f of the $STOP_MARKER marker (absence — silent);
#   through hf_up_locked — creating/truncating the $LOCK_FILE lock file and
#   `podman compose up -d` (containers, image pull, the init model pull);
#   through wait_health (core/health.sh) — GET /health polling, log lines
#   and up to 300 bytes of the /health body to stdout; 5 s sleeps per
#   waiting iteration.
#
# Limitations/assumptions: requires the STACK_DIR, STOP_MARKER, CONTAINER
#   globals (dispatcher) and the wait_health function (core/health.sh).
#   The 600 s timeout is hard (bootstrap waits 900 itself; use — 600). A
#   `compose up -d` failure inside hf_up_locked (the rc passes through
#   pipefail) terminates the process via set -e even before wait_health.
#   Live calls: the dispatcher (`up`), cmd_start (§А-3 ensure/§А-2).
#
# @stdout string   # the hf_up_locked message + the wait_health output (a
#   waiting line, the /health body up to 300 bytes, «HEALTHY после Nс»)
# @returns integer # 0 — the stack is up and the server healthy; 1 — the
#   wait_health timeout or an early engine refusal (set -e terminates the
#   process with this rc)
cmd_up()   { rm -f "$STOP_MARKER"; hf_up_locked; wait_health 600; }

# Purpose: the single stack-stop implementation — an explicit stop marker +
#   `podman compose stop` (the last 2 output lines out).
#
# Side effects: mkdir -p of the marker dir ($DATA_DIR/$ENGINE); touch of the
#   $STOP_MARKER marker (BEFORE stop — the watchdog is muted even on a stop
#   failure); `podman compose stop` — stopping the containers (volumes,
#   stack files and the image are NOT removed; stderr merged into stdout,
#   the tail is the last 2 lines).
#
# Limitations/assumptions: requires the STOP_MARKER global (dispatcher) and
#   the adapter's ENGINE_COMPOSE_FILES array. Silencing/printing is the
#   caller's duty: cmd_down prints the output and lets rc through by
#   set -e, cmd_off silences both output and rc (`|| true`).
#
# @stdout string   # the last 2 lines of `podman compose stop`
# @returns integer # 0 — stopped; a non-zero rc — a compose stop failure
#   (pipefail lets it out, tail adds nothing)
stop_with_marker() { mkdir -p "${STOP_MARKER%/*}"; touch "$STOP_MARKER"; compose stop 2>&1 | tail -2; }

# Purpose: `lctl down` (a hidden alias): an EXPLICIT stack stop — with the
#   marker so the watchdog does not raise it back before the next `lctl up`.
#
# Side effects: stop_with_marker (the marker BEFORE stop + `podman compose
#   stop`); the echo of the summary line. Reads the adapter's compose files
#   from $STACK_DIR.
#
# Limitations/assumptions: requires the STACK_DIR global (dispatcher) and
#   this file's stop_with_marker. A compose stop failure terminates the
#   process via set -e without the summary line (the marker is already in
#   place — the watchdog muted).
#
# @stdout string   # the last 2 lines of `podman compose stop` + the line
#   «остановлен (контейнеры/файлы/образ целы; вотчдог молчит до 'lctl up')»
# @returns integer # 0 — stopped, the watchdog muted; a non-zero rc — a
#   compose stop failure (set -e terminates the process before the message)
cmd_down() { stop_with_marker; echo "остановлен (контейнеры/файлы/образ целы; вотчдог молчит до 'lctl up')"; }

# Purpose: switch off a FOREIGN engine F (the exclusive branch of
#   `on --engine` / `switch --engine`, §3 task 1.1): a full honest off with
#   F's adapter — its container/units/marker/linger; the .env canon is NOT
#   touched (the caller resets it — write_env will rewrite it at the new
#   engine's bootstrap).
#
# Side effects: a subshell with F's adapter loaded (engine_load in
#   isolation — the current engine's globals stay intact) and cmd_off F:
#   stop_with_marker, an explicit podman stop of F's container,
#   disable+removal of the ${F}-compose* units, daemon-reload, linger off.
#   A failure (no F adapter, an off failure) — rc ≠ 0.
#
# Limitations/assumptions: calls die (exit 1) when F has no adapter — the
#   caller must catch it (`|| die … the switch is aborted`: two stacks in
#   autostart are not allowed). Requires engine_load (dispatcher) and this
#   file's cmd_off.
#
# @param 1: string  # the engine id (= the adapter dir name)
# @returns integer # cmd_off F's rc in the subshell
engine_off_foreign() {
  local f="$1"
  ( engine_load "$f"; cmd_off )
}

# Purpose: the honest off — the implementation behind `lctl stop` (through
#   engine_off_foreign with the active engine's adapter) and the
#   `off --engine E` alias (the target engine: its adapter is loaded by
#   engine_load, the .env canon is NOT rewritten): the stack stopped, the
#   units removed, linger off; files/models/image intact.
#
# Side effects: stop_with_marker (the marker BEFORE stop + compose stop;
#   output and rc silenced — "the watchdog is muted even on a stop
#   failure", the cmd_down semantics) + an explicit podman stop of the main
#   container ($CONTAINER, silent and failure-tolerant — a compose stop can
#   be incomplete under the rootless-netns bug); systemctl --user disable
#   of $UNIT_NAME.service and $UNIT_NAME-watchdog.timer (stderr silenced,
#   rc — `|| true`); rm -f of the three unit files
#   ~/.config/systemd/user/{$UNIT_NAME.service, $UNIT_NAME-watchdog.service,
#   $UNIT_NAME-watchdog.timer}; systemctl --user daemon-reload; sudo
#   loginctl disable-linger $USER (the user's unit manager no longer
#   starts at boot and dies after all sessions log out); two stdout lines.
#
# Limitations/assumptions: the stack stops BEFORE the units are removed —
#   a oneshot unit holds no containers (compose up -d is detached),
#   ExecStop of an already finished unit would not run. Requires the
#   UNIT_NAME, STOP_MARKER globals (dispatcher) and this file's
#   stop_with_marker. Unsilenced systemctl daemon-reload and sudo
#   disable-linger under `lctl off` terminate the process via set -e with
#   their rc (the units are already removed by then); a call from
#   cmd_uninstall (commands.sh) via `|| true` disarms set -e inside the
#   function — there failures are tolerated and the run continues.
#
# @stdout string   # the two summary lines («ВЫКЛ: …» and «Файлы, модели и
#   образ целы. Вернуть: lctl start»)
# @returns integer # 0 — reached the end; daemon-reload/disable-linger
#   failures do not come back out (they terminate the process via set -e or
#   are silenced by the uninstall context)
cmd_off() {
  # A oneshot unit holds no containers (compose up -d is detached) — stop
  # the stack directly, otherwise ExecStop will not run for an already
  # finished unit.
  stop_with_marker >/dev/null 2>&1 || true
  # compose stop under the rootless-netns bug (AppArmor pasta denied signal)
  # dies on the init container BEFORE the main one → silently incomplete
  # stop; a direct podman stop does not do the project netns teardown and
  # always gets through (the 2026-11-21 window).
  podman stop "$CONTAINER" >/dev/null 2>&1 || true   # fix:off-stop
  systemctl --user disable --now "$UNIT_NAME.service" "$UNIT_NAME-watchdog.timer" 2>/dev/null || true   # fix:off-now (disable без --now оставлял активный таймер до daemon-reload — окно гонки тика вотчдога; gfctl 95bf4e4)
  rm -f "$HOME/.config/systemd/user/$UNIT_NAME.service" \
        "$HOME/.config/systemd/user/$UNIT_NAME-watchdog.service" \
        "$HOME/.config/systemd/user/$UNIT_NAME-watchdog.timer"
  systemctl --user daemon-reload
  # mute linger: in the off state the server must not jump up at boot.
  sudo loginctl disable-linger "$USER"
  echo "ВЫКЛ: сервер остановлен, с автозапуска снят (юниты удалены, linger off)."
  echo "Файлы, модели и образ целы. Вернуть: lctl start"
}

# Purpose: install/update the autostart configuration in systemd-user: the
#   compose service (ExecStart = bash $STACK_DIR/lctl _boot), the watchdog
#   service (ExecStart = $STACK_DIR/lctl _watchdog) and its minute timer;
#   enable them and turn linger on. The units are rendered from
#   core/tpl/systemd/ with the __ENGINE__ placeholder (the unit name is
#   computed by the core: $UNIT_NAME="$ENGINE-compose"); the units set
#   LCTL_ENGINE themselves (engine resolution in _boot/_watchdog goes
#   through env) and CONTAINERS_CONF (the clone's tracked core/tpl file).
#
# Side effects: mkdir -p ~/.config/systemd/user; render_tpl writes
#   ~/.config/systemd/user/$UNIT_NAME.service (from
#   core/tpl/systemd/lctl-compose.service.tpl with PODMAN_BIN=$(command -v
#   podman), STACK_DIR, the adapter's compose-file line and ENGINE) and
#   …-watchdog.service (tpl, STACK_DIR, ENGINE); the timer is rendered from
#   core/tpl/systemd/lctl-compose-watchdog.timer.tpl (ENGINE in the
#   Description); systemctl --user daemon-reload, enable
#   ($UNIT_NAME.service + $UNIT_NAME-watchdog.timer), start of the timer;
#   rm -f of the $STOP_MARKER marker; sudo loginctl enable-linger $USER;
#   a summary line to stdout.
#
# Limitations/assumptions: the units execute $STACK_DIR/lctl — in the
#   "clone = stack" layout the binary and the tree exist side by side by
#   the fact of the run; by the enable moment the compose files and .env
#   must already be in $STACK_DIR (bootstrap/cmd_use write them earlier).
#   enable ≠ an immediate compose-service start: it starts at boot (or
#   cmd_up raises the stack now), while the timer is active immediately
#   (the first tick OnBootSec=2min). Live call: cmd_start (§А: after
#   bootstrap or ensure/use — units last, Р1). Locals on one line:
#   unit_dir — the fixed ~/.config/systemd/user path; bin — the absolute
#   podman path (command -v). Requires the UNIT_NAME, STACK_DIR,
#   STOP_MARKER, CORE_TPL globals (dispatcher), the adapter's
#   ENGINE_COMPOSE_FILES array, render_tpl (stack_files.sh) and die. Under
#   set -e a failure of any unprotected step
#   (mkdir/render_tpl-die/systemctl/sudo) terminates the process.
#
# @stdout string   # the line «автозапуск ВКЛ (unit + watchdog-таймер 1м,
#   linger=yes)»
# @returns integer # always 0 on return — refusals are die (render_tpl)
#   or process termination via set -e
cmd_autostart() {
  local unit_dir="$HOME/.config/systemd/user" bin
  bin="$(command -v podman)"
  mkdir -p "$unit_dir"
  render_tpl "$CORE_TPL/systemd/lctl-compose.service.tpl" "$unit_dir/$UNIT_NAME.service" \
    PODMAN_BIN="$bin" STACK_DIR="$STACK_DIR" CF="${ENGINE_COMPOSE_FILES[*]}" ENGINE="$ENGINE"
  # the crash watchdog: rootless podman leaves no live observer after
  # `compose up -d` (verified by a kill test), so once a minute we check the
  # container is alive unless the stack was stopped EXPLICITLY (lctl down /
  # off write the marker).
  render_tpl "$CORE_TPL/systemd/lctl-compose-watchdog.service.tpl" "$unit_dir/$UNIT_NAME-watchdog.service" \
    STACK_DIR="$STACK_DIR" ENGINE="$ENGINE"
  render_tpl "$CORE_TPL/systemd/lctl-compose-watchdog.timer.tpl" "$unit_dir/$UNIT_NAME-watchdog.timer" \
    ENGINE="$ENGINE"
  systemctl --user daemon-reload
  systemctl --user enable "$UNIT_NAME.service" "$UNIT_NAME-watchdog.timer"
  systemctl --user start "$UNIT_NAME-watchdog.timer"
  rm -f "$STOP_MARKER"
  sudo loginctl enable-linger "$USER"
  echo "автозапуск ВКЛ (unit + watchdog-таймер 1м, linger=yes)"
}

# Purpose: self-heal of the storage orphan "already in use by an external
#   entity" (a libpod-DB vs podman storage-layer desync, the 2026-11-21
#   window GOTCHAS): extract the orphan container's ID from the up output,
#   remove it via containers-storage delete-container and return 0 — the
#   caller does one up retry. Guards: the HEAL_MAX cap per process
#   (HF_ORPHAN_HEALS); no containers-storage binary → a WARN with the manual
#   command, behavior as before; an ID visible to libpod is NOT an orphan,
#   must not be touched (insurance against deleting a live container under
#   the reverse desync).
#
# Side effects: on success — containers-storage delete-container <ID> (the
#   self-heal is counted in the HF_ORPHAN_HEALS global) and a log line; on
#   a heal refusal — a warn line to stderr. Deletes nothing except the
#   orphan from the text.
#
# Limitations/assumptions: requires the HF_ORPHAN_HEALS/HEAL_MAX globals
#   (the file header) and log/warn (dispatcher). The heal syntax is
#   containers-storage-delete-container(1) (no -f flags; a refusal → WARN,
#   behavior = the former one). The ID is searched by the signature
#   "already in use by <12..64-hex>"; the grep is silenced by `|| true` —
#   an empty ID = not an orphan (rc 1). Called from hf_up_locked and
#   hf_up_devsafe only when the container ≠ running (the happy path does
#   not call it).
#
# @param 1: string  # the full output of the failed `compose up` (2>&1)
# @stdout string   # a log line on success; warn lines on failure (stderr)
# @returns integer # 0 — the orphan found and removed; 1 — no signature /
#   the cap / no binary / libpod sees the ID / delete-container refused
hf_orphan_heal() {
  local id
  id=$(printf '%s' "$1" | { grep -oE 'already in use by [0-9a-f]{12,64}' || true; } | head -1 | awk '{print $5}')
  [ -n "$id" ] || return 1
  [ "$HF_ORPHAN_HEALS" -lt "$HEAL_MAX" ] || return 1        # кап за процесс
  command -v containers-storage >/dev/null || { warn "containers-storage нет в PATH — самолечение невозможно: sudo apt install containers-storage; вручную: containers-storage delete-container $id"; return 1; }
  podman inspect -f '{{.State.Status}}' "$id" >/dev/null 2>&1 && { warn "ID $id видит libpod — не сирота, самолечение отменено"; return 1; }
  HF_ORPHAN_HEALS=$((HF_ORPHAN_HEALS + 1))
  containers-storage delete-container "$id" || { warn "containers-storage delete-container $id отказался"; return 1; }
  log "storage-сирота $id удалена (external entity) — повторяю up"
}

# Purpose: reclaim stuck $LOCK_FILE holders — when the first `flock -n`
#   fails (up/_boot/_watchdog starved on SIGKILL survivors, the 2026-11-21
#   window GOTCHAS): identify the holders (fuser), kill -9 only if the
#   holder is older than LOCK_STALE_SECS AND its cmdline matches
#   `podman|lctl|slirp4netns|pasta` (the rootless-network helpers inherit
#   the lock's fd 9 from a compose up that ran inside the flock subshell —
#   live 2026-11-24, a 43h lock; GOTCHAS). A fresh holder (a healthy
#   parallel boot/watchdog/up) is untouched; no fuser — a silent degradation
#   to the former behavior ("skip").
#
# Side effects: reading /proc via fuser/ps; kill -9 of mature podman/lctl
#   holders (the kernel releases flock on fd close); spawns no processes in
#   the happy path (called only after a flock -n failure).
#
# Limitations/assumptions: requires the LOCK_FILE global and
#   LOCK_STALE_SECS (the file header). The 900 s threshold = the unit's
#   TimeoutStartSec: a watchdog/boot tick holds the lock for seconds, a
#   manual up > 15 min is legitimately impossible (the image is spun up,
#   the init model pull runs INSIDE the container). An argv spoof
#   (`exec -a`) can fool the cmdline predicate — the etimes threshold
#   narrows the window. Called from both up subshells.
#
# @returns integer # always 0 — failures (no fuser, the process vanished,
#   the kill did not take) are silenced; the caller decides "reclaim
#   failed" by the second flock -n
hf_lock_reclaim() {
  local pids p age args
  pids=$(fuser "$LOCK_FILE" 2>/dev/null) || return 0
  # no fuser (or no holders) — silent degradation, rc 0; the caller's second
  # flock -n decides
  for p in $pids; do
    kill -0 "$p" 2>/dev/null || continue
    age=$(ps -o etimes= -p "$p" 2>/dev/null || true); [ -n "$age" ] || continue
    [ "$age" -gt "$LOCK_STALE_SECS" ] || continue             # fresh — do not touch
    args=$(ps -o args= -p "$p" 2>/dev/null || true)
    printf '%s' "$args" | grep -qE 'podman|lctl|slirp4netns|pasta' || continue   # foreign — do not touch; slirp4netns/pasta inherit the lock's fd 9 (the compose up ran inside the flock subshell) — 43h holders of .lctl.lock, live 2026-11-24
    kill -9 "$p" 2>/dev/null || true                           # the kernel will release the flock
  done
}

# Purpose: the pod pristine check before up — $ENGINE_POD in the Created
#   state with an EMPTY InfraContainerID (a legacy of the falling-up era,
#   the 2026-11-21 window GOTCHAS) survives everything and breaks every
#   create: podman pod rm -f → a normal up will recreate the pod itself.
#   No pod / inspect refused (a fresh stack) → a no-op.
#
# Side effects: podman pod inspect (a read); on an empty INFRA ID — a warn
#   line and podman pod rm -f $ENGINE_POD (output silenced, a refusal
#   silenced by `|| true`).
#
# Limitations/assumptions: the pod name — the adapter's ENGINE_POD global
#   (the same project as CONTAINER and the
#   io.podman.compose.project=$ENGINE_PROJECT label). Called INSIDE the
#   lock of both up subshells before the first compose up — does not race
#   the watchdog. Requires warn (dispatcher).
#
# @returns integer # always 0 — an inspect refusal (no-op) and a successful rm give 0
hf_pod_pristine() {
  local infra
  infra=$(podman pod inspect "$ENGINE_POD" --format '{{.InfraContainerID}}' 2>/dev/null) || return 0
  [ -n "$infra" ] || { warn "$ENGINE_POD с пустым INFRA ID — пересоздаю"; podman pod rm -f "$ENGINE_POD" >/dev/null 2>&1 || true; }
}

# Purpose: `podman compose up -d` under a file lock: parallel raises (the
#   watchdog + the boot unit + a manual up) fight over the netns — only one
#   at a time is let through. On a busy lock — an attempt to reclaim stuck
#   holders (hf_lock_reclaim) and a second flock -n; on a storage orphan in
#   the up output (a container that is not running AND the "external
#   entity" signature) — hf_orphan_heal + one up retry (at most TWO up
#   attempts per call).
#
# Side effects: creating/truncating the $LOCK_FILE lock file (the fd 9
#   redirection in the subshell) with a non-blocking flock released on
#   subshell exit; on a busy lock — hf_lock_reclaim (kill -9 of mature
#   podman/lctl holders); hf_pod_pristine (a possible podman pod rm -f on
#   an empty INFRA ID); up to two `podman compose up -d` — starting the
#   containers (image pull, the init model pull); a podman inspect of the
#   container status; stdout — the skip message or the last 2 lines of the
#   compose output.
#
# Limitations/assumptions: requires the STACK_DIR, CONTAINER, LOCK_FILE
#   globals (dispatcher), compose (core/stack.sh) and this file's
#   hf_lock_reclaim/hf_pod_pristine/hf_orphan_heal. A lock race is NOT an
#   error: "up already running — skip" and return 0 — boot/watchdog call it
#   concurrently on purpose; the reclaim touches only mature
#   (LOCK_STALE_SECS) podman/lctl holders. The final up's rc goes up
#   (return rc): the happy path / a healed up → 0, an unhealed failure →
#   rc 1 (cmd_up dies via set -e before wait_health — as before). The heal
#   runs ONLY when the container ≠ running (the happy path without extra
#   inspect branches). This file's live caller: cmd_up (cmd_start raises
#   through cmd_up).
#
# @stdout string   # «up уже выполняется — пропуск» on a busy lock or the
#   last 2 lines of the last `compose up -d`
# @returns integer # 0 — the stack is up (immediately or after self-healing)
#   or a race skip; a non-zero rc — a final `compose up -d` failure
hf_up_locked() {
  ( if ! flock -n 9; then
      hf_lock_reclaim              # fix:lock-reclaim
      flock -n 9 || { echo "up уже выполняется — пропуск"; return 0; }
    fi
    hf_pod_pristine                # fix:pod-infra
    local out rc=0
    out=$(compose up -d 2>&1) || rc=$?
    if [ -n "$out" ]; then printf '%s\n' "$out" | tail -2; fi
    [ "$(podman inspect -f '{{.State.Status}}' "$CONTAINER" 2>/dev/null)" = running ] || { hf_orphan_heal "$out" && { rc=0; out=$(compose up -d 2>&1) || rc=$?; if [ -n "$out" ]; then printf '%s\n' "$out" | tail -2; fi; }; }   # fix:orphan-heal
    return "$rc"
  ) 9>"$LOCK_FILE"
}

# Purpose: `compose up -d` under a non-blocking lock with auto-healing of
#   device-mismatch and the storage orphan: podman bakes the /dev/dri
#   snapshot into the OCI spec at create, and the card numbering changes
#   between boots → starting an OLD container in a new boot dies with
#   "cannot stat …" / "Failed to create container", and a normal up never
#   heals it; a libpod-DB vs storage-layer desync gives "already in use by
#   … external entity" (the 2026-11-21 window GOTCHAS). If after up the
#   project container is not running, the diagnosis picks ONE heal: the
#   device branch (the cannot stat / Failed to create container signature →
#   podman rm -f by the io.podman.compose.project label) or hf_orphan_heal
#   (the orphan signature → containers-storage delete-container), then one
#   up retry: a fresh create bakes the current numbering / a clean storage.
#   At most TWO up attempts per call. Before the first up — hf_lock_reclaim
#   on a busy lock and hf_pod_pristine.
#
# Side effects: creating/truncating the $LOCK_FILE lock file (a
#   non-blocking flock released by the subshell; on a busy lock — the
#   reclaim of mature holders); hf_pod_pristine (a possible podman pod rm
#   -f); up to two `compose up -d` (stdout — the last 2 lines of the last
#   one); on a signature — podman ps -aq --filter label=… and podman rm -f
#   of the found containers, or containers-storage delete-container of the
#   orphan (both — output silenced); two podman inspects of the container
#   status.
#
# Limitations/assumptions: requires the STACK_DIR, CONTAINER, LOCK_FILE
#   globals (dispatcher), compose (core/stack.sh), the adapter's
#   $ENGINE_PROJECT and this file's hf_lock_reclaim/hf_pod_pristine/
#   hf_orphan_heal. The rc of compose calls is silenced (`|| true`): a
#   failure is recognized by the pair "status ≠ running + a signature in
#   the output", not by rc — other up failures (pull, network) are NOT
#   healed (rm is not called), the helper returns 1, the caller decides
#   next (the _boot loop / the watchdog's quiet exit). The device signature
#   is checked first — under it hf_orphan_heal is not called (one heal per
#   call); the heal cap — HEAL_MAX per process. A lock race is not an
#   error: "skip" and 0 (as hf_up_locked). The project label — the
#   adapter's ENGINE_PROJECT global (the `name:` pin in the golden); if a
#   future podman-compose changes the label, rm finds no targets and the
#   degradation equals the former behavior (the unit restarts _boot on
#   rc 1). Does not check engine health — only the container status. Live
#   callers: cmd_boot (in the loop) and cmd_watchdog (via `|| true`) of
#   this file.
#
# @stdout string   # «up уже выполняется — пропуск» on a busy lock or the
#   last 2 lines of the last `compose up -d`
# @returns integer # 0 — the project container running (immediately or after
#   the rm+re-up / the orphan heal); 1 — not running (the failure is neither
#   device-kind nor an orphan, or the retry did not save it)
hf_up_devsafe() {
  ( if ! flock -n 9; then
      hf_lock_reclaim              # fix:lock-reclaim
      flock -n 9 || { echo "up уже выполняется — пропуск"; return 0; }
    fi
    hf_pod_pristine                # fix:pod-infra
    local out
    out=$(compose up -d 2>&1) || true
    if [ -n "$out" ]; then printf '%s\n' "$out" | tail -2; fi
    if [ "$(podman inspect -f '{{.State.Status}}' "$CONTAINER" 2>/dev/null)" != running ]; then
      if printf '%s' "$out" | grep -qE 'cannot stat|Failed to create container'; then
        podman rm -f $(podman ps -aq --filter label=io.podman.compose.project=$ENGINE_PROJECT) >/dev/null 2>&1 || true
        out=$(compose up -d 2>&1) || true
        if [ -n "$out" ]; then printf '%s\n' "$out" | tail -2; fi
      elif hf_orphan_heal "$out"; then
        out=$(compose up -d 2>&1) || true   # fix:orphan-heal
        if [ -n "$out" ]; then printf '%s\n' "$out" | tail -2; fi
      fi
    fi
    [ "$(podman inspect -f '{{.State.Status}}' "$CONTAINER" 2>/dev/null)" = running ]
  ) 9>"$LOCK_FILE"
}

# Purpose: the `_boot` internal command of the $ENGINE-compose boot unit
#   (ExecStart = /usr/bin/env bash $STACK_DIR/lctl _boot): raise the stack
#   at boot; before the first up — wait for the GPU nodes (gpu_ready_or_die,
#   a die with diagnostics on timeout); every up goes through hf_up_devsafe —
#   on a device create/start failure ("cannot stat", "Failed to create
#   container") the project container is removed and created anew (the
#   /dev/dri snapshot baked into the OCI spec is refreshed to the current
#   numbering).
#
# Side effects: gpu_ready_or_die — sleeps of GPU_WAIT_INTERVAL, up to 60 s,
#   a die on timeout; in the loop — hf_up_devsafe (rc silenced `|| true`,
#   the inspect below decides the outcome; the lock file, up to two compose
#   ups and a `podman rm -f` per iteration — see its contract), a podman
#   inspect of the container state; reading KFD_NODE and DRI_GLOB,
#   /dev/dri (ls in diagnostics); date +%s (the deadline); sleep 10 between
#   attempts; on budget exhaustion — a message to stderr and rc 1 (systemd
#   itself restarts the unit).
#
# Limitations/assumptions: called only from systemd (the ExecStart of the
#   compose unit, rendered from core/tpl/systemd/), not a user command.
#   Budget: gpu_ready_or_die ≤ 60 s + the loop deadline = start + 420 s
#   (the deadline local — whole unix seconds `date +%s`), checked at the
#   start of every attempt; the cap of 48 attempts (the i local — the
#   number from seq 1 48) — insurance against a standing clock; the tail of
#   an attempt started before the deadline: two compose calls + rm +
#   sleep 10 ≈ ≤2–3 min → the total ≤ ~10 min, within the unit's
#   TimeoutStartSec=900 (the external systemd cap for a stuck compose). The
#   node gate repeats at the start of every attempt (gpu_present): the
#   EFI-fb stub gives card* WITHOUT renderD* — the renderD*+kfd gate
#   filters it out; on Halo there may be no card0 at all (numbering starts
#   at 1, AGENTS gotcha 5). rc=1 for the unit — the normal failure signal
#   (Restart=on-failure, RestartSec=30). Requires the CONTAINER, STACK_DIR
#   globals (dispatcher), compose (core/stack.sh), this file's
#   gpu_present/gpu_ready_or_die/hf_up_devsafe.
#
# @returns integer # 0 — the container is running; 1 — the ~7 min budget
#   exhausted (a message to stderr; systemd will restart the unit)
cmd_boot() {
  local i deadline
  gpu_ready_or_die
  # the loop budget: 420 s + a tail of ≤ ~3 min, plus ≤60 s of GPU-wait < TimeoutStartSec=900
  deadline=$(( $(date +%s) + 420 ))
  for i in $(seq 1 48); do
    [ "$(date +%s)" -ge "$deadline" ] && break
    if ! gpu_present; then sleep 10; continue; fi
    hf_up_devsafe || true
    if [ "$(podman inspect -f '{{.State.Status}}' "$CONTAINER" 2>/dev/null)" = running ]; then
      return 0
    fi
    sleep 10
  done
  echo "boot: контейнер так и не запущен за ~7 мин" >&2
  return 1
}

# Purpose: the `_watchdog` internal command of the watchdog timer
#   ($ENGINE-compose-watchdog.service, OnUnitActiveSec=1min, ExecStart =
#   bash $STACK_DIR/lctl _watchdog): if the container is not running and
#   the stack was not stopped EXPLICITLY — raise it; the raise goes through
#   hf_up_devsafe (the same protection class as the boot unit: a device
#   create/start failure is healed by rm+re-up in place — the watchdog no
#   longer runs into a dead container with the baked old /dev/dri numbering
#   until the next reboot).
#
# Side effects: reading the $STOP_MARKER marker, the container state
#   (podman inspect) and the GPU nodes (gpu_present); on an unready GPU —
#   a silent immediate exit (an early timer tick after boot: an up on a
#   half-empty /dev/dri would bake an incomplete snapshot into a fresh
#   container); when needed — mkdir -p $LOG_DIR and appending a line with
#   the ISO time to $LOG_DIR/watchdog.log (stderr silenced, an append
#   failure silenced by `|| true`) and hf_up_devsafe (the lock file + up to
#   two compose ups + a possible rm, rc silenced `|| true`).
#
# Limitations/assumptions: called only from systemd, not for manual runs.
#   The marker in place — an immediate return 0 without side effects (an
#   explicit `lctl down`/`off` mutes the watchdog); the GPU gate is second
#   (the marker is older: an explicit stop is respected even without a
#   GPU). A silent tick refusal on an unready GPU was chosen over a short
#   wait: the watchdog is minute-based, it simply comes back in a minute,
#   and the tick budget stays in seconds. The st local — the podman state
#   (`running`/`exited`/`created`/`paused`…) or `missing` — the fallback
#   stub `|| echo missing` for an unavailable inspect; any st ≠ running
#   counts as a fall. Requires the CONTAINER, STOP_MARKER, LOG_DIR globals
#   (dispatcher), compose (core/stack.sh) and this file's
#   gpu_present/hf_up_devsafe.
#
# @returns integer # always 0 — all failure rcs are silenced (`|| true`,
#   `[ … ] &&`), a healthy container and an unready GPU also give 0
cmd_watchdog() {
  [ -f "$STOP_MARKER" ] && return 0
  gpu_present || return 0
  local st
  st=$(podman inspect -f '{{.State.Status}}' "$CONTAINER" 2>/dev/null || echo missing)
  if [ "$st" != running ]; then
    mkdir -p "$LOG_DIR" 2>/dev/null || true
    echo "$(date -Is) watchdog: container state=$st -> up" >> "$LOG_DIR/watchdog.log" 2>/dev/null || true
    hf_up_devsafe || true
  fi
}
