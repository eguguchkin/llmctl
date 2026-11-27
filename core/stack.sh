# shellcheck shell=bash
# ── stack: compose wrapper, .env reading, preflight and host prep (core) ─────
# The module reads dispatcher globals STACK_DIR/MEMLOCK/LIMITS_FILE/CORE_TPL
# and the log/warn/die helpers; compose files come from the adapter
# (ENGINE_COMPOSE_FILES, contract §2.1 task 1.1). This module only reads .env
# (env_val); all .env writing lives in write_env in core/stack_files.sh.

# Purpose: the single `podman compose` wrapper over the adapter's -f triple
#   (ENGINE_COMPOSE_FILES) with working dir $STACK_DIR — podman-compose does
#   not read COMPOSE_FILE, so -f is listed at every call (that "every call"
#   is assembled here). When the clone file
#   $STACK_DIR/core/tpl/lctl-containers.conf exists — CONTAINERS_CONF is
#   scoped to the stack (slirp4netns instead of pasta, working around the
#   AppArmor netns teardown bug; clone = stack: there is no derived copy,
#   consumers read the tpl file directly). No file (broken clone tree) →
#   clean env, behavior as before. The global ~/.config/containers is never
#   touched.
#
# Side effects: everything podman compose <subcommand> does: container/volume
#   lifecycle (up/stop/down), one-shot run containers, image pull, reading
#   compose files from $STACK_DIR; CONTAINERS_CONF exported into the
#   subshell environment (only when the tracked file is in place). The
#   caller's cwd is unchanged (cd runs in a subshell).
#
# Limitations/assumptions: requires the STACK_DIR global (dispatcher) and
#   the adapter's ENGINE_COMPOSE_FILES array (after engine_load). The
#   function name shadows an external binary of the same name. stdout
#   pass-through: live callers tail the output themselves or silence the rc
#   (`|| true` in autostart.sh watchdog/boot). Direct core podman calls
#   (inspect/stop/rm) get no env — the network backend only matters at
#   create/netns time, storage is shared.
#
# @param 1: string[] # rest from $1: podman compose subcommand and flags
#   (live: run, up -d [--force-recreate], stop, down). fix-r1 addition
#   (EXP-002): the core appends the adapter's ENGINE_COMPOSE_EXTRA_ARGS
#   before the -f triple (global podman-compose options — the core knows no
#   values, R6)
# @stdout string     # podman compose output as is
# @returns integer   # podman compose rc, or the cd rc when STACK_DIR is unavailable
compose() { ( cd "$STACK_DIR" || exit
  # containers.conf scoped to the stack only: the tracked clone file always
  # exists (the "conf before up" invariant holds by the fact of the clone)
  if [ -f "$STACK_DIR/core/tpl/lctl-containers.conf" ]; then export CONTAINERS_CONF="$STACK_DIR/core/tpl/lctl-containers.conf"; fi   # fix:containers-conf
  # engine-global compose options (the adapter's ENGINE_COMPOSE_EXTRA_ARGS:
  # the core knows no values — R6); placement — right after `compose`, BEFORE
  # -f and the subcommand (podman-compose argparse: global options before
  # the positional subcommand; --in-pod is defined on the root parser).
  # Default — empty (no adapter setting → call as before)
  podman compose ${ENGINE_COMPOSE_EXTRA_ARGS[@]+"${ENGINE_COMPOSE_EXTRA_ARGS[@]}"} "${ENGINE_COMPOSE_FILES[@]}" "$@" ); }

# Purpose: value of a key from $STACK_DIR/.env — the first line of the form
#   KEY=...; the value is everything right of the first '=' (it may contain
#   '=').
#
# Side effects: prints to stdout only; reads the .env file; does NOT modify
#   files (all .env writing — write_env in core/stack_files.sh).
#
# Limitations/assumptions: requires the STACK_DIR global. The key is
#   substituted into a grep -E template without escaping — only capital
#   letters, digits and underscore are safe (live keys: LCTL_ENGINE,
#   LCTL_PROFILE, LCTL_MODEL, LCTL_PORT, LCTL_BIND). A missing .env or key
#   gives empty stdout and rc 0: the grep failure is silenced by `|| true`,
#   so "no key" is indistinguishable from "empty value" — callers check via
#   [ -n "$v" ].
#
# @param 1: /^[A-Z][A-Z0-9_]*$/ # .env key name
# @stdout string                # value right of the first '=' (first match);
#   '' — no key or no .env
# @returns integer              # always 0 — a no-match grep failure is silenced
env_val() { [ -f "$STACK_DIR/.env" ] && grep -E "^$1=" "$STACK_DIR/.env" 2>/dev/null | head -1 | cut -d= -f2- || true; }

# Purpose: the profile id of the deployed stack — LCTL_PROFILE from
#   $STACK_DIR/.env, normalized through the adapter's resolve_profile (the
#   .env canon stores the new name; legacy transitional names are mapped at
#   read time — 1.2); with an empty/missing key — the adapter's
#   PROFILE_DEFAULT.
#
# Side effects: prints to stdout only; reads .env (via env_val) and the
#   adapter's PROFILE_DEFAULT global; touches no files or globals.
#
# Limitations/assumptions: an unrecognized resolve_profile canon is printed
#   verbatim (profile_field will error with a clear "unknown profile");
#   resolve_profile is called with stderr silenced (alias mapping is a
#   normal branch, not an error).
#
# @stdout string    # active profile (canonical id)
# @returns integer  # always 0 — final echo
cur_profile() {
  local p c
  p=$(env_val LCTL_PROFILE); p="${p:-$PROFILE_DEFAULT}"
  c=$(resolve_profile "$p" 2>/dev/null) && { echo "$c"; return 0; }
  echo "$p"
}

# Purpose: the model the server uses by default (for smoke, status) —
#   LCTL_MODEL from $STACK_DIR/.env.
#
# Side effects: prints to stdout only; reads .env via env_val; touches no
#   globals.
#
# Limitations/assumptions: '' when LCTL_MODEL is missing from .env — env_val
#   always returns 0, so the profile default is NOT substituted (live
#   callers die on a missing .env beforehand).
#
# @stdout /^[\w.-]+:[\w.-]+$/ | '' # LCTL_MODEL verbatim from .env; '' — no key
# @returns integer                 # always 0
cur_model()   { env_val LCTL_MODEL; }

# ── preflight and host preparation ──────────────────────────────────────────
# Purpose: GPU host preparation (I1) — a self-sufficient preflight step:
#   gated on device presence (/dev/kfd OR /dev/dri), render/video groups for
#   rootless GPU access, limits.d memlock from the core/tpl template (the
#   MEMLOCK value — from the adapter's ENGINE_MEMLOCK, "engine picking"). On
#   a machine without GPU devices — an info-skip and ZERO mutations (the §6.3
#   die stays in preflight after this step).
#
# Side effects: when devices exist — possibly sudo usermod -aG
#   render,video $USER (when either group is missing from id -nG; then an
#   honest warn and exit 42 — groups apply only after re-login) and possibly
#   sudo install -m 0644 of the limits file (rendering
#   core/tpl/99-lctl-memlock.conf.tpl with __USER__/__MEMLOCK__; written
#   only when the file is missing OR its content differs from the render —
#   cmp; right after writing — the memlock gate on the SUFFICIENCY threshold
#   of 8388608 kB (fix:memlock-gate, post-EXP-008: unlimited → PASS; "?"/
#   below threshold → warn and exit 42; ≥ threshold → warn "enough",
#   continue). The render temp file is removed in all branches. Reads
#   id -nG, ulimit -Hl. stdout — log lines, stderr — warn().
#
# Limitations/assumptions: requires the globals MEMLOCK, LIMITS_FILE, CORE_TPL
#   (dispatcher), render_tpl (stack_files.sh) and log/warn/die. Env hooks —
#   selfcheck only, prod never overrides: LCTL_KFD/LCTL_DRI — gate paths
#   (defaults /dev/kfd, /dev/dri; the autostart.sh header uses the same names
#   with different defaults — glob renderD*; no conflicts), LCTL_LIMITS —
#   limits file path (default LIMITS_FILE; the actual path is single — see
#   the core). No render/video group in the system → usermod dies by set -e
#   with its own rc — a loud honest failure. Edge case kfd-missing + dri-present
#   (half-broken driver): the step applies, then preflight dies per §6.3 —
#   mutations are idempotent and harmless.
#
# @returns integer # always 0 on return — exit 42 (re-login/reboot)
#   terminates the process without returning to the caller
gpu_prep() {
  local kfd="${LCTL_KFD:-/dev/kfd}" dri="${LCTL_DRI:-/dev/dri}"
  # GPU host prep (I1): only when devices exist; non-GPU — an info-skip
  if [ -e "$kfd" ] || [ -e "$dri" ]; then
    if ! id -nG | grep -qw render || ! id -nG | grep -qw video; then
      log "добавляю $USER в группы render,video (sudo точечно)"
      sudo usermod -aG render,video "$USER"                        # fix:gpu-groups
      warn "группы применятся только после перезахода. Выйди и зайди снова, затем повтори start."
      exit 42
    fi
    # memlock for NPU-trunk (limits.d; needs a reboot/session recreation)
    local lim="${LCTL_LIMITS:-$LIMITS_FILE}"
    local tmp; tmp=$(mktemp)
    render_tpl "$CORE_TPL/99-lctl-memlock.conf.tpl" "$tmp" \
      MEMLOCK="$MEMLOCK" USER="$USER"
    if ! cmp -s "$tmp" "$lim"; then
      log "пишу $lim (memlock $MEMLOCK)"
      sudo install -m 0644 "$tmp" "$lim"                           # fix:gpu-limits
      # memlock gate on the SUFFICIENCY threshold (fix:memlock-gate,
      # post-EXP-008, mirror 4.1-F2), not on "unlimited": in
      # environments without pam_limits unlimited is unreachable and the
      # relogin ulimit does not change — the old hard gate looped (install:
      # file+exit 42 ↔ relogin changes nothing). Threshold 8388608 kB is an
      # empirical lower bound of both engines (live windows loaded at
      # 1318060032 kB). unlimited → PASS without WARN; "?" → file + WARN +
      # exit 42 (conservative); ≥ threshold → file + WARN "enough",
      # continue; < threshold → file + WARN + exit 42.
      local ml; ml=$(ulimit -Hl 2>/dev/null || echo "?")           # fix:memlock-gate
      if [ "$ml" = "?" ]; then                                     # fix:memlock-gate
        warn "memlock не читается (ulimit -l) — записан $lim; ПЕРЕЛОГИНЬСЯ (или ребутни) и повтори start."
        rm -f "$tmp"; exit 42                                      # fix:memlock-gate
      elif [ "$ml" != "unlimited" ] && [ "$ml" -lt 8388608 ]; then  # fix:memlock-gate
        warn "текущая сессия ещё с memlock=${ml} kB < порога 8388608 kB. Требуется ребут (или перезаход+сервис-менеджер). Повтори on после ребута."
        rm -f "$tmp"; exit 42                                      # fix:memlock-gate
      elif [ "$ml" != "unlimited" ]; then                           # fix:memlock-gate
        warn "memlock ${ml} kB — достаточно (порог 8388608 kB); limits.d-файл перезаписан для будущих relogin"
      fi                                                            # fix:memlock-gate
    fi
    rm -f "$tmp"
  fi
  # non-GPU machine — an info-skip and ZERO mutations (the hardware die lives in preflight below)
  if ! [ -e "$kfd" ] && ! [ -e "$dri" ]; then log "GPU-устройства не найдены ($kfd, $dri) — GPU-подготовка пропущена"; fi   # fix:gpu-gate
}

# Purpose: environment check and one-time host preparation before
#   bootstrap/use: not root, distro Ubuntu/Debian, GPU host preparation
#   (gpu_prep above; on a non-GPU machine — an info-skip), AMD GPU (/dev/kfd —
#   hardware gate §6.3, refusal before apt/downloads), RAM volume, the apt
#   five (podman, podman-compose, containers-storage, psmisc, curl — one
#   need list), linger so the server lives without a login and at boot. Live
#   callers — cmd_bootstrap and cmd_use (before any system changes).
#
# Side effects: targeted sudo — apt-get update + install (a single call when
#   the need list is non-empty; everything in place — apt is not invoked at
#   all), usermod -aG render,video and the limits file (see gpu_prep),
#   loginctl enable-linger $USER. Reads /etc/os-release, /proc/meminfo,
#   user groups, its own ulimit -Hl, the loginctl Linger property. stdout —
#   log lines, stderr — warn(). Does not touch .env or stack files.
#
# Limitations/assumptions: running as root — die. Locals: id — $ID from
#   os-release (ubuntu and debian pass, others die, shadowing the id
#   utility), mem_kb — MemTotal in KiB (threshold 57671680 KiB ≈ 58 GB
#   decimal), need — a package-name string (the split is intentional: names
#   without spaces). Order: the GPU step before the hardware gate and apt —
#   a non-GPU machine gets an info-skip, then die, zero mutations before the
#   refusal; a GPU machine with incomplete groups gets exit 42 before apt
#   (less sudo work before re-login). The two intentional exit 42s terminate
#   the process demanding a repeat of on after re-login/reboot; other
#   failures — die (exit 1).
#
# @returns integer # always 0 on return — exit 42 and die terminate the
#   process without returning to the caller
preflight() {
  [ "$(id -u)" != 0 ] || die "не запускай от root — работай от своего имени (sudo lctl не нужен)"
  local id
  id=$(. /etc/os-release && echo "$ID")
  case "$id" in ubuntu|debian) ;; *) die "дистрибутив '$id' не поддерживается (нужен Ubuntu/Debian)" ;; esac
  gpu_prep
  # hardware gate §6.3: path through the env hooks (see gpu_prep Limitations), same text as before
  [ -e "${LCTL_KFD:-/dev/kfd}" ] || die "/dev/kfd нет: AMD GPU не виден (проверь драйвер amdgpu)"
  local mem_kb; mem_kb=$(awk '/MemTotal/{print $2}' /proc/meminfo)
  [ "$mem_kb" -ge 57671680 ] || warn "RAM ${mem_kb}kB < ~58 GiB: 27B@262K может не влезть (нужна Halo 60 GiB+)"
  # the apt five in one need list: containers-storage — orphan storage inspect,
  # psmisc provides fuser for lock reclaim
  local need=""
  command -v podman >/dev/null             || need+=" podman"
  command -v podman-compose >/dev/null     || need+=" podman-compose"
  command -v containers-storage >/dev/null || need+=" containers-storage"   # fix:preflight-pkgs
  command -v fuser >/dev/null              || need+=" psmisc"               # fix:preflight-pkgs
  command -v curl >/dev/null               || need+=" curl"
  if [ -n "$need" ]; then
    log "установка пакетов:$need (sudo точечно)"
    sudo apt-get update -qq && sudo apt-get install -y -qq $need
  fi
  # linger: the server must live without an active login and at boot
  if [ "$(loginctl show-user "$USER" --property=Linger 2>/dev/null | cut -d= -f2)" != "yes" ]; then
    log "включаю linger для $USER (сервер переживает logout и стартует при boot)"
    sudo loginctl enable-linger "$USER"
  fi
}
