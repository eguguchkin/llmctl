#!/usr/bin/env bash
# run_checks.sh — the llmctl internal-check battery (stage 2, waves 0–3;
# stage 8 — the render convergence: S2/S7 updated, S2a/S2b/S2c + the
# render-converge/no-recreate mutations): the frame from
# battery skeleton adapted to the core/ + engines/
# layout and the core↔adapter contract (§2 task 1.1): the Ф1–Ф5 scenarios
# (self-healing), P-A…P-H (preflight: the apt five + the GPU prep), N1–N7
# (the .data/<engine>/ layout + the root .env), N10 (a faux end-to-end
# `lctl on --engine hipfire` through the real dispatcher), N11 (a switch:
# on with another engine active = off→on), N12 (a port conflict → a die
# hint), N13 (env-model) + the adapter sections
# engines/<name>/tests/*.sh (included by the runner).
#
# FIXED a known battery bug (task 1.1 §6, confirmed empirically):
# `bash -n a.sh b.sh` reads only the FIRST file as the script, the rest
# become positional parameters → a syntax error of the second file is
# invisible. Both legacy multi-file calls replaced with a PER-FILE loop
# (mutant_parses — the mutations' guard, and section 0 — the whole tree),
# a MANDATORY negative test of the fix added (a mutant with a broken
# SECOND file must be caught by the guard).
#
# Purpose: one call — the syntax (per file), py_compile, the usage
#   contract, a status refusal on a chunked port; the # fix:<name> marker
#   inventory; FOR EACH ONE (a scenario fails on a tree copy → the
#   protection holds; the marker not found → a FAIL «мутация не
#   применилась», the marker-drift protection). A deliberate exception
#   (2026-11-25): w38-bootlines / w41 / w33-spec-pulse
#   (engines/hipfire/py/watch_tui.py) are covered by the panel's
#   selfcheck pins — no mutations for them on purpose. The SR section —
#   the gufo/flash smoke race (fix:smoke-race, task 3.2): a late log flush
#   + a poll-cut mutation. The PASS/FAIL count;
#   rc 0 only at FAIL=0.
#
# Side effects: only an mktemp temp dir (removed on EXIT) with tree copies
#   for the mutants/switches. No real podman/systemctl/sudo/machines —
#   everything via a faux PATH; HOME/USER — inside $TMP. Ф3 runs with the
#   REAL flock/ps/fuser (the core provides the lock semantics): the holder
#   — a python3 process with the argv0 «podman-compose» (the cmdline
#   matches the reclaim predicate; the container's busybox flock cannot
#   do the fd+command form).
#
# Limitations/assumptions: bash + python3 in PATH; /dev/kfd and /dev/dri
#   are not needed here (the battery's up paths are called directly, the
#   GPU gate only in _boot; the P scenarios hook them via
#   LCTL_KFD/LCTL_DRI). The sandbox is not Ubuntu/Debian, but the
#   preflight requires ubuntu|debian from /etc/os-release: the battery
#   (except the chunked checks of section 0 on the real path) re-runs
#   itself under `unshare -rm` with a bind-swap of /etc/os-release to a
#   fake ID=ubuntu — only inside its own namespace, the real /etc is not
#   touched; if userns is unavailable, the battery runs without the swap
#   and the P scenarios fail honestly on the os check. Runs from any dir.
#   The exit code = the verdict.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# a re-exec under a user+mount namespace (see Limitations): before $TMP is created, no leftovers
if [ "${LCTL_CHECKS_UNSHARED:-0}" != 1 ] && command -v unshare >/dev/null 2>&1 \
   && command -v mount >/dev/null 2>&1 && unshare -rm true 2>/dev/null; then
  exec unshare -rm env LCTL_CHECKS_UNSHARED=1 bash "$0" "$@"
fi
TMP="$(mktemp -d "${TMPDIR:-/tmp}/lctl-checks.XXXXXX")" || { echo "run_checks: mktemp недоступен" >&2; exit 1; }
trap '[ -n "${TMP:-}" ] && rm -rf "$TMP"' EXIT
# the /etc/os-release swap inside the namespace (the product reads the absolute path)
if [ "${LCTL_CHECKS_UNSHARED:-0}" = 1 ]; then
  printf 'ID=ubuntu\nVERSION_ID="24.04"\nPRETTY_NAME="Ubuntu 24.04 LTS"\n' > "$TMP/fake-os-release"
  mount -o bind "$TMP/fake-os-release" /etc/os-release 2>/dev/null || true
fi
PASS=0 FAIL=0
ok()  { PASS=$((PASS + 1)); printf 'PASS: %s\n' "$*"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$*"; }
unset CONTAINERS_CONF || true   # env-гигиена: сценарий «файла нет → env чист»

ORPHAN_ID="dccea132feedbeef00112233445566778899aabbccddeeff00112233445566"

# ── faux-bin: PATH stubs of the external binaries ────────────────────────────
# Each writes «<cmd> <args…>» line by line into $LCTL_FAUX_LOG and is
# scripted by the LCTL_FAUX_* env flags; they play no roles (no real
# podman/systemd/loginctl/sudo — the AGENTS hygiene). The scripts:
#   podman  — per call also «env CONTAINERS_CONF=<v|UNSET>» into the
#             journal (the Ф5 assert); compose up: LCTL_FAUX_UP=ok |
#             orphan-once (the first up prints an orphan error with
#             LCTL_FAUX_ORPHAN_ID, rc 1; then rc 0) | orphan-always; the up
#             counters in the $LCTL_FAUX_CNT.up / .upok files; inspect: the
#             last target argument — a hipfire_* container (running after
#             the first successful up, else rc 1) or the orphan guard's
#             hex-ID (LCTL_FAUX_INSPECT_ID=running → rc 0);
#             pod inspect → LCTL_FAUX_POD_INFRA=absent(rc 1, default) |
#             empty(rc 0, empty) | full(rc 0, an ID); pod rm / ps / rm /
#             stop rc 0; compose stop — LCTL_FAUX_STOPFAIL=1 → rc 1 with
#             an error.
#   containers-storage — journals delete-container <ID>;
#             LCTL_FAUX_CS_FAIL=1 → rc 1; a missing binary = not putting
#             it into PATH (FAUX_NS).
#   systemctl/loginctl/sudo/ss — journaling, rc 0; the sudo form
#             install -m 0644 SRC DST makes a REAL copy only when DST is
#             inside $TMP (the P-E/P-F limits asserts).
FAUX="$TMP/faux"; mkdir -p "$FAUX"
FAUXLOG="$TMP/faux.log"; FAUXCNT="$TMP/faux.cnt"
: > "$FAUXLOG"

# The shim bodies live as FILES in tests/shims/ (the 0-inline-fixture
# canon, the fixture rule: a heredoc -> cp of a file): shim()
# installs one into the faux PATH.
SHIMS="$ROOT/tests/shims"
shim() { cp "$SHIMS/$1" "$2" && chmod +x "$2"; }
shim podman "$FAUX/podman"
shim containers-storage "$FAUX/containers-storage"
shim systemctl "$FAUX/systemctl"
# loginctl: with LCTL_FAUX_LINGER=1 prints Linger=yes (the «linger already
#   on» branch), else empty (the preflight's enable-linger branch)
shim loginctl "$FAUX/loginctl"
# sudo: a journal + rc 0; the install -m 0644 SRC DST form — additionally a
#   REAL copy by install into the target, only when DST is inside $TMP
#   (the P-E/P-F limits asserts; no real sudo mutations — LCTL_LIMITS is
#   always hooked into $TMP)
shim sudo "$FAUX/sudo"
# id/usermod: id -u → 1000 (the preflight root check), id -nG →
#   LCTL_FAUX_GROUPS (the default tester render video); usermod — a
#   journal, rc 0
shim id "$FAUX/id"
shim usermod "$FAUX/usermod"
shim ss "$FAUX/ss"
chmod +x "$FAUX"/*
# FAUX_FULL: FAUX + a faux podman-compose/fuser — the P/N scenarios «all
#   in place»; curl is NOT created here — that is the engine faux (the
#   hipfire-answer dialect), the adapter file
#   engines/hipfire/tests/adapter_checks.sh puts it in (wave 2).
FAUX_FULL="$TMP/faux-full"; mkdir -p "$FAUX_FULL"
for b in "$FAUX"/*; do ln -sf "$b" "$FAUX_FULL/$(basename "$b")"; done
shim podman-compose "$FAUX_FULL/podman-compose"
shim fuser "$FAUX_FULL/fuser"
chmod +x "$FAUX_FULL"/*
# STRIPPED: the base utils + mktemp/cmp/install WITHOUT
#   podman/podman-compose/containers-storage/fuser/curl — the P-A «all
#   missing» (the apt five in full); faux id/loginctl/sudo/usermod —
#   journaling stubs
STRIPPED="$TMP/faux-stripped"; mkdir -p "$STRIPPED"
for b in bash python3 flock ps tail grep awk sed head cat cut date sleep touch mkdir rm ls env dirname mktemp cmp install; do
  src=$(command -v "$b" 2>/dev/null) && ln -sf "$src" "$STRIPPED/$b"
done
for b in id usermod loginctl sudo; do ln -sf "$FAUX/$b" "$STRIPPED/$b"; done
# existing path targets for LCTL_KFD/LCTL_DRI (the gpu_prep gate: [ -e ])
: > "$TMP/kfd-node"; : > "$TMP/dri-node"
# FAUX_NS: the same WITHOUT containers-storage (the «no binary» scenario, Variant B)
FAUX_NS="$TMP/faux-nostor"; mkdir -p "$FAUX_NS"
for b in podman systemctl loginctl sudo; do ln -sf "$FAUX/$b" "$FAUX_NS/$b"; done
# FAUX_BENCH: the bench faux (stage 7.1) — the base binaries + a curl with
#   the /health, /ready, /metrics and /v1/chat/completions dialects WITH
#   usage+timings (the bench_run.py runner measures the wall and writes
#   the JSONL); the POST bodies are logged into $LCTL_FAUX_BENCH_BODY (the
#   model asserts), the gate seams —
#   LCTL_FAUX_BENCH_HEALTHFAIL (a curl rc 7) / LCTL_FAUX_BENCH_HEALTHFILE
#   (a /health body from a file, e.g. loading_model)
FAUX_BENCH="$TMP/faux-bench"; mkdir -p "$FAUX_BENCH"
for b in "$FAUX_FULL"/*; do ln -sf "$b" "$FAUX_BENCH/$(basename "$b")"; done
shim curl_bench "$FAUX_BENCH/curl"
shim bench_body_model.py "$FAUX_BENCH/bench_body_model.py"   # рядом с curl: шим зовёт "$(dirname "$0")/bench_body_model.py"
chmod +x "$FAUX_BENCH/curl"
# NOFU: a strict PATH without fuser/lsof and without the system one (the
#   «no fuser» scenario — a silent degradation); the Ф3 holder and the up
#   path must work with this set
NOFU="$TMP/faux-nofu"; mkdir -p "$NOFU"
for b in bash python3 flock ps tail grep awk sed head cat cut date sleep touch mkdir rm ls env dirname; do
  src=$(command -v "$b" 2>/dev/null) && ln -sf "$src" "$NOFU/$b"
done
ln -sf "$FAUX/podman" "$NOFU/podman"

# ── the battery's adapter sections: each engines/<name>/tests/*.sh is sourced
#    by the runner and registers its scenario function in ADAPTER_FUNCS (the
#    engine faux binaries — e.g. a curl with hipfire answers — the file
#    creates itself) ────
ADAPTER_FUNCS=""
for tf in "$ROOT"/engines/*/tests/*.sh; do
  [ -e "$tf" ] || continue
  # shellcheck disable=SC1090
  source "$tf"
done

# ── hf — a harness: a subshell with the core globals + the adapter's engine_load + a faux PATH ─
# (the source order mirrors the lctl dispatcher: the globals → core/*.sh →
#  engine_load; the tree under test — LCTL_TREE, the repo by default).
LCTL_TEST_STACK="$TMP/stack"
hf() {  # hf <bash-код> — stdout+stderr и rc наружу
  local tree="${LCTL_TREE:-$ROOT}"
  (
    set -euo pipefail
    export PATH="${LCTL_TEST_PATH:-$FAUX:$PATH}"
    export LCTL_FAUX_LOG="$FAUXLOG" LCTL_FAUX_CNT="$FAUXCNT" LCTL_FAUX_ORPHAN_ID="$ORPHAN_ID"
    export HOME="$TMP/home" USER="tester" LCTL_FAUX_TMP="$TMP"
    SELF="$tree/lctl" STACK_DIR="$LCTL_TEST_STACK" DATA_DIR="$STACK_DIR/.data"
    CORE_DIR="$tree/core" CORE_TPL="$tree/core/tpl" CORE_PY="$tree/core/py"
    log()  { printf '\n== %s\n' "$*"; }
    warn() { printf 'WARN: %s\n' "$*" >&2; }
    die()  { printf 'FATAL: %s\n' "$*" >&2; exit 1; }
    ask()  { return 0; }
    isint() { case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }
    source "$CORE_DIR/profiles.sh"
    source "$CORE_DIR/stack.sh"
    source "$CORE_DIR/state.sh"
    source "$CORE_DIR/stack_files.sh"
    source "$CORE_DIR/health.sh"
    source "$CORE_DIR/models.sh"
    source "$CORE_DIR/commands.sh"
    source "$CORE_DIR/bench.sh"
    source "$CORE_DIR/autostart.sh"
    engine_load() {   # зеркальная копия engine_load диспетчера (см. lctl)
      local e="$1"
      ADAPTER_DIR="$(dirname "$SELF")/engines/$e"
      [ -f "$ADAPTER_DIR/adapter.sh" ] || die "адаптер '$e' не найден ($ADAPTER_DIR/adapter.sh нет)"
      source "$ADAPTER_DIR/adapter.sh"
      [ "$ENGINE" = "$e" ] || die "адаптер '$e' объявил ENGINE='$ENGINE' — должно совпадать с именем каталога"
      UNIT_NAME="$ENGINE-compose"
      STOP_MARKER="$DATA_DIR/$ENGINE/.stopped"
      LOCK_FILE="$DATA_DIR/.lctl.lock"
      MODELS_BASE="${LCTL_MODELS:-$DATA_DIR/$ENGINE/models}"
      STATE_BASE="${LCTL_STATE:-$DATA_DIR/$ENGINE/profiles}"
      LOG_DIR="$DATA_DIR/$ENGINE/logs"
      LIMITS_FILE="/etc/security/limits.d/99-lctl-$ENGINE-memlock.conf"
      IMAGE="${LCTL_IMAGE:-$ENGINE_IMAGE}"
      PORT="${LCTL_PORT:-$ENGINE_PORT_DEFAULT}"
      BIND="${LCTL_BIND:-0.0.0.0}"
      MEMLOCK="${LCTL_TEST_MEMLOCK:-$ENGINE_MEMLOCK}"
      CONTAINER="$ENGINE_CONTAINER"
      HEALTH_PATH="${ENGINE_HEALTH_PATH:-/health}"
      # an ulimit shim (fix:memlock-gate K-4): the gate reads the BUILTIN
      # ulimit - — not taken by a PATH substitute; the gate scenarios set
      # LCTL_FAUX_ULIMIT
      if [ -n "${LCTL_FAUX_ULIMIT:-}" ]; then ulimit() { printf '%s\n' "$LCTL_FAUX_ULIMIT"; }; fi
      MODELS_DIR="$MODELS_BASE/$(engine_model_set "$(cur_profile)")"
    }
    engine_load "${LCTL_TEST_ENGINE:-hipfire}"
    # a port_open shim (the adapter's agent-check): a real /dev/tcp probe
    # is always dead in the sandbox; the scenario sets LCTL_FAUX_PORTOPEN=1
    if [ "${LCTL_FAUX_PORTOPEN:-0}" = 1 ]; then port_open() { return 0; }; fi
    eval "$1"
  )
}

# ── the scenario seams ──────────────────────────────────────────────────────
new_stack() { LCTL_TEST_STACK="$TMP/stack-$1"; rm -rf "$LCTL_TEST_STACK"; mkdir -p "$LCTL_TEST_STACK/.data"; }
fresh_log() { : > "$FAUXLOG"; rm -f "$FAUXCNT"* 2>/dev/null || true; }
ups_count()     { local n; n=$(grep -c 'up -d' "$FAUXLOG" 2>/dev/null); echo "${n:-0}"; }
deletes_count() { local n; n=$(grep -c 'containers-storage delete-container' "$FAUXLOG" 2>/dev/null); echo "${n:-0}"; }
is_dead() { local s; s="$(ps -o stat= -p "$1" 2>/dev/null)"; [ -z "$s" ] || [ "${s#*Z}" != "$s" ]; }

# the Ф3 holder: a real flock holder — a python3 with the argv0
# «podman-compose» (the cmdline matches the product's predicate; the
# etimes real; this container's busybox flock cannot do «flock FD
# command», so python takes the lock itself).
HOLDER_CODE='import fcntl,sys,time
f=open(sys.argv[1],"a+")
fcntl.flock(f, fcntl.LOCK_EX|fcntl.LOCK_NB)
sys.stderr.write("held\n")
time.sleep(600)'
spawn_holder() {  # spawn_holder <lock-path> — печатает pid holder'а
  ( exec -a podman-compose python3 -c "$HOLDER_CODE" "$1" ) >/dev/null 2>&1 &
  echo $!
}
lock_is_held() {  # lock_is_held <lock-path> — 0, если flock -n не может взять
  ( flock -n 9 ) 9>"$1" 2>/dev/null
  [ $? -ne 0 ]
}

limits_bytes() {  # limits_bytes <user> <memlock> — ожидаемые байты limits-файла
  printf '%s soft memlock %s\n%s hard memlock %s\n' "$1" "$2" "$1" "$2"
}

# ── the positive scenarios (return 0 = all the asserts hold) ────────────────

# Ф1: a compose stop failed → the main container's podman stop is called
#     anyway, the off reached «ВЫКЛ…» with rc 0
scen_f1_fail() {
  new_stack f1fail; fresh_log
  local out rc
  out=$(LCTL_FAUX_STOPFAIL=1 hf 'cmd_off' 2>&1); rc=$?
  grep -qF 'podman stop hipfire_hipfire_1' "$FAUXLOG" \
    && grep -qE 'compose .* stop' "$FAUXLOG" \
    && [ "$rc" = 0 ] && printf '%s' "$out" | grep -q 'ВЫКЛ'
}

# Ф1 happy: a compose stop ok → a podman stop called too (harmless by the contract)
scen_f1_happy() {
  new_stack f1happy; fresh_log
  local out rc
  out=$(hf 'cmd_off' 2>&1); rc=$?
  grep -qF 'podman stop hipfire_hipfire_1' "$FAUXLOG" \
    && grep -qE 'compose .* stop' "$FAUXLOG" \
    && [ "$rc" = 0 ] && printf '%s' "$out" | grep -q 'ВЫКЛ'
}

# Ф2 locked: up#1 — an orphan error, the heal removes the ID, up#2 ok → rc 0, exactly 2 ups
scen_f2_locked() {
  new_stack f2locked; fresh_log
  local out rc
  out=$(LCTL_FAUX_UP=orphan-once hf 'hf_up_locked' 2>&1); rc=$?
  grep -qF "containers-storage delete-container $ORPHAN_ID" "$FAUXLOG" \
    && [ "$(ups_count)" = 2 ] && [ "$rc" = 0 ] \
    && printf '%s' "$out" | grep -q 'повторяю up'
}

# Ф2 devsafe: the same scenario via the boot/watchdog path
scen_f2_devsafe() {
  new_stack f2devsafe; fresh_log
  local out rc
  out=$(LCTL_FAUX_UP=orphan-once hf 'hf_up_devsafe' 2>&1); rc=$?
  grep -qF "containers-storage delete-container $ORPHAN_ID" "$FAUXLOG" \
    && [ "$(ups_count)" = 2 ] && [ "$rc" = 0 ]
}

# Ф2 happy: a clean up — exactly 1 compose up call, rc 0 (a contract without anomalies)
scen_up_happy() {
  new_stack uhappy; fresh_log
  local out rc
  out=$(hf 'hf_up_locked' 2>&1); rc=$?
  [ "$(ups_count)" = 1 ] && [ "$rc" = 0 ] && [ "$(deletes_count)" = 0 ]
}

# Ф2 the cap: both orphan errors at HEAL_MAX=1 → the second heal does NOT happen
scen_f2_cap() {
  new_stack f2cap; fresh_log
  local out rc
  out=$(LCTL_HEAL_MAX=1 LCTL_FAUX_UP=orphan-always hf 'hf_up_locked' 2>&1); rc=$?
  [ "$(deletes_count)" = 1 ] && [ "$(ups_count)" = 2 ] && [ "$rc" != 0 ]
}

# Ф2 no binary: a WARN with the manual command, delete-container NOT
# called, the behavior as before (one up, rc 1)
scen_f2_nobin() {
  new_stack f2nobin; fresh_log
  local out rc
  out=$(LCTL_FAUX_UP=orphan-once LCTL_TEST_PATH="$FAUX_NS:$PATH" hf 'hf_up_locked' 2>&1); rc=$?
  printf '%s' "$out" | grep -qF "containers-storage delete-container $ORPHAN_ID" \
    && [ "$(deletes_count)" = 0 ] && [ "$(ups_count)" = 1 ] && [ "$rc" != 0 ]
}

# Ф2 guard: libpod sees the ID → not an orphan, delete NOT called
scen_f2_guard() {
  new_stack f2guard; fresh_log
  local out rc
  out=$(LCTL_FAUX_UP=orphan-once LCTL_FAUX_INSPECT_ID=running hf 'hf_up_locked' 2>&1); rc=$?
  printf '%s' "$out" | grep -q 'не сирота, самолечение отменено' \
    && [ "$(deletes_count)" = 0 ] && [ "$(ups_count)" = 1 ]
}

# Ф3 stale: a stuck holder (the argv0 podman-compose, older than the
# threshold) killed, the up passed, no «skip»
scen_f3_stale() {
  new_stack f3stale; fresh_log
  local lock="$LCTL_TEST_STACK/.data/.lctl.lock" hp out rc
  hp=$(spawn_holder "$lock")
  sleep 2
  is_dead "$hp" && { echo "holder не дожил до сценария"; return 1; }
  lock_is_held "$lock" || { echo "holder не держит лок (сценарий пустой)"; return 1; }
  out=$(LCTL_LOCK_STALE=1 hf 'hf_up_locked' 2>&1); rc=$?
  is_dead "$hp" \
    && ! printf '%s' "$out" | grep -q 'уже выполняется' \
    && [ "$(ups_count)" = 1 ] && [ "$rc" = 0 ]
}

# Ф3 fresh: a healthy parallel holder (younger than the threshold) NOT touched — a «skip»
scen_f3_fresh() {
  new_stack f3fresh; fresh_log
  local lock="$LCTL_TEST_STACK/.data/.lctl.lock" hp out rc
  hp=$(spawn_holder "$lock")
  sleep 2
  lock_is_held "$lock" || { echo "holder не держит лок (сценарий пустой)"; return 1; }
  out=$(hf 'hf_up_locked' 2>&1); rc=$?
  ! is_dead "$hp" \
    && printf '%s' "$out" | grep -q 'up уже выполняется — пропуск' \
    && [ "$(ups_count)" = 0 ] && [ "$rc" = 0 ]
}

# Ф3 no fuser in PATH: a silent degradation to the former behavior (a skip, no kill)
scen_f3_nofuser() {
  new_stack f3nofu; fresh_log
  local lock="$LCTL_TEST_STACK/.data/.lctl.lock" hp out rc
  hp=$(spawn_holder "$lock")
  sleep 2
  lock_is_held "$lock" || { echo "holder не держит лок (сценарий пустой)"; return 1; }
  out=$(LCTL_LOCK_STALE=1 LCTL_TEST_PATH="$NOFU" hf 'hf_up_locked' 2>&1); rc=$?
  ! is_dead "$hp" \
    && printf '%s' "$out" | grep -q 'up уже выполняется — пропуск' \
    && [ "$(ups_count)" = 0 ] && [ "$rc" = 0 ]
}

# Ф4 a pod with an empty INFRA ID: a pod rm -f BEFORE the first compose up, the up passed
scen_f4_empty() {
  new_stack f4empty; fresh_log
  local out rc rm_line up_line
  out=$(LCTL_FAUX_POD_INFRA=empty hf 'hf_up_locked' 2>&1); rc=$?
  rm_line=$(grep -n 'podman pod rm -f pod_hipfire' "$FAUXLOG" | head -1 | cut -d: -f1)
  up_line=$(grep -n 'up -d' "$FAUXLOG" | head -1 | cut -d: -f1)
  printf '%s' "$out" | grep -q 'пустым INFRA ID' \
    && [ -n "$rm_line" ] && [ -n "$up_line" ] && [ "$rm_line" -lt "$up_line" ] \
    && [ "$(ups_count)" = 1 ] && [ "$rc" = 0 ]
}

# Ф4 a healthy pod (a non-empty INFRA ID): no rm, the up passed
scen_f4_full() {
  new_stack f4full; fresh_log
  local rc
  LCTL_FAUX_POD_INFRA=full hf 'hf_up_locked' >/dev/null 2>&1; rc=$?
  ! grep -q 'podman pod rm -f pod_hipfire' "$FAUXLOG" && [ "$(ups_count)" = 1 ] && [ "$rc" = 0 ]
}

# Ф4 no pod (an inspect rc 1): a no-op, the up passed
scen_f4_absent() {
  new_stack f4absent; fresh_log
  local rc
  hf 'hf_up_locked' >/dev/null 2>&1; rc=$?
  ! grep -q 'podman pod rm -f pod_hipfire' "$FAUXLOG" && [ "$(ups_count)" = 1 ] && [ "$rc" = 0 ]
}

# Ф5 the delivery (the layout: a clone = the stack): the conf — a tracked
#     file of the clone's core/tpl (no copy), the units rendered with an
#     Environment pointing at the core/tpl path (cmd_autostart)
scen_f5_deliver() {
  new_stack f5deliver; fresh_log
  rm -rf "$TMP/home"; mkdir -p "$TMP/home"
  local rc tree="${LCTL_TREE:-$ROOT}"
  hf 'cmd_autostart' >/dev/null 2>&1; rc=$?
  [ "$rc" = 0 ] \
    && [ -f "$tree/core/tpl/lctl-containers.conf" ] \
    && grep -q "Environment=CONTAINERS_CONF=$LCTL_TEST_STACK/core/tpl/lctl-containers.conf" "$TMP/home/.config/systemd/user/hipfire-compose.service" \
    && grep -q "Environment=CONTAINERS_CONF=$LCTL_TEST_STACK/core/tpl/lctl-containers.conf" "$TMP/home/.config/systemd/user/hipfire-compose-watchdog.service" \
    && grep -q "Environment=LCTL_ENGINE=hipfire" "$TMP/home/.config/systemd/user/hipfire-compose.service"
}

# Ф5 the compose() env contract: the clone's file in place (a clone = the
#     stack — we mirror core/tpl into the fake stack) → the env set; a
#     broken tree (no tpl file) → the env clean
scen_f5_env() {
  local tree="${LCTL_TREE:-$ROOT}"
  new_stack f5env; fresh_log
  mkdir -p "$LCTL_TEST_STACK/core/tpl"; cp -a "$tree/core/tpl/lctl-containers.conf" "$LCTL_TEST_STACK/core/tpl/" || return 1
  hf 'write_stack_files' >/dev/null 2>&1 || return 1
  fresh_log
  hf 'hf_up_locked' >/dev/null 2>&1 || return 1
  grep -qF "env CONTAINERS_CONF=$LCTL_TEST_STACK/core/tpl/lctl-containers.conf" "$FAUXLOG" || return 1
  new_stack f5noconf; fresh_log
  hf 'hf_up_locked' >/dev/null 2>&1 || return 1
  grep -q 'env CONTAINERS_CONF=UNSET' "$FAUXLOG" || return 1
  return 0
}

# ── preflight — the apt five + the GPU prep (the gate/groups/limits.d) ──────
# Hooks: LCTL_KFD/LCTL_DRI (existing/non-existing paths), LCTL_LIMITS
#   (always in $TMP), LCTL_FAUX_GROUPS (the user's groups),
#   LCTL_FAUX_LINGER, LCTL_TEST_MEMLOCK (the session limit: the sandbox's
#   hard limit cannot be raised — a «sufficient session» is emulated by
#   MEMLOCK=2097152 ≤ the hard).

# P-A pkgs-missing: a stripped PATH (all five missing), a GPU present, the
# groups ok, the limits pre-set equal to the render → exactly one apt
# install with the five names, an update before it, rc 0
scen_p_a() {
  new_stack pa; fresh_log
  local lim="$TMP/limits-pa.conf" rc n_upd n_inst
  limits_bytes tester 1318060032 > "$lim"
  LCTL_LIMITS="$lim" LCTL_KFD="$TMP/kfd-node" LCTL_DRI="$TMP/dri-node" \
    LCTL_TEST_PATH="$STRIPPED" hf 'preflight' >/dev/null 2>&1; rc=$?
  n_inst=$(grep -c 'apt-get install -y -qq podman podman-compose containers-storage psmisc curl' "$FAUXLOG" || true)
  n_upd=$(grep -n 'apt-get update -qq' "$FAUXLOG" | head -1 | cut -d: -f1)
  local n_ln; n_ln=$(grep -n 'apt-get install -y -qq podman' "$FAUXLOG" | head -1 | cut -d: -f1)
  [ "${n_inst:-0}" = 1 ] && [ -n "$n_upd" ] && [ -n "$n_ln" ] \
    && [ "$n_upd" -lt "$n_ln" ] && [ "$rc" = 0 ]
}

# P-B pkgs-present: FAUX_FULL (all five present) → rc 0, apt-get 0 times in the journal
scen_p_b() {
  new_stack pb; fresh_log
  local lim="$TMP/limits-pb.conf" rc n_apt
  limits_bytes tester 1318060032 > "$lim"
  LCTL_LIMITS="$lim" LCTL_KFD="$TMP/kfd-node" LCTL_DRI="$TMP/dri-node" \
    LCTL_TEST_PATH="$FAUX_FULL:$PATH" hf 'preflight' >/dev/null 2>&1; rc=$?
  n_apt=$(grep -c 'apt-get' "$FAUXLOG" || true)
  [ "$rc" = 0 ] && [ "${n_apt:-0}" = 0 ]
}

# P-C no GPU: the hooks → non-existing paths → an info skip, then the
# hardware die; zero mutations (usermod/install-limits/enable-linger/apt
# NOT in the journal)
scen_p_c() {
  new_stack pc; fresh_log
  local out rc
  out=$(LCTL_KFD="$TMP/no-kfd" LCTL_DRI="$TMP/no-dri" hf 'preflight' 2>&1); rc=$?
  printf '%s' "$out" | grep -q 'GPU-подготовка пропущена' \
    && printf '%s' "$out" | grep -q '/dev/kfd нет' \
    && [ "$rc" != 0 ] \
    && ! grep -qE 'usermod|install -m 0644|enable-linger|apt-get' "$FAUXLOG"
}

# P-D fresh groups: kfd present, video missing from id -nG → usermod
# render,video in the journal, the honest «после перезахода» output, rc
# 42; limits/linger/apt not reached
scen_p_d() {
  new_stack pd; fresh_log
  local out rc
  out=$(LCTL_FAUX_GROUPS="tester render" LCTL_KFD="$TMP/kfd-node" \
    LCTL_DRI="$TMP/dri-node" hf 'preflight' 2>&1); rc=$?
  grep -qF 'sudo usermod -aG render,video tester' "$FAUXLOG" \
    && printf '%s' "$out" | grep -q 'после перезахода' \
    && [ "$rc" = 42 ] \
    && ! grep -qE 'install -m 0644|enable-linger|apt-get' "$FAUXLOG"
}

# P-E no limits file: created, the bytes == the render (tester/2097152), a
# session with a sufficient limit → rc 0, linger called
scen_p_e() {
  new_stack pe; fresh_log
  local lim="$TMP/limits-pe.conf" rc
  rm -f "$lim"
  LCTL_FAUX_ULIMIT=unlimited LCTL_TEST_MEMLOCK=2097152 LCTL_LIMITS="$lim" LCTL_KFD="$TMP/kfd-node" \
    LCTL_DRI="$TMP/dri-node" hf 'preflight' >/dev/null 2>&1; rc=$?
  [ -f "$lim" ] || return 1
  limits_bytes tester 2097152 > "$TMP/limits-pe.expected"
  cmp -s "$TMP/limits-pe.expected" "$lim" || return 1
  grep -q 'enable-linger' "$FAUXLOG" && [ "$rc" = 0 ]
}

# P-F idempotence: the file pre-set equal to the render → install 0 times
# in the journal; a «foreign» content → rewritten (the journal + the bytes)
scen_p_f() {
  new_stack pf; fresh_log
  local lim="$TMP/limits-pf.conf" rc
  limits_bytes tester 2097152 > "$lim"
  LCTL_FAUX_ULIMIT=unlimited LCTL_TEST_MEMLOCK=2097152 LCTL_LIMITS="$lim" LCTL_KFD="$TMP/kfd-node" \
    LCTL_DRI="$TMP/dri-node" hf 'preflight' >/dev/null 2>&1; rc=$?
  [ "$rc" = 0 ] || return 1
  [ "$(grep -c 'install -m 0644' "$FAUXLOG" || true)" = 0 ] || return 1
  fresh_log
  printf 'someone soft memlock 64\n' > "$lim"
  LCTL_FAUX_ULIMIT=unlimited LCTL_TEST_MEMLOCK=2097152 LCTL_LIMITS="$lim" LCTL_KFD="$TMP/kfd-node" \
    LCTL_DRI="$TMP/dri-node" hf 'preflight' >/dev/null 2>&1; rc=$?
  [ "$rc" = 0 ] || return 1
  grep -q 'install -m 0644' "$FAUXLOG" || return 1
  limits_bytes tester 2097152 > "$TMP/limits-pf.expected"
  cmp -s "$TMP/limits-pf.expected" "$lim"
}

# P-G a low session memlock: no file + a subshell with a real builtin
#   ulimit -l 65536 (hard=65536; a lone `ulimit -Hl` in the sandbox gives
#   EINVAL: cur>max) → rc 42, a warn «Требуется ребут», the file written,
#   linger not reached
scen_p_g() {
  new_stack pg; fresh_log
  local lim="$TMP/limits-pg.conf" out rc
  rm -f "$lim"
  out=$( ( ulimit -l 65536; \
           LCTL_TEST_MEMLOCK=2097152 LCTL_LIMITS="$lim" LCTL_KFD="$TMP/kfd-node" LCTL_DRI="$TMP/dri-node" \
           hf 'preflight' ) 2>&1 ); rc=$?
  printf '%s' "$out" | grep -q 'Требуется ребут' \
    && [ -f "$lim" ] && [ "$rc" = 42 ] \
    && ! grep -q 'enable-linger' "$FAUXLOG"
}

# P-H a full no-op: everything in place, the groups ok, the limits equal,
# the linger already on → rc 0; no apt/usermod/install-limits/enable-linger
# in the journal
scen_p_h() {
  new_stack ph; fresh_log
  local lim="$TMP/limits-ph.conf" rc n_bad
  limits_bytes tester 1318060032 > "$lim"
  LCTL_FAUX_LINGER=1 LCTL_LIMITS="$lim" LCTL_KFD="$TMP/kfd-node" \
    LCTL_DRI="$TMP/dri-node" LCTL_TEST_PATH="$FAUX_FULL:$PATH" \
    hf 'preflight' >/dev/null 2>&1; rc=$?
  n_bad=$(grep -cE 'apt-get|usermod|install -m 0644|enable-linger' "$FAUXLOG" || true)
  [ "$rc" = 0 ] && [ "${n_bad:-0}" = 0 ]
}

# ── the .data/<engine>/ layout + the root .env + wave 3 (N1–N7, N10–N12) ────
# The preflight hooks (as in the P scenarios): LCTL_LIMITS — a file
#   pre-set equal to the render (gpu_prep without a write and without
#   exit 42), LCTL_KFD/LCTL_DRI — existing paths, LCTL_FAUX_LINGER=1 (a
#   preflight without sudo mutations).
#   PATH — FAUX_FULL: the podman five in place + the adapter's curl with
#   live answers (/health ok-JSON, /v1/chat/completions chat-JSON) —
#   wait_health/smoke pass without the network and without a real server.

# N1 bootstrap-happy: the first `on` on a clean clone — the pipeline in
#     order, the units LAST (Р1: enable after smoke/check_route), the
#     marker taken, the .env — the LCTL_* canon + the .data/hipfire/…
#     paths (root, relative)
scen_n1_bootstrap() {
  new_stack n1; fresh_log
  rm -rf "$TMP/home"; mkdir -p "$TMP/home"
  local lim="$TMP/limits-n1.conf"
  limits_bytes tester 1318060032 > "$lim"
  local out rc en recreate smoke_ln logs_ln
  out=$(LCTL_LIMITS="$lim" LCTL_KFD="$TMP/kfd-node" LCTL_DRI="$TMP/dri-node" \
    LCTL_FAUX_LINGER=1 LCTL_TEST_PATH="$FAUX_FULL:$PATH" \
    hf 'cmd_start 27b --yes --force' 2>&1); rc=$?
  en=$(grep -n 'systemctl --user enable' "$FAUXLOG" | head -1 | cut -d: -f1)
  recreate=$(grep -n 'up -d --force-recreate' "$FAUXLOG" | head -1 | cut -d: -f1)
  smoke_ln=$(grep -n 'chat/completions' "$FAUXLOG" | tail -1 | cut -d: -f1)
  logs_ln=$(grep -n 'podman logs' "$FAUXLOG" | tail -1 | cut -d: -f1)
  [ "$rc" = 0 ] \
    && printf '%s' "$out" | grep -q 'SMOKE: OK' \
    && printf '%s' "$out" | grep -q 'HEALTHY' \
    && printf '%s' "$out" | grep -q 'автозапуск ВКЛ' \
    && printf '%s' "$out" | grep -q 'активно: hipfire/27b' \
    && [ -n "$en" ] && [ -n "$recreate" ] && [ -n "$smoke_ln" ] && [ -n "$logs_ln" ] \
    && [ "$recreate" -lt "$en" ] && [ "$smoke_ln" -lt "$en" ] && [ "$logs_ln" -lt "$en" ] \
    && [ "$(ups_count)" = 3 ] \
    && [ ! -e "$LCTL_TEST_STACK/.data/hipfire/.stopped" ] \
    && [ -f "$LCTL_TEST_STACK/.env" ] \
    && grep -qF 'LCTL_ENGINE=hipfire' "$LCTL_TEST_STACK/.env" \
    && grep -qF 'LCTL_PROFILE=27b' "$LCTL_TEST_STACK/.env" \
    && grep -qF 'LCTL_PORT=11435' "$LCTL_TEST_STACK/.env" \
    && [ -f "$LCTL_TEST_STACK/compose.yml" ] && [ -f "$LCTL_TEST_STACK/compose.local.yml" ] \
    && [ -d "$LCTL_TEST_STACK/.data/hipfire/models/27b" ] \
    && [ -L "$TMP/home/.local/bin/lctl" ] \
    && grep -q "Environment=CONTAINERS_CONF=$LCTL_TEST_STACK/core/tpl/lctl-containers.conf" "$TMP/home/.config/systemd/user/hipfire-compose.service" \
    && grep -qF 'HIPFIRE_MODELS_PATH=.data/hipfire/models/27b' "$LCTL_TEST_STACK/.env" \
    && grep -qF 'HIPFIRE_STATE_DIR=.data/hipfire/profiles/27b' "$LCTL_TEST_STACK/.env"
}

# N2 bootstrap-idempotent: a second `on` on a deployed stack — WITHOUT the
#     pipeline (a journal without apt/usermod/sudo-install and without a
#     podman run), the units+up
scen_n2_idempotent() {
  new_stack n2; fresh_log
  hf 'set_models_dir 27b; write_stack_files; write_env 27b "$(profile_field 27b 1)"' >/dev/null 2>&1 || return 1
  fresh_log
  local out rc
  out=$(LCTL_TEST_PATH="$FAUX_FULL:$PATH" hf 'cmd_start' 2>&1); rc=$?
  [ "$rc" = 0 ] \
    && ! grep -qE 'apt-get|usermod|sudo install' "$FAUXLOG" \
    && ! grep -q 'podman run' "$FAUXLOG" \
    && printf '%s' "$out" | grep -q 'автозапуск ВКЛ' \
    && [ "$(ups_count)" = 1 ]
}

# N3 the on-mutators guard: on a deployed stack --profile and
#     --no-autostart → a die with a hint ('use' / 'lctl up'), zero actions
#     in the journal
scen_n3_guard() {
  new_stack n3; fresh_log
  hf 'write_env 27b "$(profile_field 27b 1)"' >/dev/null 2>&1 || return 1
  fresh_log
  local out1 rc1 out2 rc2
  out1=$(LCTL_TEST_PATH="$FAUX_FULL:$PATH" hf 'cmd_start --port 1234' 2>&1); rc1=$?
  out2=$(LCTL_TEST_PATH="$FAUX_FULL:$PATH" hf 'cmd_start --no-autostart' 2>&1); rc2=$?
  [ "$rc1" != 0 ] && printf '%s' "$out1" | grep -q "меняет 'stop' + повторный 'start'" \
    && [ "$rc2" != 0 ] && printf '%s' "$out2" | grep -q "поднять без него: 'lctl up'" \
    && [ "$(ups_count)" = 0 ] && ! grep -q 'systemctl --user enable' "$FAUXLOG"
}

# N4 a bootstrap with a ready .data/hipfire/models (the §М migration
#     scenario): the mv move — the podman run mount points into
#     .data/hipfire/models/27b, the files in place are not wiped, the
#     image pull skipped (image exists), the .env — the .data paths
scen_n4_prepopulated() {
  new_stack n4; fresh_log
  mkdir -p "$LCTL_TEST_STACK/.data/hipfire/models/27b" "$LCTL_TEST_STACK/.data/hipfire/profiles/27b/config"
  printf 'dummy-model-bytes' > "$LCTL_TEST_STACK/.data/hipfire/models/27b/qwen38-27b-mq4-xts.safetensors"
  local lim="$TMP/limits-n4.conf"
  limits_bytes tester 1318060032 > "$lim"
  local out rc
  out=$(LCTL_LIMITS="$lim" LCTL_KFD="$TMP/kfd-node" LCTL_DRI="$TMP/dri-node" \
    LCTL_FAUX_LINGER=1 LCTL_TEST_PATH="$FAUX_FULL:$PATH" \
    hf 'cmd_start 27b --yes --force' 2>&1); rc=$?
  [ "$rc" = 0 ] \
    && ! grep -q 'podman pull' "$FAUXLOG" \
    && grep -qF -- "-v $LCTL_TEST_STACK/.data/hipfire/models/27b:/home/hipfire/.hipfire/models" "$FAUXLOG" \
    && [ -f "$LCTL_TEST_STACK/.data/hipfire/models/27b/qwen38-27b-mq4-xts.safetensors" ] \
    && grep -qF 'HIPFIRE_STATE_DIR=.data/hipfire/profiles/27b' "$LCTL_TEST_STACK/.env"
}

# N5 the uninstall-v2 gentle: the units/linger/limits.d/compose down
#     removed; the clone (.env, compose.yml) and .data/hipfire (the
#     models, the profiles) INTACT; without a purge — neither an rmi nor
#     an rm of the models
scen_n5_uninstall() {
  new_stack n5; fresh_log
  hf 'set_models_dir 27b; write_stack_files; write_env 27b "$(profile_field 27b 1)"' >/dev/null 2>&1 || return 1
  mkdir -p "$LCTL_TEST_STACK/.data/hipfire/models/27b"; printf x > "$LCTL_TEST_STACK/.data/hipfire/models/27b/keep-me.bin"
  local out rc
  out=$(LCTL_TEST_PATH="$FAUX_FULL:$PATH" hf 'cmd_uninstall --yes' 2>&1); rc=$?
  [ "$rc" = 0 ] \
    && grep -qE 'compose .* down' "$FAUXLOG" \
    && { [ ! -f /etc/security/limits.d/99-lctl-hipfire-memlock.conf ] \
         || grep -qF 'rm -f /etc/security/limits.d/99-lctl-hipfire-memlock.conf' "$FAUXLOG"; } \
    && grep -q 'disable-linger' "$FAUXLOG" \
    && grep -q 'systemctl --user disable' "$FAUXLOG" \
    && [ -f "$LCTL_TEST_STACK/.data/hipfire/models/27b/keep-me.bin" ] \
    && [ -f "$LCTL_TEST_STACK/.env" ] && [ -f "$LCTL_TEST_STACK/compose.yml" ] \
    && ! grep -q 'podman rmi' "$FAUXLOG" \
    && printf '%s' "$out" | grep -q 'uninstall DONE'
}

# N6 the uninstall purge flags: --purge-models → .data/hipfire/models
#     removed (the profiles intact), --purge-image → a podman rmi in the
#     journal
scen_n6_purge() {
  new_stack n6; fresh_log
  hf 'set_models_dir 27b; write_stack_files; write_env 27b "$(profile_field 27b 1)"' >/dev/null 2>&1 || return 1
  mkdir -p "$LCTL_TEST_STACK/.data/hipfire/models/27b" "$LCTL_TEST_STACK/.data/hipfire/profiles/27b/config"
  local out rc
  out=$(LCTL_TEST_PATH="$FAUX_FULL:$PATH" hf 'cmd_uninstall --purge-models --purge-image --yes' 2>&1); rc=$?
  [ "$rc" = 0 ] \
    && [ ! -e "$LCTL_TEST_STACK/.data/hipfire/models" ] \
    && [ -d "$LCTL_TEST_STACK/.data/hipfire/profiles" ] \
    && grep -qF 'podman rmi ghcr.io/warpfront/hipfire:0.4.8' "$FAUXLOG" \
    && printf '%s' "$out" | grep -q 'модели удалены' \
    && printf '%s' "$out" | grep -q 'образ удалён'
}

# N7 the layout statics (.gitignore, the engine_load .data globals, the
#     lock in .data, the conf tpl path, the watchdog log in logs/, no
#     sync_tree) + a run from the clone's subdir (STACK_DIR = the
#     dispatcher's dirname, the cwd not read)
scen_n7_layout_statics() {
  local tree="${LCTL_TREE:-$ROOT}"
  grep -qx '.data/' "$ROOT/.gitignore" && grep -qx '.env' "$ROOT/.gitignore" \
    && grep -qF 'STACK_DIR="${LCTL_DIR:-$(dirname "$SELF")}"' "$tree/lctl" \
    && grep -qF 'DATA_DIR="$STACK_DIR/.data"' "$tree/lctl" \
    && grep -qF 'UNIT_NAME="$ENGINE-compose"' "$tree/lctl" \
    && grep -qF 'STOP_MARKER="$DATA_DIR/$ENGINE/.stopped"' "$tree/lctl" \
    && grep -qF 'LOCK_FILE="$DATA_DIR/.lctl.lock"' "$tree/lctl" \
    && grep -qF 'MODELS_BASE="${LCTL_MODELS:-$DATA_DIR/$ENGINE/models}"' "$tree/lctl" \
    && grep -qF 'STATE_BASE="${LCTL_STATE:-$DATA_DIR/$ENGINE/profiles}"' "$tree/lctl" \
    && grep -qF '$STACK_DIR/core/tpl/lctl-containers.conf' "$tree/core/stack.sh" \
    && grep -qF '$LOG_DIR/watchdog.log' "$tree/core/autostart.sh" \
    && [ "$(grep -cF '$LOCK_FILE' "$tree/core/autostart.sh")" = 8 ] \
    && ! grep -q 'sync_tree' "$tree/core/stack_files.sh" \
    && [ ! -e "$tree/install.sh" ] || return 1
  local sub="$TMP/subtree" dout
  rm -rf "$sub"; mkdir -p "$sub"
  cp -a "$tree/lctl" "$tree/core" "$tree/engines" "$sub/" || return 1
  dout=$(cd "$sub/core" && env PATH="$FAUX_FULL:$PATH" HOME="$TMP/home" USER=tester \
    LCTL_ENGINE=hipfire \
    LCTL_FAUX_LOG="$FAUXLOG" LCTL_FAUX_CNT="$FAUXCNT" LCTL_FAUX_ORPHAN_ID="$ORPHAN_ID" \
    LCTL_FAUX_TMP="$TMP" bash "$sub/lctl" doctor 2>&1)
  printf '%s' "$dout" | grep -qF "НЕ УСТАНОВЛЕН ($sub/.env нет)" \
    && printf '%s' "$dout" | grep -q "сначала 'lctl start'"
}

# N10 a faux end-to-end through the REAL dispatcher: `lctl start hipfire
#     27b` on a clean clone (LCTL_DIR=a fake stack) — the positional
#     engine/profile, the pipeline, the units last, the .env canon
scen_n10_e2e_dispatcher() {
  new_stack n10; fresh_log
  rm -rf "$TMP/home"; mkdir -p "$TMP/home"
  local lim="$TMP/limits-n10.conf"
  limits_bytes tester 1318060032 > "$lim"
  local out rc en recreate smoke_ln
  out=$(env PATH="$FAUX_FULL:$PATH" HOME="$TMP/home" USER=tester \
    LCTL_DIR="$LCTL_TEST_STACK" LCTL_LIMITS="$lim" LCTL_KFD="$TMP/kfd-node" LCTL_DRI="$TMP/dri-node" \
    LCTL_FAUX_LINGER=1 \
    LCTL_FAUX_LOG="$FAUXLOG" LCTL_FAUX_CNT="$FAUXCNT" LCTL_FAUX_ORPHAN_ID="$ORPHAN_ID" LCTL_FAUX_TMP="$TMP" \
    bash "$ROOT/lctl" start hipfire 27b --yes --force 2>&1); rc=$?
  en=$(grep -n 'systemctl --user enable' "$FAUXLOG" | head -1 | cut -d: -f1)
  recreate=$(grep -n 'up -d --force-recreate' "$FAUXLOG" | head -1 | cut -d: -f1)
  smoke_ln=$(grep -n 'chat/completions' "$FAUXLOG" | tail -1 | cut -d: -f1)
  [ "$rc" = 0 ] \
    && printf '%s' "$out" | grep -q 'SMOKE: OK' \
    && printf '%s' "$out" | grep -q 'автозапуск ВКЛ' \
    && printf '%s' "$out" | grep -q 'активно: hipfire/27b' \
    && [ -n "$en" ] && [ -n "$recreate" ] && [ -n "$smoke_ln" ] \
    && [ "$recreate" -lt "$en" ] && [ "$smoke_ln" -lt "$en" ] \
    && [ -f "$LCTL_TEST_STACK/.env" ] \
    && grep -qF 'LCTL_ENGINE=hipfire' "$LCTL_TEST_STACK/.env" \
    && grep -qF 'LCTL_PROFILE=27b' "$LCTL_TEST_STACK/.env" \
    && [ -f "$TMP/home/.config/systemd/user/hipfire-compose.service" ]
}

# N11 the switch (§А-1): `lctl start hipfire 27b` with ANOTHER engine
#     active (the canon .env=LCTL_ENGINE=stub) = an honest stub off (its
#     container/units) → the hipfire bootstrap; a podman stop stub in the
#     journal before the first hipfire up; the final canon — hipfire; the
#     units — hipfire-compose
scen_n11_switch() {
  new_stack n11; fresh_log
  rm -rf "$TMP/home"; mkdir -p "$TMP/home"
  # a tree copy with a fictitious second adapter «stub»
  local tree="$TMP/sw-tree"
  rm -rf "$tree"; mkdir -p "$tree"
  cp -a "$ROOT/lctl" "$ROOT/core" "$ROOT/engines" "$tree/" || return 1
  mkdir -p "$tree/engines/stub"
  shim stub_adapter.sh "$tree/engines/stub/adapter.sh"
  mkdir -p "$tree/engines/stub/profiles"
  shim stub_profile.env "$tree/engines/stub/profiles/stub-p.env"
  # the canon: stub active (as after a switch to stub)
  printf 'LCTL_ENGINE=stub\nLCTL_PROFILE=stub-p\nLCTL_PORT=11999\nLCTL_BIND=0.0.0.0\n' > "$LCTL_TEST_STACK/.env"
  local lim="$TMP/limits-n11.conf"
  limits_bytes tester 1318060032 > "$lim"
  local out rc stop_ln up1_ln
  out=$(env PATH="$FAUX_FULL:$PATH" HOME="$TMP/home" USER=tester \
    LCTL_DIR="$LCTL_TEST_STACK" LCTL_LIMITS="$lim" LCTL_KFD="$TMP/kfd-node" LCTL_DRI="$TMP/dri-node" \
    LCTL_FAUX_LINGER=1 \
    LCTL_FAUX_LOG="$FAUXLOG" LCTL_FAUX_CNT="$FAUXCNT" LCTL_FAUX_ORPHAN_ID="$ORPHAN_ID" LCTL_FAUX_TMP="$TMP" \
    bash "$tree/lctl" start hipfire 27b --yes --force 2>&1); rc=$?
  stop_ln=$(grep -n 'podman stop stub_stub_1' "$FAUXLOG" | head -1 | cut -d: -f1)
  up1_ln=$(grep -n 'up -d' "$FAUXLOG" | head -1 | cut -d: -f1)
  [ "$rc" = 0 ] \
    && printf '%s' "$out" | grep -q 'ВЫКЛ' \
    && printf '%s' "$out" | grep -q 'SMOKE: OK' \
    && printf '%s' "$out" | grep -q 'активно: hipfire/27b' \
    && [ -n "$stop_ln" ] && [ -n "$up1_ln" ] && [ "$stop_ln" -lt "$up1_ln" ] \
    && grep -qF 'LCTL_ENGINE=hipfire' "$LCTL_TEST_STACK/.env" \
    && [ -f "$TMP/home/.config/systemd/user/hipfire-compose.service" ] \
    && [ ! -e "$TMP/home/.config/systemd/user/stub-compose.service" ]
}

# N12 a port conflict via start (§А-2): a faux ss (LCTL_FAUX_SS_LISTEN=1)
#     shows a foreign listener on PORT → the bootstrap phase dies with a
#     hint BEFORE the first up; without a listener — the pipeline goes
scen_n12_port_conflict() {
  new_stack n12; fresh_log
  local out1 rc1 out2 rc2 lim="$TMP/limits-n12.conf"
  limits_bytes tester 1318060032 > "$lim"
  out1=$(LCTL_FAUX_SS_LISTEN=1 LCTL_LIMITS="$lim" LCTL_KFD="$TMP/kfd-node" LCTL_DRI="$TMP/dri-node" \
    LCTL_FAUX_LINGER=1 LCTL_TEST_PATH="$FAUX_FULL:$PATH" \
    hf 'cmd_start 27b --yes --force' 2>&1); rc1=$?
  local ups1; ups1=$(ups_count)
  fresh_log
  out2=$(LCTL_LIMITS="$lim" LCTL_KFD="$TMP/kfd-node" LCTL_DRI="$TMP/dri-node" \
    LCTL_FAUX_LINGER=1 LCTL_TEST_PATH="$FAUX_FULL:$PATH" \
    hf 'cmd_start 27b --yes --force' 2>&1); rc2=$?
  [ "$rc1" != 0 ] && printf '%s' "$out1" | grep -q 'уже занят другим процессом' \
    && printf '%s' "$out1" | grep -q 'lctl start <engine> <profile> --port' \
    && [ "$ups1" = 0 ] \
    && [ "$rc2" = 0 ] && [ "$(ups_count)" -ge 1 ]
}

# N13 env-model (fix:env-model, a live window hotfix): write_env hipfire
#     flash — the engine key HIPFIRE_MODEL in .env == LCTL_MODEL == the
#     flash profile's registry model (not the compose default
#     ${HIPFIRE_MODEL:-…27b}); on 27b the defect is invisible (the profile
#     == the compose default), on gufo it is not needed (a literal
#     compose)
scen_n13_env_model() {
  new_stack n13
  hf 'write_env flash "$(profile_field flash 1)"' >/dev/null 2>&1 || return 1
  local m
  m="$(sed -n 's/^LCTL_MODEL=//p' "$LCTL_TEST_STACK/.env")"
  [ "$m" = "qwen3.8:flash-next-mq4-xts" ] || return 1
  [ "$m" = "$(sed -n 's/^HIPFIRE_MODEL=//p' "$LCTL_TEST_STACK/.env")" ]
}

# ── 1.2: the §А automat — the use absorption, a no-op, stop, pull, the verb aliases ─

# S1 the use absorption: a start with a profile FOREIGN to the canon = §А-4
#     (apply_profile + a recreate, the former use): the canon rewritten,
#     the cfgset keys in the journal, the units last (Р1), a status line
scen_s1_use_absorbed() {
  new_stack s1; fresh_log
  hf 'set_models_dir 27b; write_stack_files; write_env 27b "$(profile_field 27b 1)"' >/dev/null 2>&1 || return 1
  local lim="$TMP/limits-s1.conf"
  limits_bytes tester 1318060032 > "$lim"
  local out rc en recreate
  out=$(LCTL_LIMITS="$lim" LCTL_KFD="$TMP/kfd-node" LCTL_DRI="$TMP/dri-node" \
    LCTL_FAUX_LINGER=1 LCTL_TEST_PATH="$FAUX_FULL:$PATH" \
    hf 'cmd_start 27b-parallel --force' 2>&1); rc=$?
  en=$(grep -n 'systemctl --user enable' "$FAUXLOG" | head -1 | cut -d: -f1)
  recreate=$(grep -n 'up -d --force-recreate' "$FAUXLOG" | head -1 | cut -d: -f1)
  [ "$rc" = 0 ] \
    && grep -qF 'LCTL_PROFILE=27b-parallel' "$LCTL_TEST_STACK/.env" \
    && grep -qF 'config set serve.multi_slot true' "$FAUXLOG" \
    && printf '%s' "$out" | grep -q 'SMOKE: OK' \
    && printf '%s' "$out" | grep -q 'активно: hipfire/27b-parallel' \
    && [ -n "$en" ] && [ -n "$recreate" ] && [ "$recreate" -lt "$en" ]
}

# S2 a start no-op (stage 8): deployed, the canon == the profile, the
#     container running, the render MATCHES → «уже запущено … — рендер
#     совпадает», ZERO actions: no up call, the units not re-created, the
#     files byte-identical before/after
scen_s2_start_noop() {
  new_stack s2; fresh_log
  hf 'set_models_dir 27b; write_stack_files; write_env 27b "$(profile_field 27b 1)"' >/dev/null 2>&1 || return 1
  local md5_before; md5_before=$(md5sum "$LCTL_TEST_STACK/.env" "$LCTL_TEST_STACK"/compose*.yml)
  echo 1 > "$FAUXCNT.upok"      # faux inspect: контейнер running
  : > "$FAUXLOG"
  local out rc
  out=$(hf 'cmd_start 27b' 2>&1); rc=$?
  [ "$rc" = 0 ] \
    && printf '%s' "$out" | grep -q 'уже запущено: hipfire/27b' \
    && printf '%s' "$out" | grep -q '— рендер совпадает' \
    && [ "$md5_before" = "$(md5sum "$LCTL_TEST_STACK/.env" "$LCTL_TEST_STACK"/compose*.yml)" ] \
    && [ "$(ups_count)" = 0 ] \
    && ! grep -q 'up -d' "$FAUXLOG" \
    && ! grep -q 'systemctl --user enable' "$FAUXLOG"
}

# S2-heal (autostart-heal, 5558e28): deployed, running, the render
#     matches, BUT the STOP_MARKER is in place (after an lctl stop the
#     container was raised by hand) → the start FINISHES the autostart
#     (the units in the faux-systemctl journal, «автозапуск ВКЛ») and
#     still answers «already running» — live 2026-11-24
scen_s2_autostart_heal() {
  new_stack s2heal; fresh_log
  hf 'set_models_dir 27b; write_stack_files; write_env 27b "$(profile_field 27b 1)"' >/dev/null 2>&1 || return 1
  echo 1 > "$FAUXCNT.upok"      # faux inspect: контейнер running
  : > "$FAUXLOG"
  touch "$LCTL_TEST_STACK/.data/hipfire/.stopped"   # STOP_MARKER (лейаут ядра)
  local out rc
  out=$(hf 'cmd_start 27b' 2>&1); rc=$?
  [ "$rc" = 0 ] \
    && printf '%s' "$out" | grep -q 'уже запущено: hipfire/27b' \
    && printf '%s' "$out" | grep -q 'автозапуск ВКЛ' \
    && grep -q 'systemctl --user enable' "$FAUXLOG" \
    && [ "$(ups_count)" = 0 ]
}

# S2a the convergence + a recreate (stage 8): running, .env and
#     compose.local.yml diverge from the render → a WARN «рендер
#     изменился», the files rewritten (the bytes == a fresh render: an
#     independent render into a buffer, cmp), apply_profile + up -d
#     --force-recreate (exactly 1, no plain up) + wait_health (HEALTHY),
#     the units last, «активно:»
scen_s2a_render_converge() {
  new_stack s2a; fresh_log
  hf 'set_models_dir 27b; write_stack_files; write_env 27b "$(profile_field 27b 1)"' >/dev/null 2>&1 || return 1
  printf 'garbage: ручная правка не переживает start\n' >> "$LCTL_TEST_STACK/.env"
  printf 'garbage: not-a-compose\n' > "$LCTL_TEST_STACK/compose.local.yml"
  echo 1 > "$FAUXCNT.upok"      # faux inspect: контейнер running
  : > "$FAUXLOG"
  local out rc
  out=$(LCTL_TEST_PATH="$FAUX_FULL:$PATH" hf 'cmd_start 27b' 2>&1); rc=$?
  # the files == a fresh render (an independent render into a buffer + cmp)
  local ref="$TMP/s2a-ref"; rm -rf "$ref"; mkdir -p "$ref"
  hf "set_models_dir 27b; render_env_to '$ref/.env' 27b \"\$(profile_field 27b 1)\"; engine_write_compose '$ref'" >/dev/null 2>&1 || return 1
  cmp -s "$ref/.env" "$LCTL_TEST_STACK/.env" || return 1
  cmp -s "$ref/compose.yml" "$LCTL_TEST_STACK/compose.yml" || return 1
  cmp -s "$ref/compose.halo.yml" "$LCTL_TEST_STACK/compose.halo.yml" || return 1
  cmp -s "$ref/compose.local.yml" "$LCTL_TEST_STACK/compose.local.yml" || return 1
  grep -qF 'LCTL_PROFILE=27b' "$LCTL_TEST_STACK/.env" || return 1
  ! grep -q 'garbage' "$LCTL_TEST_STACK/.env" || return 1
  [ "$(grep -c 'up -d --force-recreate' "$FAUXLOG")" = 1 ] || return 1
  [ "$(grep -cE 'up -d$' "$FAUXLOG")" = 0 ] || return 1
  grep -qF 'config set memory.max_seq' "$FAUXLOG" || return 1   # apply_profile пройден
  printf '%s' "$out" | grep -q 'рендер изменился' || return 1
  printf '%s' "$out" | grep -q 'HEALTHY' || return 1
  printf '%s' "$out" | grep -q 'автозапуск ВКЛ' || return 1
  printf '%s' "$out" | grep -q 'активно: hipfire/27b' || return 1
  [ "$rc" = 0 ]
}

# S2b --no-recreate (stage 8): running + a .env diff → the render and the
#     WRITE done (canonical bytes), a recreate NOT called (neither up -d
#     nor cfgset/apply_profile), the WARN honestly names the «stop &&
#     start» path; a repeated start without the flag → «the render
#     matches», no recreate (the documented flag gap)
scen_s2b_no_recreate() {
  new_stack s2b; fresh_log
  hf 'set_models_dir 27b; write_stack_files; write_env 27b "$(profile_field 27b 1)"' >/dev/null 2>&1 || return 1
  printf 'garbage: ручная правка\n' >> "$LCTL_TEST_STACK/.env"
  echo 1 > "$FAUXCNT.upok"      # faux inspect: контейнер running
  : > "$FAUXLOG"
  local out rc
  out=$(LCTL_TEST_PATH="$FAUX_FULL:$PATH" hf 'cmd_start 27b --no-recreate' 2>&1); rc=$?
  [ "$rc" = 0 ] || return 1     # флаг на развёрнутом стеке НЕ die (не мутатор)
  local ref="$TMP/s2b-ref"; rm -rf "$ref"; mkdir -p "$ref"
  hf "set_models_dir 27b; render_env_to '$ref/.env' 27b \"\$(profile_field 27b 1)\"; engine_write_compose '$ref'" >/dev/null 2>&1 || return 1
  cmp -s "$ref/.env" "$LCTL_TEST_STACK/.env" || return 1        # запись выполнена
  [ "$(grep -c 'up -d --force-recreate' "$FAUXLOG")" = 0 ] || return 1
  [ "$(ups_count)" = 0 ] || return 1
  ! grep -q 'config set' "$FAUXLOG" || return 1                 # apply_profile не звался
  printf '%s' "$out" | grep -q 'рендер изменился' || return 1
  printf '%s' "$out" | grep -q 'не пересоздавался' || return 1
  printf '%s' "$out" | grep -q 'stop && lctl start' || return 1
  # a repeated start WITHOUT the flag: «the render matches», no recreate (the flag gap)
  : > "$FAUXLOG"
  out=$(hf 'cmd_start 27b' 2>&1); rc=$?
  [ "$rc" = 0 ] \
    && printf '%s' "$out" | grep -q '— рендер совпадает' \
    && [ "$(ups_count)" = 0 ]
}

# S2c a cold one + a diff (stage 8): the stack not running, .env diverges
#     → a WARN «стек поднимется с новым рендером», a write, exactly 1
#     PLAIN up (cmd_up; without
#     force-recreate), HEALTHY
scen_s2c_cold_diff() {
  new_stack s2c; fresh_log
  hf 'set_models_dir 27b; write_stack_files; write_env 27b "$(profile_field 27b 1)"' >/dev/null 2>&1 || return 1
  printf 'garbage: ручная правка\n' >> "$LCTL_TEST_STACK/.env"
  : > "$FAUXLOG"                # upok сброшен → контейнер НЕ running
  local out rc
  out=$(LCTL_TEST_PATH="$FAUX_FULL:$PATH" hf 'cmd_start 27b' 2>&1); rc=$?
  local ref="$TMP/s2c-ref"; rm -rf "$ref"; mkdir -p "$ref"
  hf "set_models_dir 27b; render_env_to '$ref/.env' 27b \"\$(profile_field 27b 1)\"" >/dev/null 2>&1 || return 1
  cmp -s "$ref/.env" "$LCTL_TEST_STACK/.env" || return 1
  ! grep -q 'garbage' "$LCTL_TEST_STACK/.env" || return 1
  printf '%s' "$out" | grep -q 'рендер изменился' || return 1
  printf '%s' "$out" | grep -q 'стек поднимется с новым рендером' || return 1
  [ "$(grep -cE 'up -d$' "$FAUXLOG")" = 1 ] || return 1         # ровно 1 обычный up
  [ "$(grep -c 'force-recreate' "$FAUXLOG")" = 0 ] || return 1
  printf '%s' "$out" | grep -q 'HEALTHY' || return 1
  [ "$rc" = 0 ]
}

# S3 a stop on an empty machine: no units (an empty LCTL_FAUX_UNITS) →
#     «not running», rc 0, zero actions
scen_s3_stop_empty() {
  new_stack s3; fresh_log
  local out rc
  out=$(LCTL_FAUX_UNITS="" hf 'cmd_stop' 2>&1); rc=$?
  [ "$rc" = 0 ] \
    && printf '%s' "$out" | grep -q 'не запущено' \
    && ! grep -q 'podman stop' "$FAUXLOG" \
    && ! grep -q 'disable-linger' "$FAUXLOG"
}

# S4 a stop of an active one: the hipfire-compose unit enabled
#     (LCTL_FAUX_UNITS) → an honest off by its adapter (an explicit podman
#     stop + linger off), rc 0
scen_s4_stop_active() {
  new_stack s4; fresh_log
  local out rc
  out=$(LCTL_FAUX_UNITS="hipfire-compose" hf 'cmd_stop' 2>&1); rc=$?
  grep -qF 'podman stop hipfire_hipfire_1' "$FAUXLOG" \
    && grep -q 'disable-linger' "$FAUXLOG" \
    && grep -q 'systemctl --user disable' "$FAUXLOG" \
    && [ "$rc" = 0 ] && printf '%s' "$out" | grep -q 'ВЫКЛ'
}

# S5 a pull prefetch: a pull WITHOUT .env/units/a start — the set in place, 0 ups
scen_s5_pull_prefetch() {
  new_stack s5; fresh_log
  local out rc
  out=$(hf 'cmd_pull flash' 2>&1); rc=$?
  [ "$rc" = 0 ] \
    && [ ! -f "$LCTL_TEST_STACK/.env" ] \
    && [ -d "$LCTL_TEST_STACK/.data/hipfire/models/flash" ] \
    && grep -qF -- "-v $LCTL_TEST_STACK/.data/hipfire/models/flash:/home/hipfire/.hipfire/models" "$FAUXLOG" \
    && [ "$(ups_count)" = 0 ] \
    && ! grep -q 'systemctl --user enable' "$FAUXLOG"
}

# S6 the transitional verb aliases: one mapping assert each in the router
#     (on/install → cmd_start, use → cmd_start, switch → cmd_start,
#      off [--engine] → engine_off_foreign, stop → cmd_stop)
scen_s6_verb_aliases() {
  grep -qF 'on|install)    cmd_start' "$ROOT/lctl" \
    && grep -qF 'use)           cmd_start' "$ROOT/lctl" \
    && grep -qF 'switch)        cmd_start' "$ROOT/lctl" \
    && grep -qF 'engine_off_foreign "$engine_opt"' "$ROOT/lctl" \
    && grep -qF 'cmd_stop' "$ROOT/lctl"
}

# S5b a pull through the REAL dispatcher: the positional <engine>
#     <profile> (the round-2 regression — the router parsed the profile
#     only at start)
scen_s5b_pull_dispatcher() {
  new_stack s5b; fresh_log
  rm -rf "$TMP/home"; mkdir -p "$TMP/home"
  local out rc
  out=$(env PATH="$FAUX_FULL:$PATH" HOME="$TMP/home" USER=tester \
    LCTL_DIR="$LCTL_TEST_STACK" \
    LCTL_FAUX_LOG="$FAUXLOG" LCTL_FAUX_CNT="$FAUXCNT" LCTL_FAUX_ORPHAN_ID="$ORPHAN_ID" LCTL_FAUX_TMP="$TMP" \
    bash "$ROOT/lctl" pull hipfire flash 2>&1); rc=$?
  [ "$rc" = 0 ] \
    && printf '%s' "$out" | grep -qF "готово: $LCTL_TEST_STACK/.data/hipfire/models/flash" \
    && [ ! -f "$LCTL_TEST_STACK/.env" ] \
    && [ -d "$LCTL_TEST_STACK/.data/hipfire/models/flash" ] \
    && [ "$(ups_count)" = 0 ] \
    && ! grep -q 'systemctl --user enable' "$FAUXLOG"
}

# S7 the §А-1 fix + the stage-8 rework: foreign units with OUR canon — an
#     off of the foreign one by the units; a canon with a custom port/bind
#     set by a LEGITIMATE mechanism (the PORT/BIND globals before
#     write_env — as in use) and it SURVIVES a start as the canonical
#     render: the convergence sees a match (WITHOUT a false recreate),
#     the §А-3 ensure — one up, no re-bootstrap
scen_s7_own_canon_survives() {
  new_stack s7; fresh_log
  rm -rf "$TMP/home"; mkdir -p "$TMP/home"
  local tree="$TMP/s7-tree"
  rm -rf "$tree"; mkdir -p "$tree"
  cp -a "$ROOT/lctl" "$ROOT/core" "$ROOT/engines" "$tree/" || return 1
  mkdir -p "$tree/engines/stub"
  shim stub_adapter.sh "$tree/engines/stub/adapter.sh"
  mkdir -p "$tree/engines/stub/profiles"
  shim stub_profile.env "$tree/engines/stub/profiles/stub-p.env"
  # a deployed canon of the TARGET engine with a custom port/bind — a
  # legitimate mechanism (the PORT/BIND globals → write_env), not a manual
  # .env edit
  hf 'set_models_dir 27b; PORT=11444 BIND=0.0.0.9; write_stack_files; write_env 27b "$(profile_field 27b 1)"' >/dev/null 2>&1 || return 1
  local lim="$TMP/limits-s7.conf"
  limits_bytes tester 1318060032 > "$lim"
  local out rc
  out=$(env PATH="$FAUX_FULL:$PATH" HOME="$TMP/home" USER=tester \
    LCTL_DIR="$LCTL_TEST_STACK" LCTL_LIMITS="$lim" LCTL_KFD="$TMP/kfd-node" LCTL_DRI="$TMP/dri-node" \
    LCTL_FAUX_LINGER=1 LCTL_FAUX_UNITS="stub-compose" \
    LCTL_FAUX_LOG="$FAUXLOG" LCTL_FAUX_CNT="$FAUXCNT" LCTL_FAUX_ORPHAN_ID="$ORPHAN_ID" LCTL_FAUX_TMP="$TMP" \
    bash "$tree/lctl" start hipfire 27b --yes --force 2>&1); rc=$?
  [ "$rc" = 0 ] \
    && grep -qF 'podman stop stub_stub_1' "$FAUXLOG" \
    && grep -q '^LCTL_PORT=11444$' "$LCTL_TEST_STACK/.env" \
    && grep -q '^LCTL_BIND=0.0.0.9$' "$LCTL_TEST_STACK/.env" \
    && [ "$(grep -c '^LCTL_PORT=' "$LCTL_TEST_STACK/.env")" = 1 ] \
    && grep -qF 'LCTL_PROFILE=27b' "$LCTL_TEST_STACK/.env" \
    && ! grep -q 'apt-get' "$FAUXLOG" \
    && ! grep -q 'up -d --force-recreate' "$FAUXLOG" \
    && ! grep -q 'рендер изменился' <<<"$out" \
    && [ "$(ups_count)" = 1 ] \
    && printf '%s' "$out" | grep -q 'активно: hipfire/27b' \
    && printf '%s' "$out" | grep -q 'http://0.0.0.9:11444'
}

# ── W0: the watch frame (the core) — the cmd_watch guards + the frame's selfcheck ─

# W0 the cmd_watch guards: a crooked interval/argument → die; with W2 the
#     panel EXISTS — the exec branch is finite by the battery seam
#     LCTL_WATCH_TICKS=1 (one tick — the frame's loop terminates itself;
#     no eternal waits — the timeout rule):
#     a faux curl answers /health on :11435 → [движок] in plain
scen_w0_cmd_watch() {
  new_stack w0; fresh_log
  local out rc
  out=$(hf 'cmd_watch --interval abc' 2>&1); rc=$?
  [ "$rc" = 1 ] && printf '%s' "$out" | grep -q 'интервал должен быть целым' || return 1
  out=$(hf 'cmd_watch --interval 0' 2>&1); rc=$?
  [ "$rc" = 1 ] && printf '%s' "$out" | grep -q 'интервал должен быть ≥ 1 с' || return 1
  out=$(hf 'cmd_watch --interval' 2>&1); rc=$?
  [ "$rc" = 1 ] && printf '%s' "$out" | grep -q 'использование: lctl watch' || return 1
  out=$(hf 'cmd_watch --garbage' 2>&1); rc=$?
  [ "$rc" = 1 ] && printf '%s' "$out" | grep -q "неизвестный аргумент '--garbage'" || return 1
  out=$(LCTL_TEST_PATH="$FAUX_FULL:$PATH" LCTL_WATCH_TICKS=1 \
    hf 'cmd_watch --interval=1' 2>&1); rc=$?
  [ "$rc" = 0 ] \
    && printf '%s' "$out" | grep -q '\[движок\]' \
    && grep -qF 'http://127.0.0.1:11435/health' "$FAUXLOG" \
    && grep -qF 'http://127.0.0.1:11435/stats' "$FAUXLOG" \
    && grep -qF 'http://127.0.0.1:11435/metrics' "$FAUXLOG" || return 1
  # the W3 env seam: the core passes LCTL_WATCH_ENGINE="$ENGINE" (a
  #     variable, not a value — R6), the frame reads it into Watch.engine
  grep -qF 'LCTL_WATCH_ENGINE="$ENGINE"' "$ROOT/core/commands.sh" || return 1
  LCTL_WATCH_ENGINE=engine-x PYTHONPATH="$ROOT/core/py/watch" \
    python3 -c 'import watch_frame, sys; w = watch_frame.Watch([], eng=None); sys.exit(0 if w.engine == "engine-x" else 1)' || return 1
  # the W3.2.2 header seam: the LCTL_WATCH_IP stub is read without a socket call
  LCTL_WATCH_IP=10.0.0.9 LCTL_WATCH_PORT=11435 \
    PYTHONPATH="$ROOT/core/py/watch" \
    python3 -c 'import watch_frame, sys; w = watch_frame.Watch([], eng=None); sys.exit(0 if w.watch_ip == "10.0.0.9" and w.port == 11435 else 1)' || return 1
  # a long log line via the faux: plain does not crash (the clip is in
  #     the TUI frame, the frame's log_clip; plain prints as is)
  printf '2026-11-23 09:00:00 [INFO] %s\n' "$(printf 'x%.0s' $(seq 1 300))" > "$TMP/w0-longlog"
  out=$(LCTL_TEST_PATH="$FAUX_FULL:$PATH" LCTL_WATCH_TICKS=1 \
    LCTL_FAUX_PODMAN_LOGS="$TMP/w0-longlog" \
    hf 'cmd_watch --interval=1' 2>&1); rc=$?
  [ "$rc" = 0 ] && printf '%s' "$out" | grep -q '\[логи\]' || return 1
  # the router: watch in the command list + the ENGINE_WATCH_TUI guard in the core
  grep -q 'watch)' "$ROOT/lctl" && grep -q 'ENGINE_WATCH_TUI' "$ROOT/core/commands.sh" || return 1
  return 0
}

# W0 the frame's selfcheck: the glyphs/colors/formatters (the W3 «—»
#     invariant: fmt_pct «58.0 %», fmt_uptime, fmt_int_sep), a dead line,
#     the status-bar (incl. the engine name), log_clip + log_lines_fit
#     (the D3 vertical clip), the D5 constants, the v2 scheme of the
#     CommonEnginePanel (the flat §1 rows) + the MetricsPanel (the 7 §1
#     rows), the hardware (CPU first)/speed («Скорость» title) panels,
#     dir_size_bytes (a recursive used-scan of a dir), the wire primitives
#     (parse_metrics/Deltas/sparkline/TZ + the podman RFC3339 F1),
#     watch_hw on fake trees, the LogStreamer (no podman /
#     stderr→stdout / args WITH -t in the seed and live, a dedup of the
#     stamped seed)
scen_w0_selfcheck() {
  local out rc
  out=$(LCTL_WATCH_SELFCHECK=1 timeout 120 python3 "$ROOT/core/py/watch/watch_frame.py" 2>&1); rc=$?
  [ "$rc" = 0 ] && printf '%s' "$out" | grep -q 'selfcheck: 104/104 ok' || return 1
  return 0
}

# W0 the R6 statics (W3): the frame has neither engine names nor their
#     dialects — the boundary invariant for the future (a new R6 check of
#     the battery)
scen_w0_r6_watch() {
  ! grep -rniE 'gufo|hipfire' "$ROOT/core/py/watch/" || return 1
  return 0
}

# the Core-R6 statics (the 2026-11-25 audit): the shell core (lctl +
#     core/*.sh) and the tpls not covered by the waves (smoke_resp,
#     systemd, containers.conf) WITHOUT engine names. A cheap trap against
#     copy-pasting dialects into the core; the full boundary is proven by
#     the adapters (two implementations on one core), not by a grep.
#     Comments count the same as code: the names are allowed only in
#     engines/<name>/.
scen_core_r6_static() {
  ! grep -rniE 'gufo|hipfire|halogen' "$ROOT/lctl" "$ROOT/core/"*.sh \
    "$ROOT/core/py/smoke_resp.py" "$ROOT/core/tpl/systemd/" \
    "$ROOT/core/tpl/lctl-containers.conf" || return 1
  return 0
}

# ── the K wave (task 3.1 §2): health-path / off-now / memlock-gate / compose-rerender ─

# K-1 the hipfire surface unchanged: wait_health curls the DEFAULT /health
#     (HEALTH_PATH — a mirror of ENGINE_HEALTH_PATH; the hipfire global
#     does not set it)
scen_k1_health_default() {
  new_stack k1; fresh_log
  local out rc
  out=$(LCTL_TEST_PATH="$FAUX_FULL:$PATH" hf 'wait_health 5' 2>&1); rc=$?
  [ "$rc" = 0 ] \
    && printf '%s' "$out" | grep -q 'HEALTHY' \
    && grep -qF 'curl -fsS -m 5 http://127.0.0.1:11435/health' "$FAUXLOG" \
    && ! grep -qF '/ready' "$FAUXLOG"
}

# K-3 off-now: cmd_off → a systemctl disable --now in the journal (the
#     timer goes out immediately, without a race window to daemon-reload)
scen_k3_off_now() {
  new_stack k3; fresh_log
  hf 'cmd_off' >/dev/null 2>&1 || return 1
  grep -qF 'systemctl --user disable --now hipfire-compose.service hipfire-compose-watchdog.timer' "$FAUXLOG"
}

# K-4 the «достаточно» branch: the session exactly at the 8388608
#     threshold → the file written, a WARN «достаточно», rc 0 (we
#     continue), linger reached
scen_k4_enough() {
  new_stack k4a; fresh_log
  local lim="$TMP/limits-k4a.conf" out rc
  rm -f "$lim"
  out=$(LCTL_FAUX_ULIMIT=8388608 LCTL_TEST_MEMLOCK=2097152 LCTL_LIMITS="$lim" \
    LCTL_KFD="$TMP/kfd-node" LCTL_DRI="$TMP/dri-node" hf 'preflight' 2>&1); rc=$?
  [ -f "$lim" ] && [ "$rc" = 0 ] \
    && printf '%s' "$out" | grep -q 'достаточно (порог 8388608 kB)' \
    && grep -q 'enable-linger' "$FAUXLOG"
}

# K-4 the «unlimited» branch: a PASS without any WARN (neither «достаточно» nor «ребут»)
scen_k4_unlimited() {
  new_stack k4b; fresh_log
  local lim="$TMP/limits-k4b.conf" out rc
  rm -f "$lim"
  out=$(LCTL_FAUX_ULIMIT=unlimited LCTL_TEST_MEMLOCK=2097152 LCTL_LIMITS="$lim" \
    LCTL_KFD="$TMP/kfd-node" LCTL_DRI="$TMP/dri-node" hf 'preflight' 2>&1); rc=$?
  [ -f "$lim" ] && [ "$rc" = 0 ] \
    && ! printf '%s' "$out" | grep -qE 'достаточно|Требуется ребут|ПЕРЕЛОГИНЬСЯ' \
    && grep -q 'enable-linger' "$FAUXLOG"
}

# K-4 the «below the threshold» branch DISTINGUISHING from the old gate: a
#     4194304 session at MEMLOCK=2097152 — the old gate (a comparison
#     against MEMLOCK) would have passed it (rc 0), the new one (the
#     8388608 threshold) → a file + a WARN «ребут» + exit 42
scen_k4_below() {
  new_stack k4c; fresh_log
  local lim="$TMP/limits-k4c.conf" out rc
  rm -f "$lim"
  out=$(LCTL_FAUX_ULIMIT=4194304 LCTL_TEST_MEMLOCK=2097152 LCTL_LIMITS="$lim" \
    LCTL_KFD="$TMP/kfd-node" LCTL_DRI="$TMP/dri-node" hf 'preflight' 2>&1); rc=$?
  [ -f "$lim" ] && [ "$rc" = 42 ] \
    && printf '%s' "$out" | grep -q 'Требуется ребут' \
    && ! grep -q 'enable-linger' "$FAUXLOG"
}

# K-4 the «?» branch: an unreadable ulimit → a file + a WARN + exit 42 (conservatively)
scen_k4_unknown() {
  new_stack k4d; fresh_log
  local lim="$TMP/limits-k4d.conf" out rc
  rm -f "$lim"
  out=$(LCTL_FAUX_ULIMIT='?' LCTL_TEST_MEMLOCK=2097152 LCTL_LIMITS="$lim" \
    LCTL_KFD="$TMP/kfd-node" LCTL_DRI="$TMP/dri-node" hf 'preflight' 2>&1); rc=$?
  [ -f "$lim" ] && [ "$rc" = 42 ] \
    && printf '%s' "$out" | grep -q 'ПЕРЕЛОГИНЬСЯ'
}

# K-2 the compose-rerender in use: a spoiled compose.yml on a deployed
#     stack is restored by a re-render at a profile change (§А-4 →
#     cmd_use)
scen_k2_rerender() {
  new_stack k2; fresh_log
  hf 'set_models_dir 27b; write_stack_files; write_env 27b "$(profile_field 27b 1)"' >/dev/null 2>&1 || return 1
  printf 'garbage: not-a-compose\n' > "$LCTL_TEST_STACK/compose.yml"
  local lim="$TMP/limits-k2.conf" out rc
  limits_bytes tester 1318060032 > "$lim"
  out=$(LCTL_LIMITS="$lim" LCTL_KFD="$TMP/kfd-node" LCTL_DRI="$TMP/dri-node" \
    LCTL_FAUX_LINGER=1 LCTL_TEST_PATH="$FAUX_FULL:$PATH" \
    hf 'cmd_start 27b-parallel --force' 2>&1); rc=$?
  grep -qF 'name: hipfire' "$LCTL_TEST_STACK/compose.yml" \
    && grep -qF 'LCTL_PROFILE=27b-parallel' "$LCTL_TEST_STACK/.env" \
    && [ "$rc" = 0 ] && printf '%s' "$out" | grep -q 'SMOKE: OK'
}

# the marker inventory: the names in place, the per-location count right
check_markers() {
  local m
  for m in off-stop orphan-heal lock-reclaim pod-infra containers-conf preflight-pkgs gpu-gate gpu-groups gpu-limits bootstrap-guard uninstall-v2 health-path off-now memlock-gate compose-rerender render-converge no-recreate autostart-heal bench-version bench-gate bench-md5 bench-model bench-report bench-overwrite; do
    grep -rq "# fix:$m" "$ROOT/core" || { echo "маркер # fix:$m отсутствует"; return 1; }
  done
  [ "$(grep -c '# fix:off-stop'    "$ROOT/core/autostart.sh")" = 1 ] || return 1
  [ "$(grep -c '# fix:orphan-heal' "$ROOT/core/autostart.sh")" = 2 ] || return 1
  [ "$(grep -c '# fix:lock-reclaim' "$ROOT/core/autostart.sh")" = 2 ] || return 1
  [ "$(grep -c '# fix:pod-infra'   "$ROOT/core/autostart.sh")" = 2 ] || return 1
  local s=0 f c
  for f in stack.sh stack_files.sh autostart.sh; do
    c=$(grep -c '# fix:containers-conf' "$ROOT/core/$f" 2>/dev/null) || c=0
    s=$((s + c))
  done
  [ "$s" = 1 ] || return 1   # только export в core/stack.sh — копии conf упразднены
  [ "$(grep -c '# fix:preflight-pkgs' "$ROOT/core/stack.sh")" = 2 ] || return 1
  [ "$(grep -c '# fix:gpu-gate'       "$ROOT/core/stack.sh")" = 1 ] || return 1
  [ "$(grep -c '# fix:gpu-groups'     "$ROOT/core/stack.sh")" = 1 ] || return 1
  [ "$(grep -c '# fix:gpu-limits'     "$ROOT/core/stack.sh")" = 1 ] || return 1
  [ "$(grep -c '# fix:bootstrap-guard' "$ROOT/core/commands.sh")" = 2 ] || return 1
  [ "$(grep -c '# fix:uninstall-v2'    "$ROOT/core/commands.sh")" = 1 ] || return 1
  local h=0
  for f in health.sh commands.sh; do
    c=$(grep -c '# fix:health-path' "$ROOT/core/$f" 2>/dev/null) || c=0
    h=$((h + c))
  done
  [ "$h" = 2 ] || return 1   # curl в wait_health + curl в cmd_status
  [ "$(grep -c '# fix:off-now'        "$ROOT/core/autostart.sh")" = 1 ] || return 1
  [ "$(grep -c '# fix:memlock-gate'   "$ROOT/core/stack.sh")" = 7 ] || return 1
  [ "$(grep -c '# fix:compose-rerender' "$ROOT/core/commands.sh")" = 1 ] || return 1
  [ "$(grep -c '# fix:render-converge' "$ROOT/core/stack_files.sh")" = 1 ] || return 1
  [ "$(grep -c '# fix:render-converge' "$ROOT/core/commands.sh")"  = 1 ] || return 1
  [ "$(grep -c '# fix:no-recreate'      "$ROOT/core/commands.sh")" = 2 ] || return 1
  [ "$(grep -c '# fix:bench-version'   "$ROOT/core/bench.sh")" = 1 ] || return 1
  [ "$(grep -c '# fix:bench-gate'      "$ROOT/core/bench.sh")" = 1 ] || return 1
  [ "$(grep -c '# fix:bench-md5'       "$ROOT/core/bench.sh")" = 1 ] || return 1
  [ "$(grep -c '# fix:bench-model'     "$ROOT/core/bench.sh")" = 1 ] || return 1
  [ "$(grep -c '# fix:bench-report'    "$ROOT/core/bench.sh")" = 1 ] || return 1
  [ "$(grep -c '# fix:bench-overwrite' "$ROOT/core/bench.sh")" = 1 ] || return 1
}

# ── the mutation engine ─────────────────────────────────────────────────────
# A tree copy (lctl+core+engines) into $TMP, a sed removal of the lines
# with the marker (or an explicit sed expression for a unit mutant), a
# PER-FILE bash -n of the mutant (mutant_parses — the multi-file bug
# fix), the scenario must FAIL.
tree_sh_list() {  # tree_sh_list <dir> — все скрипты дерева (.sh + диспетчер lctl), NUL-раздельно
  find "$1" -name .git -prune -o -type f \( -name '*.sh' -o -name lctl \) -print0
}
mutant_parses() {  # mutant_parses <dir> — rc 0 = КАЖДЫЙ .sh дерева парсится
  # (the known battery bug: `bash -n a.sh b.sh` validated only the first file)
  local f
  while IFS= read -r -d '' f; do bash -n "$f" 2>/dev/null || return 1; done < <(tree_sh_list "$1")
  return 0
}
mutant_marker() {  # mutant_marker <имя> <маркер> → путь мутанта | '' (маркер не найден)
  local dst="$TMP/mut-$1"
  rm -rf "$dst"; mkdir -p "$dst"
  cp -a "$ROOT/lctl" "$ROOT/core" "$ROOT/engines" "$dst/" || { echo ''; return; }
  grep -rq "# fix:$2" "$dst/core" || { echo ''; return; }
  find "$dst/core" -name '*.sh' -exec sed -i "/# fix:$2/d" {} +
  echo "$dst"
}
mutant_sed() {  # mutant_sed <имя> <файл-от-ROOT> <sed-expr> → путь | '' (нет цели)
  local dst="$TMP/mut-$1" rel="$2"
  rm -rf "$dst"; mkdir -p "$dst"
  cp -a "$ROOT/lctl" "$ROOT/core" "$ROOT/engines" "$dst/" || { echo ''; return; }
  [ -f "$ROOT/$rel" ] || { echo ''; return; }
  sed -i "$3" "$dst/$rel"
  echo "$dst"
}
check_mutation() {  # check_mutation <лейбл> <путь|''> <сценарий…>
  local label="$1" dst="$2"; shift 2
  if [ -z "$dst" ]; then bad "мутация $label: маркер не найден (дрейф маркеров)"; return; fi
  if ! mutant_parses "$dst"; then
    bad "мутация $label: мутант не парсится"; return
  fi
  local prev="${LCTL_TREE:-$ROOT}"; LCTL_TREE="$dst"   # $ROOT эквивалентен unset для hf
  if "$@"; then bad "мутация $label: сценарий прошёл на мутанте — защита не держит"; else ok "мутация $label: сценарий упал — защита держит"; fi
  LCTL_TREE="$prev"
}

# a negative test of the bash -n fix (mandatory, task 1.1 §6): a tree with
# a syntax error in a NON-first file must be caught by the mutant_parses
# guard (the former multi-file call gave rc 0).
scen_bashn_second() {
  local dst="$TMP/syn2" first f
  rm -rf "$dst"; mkdir -p "$dst"
  cp -a "$ROOT/lctl" "$ROOT/core" "$ROOT/engines" "$dst/" || return 1
  printf 'then\n' >> "$dst/engines/hipfire/adapter.sh"   # непарный then — честная синтакс-ошибка
  first=$(find "$dst" -type f \( -name '*.sh' -o -name lctl \) -print | sort | head -1)
  [ "$first" = "$dst/engines/hipfire/adapter.sh" ] && { echo "негатив-тест вырожден: поломанный файл оказался первым"; return 1; }
  mutant_parses "$ROOT" || return 1        # здоровое дерево парсится целиком
  ! mutant_parses "$dst"                   # поломка НЕпервого файла видна гарде
}

# ═════════════════════════════════════════════════════════════════════════════
echo "== 0. AGENTS-четыре: bash -n ПОФАЙЛОВО / py_compile / usage rc=1 / status --json на чанковом порту"
n_sh=0 syn_err=0
while IFS= read -r -d '' f; do
  n_sh=$((n_sh + 1))
  if ! bash -n "$f" 2>"$TMP/syn.err"; then syn_err=1; bad "bash -n $f: $(cat "$TMP/syn.err")"; fi
done < <(tree_sh_list "$ROOT")
[ "$syn_err" = 0 ] && ok "bash -n пофайлово: все скрипты дерева ($n_sh файлов; мультифайл-баг батареи починен)"
py_err=0
while IFS= read -r -d '' f; do
  if ! PYTHONPYCACHEPREFIX="$TMP/pycache" python3 -m py_compile "$f" 2>"$TMP/py.err"; then
    py_err=1; bad "py_compile $f: $(tail -1 "$TMP/py.err")"
  fi
done < <(find "$ROOT"/core "$ROOT"/engines -type f -name '*.py' -print0)
[ "$py_err" = 0 ] && ok "python3 -m py_compile {core,engines}/*/py/*.py (пофайлово, вкл. watch-каркас)"
out=$(bash "$ROOT/lctl" 2>&1); rc=$?
if [ "$rc" = 1 ] && [ -n "$out" ]; then ok "bare-вызов: usage напечатан, rc=1"; else bad "bare-вызов: rc=$rc (нужен 1 + usage)"; fi
out=$(HOME="$TMP/home" LCTL_ENGINE=hipfire LCTL_PORT=1 bash "$ROOT/lctl" status --json 2>&1); rc=$?
if [ -n "$out" ] && ! printf '%s' "$out" | grep -qiE 'traceback|internal error|syntax error'; then
  ok "status --json на чанковом порту: корректный отказ, не краш (rc=$rc)"
else
  bad "status --json на чанковом порту: подозрительный вывод (rc=$rc)"; printf '%s\n' "$out" | tail -3
fi

echo "== 1. инвентарь маркеров # fix:<имя> (защита от дрейфа)"
if check_markers; then ok "23 имени маркеров на месте, счёт по локациям верен (containers-conf: 1 — export в core/stack.sh; health-path: 2 — wait_health+cmd_status; memlock-gate: 7; render-converge: stack_files+commands по 1; no-recreate: commands ×2; bench-шестёрка: по 1 в core/bench.sh)"; else bad "инвентарь маркеров: $(check_markers 2>&1)"; fi

echo "== 2. Ф1 off: явный podman stop основного контейнера"
if scen_f1_fail; then ok "Ф1: compose stop rc 1 → podman stop hipfire_hipfire_1 вызван, off дошёл до «ВЫКЛ» rc 0"; else bad "Ф1 позитив (compose stop fail)"; fi
if scen_f1_happy; then ok "Ф1: happy compose stop rc 0 → podman stop тоже вызван (безвреден)"; else bad "Ф1 позитив (happy)"; fi

echo "== 3. Ф2 storage-сирота: самолечение + retry up"
if scen_f2_locked; then ok "Ф2: hf_up_locked — сирота удалена (delete-container ID), ровно 2 up, rc 0"; else bad "Ф2 позитив (hf_up_locked)"; fi
if scen_f2_devsafe; then ok "Ф2: hf_up_devsafe — сирота удалена, ровно 2 up, rc 0"; else bad "Ф2 позитив (hf_up_devsafe)"; fi
if scen_up_happy; then ok "Ф2: happy up без аномалий — ровно 1 up, rc 0, хил не звался"; else bad "Ф2 позитив (happy up)"; fi
if scen_f2_cap; then ok "Ф2: кап HEAL_MAX=1 — второй хил НЕ случился (1 delete, 2 up, rc≠0)"; else bad "Ф2 кап"; fi
if scen_f2_nobin; then ok "Ф2: containers-storage нет — WARN с ручной командой, delete НЕ вызван"; else bad "Ф2 Variant B (нет бинаря)"; fi
if scen_f2_guard; then ok "Ф2: ID видит libpod — «не сирота», delete НЕ вызван"; else bad "Ф2 guard (libpod видит ID)"; fi

echo "== 4. Ф3 lock: реклейм зависших держателей (настоящие flock/fuser/ps)"
if scen_f3_stale; then ok "Ф3: stale-holder убит (kill -9), up прошёл, «пропуска» нет"; else bad "Ф3 позитив (stale)"; fi
if scen_f3_fresh; then ok "Ф3: fresh-holder не тронут — «up уже выполняется — пропуск», up не звался"; else bad "Ф3 позитив (fresh)"; fi
if scen_f3_nofuser; then ok "Ф3: нет fuser в PATH — тихая деградация к прежнему skip"; else bad "Ф3 позитив (нет fuser)"; fi

echo "== 5. Ф4 pod: пустой INFRA ID → пересоздание до up"
if scen_f4_empty; then ok "Ф4: pod rm -f pod_hipfire ДО compose up, up прошёл rc 0"; else bad "Ф4 позитив (пустой INFRA)"; fi
if scen_f4_full; then ok "Ф4: INFRA ID непуст — rm нет, up прошёл"; else bad "Ф4 позитив (здоровый pod)"; fi
if scen_f4_absent; then ok "Ф4: pod нет (inspect rc 1) — no-op, up прошёл"; else bad "Ф4 позитив (pod отсутствует)"; fi

echo "== 6. Ф5 CONTAINERS_CONF: доставка + env-контракт compose()"
if scen_f5_deliver; then ok "Ф5: cmd_autostart отрендерил юниты с Environment на core/tpl-conf и LCTL_ENGINE"; else bad "Ф5 позитив (cmd_autostart)"; fi
if scen_f5_env; then ok "Ф5: compose() — env выставлен при файле, UNSET при отсутствии"; else bad "Ф5 позитив (env-контракт)"; fi

echo "== 7. preflight: apt-пятёрка + GPU-подготовка (гейт/группы/limits.d)"
if scen_p_a; then ok "P-A: pkgs-missing — apt-пятёрка одним списком (5 имён), update перед install, rc 0"; else bad "P-A позитив (apt-пятёрка)"; fi
if scen_p_b; then ok "P-B: pkgs-present — apt-get в журнале 0 раз, rc 0"; else bad "P-B позитив (всё на месте — apt не звался)"; fi
if scen_p_c; then ok "P-C: не-GPU — info-пропуск + die, ноль мутаций"; else bad "P-C позитив (гейт)"; fi
if scen_p_d; then ok "P-D: группы свежие — usermod render,video, «после перезахода», rc 42"; else bad "P-D позитив (группы)"; fi
if scen_p_e; then ok "P-E: limits-файла нет — создан, байты == рендер, rc 0, linger вызван"; else bad "P-E позитив (запись limits)"; fi
if scen_p_f; then ok "P-F: limits idempotent — равен → install 0 раз; чужой → переписан"; else bad "P-F позитив (cmp-idempotence)"; fi
if scen_p_g; then ok "P-G: низкий memlock сессии (настоящий ulimit) — rc 42, warn «ребут», файл записан"; else bad "P-G позитив (низкий ulimit)"; fi
if scen_p_h; then ok "P-H: полный no-op — rc 0, в журнале нет apt/usermod/install/linger"; else bad "P-H позитив (happy no-op)"; fi

echo "== 8. мутации: вырезание по маркерам на КОПИИ дерева → сценарий падает (bash -n мутанта ПОФАЙЛОВО)"
check_mutation "off-stop" "$(mutant_marker off-stop off-stop)" scen_f1_fail
d=$(mutant_marker orphan-heal orphan-heal)
if [ -n "$d" ]; then
  check_mutation "orphan-heal" "$d" scen_f2_locked
  check_mutation "orphan-heal(devsafe)" "$d" scen_f2_devsafe
else
  bad "мутация orphan-heal: маркер не найден (дрейф маркеров)"
fi
check_mutation "lock-reclaim" "$(mutant_marker lock-reclaim lock-reclaim)" scen_f3_stale
check_mutation "pod-infra" "$(mutant_marker pod-infra pod-infra)" scen_f4_empty
check_mutation "containers-conf" "$(mutant_marker containers-conf containers-conf)" scen_f5_env
if grep -q 'Environment=CONTAINERS_CONF' "$ROOT/core/tpl/systemd/lctl-compose.service.tpl"; then
  check_mutation "containers-conf-unit" "$(mutant_sed containers-conf-unit core/tpl/systemd/lctl-compose.service.tpl '/Environment=CONTAINERS_CONF/d')" scen_f5_deliver
else
  bad "мутация containers-conf-unit: Environment-строки нет в tpl (дрейф)"
fi
check_mutation "preflight-pkgs" "$(mutant_marker preflight-pkgs preflight-pkgs)" scen_p_a
check_mutation "gpu-gate" "$(mutant_marker gpu-gate gpu-gate)" scen_p_c
check_mutation "gpu-groups" "$(mutant_marker gpu-groups gpu-groups)" scen_p_d
check_mutation "gpu-limits" "$(mutant_marker gpu-limits gpu-limits)" scen_p_e
check_mutation "health-path" "$(mutant_marker health-path health-path)" scen_k1_health_default
check_mutation "off-now" "$(mutant_marker off-now off-now)" scen_k3_off_now
check_mutation "memlock-gate" "$(mutant_marker memlock-gate memlock-gate)" scen_k4_below
check_mutation "compose-rerender" "$(mutant_marker compose-rerender compose-rerender)" scen_k2_rerender
check_mutation "render-converge" "$(mutant_marker render-converge render-converge)" scen_s2a_render_converge
check_mutation "no-recreate"     "$(mutant_marker no-recreate no-recreate)"     scen_s2b_no_recreate
check_mutation "autostart-heal"  "$(mutant_marker autostart-heal autostart-heal)" scen_s2_autostart_heal
check_mutation "in-pod" "$(mutant_sed in-pod engines/gufo/adapter.sh '/# fix:in-pod/d')" scen_g19_inpod
# the W2 mutation: a cut of the hipfire panel's health-parser json.loads
#     (the marker in a py — the marker Inventory does not count it: it is
#     over core/) → the panel's selfcheck fails
if grep -q '# fix:w2-health-parse' "$ROOT/engines/hipfire/py/watch_tui.py"; then
  check_mutation "w2-health-parse" "$(mutant_sed w2-health-parse engines/hipfire/py/watch_tui.py '/# fix:w2-health-parse/d')" scen_w2_panel
else
  bad "мутация w2-health-parse: маркера нет в watch_tui.py (дрейф)"
fi
# the W3 mutation: a cut of the REAL ` | ` load-summary format regexps
#     (the «Роут: нет данных» defect) → the summary pins of the
#     selfcheck/scenario fail
if grep -q '# fix:w3-summary-parse' "$ROOT/engines/hipfire/py/watch_tui.py"; then
  check_mutation "w3-summary-parse" "$(mutant_sed w3-summary-parse engines/hipfire/py/watch_tui.py '/# fix:w3-summary-parse/d')" scen_w2_panel
else
  bad "мутация w3-summary-parse: маркера нет в watch_tui.py (дрейф)"
fi
# the W3.2 mutations (the §5 layout): a cut of the draft_positions
#     aggregate (принято %) — the aggregate's selfcheck pins fail; a cut
#     of uptime_from_log (the gufo uptime from the first -t stamp) — the
#     uptime/средн pins of the selfcheck fail
if grep -q '# fix:w32-draft-agg' "$ROOT/engines/hipfire/py/watch_tui.py"; then
  check_mutation "w32-draft-agg" "$(mutant_sed w32-draft-agg engines/hipfire/py/watch_tui.py '/# fix:w32-draft-agg/d')" scen_w2_panel
else
  bad "мутация w32-draft-agg: маркера нет в watch_tui.py (дрейф)"
fi
# the A mutation: a cut of the canon_catalog call (the canon-ID not
#     written into the hipfire local catalog's models.toml) → the catalog
#     pins in A-apply_profile fail
if grep -q '# fix:canon-alias' "$ROOT/engines/hipfire/engine.sh"; then
  check_mutation "canon-alias" "$(mutant_sed canon-alias engines/hipfire/engine.sh '/# fix:canon-alias/d')" scen_a_apply_profile
else
  bad "мутация canon-alias: маркера нет в engine.sh (дрейф)"
fi
if grep -q '# fix:w42-smoke-core' "$ROOT/core/commands.sh"; then
  check_mutation "w42-smoke-core" "$(mutant_marker w42-smoke-core w42-smoke-core)" scen_a_smoke
else
  bad "мутация w42-smoke-core: маркера нет в core/commands.sh (дрейф)"
fi
if grep -q '# fix:w43-smoke-vision' "$ROOT/core/commands.sh"; then
  check_mutation "w43-smoke-vision" "$(mutant_marker w43-smoke-vision w43-smoke-vision)" scen_a_smoke_novision
else
  bad "мутация w43-smoke-vision: маркера нет в core/commands.sh (дрейф)"
fi
# the W mutation: a cut of the lanes override (compose_scheme ignores
#     summary.lanes — «1 ×» instead of the real fn-lanes parallelism) →
#     the selfcheck lanes case fails
if grep -q '# fix:w40-lanes' "$ROOT/engines/hipfire/py/watch_tui.py"; then
  check_mutation "w40-lanes" "$(mutant_sed w40-lanes engines/hipfire/py/watch_tui.py '/# fix:w40-lanes/d')" scen_w2_panel
else
  bad "мутация w40-lanes: маркера нет в watch_tui.py (дрейф)"
fi
if grep -q '# fix:w32-uptime' "$ROOT/engines/gufo/py/watch_engine.py"; then
  check_mutation "w32-uptime" "$(mutant_sed w32-uptime engines/gufo/py/watch_engine.py '/# fix:w32-uptime/d')" scen_w1_selfcheck
else
  bad "мутация w32-uptime: маркера нет в watch_engine.py (дрейф)"
fi
# the W3.2.1 mutation (p.5): a cut of the cache budgets' env seam (the
#     cache_dir from LCTL_WATCH_HIPFIRE_CACHE_DIR) → collect dead → the
#     env-stub scenario «12 GiB (бюджет) / used-скан» fails
if grep -q '# fix:w321-cache-env' "$ROOT/engines/hipfire/py/watch_tui.py"; then
  check_mutation "w321-cache-env" "$(mutant_sed w321-cache-env engines/hipfire/py/watch_tui.py '/# fix:w321-cache-env/d')" scen_w2_cache_env
else
  bad "мутация w321-cache-env: маркера нет в watch_tui.py (дрейф)"
fi
# the W3.3 mutations (the methodologies revision, dashboard-layout §5 v2):
#     SessionBase (the active window's base not pinned → all the session
#     rows «—»), hold (the W3.2.2/3/4 consolidation: a cut of the hold
#     patches → a quiet tick melts), done (ген-посл not parsed from the
#     log), slot-branch (the multi_slot «—» removed), gufo-window (the
#     session ratio-of-sums cut), the K_LAT pairs (the hipfire ген-средн
#     degrades — a NameError, the protection is not silent)
if grep -q '# fix:w33-session-base' "$ROOT/core/py/watch/watch_frame.py"; then
  check_mutation "w33-session-base" "$(mutant_sed w33-session-base core/py/watch/watch_frame.py '/# fix:w33-session-base/d')" scen_w2_panel
else
  bad "мутация w33-session-base: маркера нет в watch_frame.py (дрейф)"
fi
if grep -q '# fix:w33-hold' "$ROOT/engines/gufo/py/watch.py"; then
  check_mutation "w33-hold-gufo" "$(mutant_sed w33-hold-gufo engines/gufo/py/watch.py '/# fix:w33-hold/d')" scen_w1_selfcheck
else
  bad "мутация w33-hold-gufo: маркера нет в watch.py (дрейф)"
fi
if grep -q '# fix:w33-hold' "$ROOT/engines/hipfire/py/watch_tui.py"; then
  check_mutation "w33-hold-hipfire" "$(mutant_sed w33-hold-hipfire engines/hipfire/py/watch_tui.py '/# fix:w33-hold/d')" scen_w2_panel
else
  bad "мутация w33-hold-hipfire: маркера нет в watch_tui.py (дрейф)"
fi
if grep -q '# fix:w33-done-parse' "$ROOT/engines/hipfire/py/watch_tui.py"; then
  check_mutation "w33-done-parse" "$(mutant_sed w33-done-parse engines/hipfire/py/watch_tui.py '/# fix:w33-done-parse/d')" scen_w2_panel
else
  bad "мутация w33-done-parse: маркера нет в watch_tui.py (дрейф)"
fi
if grep -q '# fix:w33-slot-branch' "$ROOT/engines/hipfire/py/watch_tui.py"; then
  check_mutation "w33-slot-branch" "$(mutant_sed w33-slot-branch engines/hipfire/py/watch_tui.py '/# fix:w33-slot-branch/d')" scen_w2_panel
else
  bad "мутация w33-slot-branch: маркера нет в watch_tui.py (дрейф)"
fi
if grep -q '# fix:w33-gufo-window' "$ROOT/engines/gufo/py/watch_engine.py"; then
  check_mutation "w33-gufo-window" "$(mutant_sed w33-gufo-window engines/gufo/py/watch_engine.py '/# fix:w33-gufo-window/d')" scen_w1_selfcheck
else
  bad "мутация w33-gufo-window: маркера нет в watch_engine.py (дрейф)"
fi
if grep -q '# fix:w33-lat-keys' "$ROOT/engines/hipfire/py/watch_tui.py"; then
  check_mutation "w33-lat-keys" "$(mutant_sed w33-lat-keys engines/hipfire/py/watch_tui.py '/# fix:w33-lat-keys/d')" scen_w2_panel
else
  bad "мутация w33-lat-keys: маркера нет в watch_tui.py (дрейф)"
fi

echo "== 9. лейаут .data/<engine>/ + §А-автомат start/stop: N1–N7, e2e-диспетчер, switch, порт-конфликт, env-model"
if scen_n1_bootstrap; then ok "N1: bootstrap первого start — конвейер, юниты ПОСЛЕ smoke/check_route (Р1), маркер снят, .env LCTL_*/.data-пути/юниты/симлинк/статус-строка"; else bad "N1 bootstrap-happy"; fi
if scen_n2_idempotent; then ok "N2: повторный start на развёрнутом стеке — без конвейера (нет apt/usermod/sudo-install и podman run), юниты+up"; else bad "N2 bootstrap-idempotent"; fi
if scen_n3_guard; then ok "N3: guard cmd_start на развёрнутом стеке — --port/--bind и --no-autostart → die с подсказкой, ноль действий"; else bad "N3 start-мутаторы-guard"; fi
if scen_n4_prepopulated; then ok "N4: bootstrap с готовым .data/hipfire/models (мигра-механика) — maунт .data, файлы целы, pull образа пропущен"; else bad "N4 готовые модели"; fi
if scen_n5_uninstall; then ok "N5: uninstall v2 — юниты/linger/limits/down сняты; клон и .data/hipfire целы; без purge — rmi и rm моделей нет"; else bad "N5 uninstall-v2"; fi
if scen_n6_purge; then ok "N6: uninstall --purge-models --purge-image — .data/hipfire/models удалена, profiles целы, rmi вызван"; else bad "N6 purge-флаги"; fi
if scen_n7_layout_statics; then ok "N7: статика лейаута (.gitignore/.data-глобалы engine_load/lock в .data/tpl-conf/watchdog в logs/без sync_tree) + запуск из подкаталога клона"; else bad "N7 статика+подкаталог"; fi
if scen_n10_e2e_dispatcher; then ok "N10: faux end-to-end через реальный диспетчер — start hipfire 27b: позиционные аргументы, конвейер, юниты последними, .env канон"; else bad "N10 e2e-диспетчер"; fi
if scen_n11_switch; then ok "N11: §А-1 switch — start при активном другом = честный off stub (его контейнер) ДО первого up, канон переписан на hipfire"; else bad "N11 switch"; fi
if scen_n12_port_conflict; then ok "N12: чужой слушатель на порту → bootstrap-фаза start die с подсказкой до первого up; свободный порт — конвейер идёт"; else bad "N12 порт-конфликт"; fi
if scen_n13_env_model; then ok "N13: env-model (fix:env-model) — write_env hipfire flash: HIPFIRE_MODEL в .env == LCTL_MODEL == реестровая модель профиля (не дефолт compose)"; else bad "N13 env-model"; fi

echo "== 10. мутации лейаута + негатив-тест починки bash -n"
check_mutation "bootstrap-guard" "$(mutant_marker bootstrap-guard bootstrap-guard)" scen_n3_guard
check_mutation "uninstall-v2" "$(mutant_marker uninstall-v2 uninstall-v2)" scen_n6_purge
check_mutation "uninstall-v1-clone-rm" "$(mutant_sed uninstall-rm core/commands.sh 's/^  cmd_off || true$/&\n  rm -rf "${STACK_DIR:?}"/')" scen_n5_uninstall
if grep -q '^HIPFIRE_MODEL=' "$ROOT/engines/hipfire/tpl/env/env.tpl"; then
  check_mutation "env-model" "$(mutant_sed env-model engines/hipfire/tpl/env/env.tpl '/^HIPFIRE_MODEL=/d')" scen_n13_env_model
else
  bad "мутация env-model: HIPFIRE_MODEL-строки нет в env.tpl (дрейф)"
fi
if scen_bashn_second; then ok "негатив bash -n: поломка ВТОРОГО файла ловится гарде mutant_parses (легаси пропускал, rc 0)"; else bad "негатив bash -n (синтакс-ошибка не в первом файле)"; fi

echo "== 11. 1.2 автомат §А: use-поглощение / no-op / stop / pull / verb-алиасы"
if scen_s1_use_absorbed; then ok "S1: start с другим профилем = §А-4 use-поглощение — канон переписан, cfgset, recreate, юниты последними, статус-строка"; else bad "S1 use-поглощение"; fi
if scen_s2_start_noop; then ok "S2: start no-op — канон==profile, running, рендер совпадает → «уже запущено — рендер совпадает», ноль compose/systemctl, файлы md5-идентичны до/после"; else bad "S2 start no-op"; fi
if scen_s2_autostart_heal; then ok "S2-heal: autostart-heal — running + STOP_MARKER (ручной старт после stop) → cmd_start доделывает автозапуск (systemctl enable в журнале, «автозапуск ВКЛ») и отвечает «уже запущено», без up"; else bad "S2-heal autostart-heal"; fi
if scen_s2a_render_converge; then ok "S2a: конвергенция рендера (этап 8) — running + дифф (.env/compose.local.yml) → WARN «рендер изменился», файлы == свежему рендеру (cmp с независимым буфером), apply_profile + force-recreate (ровно 1, обычного up нет), HEALTHY, юниты последними, «активно:»"; else bad "S2a render-converge"; fi
if scen_s2b_no_recreate; then ok "S2b: --no-recreate — запись канонических байтов выполнена, recreate НЕ вызван (0 up, 0 cfgset, 0 юнитов), WARN с «stop && start» и честной причиной (env-дрифт), повторный start без флага → «рендер совпадает» (зазор флага), флаг на развёрнутом стеке НЕ die"; else bad "S2b no-recreate"; fi
if scen_s2c_cold_diff; then ok "S2c: холодный + дифф — WARN «стек поднимется с новым рендером», .env переписан (мусор исчез), ровно 1 обычный up (без force-recreate), HEALTHY"; else bad "S2c cold-diff"; fi
if scen_s3_stop_empty; then ok "S3: stop на пустой машине — «не запущено», rc 0, ноль действий"; else bad "S3 stop пустая"; fi
if scen_s4_stop_active; then ok "S4: stop активного — честный off его адаптером (podman stop + linger off + юниты)"; else bad "S4 stop активного"; fi
if scen_s5_pull_prefetch; then ok "S5: pull prefetch — сет на месте БЕЗ .env/юнитов/старта (ups 0)"; else bad "S5 pull prefetch"; fi
if scen_s5b_pull_dispatcher; then ok "S5b: pull через диспетчер — позиционные <engine> <profile>, prefetch без .env/юнитов (регрессия раунда 2)"; else bad "S5b pull-диспетчер"; fi
if scen_s6_verb_aliases; then ok "S6: verb-алиасы переходного периода — on/install|use|switch → cmd_start, off --engine → engine_off_foreign, stop → cmd_stop"; else bad "S6 verb-алиасы"; fi
if scen_s7_own_canon_survives; then ok "S7: чужие юниты при своём каноне — off чужого по юнитам; кастомный порт/bind задан легитимно (PORT/BIND-глобалы → write_env) и переживает start как канонический рендер БЕЗ ложного recreate (нет WARN), ensure §А-3: 1 up, «активно:» с 0.0.9:11444 (этап 8)"; else bad "S7 свой канон переживает старт"; fi

echo "== 12. K-волна (task 3.1 §2): health-path / off-now / memlock-gate / compose-rerender"
if scen_k1_health_default; then ok "K-1: wait_health hipfire curls ДЕФОЛТНЫЙ /health (HEALTH_PATH-зеркало; gufo-оверрайд — адаптерный тест)"; else bad "K-1 health-путь дефолт"; fi
if scen_k3_off_now; then ok "K-3: cmd_off → systemctl --user disable --now (юнит+таймер гаснут немедленно, mirror 95bf4e4)"; else bad "K-3 off-now"; fi
if scen_k4_enough; then ok "K-4: memlock ровно на пороге 8388608 → файл + WARN «достаточно», rc 0, linger достигнут"; else bad "K-4 достаточно"; fi
if scen_k4_unlimited; then ok "K-4: memlock unlimited → PASS без WARN, rc 0"; else bad "K-4 unlimited"; fi
if scen_k4_below; then ok "K-4: сессия ниже порога (4194304 < 8388608; старый гейт сравнивал с MEMLOCK и пропустил бы) → файл + WARN «ребут» + rc 42"; else bad "K-4 ниже порога"; fi
if scen_k4_unknown; then ok "K-4: memlock нечитаем («?») → файл + WARN «ПЕРЕЛОГИНЬСЯ» + rc 42"; else bad "K-4 нечитаемый"; fi
if scen_k2_rerender; then ok "K-2: use — испорченный compose.yml восстановлен перерендером engine_write_compose до compose up"; else bad "K-2 compose-rerender"; fi

# ── 2.2 the render_tpl die cosmetics (sub-stage 2.2): an unexpanded
#     placeholder → die prints the TEMPLATE PATH (after the shift 2 the
#     positional $1 is the first KV pair, the path saved into tpl_path
#     before the shift). One ok: the positive + the «tpl_path= cut (die
#     back onto $1)» mutation inside — the 2.2 contract: the counter
#     133→134.
scen_render_die_tplpath() {
  local out rc dst prev="${LCTL_TREE:-$ROOT}"
  new_stack die22
  printf 'канон: __RENDER_DIE__ хвост\n' > "$LCTL_TEST_STACK/broken.tpl"
  out=$(hf 'render_tpl "$STACK_DIR/broken.tpl" "$STACK_DIR/out.yml" MODELS_DIR=models STATE_DIR=prof' 2>&1); rc=$?
  [ "$rc" != 0 ] || return 1                                  # die → процесс вышел
  printf '%s' "$out" | grep -q 'нераскрытые плейсхолдеры' || return 1
  printf '%s' "$out" | grep -q 'broken\.tpl' || return 1      # имя файла шаблона в сообщении
  ! printf '%s' "$out" | grep -qE '[A-Z0-9_]+=' || return 1   # KV-пара после shift не протекла
  # the mutation: a cut of tpl_path="$1" + die back onto $1 (the old bug)
#     → the message must degrade to the KV pair → the scenario on the
#     mutant must fail
  dst=$(mutant_sed tpl-path core/stack_files.sh 's/tpl_path="\$1"; //; s/в шаблоне \$tpl_path/в шаблоне $1/')
  [ -n "$dst" ] || return 1
  mutant_parses "$dst" || return 1
  LCTL_TREE="$dst"
  out=$(hf 'render_tpl "$STACK_DIR/broken.tpl" "$STACK_DIR/out.yml" MODELS_DIR=models STATE_DIR=prof' 2>&1); rc=$?
  LCTL_TREE="$prev"
  [ "$rc" != 0 ] || return 1
  printf '%s' "$out" | grep -qE 'MODELS_DIR=models' || return 1   # старый баг воспроизведён мутантом
}

echo "== 12a. 2.2 die-косметика render_tpl: путь шаблона в die (позитив + мутация — один ok, счётчик 133→134)"
if scen_render_die_tplpath; then ok "2.2: die при нераскрытом __KEY__ печатает broken.tpl (не KV-пару); мутация «вырез tpl_path=» — сценарий упал"; else bad "2.2 die-путь шаблона"; fi

echo "== 13. W0 watch-каркас (ядро): cmd_watch-гварды + selfcheck каркаса + R6-статика"
if scen_w0_cmd_watch; then ok "W0: cmd_watch — кривой --interval/аргумент → die; exec-ветка W2 (TICKS=1 — один тик): faux /health+/stats+/metrics на :11435 → [движок] plain rc 0; env-шов LCTL_WATCH_ENGINE (grep ядра + Watch.engine=engine-x); длинная лог-строка не роняет plain; роутер+гвардия на месте"; else bad "W0 cmd_watch-гварды"; fi
if scen_w0_selfcheck; then ok "W0: selfcheck каркаса 94/94 — глифы/цвета/«—»-инвариант (все fmt*, вкл. fmt_uptime/fmt_int_sep/fmt_pct «58.0 %»), status-bar с именем движка, log_clip + log_lines_fit (D3), D5-константы (отступ 1 перед буллетом), dir_size_bytes, схема v2 «Движок» (плоские ряды §1) + «Метрики» (7 рядов §1), железо (CPU первой)/скорость (title «Скорость»), wire-примитивы (parse_metrics/Deltas/sparkline/TZ + podman-RFC3339), LogStreamer с -t, шапка «engine · ip:порт · model» addr-сегментом (W3.2.2, primary_ip + LCTL_WATCH_IP-шов)"; else bad "W0 selfcheck каркаса"; fi
if scen_w0_r6_watch; then ok "W0: R6-статика W3 — grep gufo|hipfire по core/py/watch/ пуст (граница каркас↔адаптер)"; else bad "W0 R6-статика каркаса"; fi
if scen_core_r6_static; then ok "Core-R6: grep gufo|hipfire|halogen по lctl + core/*.sh + smoke_resp/systemd/containers.tpl пуст (имена движков — только engines/<имя>/)"; else bad "Core-R6 статика ядра"; fi

# ── the B wave (task 7.1): bench — the router/gates/e2e+rewrite/md5 gate/deadline/ ─
#    the golden snapshot/R6 hygiene. The faux server — $FAUX_BENCH (a curl
#    with usage+timings, the POST bodies → $LCTL_FAUX_BENCH_BODY); the
#    stack — write_env 27b (the LCTL_* canon); the report under the fake
#    stack $LCTL_TEST_STACK/bench/reports/.

# B the router: the usage line/case list/arm/source in place; on a clean
#     clone the real dispatcher → rc!=0 with a clear «движок не определён
#     … lctl start»
scen_b_router_usage() {
  sed -n '/^# === USAGE-BEGIN ===$/,/^# === USAGE-END ===$/p' "$ROOT/lctl" | grep -q 'bench' || return 1
  grep -qF '|watch|bench) ;;' "$ROOT/lctl" || return 1
  grep -qE 'bench\)\s+cmd_bench "\$@" ;;' "$ROOT/lctl" || return 1
  grep -qF 'source "$CORE_DIR/bench.sh"' "$ROOT/lctl" || return 1
  new_stack b0r; rm -rf "$TMP/home"; mkdir -p "$TMP/home"
  local out rc
  out=$(env PATH="$FAUX_FULL:$PATH" HOME="$TMP/home" USER=tester \
    LCTL_DIR="$LCTL_TEST_STACK" \
    LCTL_FAUX_LOG="$FAUXLOG" LCTL_FAUX_CNT="$FAUXCNT" LCTL_FAUX_ORPHAN_ID="$ORPHAN_ID" LCTL_FAUX_TMP="$TMP" \
    bash "$ROOT/lctl" bench 2>&1); rc=$?
  [ "$rc" != 0 ] && printf '%s' "$out" | grep -q 'движок не определён'
}

# B the flags: --runs (a non-number/0/21), --parallel (9/a non-number),
#     an unknown flag → a die with a clear text; --help → rc 0 + usage
scen_b_flags() {
  new_stack b0f
  hf 'set_models_dir 27b; write_stack_files; write_env 27b "$(profile_field 27b 1)"' >/dev/null 2>&1 || return 1
  local out rc
  out=$(hf 'cmd_bench --runs abc' 2>&1); rc=$?
  [ "$rc" != 0 ] && printf '%s' "$out" | grep -q 'целое 1–20' || return 1
  out=$(hf 'cmd_bench --runs 0' 2>&1); rc=$?
  [ "$rc" != 0 ] && printf '%s' "$out" | grep -q 'целое 1–20' || return 1
  out=$(hf 'cmd_bench --runs 21' 2>&1); rc=$?
  [ "$rc" != 0 ] && printf '%s' "$out" | grep -q 'целое 1–20' || return 1
  out=$(hf 'cmd_bench --parallel 9' 2>&1); rc=$?
  [ "$rc" != 0 ] && printf '%s' "$out" | grep -q 'целые 1..8' || return 1
  out=$(hf 'cmd_bench --parallel 2,x' 2>&1); rc=$?
  [ "$rc" != 0 ] && printf '%s' "$out" | grep -q 'целые 1..8' || return 1
  out=$(hf 'cmd_bench --wat' 2>&1); rc=$?
  [ "$rc" != 0 ] && printf '%s' "$out" | grep -q 'неизвестный флаг bench' || return 1
  out=$(hf 'cmd_bench --help' 2>&1); rc=$?
  [ "$rc" = 0 ] && printf '%s' "$out" | grep -q 'использование: lctl bench' || return 1
  return 0
}

# B the gates: no .env → die «стек не установлен»; a health failure (a
#     curl rc 7) → die «стек не поднят» and ZERO generation requests;
#     loading_model → die «модель ещё грузится» (a gate WITHOUT waiting —
#     lctl start/up's business)
scen_b_gate_noenv() {
  new_stack b1noenv
  local out rc
  out=$(LCTL_TEST_PATH="$FAUX_BENCH:$PATH" hf 'cmd_bench --runs 1' 2>&1); rc=$?
  [ "$rc" != 0 ] && printf '%s' "$out" | grep -q "стек не установлен — сначала 'lctl start'"
}

scen_b_gate_dead() {
  new_stack b1dead; fresh_log
  hf 'set_models_dir 27b; write_stack_files; write_env 27b "$(profile_field 27b 1)"' >/dev/null 2>&1 || return 1
  local out rc
  out=$(LCTL_FAUX_BENCH_HEALTHFAIL=1 LCTL_TEST_PATH="$FAUX_BENCH:$PATH" hf 'cmd_bench --runs 1' 2>&1); rc=$?
  [ "$rc" != 0 ] && printf '%s' "$out" | grep -q 'стек не поднят' || return 1
  ! grep -q 'chat/completions' "$FAUXLOG"   # ноль запросов генерации — bench не начался
}

scen_b_gate_loading() {
  new_stack b1load
  hf 'set_models_dir 27b; write_stack_files; write_env 27b "$(profile_field 27b 1)"' >/dev/null 2>&1 || return 1
  printf '{"status":"ok","model":"qwen3.8:27b-mq4-xts","loading_model":"draft"}' > "$TMP/bench-loading.json"
  local out rc
  out=$(LCTL_FAUX_BENCH_HEALTHFILE="$TMP/bench-loading.json" LCTL_TEST_PATH="$FAUX_BENCH:$PATH" \
    hf 'cmd_bench --runs 1' 2>&1); rc=$?
  [ "$rc" != 0 ] && printf '%s' "$out" | grep -q 'модель ещё грузится'
}

# B the e2e+rewrite (a FILE-based assert): a healthy faux → the report
#     written to bench/reports/hipfire-0.4.8-27b.md, the header (the
#     date/engine/version/profile/model/md5/parameters), all the sections,
#     the И-hygiene (no host), the requests' model = the canon; a repeated
#     run — a REWRITE (one header, no timestamp copies)
scen_b_e2e_overwrite() {
  new_stack b2e2e
  hf 'set_models_dir 27b; write_stack_files; write_env 27b "$(profile_field 27b 1)"' >/dev/null 2>&1 || return 1
  : > "$TMP/bench-body.log"
  local out rc report="$LCTL_TEST_STACK/bench/reports/hipfire-0.4.8-27b.md"
  out=$(LCTL_FAUX_BENCH_BODY="$TMP/bench-body.log" LCTL_TEST_PATH="$FAUX_BENCH:$PATH" \
    hf 'cmd_bench --runs 1' 2>&1); rc=$?
  [ "$rc" = 0 ] || return 1
  [ -f "$report" ] || return 1
  printf '%s' "$out" | grep -q 'отчёт: ' || return 1
  printf '%s' "$out" | grep -q 'кратко: ' || return 1
  grep -q '^# bench hipfire 0.4.8 — профиль 27b$' "$report" || return 1
  grep -q 'движок: hipfire (версия 0.4.8)' "$report" || return 1
  grep -q 'профиль: 27b | модель: qwen3.8:27b-mq4-xts' "$report" || return 1
  grep -q 'md5 253c7ac50857fe6d0e10fb0d2c5e35c0' "$report" || return 1
  grep -q 'параметры: runs=1, parallel=2,4' "$report" || return 1
  grep -q '^## 1. Соло-декод' "$report" || return 1
  grep -q '^## 2. Короткий проза-запрос' "$report" || return 1
  grep -q '^## 3. Агентская сессия' "$report" || return 1
  grep -q '^## 4. Параллельная нагрузка' "$report" || return 1
  grep -qE '^\| 2 \| [0-9]' "$report" || return 1   # parallel-2 отмерял: строка батча с числами
  grep -qE '^\| 4 \| [0-9]' "$report" || return 1   # parallel-4 отмерял
  ! grep -q 'не выполнен' "$report" || return 1      # полный прогон: ВСЕ секции с данными (поймает молчаливый пропуск сценария — T1-класс)
  ! grep -q 'bench_run:' <<<"$out" || return 1       # раннер не ругался на кривые argv (rc 2 без set -e в условном контексте — T1)
  grep -q '^## Движковые метрики (адаптер)' "$report" || return 1
  ! grep -qE '192\.168\.|hostname|HOSTNAME' "$report" || return 1
  grep -q 'qwen3.8:27b-mq4-xts' "$TMP/bench-body.log" || return 1
  out=$(LCTL_FAUX_BENCH_BODY="$TMP/bench-body.log" LCTL_TEST_PATH="$FAUX_BENCH:$PATH" \
    hf 'cmd_bench --runs 1' 2>&1); rc=$?
  [ "$rc" = 0 ] || return 1
  [ "$(grep -c '^# bench ' "$report")" = 1 ] || return 1
  [ "$(grep -c '^- дата: ' "$report")" = 1 ] || return 1
  [ "$(ls -1 "$LCTL_TEST_STACK/bench/reports" | wc -l)" = 2 ] || return 1   # .md + .json-снапшот
  [ -f "${report%.md}.json" ] || return 1
  printf '%s' "$out" | grep -q 'матрица: ' || return 1
  grep -q '^# bench matrix' "$LCTL_TEST_STACK/bench/MATRIX.md" || return 1
  grep -q '^| hipfire 0.4.8 ' "$LCTL_TEST_STACK/bench/MATRIX.md" || return 1   # комбинация в матрице
  [ "$(grep -c '^# bench matrix' "$LCTL_TEST_STACK/bench/MATRIX.md")" = 1 ] || return 1
  return 0
}

# B the md5 gate: a byte edit of a fixture IN A TREE COPY → a WARN (not a
#     die), the run reaches the report, the comparability marked. The
#     copy — OF THE TREE UNDER TEST (LCTL_TREE: the battery substitutes
#     the mutant — check_mutation)
scen_b_md5_warn() {
  local src="${LCTL_TREE:-$ROOT}" tree="$TMP/bench-md5-tree"
  rm -rf "$tree"; mkdir -p "$tree"
  cp -a "$src/lctl" "$src/core" "$src/engines" "$tree/" || return 1
  printf 'X' | dd of="$tree/core/tpl/bench/merge_sort_thinking_off.txt" bs=1 seek=20 conv=notrunc 2>/dev/null || return 1
  new_stack b3md5
  hf 'set_models_dir 27b; write_stack_files; write_env 27b "$(profile_field 27b 1)"' >/dev/null 2>&1 || return 1
  local out rc
  out=$(LCTL_TREE="$tree" LCTL_TEST_PATH="$FAUX_BENCH:$PATH" hf 'cmd_bench --runs 1' 2>&1); rc=$?
  [ "$rc" = 0 ] \
    && printf '%s' "$out" | grep -q 'сравнимость замеров под вопросом' \
    && [ -f "$LCTL_TEST_STACK/bench/reports/hipfire-0.4.8-27b.md" ]
}

# B the model (the engine_bench_model hook, the gufo dialect): the
#     requests go with the name from load_completed, NOT with LCTL_MODEL
#     (a gguf file name); the extras hook puts the gen_avg from /metrics
#     into the report
scen_b_model_hook() {
  new_stack b3model
  LCTL_TEST_ENGINE=gufo hf 'set_models_dir 27b; write_stack_files; write_env 27b "$(profile_field 27b 1)"' >/dev/null 2>&1 || return 1
  # W3.2: a podman stamp on the first line (the uptime for the
  #     ratio-of-sums); LCTL_BENCH_UPTIME — a deterministic seam (2500 s →
  #     a gen_avg 20.0)
  printf '2026-11-23T09:00:00.000000000Z event=listening address=http://0.0.0.0:8080\n' > "$TMP/bench-glog"
  printf 'event=load_completed speculative=dflash2 sessions=1 context_tokens=262144 model=qwen3.8-27b-IQ4_XS-pure\n' >> "$TMP/bench-glog"
  : > "$TMP/bench-body.log"
  local out rc
  out=$(LCTL_TEST_ENGINE=gufo LCTL_BENCH_UPTIME=2500 LCTL_FAUX_PODMAN_LOGS="$TMP/bench-glog" \
    LCTL_FAUX_METRICS="$ROOT/engines/gufo/tests/fixtures/metrics_snap1.txt" \
    LCTL_FAUX_BENCH_BODY="$TMP/bench-body.log" LCTL_TEST_PATH="$FAUX_BENCH:$PATH" \
    hf 'cmd_bench --runs 1' 2>&1); rc=$?
  [ "$rc" = 0 ] || return 1
  grep -q 'qwen3.8-27b-IQ4_XS-pure' "$TMP/bench-body.log" || return 1   # имя из load_completed
  ! grep -q '\.gguf' "$TMP/bench-body.log" || return 1                  # НЕ имя gguf (LCTL_MODEL)
  grep -q 'gen_avg: 20' "$LCTL_TEST_STACK/bench/reports/gufo-0.37-27b.md" || return 1
  grep -q 'route_spec: dflash2' "$LCTL_TEST_STACK/bench/reports/gufo-0.37-27b.md" || return 1
  ! grep -q 'не выполнен' "$LCTL_TEST_STACK/bench/reports/gufo-0.37-27b.md" || return 1   # полный прогон gufo (T1-класс)
  ! grep -q 'bench_run:' <<<"$out" || return 1
}

# B the version guard: an ENGINE_VERSION outside ^[A-Za-z0-9._-]+$ → die
#     (it goes into the report file's name)
scen_b_version_guard() {
  new_stack b3ver
  hf 'set_models_dir 27b; write_stack_files; write_env 27b "$(profile_field 27b 1)"' >/dev/null 2>&1 || return 1
  local out rc
  out=$(LCTL_TEST_PATH="$FAUX_BENCH:$PATH" hf 'ENGINE_VERSION="bad version"; cmd_bench --runs 1' 2>&1); rc=$?
  [ "$rc" != 0 ] && printf '%s' "$out" | grep -q 'ENGINE_VERSION'
}

# B the deadline: LCTL_BENCH_MAX_S=0 → the deadline before the first
#     request: rc 0, a report with the truncation mark, the «не выполнен»
#     sections, no measurement tables
scen_b_deadline() {
  new_stack b4dl
  hf 'set_models_dir 27b; write_stack_files; write_env 27b "$(profile_field 27b 1)"' >/dev/null 2>&1 || return 1
  local out rc report="$LCTL_TEST_STACK/bench/reports/hipfire-0.4.8-27b.md"
  out=$(LCTL_BENCH_MAX_S=0 LCTL_TEST_PATH="$FAUX_BENCH:$PATH" hf 'cmd_bench --runs 1' 2>&1); rc=$?
  [ "$rc" = 0 ] || return 1
  [ -f "$report" ] || return 1
  grep -q 'ПРОГОН ОБОРВАН ПО ЛИМИТУ — цифры частичные' "$report" || return 1
  grep -q 'не выполнен' "$report" || return 1
  ! grep -q '^| прогон |' "$report" || return 1
  printf '%s' "$out" | grep -q 'ОБОРВАН' || return 1
  return 0
}

# B the golden: bench_report.py on the fixed fixtures/bench_runs →
#     byte-for-byte tests/fixtures/bench_golden_report.md (the
#     determinism: the date from the env)
scen_b_golden_snapshot() {
  B_TS=2026-11-22T00:00:00+00 B_ENGINE=engine-x B_VERSION=1.0 B_PROFILE=prof-x \
  B_MODEL=model-x B_MD5=253c7ac50857fe6d0e10fb0d2c5e35c0 \
  B_PARAMS="runs=2, parallel=2,4" LCTL_BENCH_MAX_S=3600 \
    python3 "$ROOT/core/py/bench/bench_report.py" "$ROOT/tests/fixtures/bench_runs" \
    > "$TMP/golden.out" 2>/dev/null
  cmp -s "$TMP/golden.out" "$ROOT/tests/fixtures/bench_golden_report.md"
}

# B the R6 hygiene: the bodies of core/bench.sh and
#     core/py/bench/* WITHOUT the engine names/dialects
#     (gufo|hipfire|tau|/metrics) and WITHOUT a host — the engine part
#     lives in engines/<name>/bench.sh, the host does not get into the
#     report
scen_b_r6_hygiene() {
  ! grep -rqE 'gufo|hipfire|tau|/metrics' "$ROOT/core/bench.sh" "$ROOT/core/py/bench/" || return 1
  ! grep -rqE '192\.168\.|hostname|HOSTNAME' "$ROOT/core/bench.sh" "$ROOT/core/py/bench/" || return 1
  # канон каталогов (аудит 2026-11-27): tpl — только render_tpl-шаблоны и
  # статические ассеты; исполняемый python живёт в py/ — ни одного .py в tpl
  ! find "$ROOT/core/tpl" "$ROOT"/engines/*/tpl -name '*.py' | grep -q . || return 1
  return 0
}

# B the JSON snapshot: bench_report.py argv[1] → a valid <combo>.json
#     (meta = the B_* env, the scenario rows verbatim, extras) — the
#     machine-readable artifact for bench_matrix.py
scen_b_json_snapshot() {
  B_TS=2026-11-22T00:00:00+00 B_ENGINE=engine-x B_VERSION=1.0 B_PROFILE=prof-x \
  B_MODEL=model-x B_MD5=253c7ac50857fe6d0e10fb0d2c5e35c0 \
  B_PARAMS="runs=2, parallel=2,4" LCTL_BENCH_MAX_S=3600 \
    python3 "$ROOT/core/py/bench/bench_report.py" "$ROOT/tests/fixtures/bench_runs" \
    "$TMP/snap.json" >/dev/null 2>&1 || return 1
  python3 "$ROOT/tests/shims/bench_json_check.py" "$TMP/snap.json" >/dev/null
}

# B the matrix: bench_matrix.py takes the LATEST snapshot per combination
#     (max meta.date — the stale one loses), renders the prefill/par
#     columns, marks a date mismatch, warns on a broken file, and is
#     deterministic (two renders byte-identical)
scen_b_matrix() {
  mkdir -p "$TMP/mx"
  printf '%s\n' '{"meta": {"date": "2026-11-26T00:00:00+00", "engine": "engine-a", "version": "0.9", "profile": "prof-x", "model": "m", "fixture_md5": "x", "params": "p", "truncated": false}, "solo": [{"run": 1, "wall_s": 1.0, "prompt_tokens": 140, "completion_tokens": 40, "tok_s": 99.99, "timings": null, "error": null}], "prose": [], "session": [], "followup": [], "parallel": [], "extras": null}' > "$TMP/mx/engine-a-0.9-prof-x.json"
  printf '%s\n' '{"meta": {"date": "2026-11-27T10:00:00+00", "engine": "engine-a", "version": "1.0", "profile": "prof-x", "model": "m", "fixture_md5": "x", "params": "p", "truncated": false}, "solo": [{"run": 1, "wall_s": 1.0, "prompt_tokens": 140, "completion_tokens": 40, "tok_s": 111.11, "timings": null, "error": null}], "prose": [], "session": [], "followup": [{"turn": 1, "wall_s": 10.0, "prompt_tokens": 25000, "completion_tokens": 128, "tok_s": 5.12, "timings": null, "error": null}], "parallel": [{"n": 2, "wall_s": 4.0, "agg_tok_s": 42.0, "error": null}], "extras": null}' > "$TMP/mx/engine-a-1.0-prof-x.json"
  printf '%s\n' '{"meta": {"date": "2026-11-26T09:00:00+00", "engine": "engine-b", "version": "2.0", "profile": "prof-x", "model": "m", "fixture_md5": "x", "params": "p", "truncated": false}, "solo": [{"run": 1, "wall_s": 1.0, "prompt_tokens": 140, "completion_tokens": 40, "tok_s": 55.0, "timings": null, "error": null}], "prose": [], "session": [], "followup": [], "parallel": [], "extras": null}' > "$TMP/mx/engine-b-2.0-prof-x.json"
  printf 'not json\n' > "$TMP/mx/broken.json"
  python3 "$ROOT/core/py/bench/bench_matrix.py" "$TMP/mx" > "$TMP/mx1.md" 2> "$TMP/mx1.err" || return 1
  grep -q '111.11' "$TMP/mx1.md" || return 1                 # latest by date won
  grep -q 'engine-a 0.9\|99.99' "$TMP/mx1.md" && return 1    # the stale snapshot lost
  grep -q '25k prefill (miss), s → tok/s' "$TMP/mx1.md" || return 1
  grep -q '10.00 → 2 500 tok/s' "$TMP/mx1.md" || return 1    # prompt_tokens/wall of follow-up turn 1
  grep -q '| 42.00 |' "$TMP/mx1.md" || return 1              # the par-2 column
  grep -q 'snapshot dates span several days' "$TMP/mx1.md" || return 1
  grep -q 'broken.json — не-JSON/битый, пропущен' "$TMP/mx1.err" || return 1
  python3 "$ROOT/core/py/bench/bench_matrix.py" "$TMP/mx" > "$TMP/mx2.md" 2>/dev/null || return 1
  cmp -s "$TMP/mx1.md" "$TMP/mx2.md" || return 1             # determinism
  return 0
}

echo "== B. bench (этап 7.1): роутер/флаги/гейты/e2e+перепись/md5/модель/версия/дедлайн/golden/R6"
if scen_b_router_usage; then ok "B0: bench в usage/case/arm/source диспетчера; пустой клон → rc!=0 «движок не определён … lctl start»"; else bad "B0 роутер"; fi
if scen_b_flags; then ok "B0: флаги — --runs abc/0/21, --parallel 9/2,x, неизвестный → die; --help → rc 0"; else bad "B0 флаги"; fi
if scen_b_gate_noenv; then ok "B1: .env нет → die «стек не установлен — сначала 'lctl start'»"; else bad "B1 гейт no-env"; fi
if scen_b_gate_dead; then ok "B1: health-отказ → die «стек не поднят…», ноль запросов генерации"; else bad "B1 гейт dead"; fi
if scen_b_gate_loading; then ok "B1: loading_model → die «модель ещё грузится» (БЕЗ ожидания — bench не виснет молча)"; else bad "B1 гейт loading"; fi
if scen_b_e2e_overwrite; then ok "B2: e2e на faux — отчёт hipfire-0.4.8-27b.md (+ .json-снапшот + bench/MATRIX.md с комбинацией), шапка/4 секции/extras/гигиена-без-хоста, модель=канон, повторный прогон ПЕРЕЗАПИСЫВАЕТ"; else bad "B2 e2e+перепись"; fi
if scen_b_md5_warn; then ok "B3: битая фикстура (копия дерева) → WARN «сравнимость под вопросом», прогон дошёл до отчёта"; else bad "B3 md5-гейт"; fi
if scen_b_model_hook; then ok "B3: gufo-хуки — запросы с именем из load_completed (НЕ gguf), extras gen_avg/route_spec в отчёте gufo-0.37-27b.md"; else bad "B3 bench-хуки gufo"; fi
if scen_b_version_guard; then ok "B3: ENGINE_VERSION вне ^[A-Za-z0-9._-]+$ → die (версия идёт в имя отчёта)"; else bad "B3 версия-гвард"; fi
if scen_b_deadline; then ok "B4: LCTL_BENCH_MAX_S=0 → rc 0, отчёт с «ПРОГОН ОБОРВАН», секции «не выполнен», замеров нет"; else bad "B4 дедлайн"; fi
if scen_b_golden_snapshot; then ok "B5: golden-снапшот bench_report.py — байт-в-байт (дата из env — детерминизм)"; else bad "B5 golden-снапшот"; fi
if scen_b_json_snapshot; then ok "B6: bench_report argv[1] → .json-снапшот (meta=env, строки verbatim, extras)"; else bad "B6 json-снапшот"; fi
if scen_b_matrix; then ok "B6: bench_matrix — latest-по-дате (stale проигрывает), английский генерат (префилл/пар-колонки), разнобой дней помечен, битый файл → warn, рендер детерминирован"; else bad "B6 матрица"; fi
if scen_b_r6_hygiene; then ok "B5: R6-гигиена — core/bench.sh + core/py/bench без gufo|hipfire|tau|/metrics и без хоста"; else bad "B5 R6-гигиена"; fi

echo "== B7. bench-мутации (маркеры core/bench.sh → соответствующий B-сценарий падает)"
check_mutation "bench-version"   "$(mutant_marker bench-version bench-version)"   scen_b_version_guard
check_mutation "bench-gate"      "$(mutant_marker bench-gate bench-gate)"          scen_b_gate_dead
check_mutation "bench-md5"       "$(mutant_marker bench-md5 bench-md5)"            scen_b_md5_warn
check_mutation "bench-model"     "$(mutant_marker bench-model bench-model)"        scen_b_model_hook
check_mutation "bench-report"    "$(mutant_marker bench-report bench-report)"      scen_b_e2e_overwrite
check_mutation "bench-overwrite" "$(mutant_marker bench-overwrite bench-overwrite)" scen_b_e2e_overwrite
check_mutation "bench-matrix"    "$(mutant_marker bench-matrix bench-matrix)"      scen_b_e2e_overwrite

# ── SR (task 3.2): the gufo/flash smoke race — the parse_route poll in engine_smoke ─
# The live window defect (2026-11-23): HEALTHY after 95 s, then a FATAL
# «в логе нет model= из load_completed» on a HEALTHY server (a bench
# passed on it): the load_completed line is flushed exactly at the ready
# boundary, the smoke read the log in one read before the flush (the
# ready↔log race). The fix — a poll in the adapter
# (engines/gufo/health.sh), the core untouched (R6).

# SR the «late flush» (a positive + a mutation — one ok, the counter
#     136→137): an empty ROUTE_MODEL (as after the ready↔log race), the
#     podman logs by SEQ: the 1st read — a log without load_completed,
#     the 2nd — with model= → the poll fills ROUTE_MODEL in, the smoke
#     passes (die NOT called). The mutation: a cut of the poll lines (the
#     # fix:smoke-race marker) on a tree copy → a die on the first empty
#     read → the same run must fail. Wrapped in timeout 120 (the 4.1
#     lesson: no hanging scenarios); hf is a battery function, so the
#     subshell is assembled by declare -f + an env prefix.
scen_sr1_late_flush() {
  new_stack sr1; fresh_log
  # W3.2: the `podman logs -t` podman prefixes (parse_route — substrings, not broken)
  printf '2026-11-18T08:00:00.100000000Z event=listening address=http://0.0.0.0:8080\n' > "$TMP/glog-sr-empty"
  printf '2026-11-18T08:00:01.200000000Z event=load_completed speculative=dflash2 sessions=1 context_tokens=262144 model=qwen3.8-27b-IQ4_XS-pure\n' > "$TMP/glog-sr-ok"
  local out rc dst
  out=$(timeout 120 env TMP="$TMP" FAUX="$FAUX" FAUXLOG="$FAUXLOG" FAUXCNT="$FAUXCNT" \
    ORPHAN_ID="$ORPHAN_ID" ROOT="$ROOT" LCTL_TREE="${LCTL_TREE:-$ROOT}" LCTL_TEST_STACK="$LCTL_TEST_STACK" \
    LCTL_TEST_ENGINE=gufo LCTL_TEST_PATH="$FAUX_GUFO:$PATH" \
    LCTL_SMOKE_ROUTE_WAIT_S=6 LCTL_SMOKE_RETRY_S=0 \
    LCTL_FAUX_LOGS_SEQ="$TMP/glog-sr-empty:$TMP/glog-sr-ok" \
    bash -c "$(declare -f hf); hf 'engine_smoke'" 2>&1); rc=$?
  [ "$rc" = 0 ] || { echo "DBG-sr1 rc=$rc: $(tail -3 <<<"$out")" >&2; return 1; }
  printf '%s' "$out" | grep -q 'SMOKE: OK' || return 1
  [ "$(grep -c 'podman logs' "$FAUXLOG")" = 2 ] || return 1   # ровно 2 чтения: пусто → model=
  # the mutation: the poll cut → a die on the first empty read → the run fails
  dst=$(mutant_sed smoke-race engines/gufo/health.sh '/# fix:smoke-race/d')
  [ -n "$dst" ] || return 1
  mutant_parses "$dst" || return 1
  out=$(timeout 120 env TMP="$TMP" FAUX="$FAUX" FAUXLOG="$FAUXLOG" FAUXCNT="$FAUXCNT" \
    ORPHAN_ID="$ORPHAN_ID" ROOT="$ROOT" LCTL_TREE="$dst" LCTL_TEST_STACK="$LCTL_TEST_STACK" \
    LCTL_TEST_ENGINE=gufo LCTL_TEST_PATH="$FAUX_GUFO:$PATH" \
    LCTL_SMOKE_ROUTE_WAIT_S=6 LCTL_SMOKE_RETRY_S=0 \
    LCTL_FAUX_LOGS_SEQ="$TMP/glog-sr-empty:$TMP/glog-sr-ok" \
    bash -c "$(declare -f hf); hf 'engine_smoke'" 2>&1); rc=$?
  [ "$rc" != 0 ] || return 1
  printf '%s' "$out" | grep -q 'health не выполнен' || return 1
  return 0
}

echo "== SR. смоук-гонка gufo/flash (fix:smoke-race, task 3.2): поздний flush + мутация — один ok"
if scen_sr1_late_flush; then ok "SR: поздний flush — poll parse_route дозаполнил ROUTE_MODEL (1-е чтение лога пусто, 2-е с model=), SMOKE: OK, die не звался, timeout 120; мутация «вырез poll» — die на первом пустом чтении, прогон упал"; else bad "SR смоук-гонка (позитив+мутация)"; fi

echo "== A. adapter-секции (engines/*/tests/*.sh)"
for fn in $ADAPTER_FUNCS; do
  "$fn"
done

printf 'ИТОГО: PASS=%s FAIL=%s\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
