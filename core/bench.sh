# shellcheck shell=bash
# ── bench (stage 7): a client-side read-only benchmark over the ACTIVE engine ─
# The core owns the orchestration: flags → gates (.env, engine version, live
# health) → context (profile/model/fixture md5) → running the 4 scenarios by
# the runner (core/tpl/python/bench/bench_run.py, JSONL in a mktemp dir) →
# the adapter's extras hook → report render (bench_report.py) → writing
# bench/reports/ (the same engine-version-profile combination OVERWRITES the
# file; the run history is the lab's git, the machine does not commit). The
# bench raises/switches nothing: the only effects are HTTP requests, log
# reading by the adapter and the report file. The core knows no engine
# specifics (R6): the version — ENGINE_VERSION, the model — the
# engine_bench_model hook (none — cur_model), the metrics —
# engine_bench_extras. The run deadline — LCTL_BENCH_MAX_S (default 3600):
# the runner starts no new requests after the deadline, the report is written
# with an honest truncation mark.

# @type /^[\da-f]{32}$/ # the canonical md5 of the solo-scenario fixture
#   (core/tpl/bench/merge_sort_thinking_off.txt, 1:1 from hfctl); a mismatch
#   at run time — warn, measurement comparability is in question
BENCH_FIXTURE_MD5=253c7ac50857fe6d0e10fb0d2c5e35c0

# Purpose: the INT/TERM handler (the cmd_bench trap): kill the child
#   processes (the scenario python runners and their curl children), exit
#   with rc 130/143 — the report is NOT written (writing happens only by
#   passing the full render). The temp dir is cleaned by cmd_bench's EXIT
#   trap.
#
# Side effects: SIGTERM to the direct background jobs and to the processes
#   holding an fd in the measurements dir (a unique mktemp — no false
#   matches); terminates the process (exit), which runs the EXIT trap with
#   the cleanup.
#
# Limitations/assumptions: installed ONLY after $BENCH_RUNS is created.
#   While bash waits for a foreground child, the trap is postponed until
#   its death — on Ctrl-C the whole process group gets the signal (curl
#   dies immediately).
#
# @param 1: 'INT' | 'TERM'  # the signal name for the message
# @param 2: '130' | '143'   # the rc (128+signum)
# @returns integer          # does not return — exit
bench_abort() {
  local sig="$1" rc="$2" p fd pid
  trap - INT TERM
  for p in $(jobs -p 2>/dev/null); do pkill -TERM -P "$p" 2>/dev/null || true; done
  for fd in /proc/[0-9]*/fd/*; do
    case "$(readlink -f "$fd" 2>/dev/null)" in "$BENCH_RUNS"|"$BENCH_RUNS"/*) ;; *) continue ;; esac
    pid="${fd#/proc/}"; kill -TERM "${pid%%/*}" 2>/dev/null || true
  done
  printf 'bench: прервано (%s) — незавершённый прогон НЕ сохранён\n' "$sig" >&2
  exit "$rc"
}

# Purpose: `lctl bench [--runs N] [--parallel N[,M…]] [--help]` — run the 4
#   scenarios (solo decode on the canon fixture with a warm-up, a short prose
#   request, an agent session of 15 turns + the follow-up cache, a parallel
#   load by the ladder) against the live server of the active engine and
#   write a markdown report.
#
# Side effects:
#   Gates (read-only): .env, curl GET $HEALTH_PATH + engine_health_ok,
#   the fixture md5sum, reading the canon (env_val), the adapter hooks.
#   Network: REAL generations by the runner (warm-up + measurements; the
#   LCTL_BENCH_MAX_S deadline), the adapter's extras hook (engine metrics —
#   adapter dialect, the core does not interpret them).
#   Files: the BENCH_RUNS mktemp dir (measurement JSONL + extras.json,
#   trap rm -rf EXIT); OVERWRITE of
#   bench/reports/<engine>-<version>-<profile>.md. INT/TERM — bench_abort:
#   a partial run is not saved.
#
# Limitations/assumptions: the stack is installed (.env) and healthy (the
#   gate has NO load waiting — waiting for the model is lctl start/up's
#   job); CONFIG is not touched; ENGINE_VERSION is valid (it goes into the
#   report file name); the fixture is read FROM THE REPO (no copies);
#   a deadline cut-off is not an interruption (the remaining scenarios are
#   skipped, the report is rendered with a mark); a failed run — warn + a
#   line with error, medians over the successful ones. Locals: runs — an
#   integer 1–20; par_list/par_nums — the parallelism N list; ts_iso — the
#   report date (env for bench_report determinism); truncated — '' | '1'
#   (the cut-off mark); model/prof/md5_real/report — the context and the
#   report path; fixture/deadline/runner/report_dir — internal paths and
#   the run deadline; v/body — the .env value and the /health body of the
#   gates.
#
# @param 1..N: string[] # flags: --runs <integer 1–20> (default 3) |
#   --parallel <N[,M…]> integers 1..8 (default "2,4") | --help
# @returns integer     # always 0 on return — refusals terminate the process via die
cmd_bench() {
  local runs=3 par_list="2,4" pn a
  while [ $# -gt 0 ]; do
    case "$1" in
      --runs)
        case "${2:-}" in ''|*[!0-9]*) die "bench --runs: целое 1–20 (получено '${2:-}')" ;; esac
        [ "$2" -ge 1 ] && [ "$2" -le 20 ] || die "bench --runs: целое 1–20 (получено '$2')"
        runs="$2"; shift 2 ;;
      --parallel)
        [ -n "${2:-}" ] || die "bench --parallel: целые 1..8 через запятую (получено '')"
        for pn in ${2//,/ }; do
          case "$pn" in ''|*[!0-9]*) die "bench --parallel: целые 1..8 через запятую (получено '$2')" ;; esac
          [ "$pn" -ge 1 ] && [ "$pn" -le 8 ] || die "bench --parallel: целые 1..8 через запятую (получено '$2')"
        done
        par_list="$2"; shift 2 ;;
      --help|-h)
        echo "использование: lctl bench [--runs N] [--parallel N[,M…]]"
        echo "  бенч живого движка (read-only): соло-декод на канон-фикстуре (прогрев"
        echo "  + $runs замеров по умолчанию), проза, сессия 15 ходов + follow-up,"
        echo "  параллельная нагрузка. Отчёт: bench/reports/<engine>-<version>-<profile>.md"
        echo "  Дедлайн прогона: LCTL_BENCH_MAX_S (сек, дефолт 3600)."
        return 0 ;;
      *) die "неизвестный флаг bench: $1 (доступны: --runs --parallel --help)" ;;
    esac
  done

  [ -f "$STACK_DIR/.env" ] || die "стек не установлен — сначала 'lctl start'"
  local v
  v=$(env_val LCTL_PORT); [ -n "$v" ] && PORT="$v"
  v=$(env_val LCTL_BIND); [ -n "$v" ] && BIND="$v"
  case "$ENGINE_VERSION" in ''|*[!A-Za-z0-9._-]*) die "адаптер $ENGINE: ENGINE_VERSION='${ENGINE_VERSION:-}' не подходит формату ^[A-Za-z0-9._-]+$ (версия сборки идёт в имя файла отчёта bench)" ;; esac   # fix:bench-version
  local body
  body=$(curl -fsS -m 5 "http://127.0.0.1:$PORT$HEALTH_PATH" 2>/dev/null) && printf '%s' "$body" | engine_health_ok 2>/dev/null || die "стек не поднят или модель ещё грузится — проверь 'lctl status'; bench идёт по живому движку (ждать загрузки — забота lctl start/up)"   # fix:bench-gate

  local fixture="$CORE_TPL/bench/merge_sort_thinking_off.txt"
  [ -f "$fixture" ] || die "фикстура bench не найдена: $fixture (дерево клона неполное?)"
  local prof model md5_real
  prof=$(cur_profile)
  if declare -F engine_bench_model >/dev/null 2>&1; then model=$(engine_bench_model); else model=$(cur_model); fi   # fix:bench-model — no hook → the LCTL_MODEL canon (the core knows no name dialects)
  md5_real=$(md5sum "$fixture" | cut -d' ' -f1)
  [ "$md5_real" = "$BENCH_FIXTURE_MD5" ] || warn "md5 фикстуры $md5_real ≠ эталону $BENCH_FIXTURE_MD5 — сравнимость замеров под вопросом (байты фикстуры менялись)"   # fix:bench-md5

  BENCH_RUNS="$(mktemp -d "${TMPDIR:-/tmp}/lctl-bench.XXXXXX")"
  trap 'rm -rf "$BENCH_RUNS"' EXIT
  trap 'bench_abort INT 130' INT
  trap 'bench_abort TERM 143' TERM
  local deadline=$(( $(date +%s) + ${LCTL_BENCH_MAX_S:-3600} ))
  local runner="$CORE_TPL/python/bench/bench_run.py" truncated=""
  local par_nums="${par_list//,/ }"
  log "bench: $ENGINE $ENGINE_VERSION | профиль $prof | модель $model | runs=$runs parallel=$par_list"

  python3 "$runner" solo "$PORT" "$model" "$runs" "$deadline" "$BENCH_RUNS/solo.jsonl" "$fixture"
  grep -q '"truncated":true' "$BENCH_RUNS/solo.jsonl" 2>/dev/null && truncated=1
  if [ -z "$truncated" ]; then
    python3 "$runner" prose "$PORT" "$model" "$runs" "$deadline" "$BENCH_RUNS/prose.jsonl"
    grep -q '"truncated":true' "$BENCH_RUNS/prose.jsonl" 2>/dev/null && truncated=1
  fi
  if [ -z "$truncated" ]; then
    python3 "$runner" session "$PORT" "$model" 1 "$deadline" "$BENCH_RUNS/session.jsonl"
    grep -q '"truncated":true' "$BENCH_RUNS/session.jsonl" 2>/dev/null && truncated=1
  fi
  if [ -z "$truncated" ]; then
    python3 "$runner" followup "$PORT" "$model" 1 "$deadline" "$BENCH_RUNS/followup.jsonl"
    grep -q '"truncated":true' "$BENCH_RUNS/followup.jsonl" 2>/dev/null && truncated=1
  fi
  if [ -z "$truncated" ]; then
    for pn in $par_nums; do
      python3 "$runner" parallel "$PORT" "$model" "$pn" "$deadline" "$BENCH_RUNS/parallel-$pn.jsonl" "$fixture"
      grep -q '"truncated":true' "$BENCH_RUNS/parallel-$pn.jsonl" 2>/dev/null && { truncated=1; break; }
    done
  fi

  # extras: the engine metrics of the report as one JSON line (the adapter
  # hook; a failure / non-JSON — warn, the report section is honestly marked)
  if declare -F engine_bench_extras >/dev/null 2>&1; then
    if ! engine_bench_extras "$BENCH_RUNS" > "$BENCH_RUNS/extras.json" 2>/dev/null; then
      warn "engine_bench_extras завершился с ошибкой — секция движковых метрик будет без данных"
    fi
  fi

  # report: a render from the JSONL + env headers (the date from env —
  # determinism), the write
  local report_dir="$STACK_DIR/bench/reports" report ts_iso
  mkdir -p "$report_dir"   # fix:bench-overwrite — the report dir; the same engine-version-profile combination is overwritten ('>'), no timestamp copies (the run history is the lab's git)
  report="$report_dir/$ENGINE-$ENGINE_VERSION-$prof.md"
  ts_iso=$(date +%Y-%m-%dT%H:%M:%S%z)
  B_TS="$ts_iso" B_ENGINE="$ENGINE" B_VERSION="$ENGINE_VERSION" \
  B_PROFILE="$prof" B_MODEL="$model" B_MD5="$md5_real" \
  B_PARAMS="runs=$runs, parallel=$par_list" LCTL_BENCH_MAX_S="${LCTL_BENCH_MAX_S:-3600}" \
    python3 "$CORE_TPL/python/bench/bench_report.py" "$BENCH_RUNS" > "$report"   # fix:bench-report — a markdown render; the short summary is the runner's stderr
  log "bench завершён$([ -n "$truncated" ] && echo ' (ОБОРВАН по лимиту LCTL_BENCH_MAX_S — цифры частичные)')"
  echo "отчёт: $report"
  return 0
}
