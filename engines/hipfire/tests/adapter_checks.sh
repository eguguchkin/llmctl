# shellcheck shell=bash
# adapter_checks.sh — llmctl battery's hipfire section (sourced by the
# tests/run_checks.sh runner). The engine faux curl (the hipfire answer
# dialect of /health, /v1/chat/completions) and the §2.3 adapter-contract
# scenarios: registry/aliases, the health dialect, the smoke,
# apply_profile (cfgset), the route, the status lines, the compose files
# (goldens + the DFlash wiring).

# a faux curl with live answers: /health → ok-JSON (wait_health,
# route_snapshot, engine_doctor), /stats → the /stats fixture (W3; the
# LCTL_FAUX_STATS env — a file), /metrics → the prometheus fixture (W3;
# the LCTL_FAUX_METRICS env — a file, or LCTL_FAUX_METRICS_SEQ —
# «file1:file2:…» per the call count), /v1/chat/completions → chat-JSON
# (engine_smoke); the other calls — empty, rc 0. The failure seams:
# LCTL_FAUX_CURL_FAILALL=1 — all GETs rc 7 (a dead server);
# LCTL_FAUX_STATSFAIL=1 — only /stats rc 7 (a dead tick);
# LCTL_FAUX_METRICSFAIL=1 — only /metrics rc 7 (a live tick, «—» in the
# cache/spec). The core's N-scenarios run a full bootstrap on these
# answers (the wave-1 dependency on the adapter — the R-1 risk of task
# 1.1, the final greenness — on wave 3).
cp "$ROOT/engines/hipfire/tests/shims/curl" "$FAUX_FULL/curl"
chmod +x "$FAUX_FULL/curl"

# ── the adapter scenarios (return 0 = all the asserts hold) ─────────────────

# A-registry: the resolve_profile aliases, the default, the format fields (the core contract §2.2)
scen_a_registry() {
  local out
  out=$(hf 'echo "$(resolve_profile 27b-parallel)/$(resolve_profile slots)/$(resolve_profile flash-multi)/$(resolve_profile 27b-single)"') || return 1
  [ "$out" = "27b-parallel/27b-parallel/flash/27b" ] || return 1
  hf 'resolve_profile nope' >/dev/null 2>&1 && return 1   # неизвестный — rc 1
  out=$(hf 'echo "$PROFILE_DEFAULT"') || return 1
  [ "$out" = "27b" ] || return 1
  out=$(hf 'echo "$(profile_field 27b 1) $(profile_field 27b 3) $(profile_field flash 4)"') || return 1
  [ "$out" = "qwen3.8:27b-mq4-xts qwen3.8:27b-draft-mq4 80" ] || return 1
}

# A-health-dialect: ok-JSON → healthy; loading_model → not healthy; not-JSON → 1
scen_a_health() {
  hf 'printf "%s" "{\"status\":\"ok\",\"model\":\"m\"}" | engine_health_ok' >/dev/null 2>&1 || return 1
  hf 'printf "%s" "{\"status\":\"ok\",\"model\":\"m\",\"loading_model\":\"x\"}" | engine_health_ok' >/dev/null 2>&1 && return 1
  hf 'printf "garbage" | engine_health_ok' >/dev/null 2>&1 && return 1
  return 0
}

# A-smoke: engine_smoke (core_smoke, 5 requests) via the faux curl → SMOKE: OK; the assert — ≥2 chat/completions in the journal
scen_a_smoke() {
  new_stack a-smoke; fresh_log
  printf 'LCTL_MODEL=qwen3.8:27b-mq4-xts\n' > "$LCTL_TEST_STACK/.env"   # fix:w42-smoke-core — эхо-модель валидатора требует непустую модель (в проде cur_model всегда непуст)
  local out rc
  out=$(LCTL_TEST_PATH="$FAUX_FULL:$PATH" hf 'engine_smoke' 2>&1); rc=$?
  [ "$rc" = 0 ] \
    && printf '%s' "$out" | grep -q 'SMOKE: OK' \
    && [ "$(grep -c 'chat/completions' "$FAUXLOG")" -ge 2 ]
}

# A3-vision/novision (fix:w43-smoke-vision): the core_smoke gate — with a
#     vision.hfq in the set the 6th request is sent (image_url in the faux
#     log), without — not sent
scen_a_smoke_vision() {
  new_stack a-smokev; fresh_log
  printf 'LCTL_MODEL=qwen3.8:27b-mq4-xts\n' > "$LCTL_TEST_STACK/.env"
  out=$(LCTL_TEST_PATH="$FAUX_FULL:$PATH" hf 'mkdir -p "$MODELS_DIR"; : > "$MODELS_DIR/qwen3.8-27b-vision.hfq"; engine_smoke' 2>&1); rc=$?
  [ "$rc" = 0 ] \
    && printf '%s' "$out" | grep -q 'SMOKE: OK' \
    && grep -q 'image_url' "$FAUXLOG"
}
scen_a_smoke_novision() {
  new_stack a-smokenv; fresh_log
  printf 'LCTL_MODEL=qwen3.8:27b-mq4-xts\n' > "$LCTL_TEST_STACK/.env"
  out=$(LCTL_TEST_PATH="$FAUX_FULL:$PATH" hf 'engine_smoke' 2>&1); rc=$?
  [ "$rc" = 0 ] \
    && printf '%s' "$out" | grep -q 'SMOKE: OK' \
    && ! grep -q 'image_url' "$FAUXLOG"
}

# A-apply_profile: the 27b-parallel branch's cfgset keys in the podman
# journal (dflash on, the slots from SLOTS, the ctx from MAX_SEQ), rc 0
scen_a_apply_profile() {
  new_stack a-apply; fresh_log
  local out rc cat
  cat="$LCTL_TEST_STACK/$(grep '^HIPFIRE_STATE_DIR' "$LCTL_TEST_STACK/.env" | cut -d= -f2)/config/models.toml"
  out=$(hf 'engine_apply_profile 27b-parallel' 2>&1); rc=$?
  [ "$rc" = 0 ] \
    && grep -qF 'config set speculation.dflash on' "$FAUXLOG" \
    && grep -qF 'config set serve.multi_slot_slots 2' "$FAUXLOG" \
    && grep -qF 'config set serve.multi_slot_ctx 262144' "$FAUXLOG" \
    && grep -qF 'config set serve.vmm_batch false' "$FAUXLOG" \
    && grep -qF '[models."qwen3.8-27b"]' "$cat" \
    && grep -qF 'registry_tag = "qwen3.8:27b-mq4-xts"' "$cat"
}

# A-route: engine_check_route 27b-parallel — the multi_slot line (faux /health)
scen_a_route() {
  local out rc
  out=$(LCTL_TEST_PATH="$FAUX_FULL:$PATH" hf 'engine_check_route 27b-parallel' 2>&1); rc=$?
  [ "$rc" = 0 ] && printf '%s' "$out" | grep -q 'роут: multi_slot'
}

# A-status lines: engine_status_health (hline) and engine_status_json
scen_a_status_lines() {
  local out rc
  out=$(hf 'printf "%s" "{\"status\":\"ok\",\"model\":\"m\",\"capabilities\":{\"mode\":\"multi-slot\",\"multi_slot_slots\":2}}" | engine_status_health' 2>&1); rc=$?
  [ "$rc" = 0 ] \
    && printf '%s' "$out" | grep -q 'health: ok' \
    && printf '%s' "$out" | grep -q 'модель: m' \
    && printf '%s' "$out" | grep -q 'слоты: 2' || return 1
  out=$(hf 'printf "%s" "{\"status\":\"ok\",\"model\":\"m\"}" | PROFILE="27b" AUTO="enabled" WDOG="enabled" engine_status_json' 2>&1); rc=$?
  [ "$rc" = 0 ] \
    && printf '%s' "$out" | grep -q '"profile": "27b"' \
    && printf '%s' "$out" | grep -q '"autostart": true'
}

# A-compose: engine_write_compose — the goldens (name: hipfire — the
#     project pin) + the DFlash wiring by the draft profile; the stage-8
#     contract: with a target dir the triple is written there (the buffer
#     is not read), without an argument — the former place
scen_a_compose() {
  new_stack a-compose
  hf 'set_models_dir 27b; write_stack_files; write_env 27b "$(profile_field 27b 1)"' >/dev/null 2>&1 || return 1
  grep -qF 'name: hipfire' "$LCTL_TEST_STACK/compose.yml" || return 1
  # OPS1 (W3.2.2): the ports line — the LCTL_BIND env-model canon (the
  #     podman-compose interp: a key in .env → its value; none → the
  #     0.0.0.0 default — the ratified LAN-bind); the HIPFIRE_BIND key is
  #     gone — a live outward bind is checked by a recreate + an external
  #     probe (the orchestrator window)
  grep -qF '${LCTL_BIND:-0.0.0.0}:${HIPFIRE_PORT:-11435}:11435' "$LCTL_TEST_STACK/compose.yml" || return 1
  ! grep -rq 'HIPFIRE_BIND' "$LCTL_TEST_STACK"/compose*.yml || return 1
  grep -qE '^LCTL_BIND=' "$LCTL_TEST_STACK/.env" || return 1
  [ -f "$LCTL_TEST_STACK/compose.halo.yml" ] || return 1
  grep -qF 'HIPFIRE_DFLASH_DRAFT: /home/hipfire/.hipfire/models/qwen38-27b-dflash-mq4.hfq' "$LCTL_TEST_STACK/compose.local.yml" || return 1
  local d="$TMP/wt-hipfire"; rm -rf "$d"; mkdir -p "$d"
  hf "engine_write_compose '$d'" >/dev/null 2>&1 || return 1
  [ -f "$d/compose.yml" ] && [ -f "$d/compose.halo.yml" ] && [ -f "$d/compose.local.yml" ] || return 1
  grep -qF 'name: hipfire' "$d/compose.yml" || return 1
  grep -qF 'HIPFIRE_DFLASH_DRAFT:' "$d/compose.local.yml" || return 1
  return 0
}

# A-bench-extras (stage 7): engine_bench_extras — the τ from the container
#     logs (the last tau=/τ= line) + ROUTE_SPEC → one JSON line; no tau in
#     the logs → a null tau_s (not made up — the report section is honest)
scen_a_bench_extras() {
  local taulog="$TMP/hipfire-tau-log" out
  printf '2026-11-22 10:00:00 [INFO] inference τ=13.18 tok/s\n' > "$taulog"
  out=$(LCTL_FAUX_PODMAN_LOGS="$taulog" hf 'engine_bench_extras bench-runs-x' 2>&1) || return 1
  printf '%s' "$out" | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d["tau_s"] == 13.18, d
assert d["route_spec"] is None, d' || return 1
  out=$(hf 'engine_bench_extras bench-runs-x' 2>&1) || return 1
  printf '%s' "$out" | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d["tau_s"] is None, d' || return 1
  return 0
}

# ── W2: the hipfire watch panel (ENGINE_WATCH_TUI exists + the selfcheck on
#     the fixtures rc 0, the counter in the ok line; like gufo's W1) + a
#     plain stream on the W3.2 fixtures (the scheme v2 from
#     /stats+/metrics, the ` | ` parser, the pulses, the long log-line
#     clip). The selfcheck runs by the --selfcheck flag (it terminates rc
#     0/1, the live loop is unreachable) under timeout 120 — the timeout
#     rule; the plain stream — the battery seam LCTL_WATCH_TICKS. The tree
#     under test — LCTL_TREE (the mutations substitute a copy) ────────────
W2_CNT=''
scen_w2_panel() {
  local troot="${LCTL_TREE:-$ROOT}" out rc
  [ -f "$troot/engines/hipfire/tpl/python/watch_tui.py" ] || return 1
  grep -qF 'ENGINE_WATCH_TUI="$ADAPTER_DIR/tpl/python/watch_tui.py"' "$ROOT/engines/hipfire/adapter.sh" || return 1
  grep -qF 'engine_watch_env()' "$ROOT/engines/hipfire/adapter.sh" || return 1   # PYTHONPATH-хук каркаса
  out=$(PYTHONPATH="$troot/core/tpl/python/watch" timeout 120 \
    python3 "$troot/engines/hipfire/tpl/python/watch_tui.py" --selfcheck 2>&1); rc=$?
  [ "$rc" = 0 ] \
    && printf '%s' "$out" | grep -q 'selfcheck: 104/104 ok' \
    && printf '%s' "$out" | grep -q 'selfcheck engine: 72/72 ok' || return 1
  W2_CNT=$(printf '%s' "$out" | awk '/^selfcheck engine: /{print $3}')
  [ "${W2_CNT%%/*}" = "${W2_CNT##*/}" ] || return 1   # N/N без провалов
  return 0
}

# running the frame's python panel (common to the W2 scenarios; the
#     container is set by the scenario — the frame has had no engine
#     default since fix-round 2, R6)
wrun2() {
  timeout 120 env PATH="$FAUX_FULL:$PATH" PYTHONPATH="$ROOT/core/tpl/python/watch" \
    LCTL_FAUX_LOG="$FAUXLOG" LCTL_FAUX_CNT="$FAUXCNT" LCTL_WATCH_CONTAINER=hipfire \
    "$@" python3 "$ROOT/engines/hipfire/tpl/python/watch_tui.py" 2>&1
}

# W2-plain (W3.2): 3 ticks on the fixtures — tick 1 the base (the scheme
#     v2 from /health+/stats+/metrics, the « | » parser, the uptime
#     «52 мин», the queue 0 of 4, «τ 4.9 ток/цикл», «ttft 0.24 с»), tick 2
#     the live pulse of the done counters (ген-средн 1.7 — a ratio-of-sums
#     over uptime), tick 3 the drafts done-pulse (+10 = the Δspec_cycles
#     from the /stats SEQ); a long log line does not crash plain; a dead
#     /stats → a dead line; a dead /metrics → «—» in the metrics with the
#     config alive (оч «0 запросов» — the capacity from /metrics)
scen_w2_plain() {
  new_stack w2plain; fresh_log
  local fx="$ROOT/engines/hipfire/tests/fixtures" out rc e1 m1 q1
  # tick2 = the done tick: the counters + the histograms moved (the v2
  #     session formulas: Δcompletion 300, Δ(lat−ttft) = 6480−480 = 6000 ms
  #     → ген-средн exactly 50.0; Δpf 1000/1 → prefill 1000.0; Δttft 480 ms
  #     → the window 0.48; Δtau 5.0)
  sed 's/^hipfire_completion_tokens_total 5000$/hipfire_completion_tokens_total 5300/; s/^hipfire_prompt_tokens_total 12000$/hipfire_prompt_tokens_total 12500/; s/^hipfire_request_latency_milliseconds_sum 12000$/hipfire_request_latency_milliseconds_sum 18480/; s/^hipfire_request_latency_milliseconds_count 2$/hipfire_request_latency_milliseconds_count 3/; s/^hipfire_ttft_milliseconds_sum 480$/hipfire_ttft_milliseconds_sum 960/; s/^hipfire_ttft_milliseconds_count 2$/hipfire_ttft_milliseconds_count 3/; s/^hipfire_prefill_tokens_per_second_sum 800$/hipfire_prefill_tokens_per_second_sum 1800/; s/^hipfire_prefill_tokens_per_second_count 2$/hipfire_prefill_tokens_per_second_count 3/; s/^hipfire_spec_tau_sum 9.82$/hipfire_spec_tau_sum 14.82/; s/^hipfire_spec_tau_count 2$/hipfire_spec_tau_count 3/' \
    "$fx/watch_metrics.txt" > "$TMP/w2-m2.txt"
  # the draft pulse — from /stats (R-1): no spec_cycles in /metrics,
  #     tick 3 — the done pulse via the stats SEQ (0 → 10 → +10)
  sed 's/"spec_cycles":0/"spec_cycles":10/' \
    "$fx/watch_stats.json" > "$TMP/w2-s3.json"
  out=$(wrun2 LCTL_FAUX_PODMAN_LOGS="$fx/watch_log.txt" \
    LCTL_FAUX_STATS_SEQ="$fx/watch_stats.json:$fx/watch_stats.json:$TMP/w2-s3.json" \
    LCTL_FAUX_METRICS_SEQ="$fx/watch_metrics.txt:$TMP/w2-m2.txt:$TMP/w2-m2.txt" \
    LCTL_WATCH_PORT=11435 LCTL_WATCH_INTERVAL=0.01 LCTL_WATCH_TICKS=3); rc=$?
  [ "$rc" = 0 ] || { echo "DBG-w2plain rc=$rc: $(tail -3 <<<"$out")" >&2; return 1; }
  [ "$(grep -c '/stats' "$FAUXLOG")" = 3 ] || return 1   # 1 вызов на тик
  [ "$(grep -c '/metrics' "$FAUXLOG")" = 3 ] || return 1
  grep -q 'podman logs --tail 200 -t' "$FAUXLOG" || return 1  # F1: сид С -t, окно 200 (W3.2.1-D1)
  e1=$(grep ' \[движок\] ' <<<"$out" | sed -n 1p)
  printf '%s' "$e1" | grep -qF 'аптайм 52 мин | спек mtp K=7 | ctx 1 × 262 144 ток (лента 4) | kv q8 (vmm)' || return 1
  printf '%s' "$e1" | grep -qF 'кэш-ram — | кэш-диск —' || return 1  # swap-семейство пусто (соло-прод, §5); lost скрыт (источника нет)
  ! grep -q 'qwen4 native mtp' <<<"$out" || return 1     # фасет сжат до «mtp K=7» (полный остался только в буфере лога)
  ! grep -q 'готов' <<<"$out" || return 1                # D4: ряда Статус нет
  ! grep -qE '\[(очередь|роут|счётчики)\]' <<<"$out" || return 1  # специфика ряда 2 удалена (лейаут §1)
  m1=$(grep ' \[метрики\] ' <<<"$out" | sed -n 1p)
  # W3.3 v2: tick1 — the session base → ген/prefill-средн/τ «—» (the seed
  #     (а)); ген-посл = the done-line 55.6 from the log buffer (the
  #     СИДЕ-parse, NOT recent_tok_s 24.6 — the source anti-pin);
  #     prefill-посл «—» (no work); the ttft dual: the lifetime 0.24 с
  #     (средн) · «—» (the window — an empty session)
  printf '%s' "$m1" | grep -qF 'ген — (средн) · 55.6 (посл) tok/s | prefill — (средн) · — (посл) tok/s' || return 1
  printf '%s' "$m1" | grep -qF 'кэш 9.0k из 12.0k ток из кэша (75.0 %)' || return 1
  printf '%s' "$m1" | grep -qF 'спек принято 70.1 % · τ — ток/цикл | оч 0 из 4 запросов' || return 1  # принято = tau/K (fallback сериала: done tau 4.91, K=7 — fix:w33-spec-pct); τ — база session
  printf '%s' "$m1" | grep -qF 'оч 0 из 4 запросов | ttft 0.24 с (средн) · — (окно)' || return 1
  printf '%s' "$m1" | grep -qF 'сген 5.0k ток' || return 1
  m2l=$(grep ' \[метрики\] ' <<<"$out" | sed -n 2p)
  m3l=$(grep ' \[метрики\] ' <<<"$out" | sed -n 3p)
  # W3.3 v2 tick2 (the done tick, Δcount>0): ген-средн exactly 50.0
  #     (300/(18480−960−11520)/1000 — Σтокены/Σдекод-время, NOT
  #     300/uptime); prefill-средн/посл = 1000.0 (Δpf 1000/1); τ 5.0
  #     (Δ5.0/1); the ttft dual «0.32 с (средн) · 0.48 с (окно)»
  #     (the lifetime 960/3 · the session 480/1)
  printf '%s' "$m2l" | grep -qF 'ген 50.0 (средн) · 55.6 (посл) tok/s | prefill 1000.0 (средн) · 1000.0 (посл) tok/s' || return 1
  printf '%s' "$m2l" | grep -qF 'кэш 9.0k из 12.5k ток из кэша (72.0 %)' || return 1
  printf '%s' "$m2l" | grep -qF 'спек принято 70.1 % · τ 5.0 ток/цикл' || return 1
  printf '%s' "$m2l" | grep -qF 'ttft 0.32 с (средн) · 0.48 с (окно)' || return 1
  printf '%s' "$m2l" | grep -qF 'сген 5.3k ток' || return 1
  # the W3.3 hold pin tick3 (Δcount=0 — raw «—»): all the rows HOLD exactly
  printf '%s' "$m3l" | grep -qF 'ген 50.0 (средн) · 55.6 (посл) tok/s | prefill 1000.0 (средн) · 1000.0 (посл) tok/s' || return 1
  printf '%s' "$m3l" | grep -qF 'τ 5.0 ток/цикл' || return 1
  printf '%s' "$m3l" | grep -qF 'ttft 0.32 с (средн) · 0.48 с (окно)' || return 1
  grep -qF 'decode +300 · prefill +500 (ток/тик) · drafts +0 (цикл/тик)' \
    <<<"$(grep ' \[скорость\] ' <<<"$out" | sed -n 2p)" || return 1
  grep -qF 'drafts +10 (цикл/тик)' \
    <<<"$(grep ' \[скорость\] ' <<<"$out" | sed -n 3p)" || return 1  # Δspec_cycles 0→10 (fix:w3-r1-cycles)
  lg=$(grep ' \[логи\] ' <<<"$out" | tail -1)
  printf '%s' "$lg" | grep -qE '\[логи\] [0-9]{2}:[0-9]{2}:[0-9]{2} \[INFO\] \[req chatcmpl' || return 1
  ! printf '%s' "$lg" | grep -q '2026-11-23' || return 1  # podman-метка → HH:MM:SS, движковый штамп срезан (F1)
  ! grep -q '?' <<<"$out" || return 1                    # инвариант: «?» не существует
  # a dead /stats → a dead line on every tick, no [движок]
  out=$(wrun2 LCTL_FAUX_STATSFAIL=1 LCTL_WATCH_PORT=11435 \
    LCTL_WATCH_INTERVAL=0.01 LCTL_WATCH_TICKS=2); rc=$?
  [ "$rc" = 0 ] || return 1
  [ "$(grep -c 'недоступен' <<<"$out")" = 2 ] || return 1
  ! grep -q ' \[движок\] ' <<<"$out" || return 1
  # a dead /metrics with the rest alive → «—» in the metrics, the config
  #     alive, the queue depth-only («0 запросов» — the capacity from
  #     /metrics)
  out=$(wrun2 LCTL_FAUX_PODMAN_LOGS="$fx/watch_log.txt" \
    LCTL_FAUX_STATS="$fx/watch_stats.json" LCTL_FAUX_METRICSFAIL=1 \
    LCTL_WATCH_PORT=11435 LCTL_WATCH_INTERVAL=0.01 LCTL_WATCH_TICKS=1); rc=$?
  [ "$rc" = 0 ] || return 1
  m1=$(grep ' \[метрики\] ' <<<"$out" | sed -n 1p)
  printf '%s' "$m1" | grep -qF 'ген — (средн) · 55.6 (посл) tok/s | prefill — (средн) · — (посл) tok/s | кэш —' || return 1  # W3.3: ген-посл = done-line жив (тик не dead)
  printf '%s' "$m1" | grep -qF 'спек принято 70.1 % · τ — ток/цикл | оч 0 запросов | ttft — | сген —' || return 1
  e1=$(grep ' \[движок\] ' <<<"$out" | sed -n 1p)
  printf '%s' "$e1" | grep -qF 'аптайм 52 мин' || return 1
  ! grep -qi 'traceback' <<<"$out" || return 1
  return 0
}

# W2-cache-env (W3.2.1 p.5): the adapter's env seam — the cache budgets
#     «from the config» (the LCTL_WATCH_HIPFIRE_CACHE_RAM/DISK stub keys,
#     the way engine_watch_env delivers them from config.toml) + the disk
#     used BY SCANNING the fixture dir (a sparse file 3435973837 B =
#     3.2 GiB st_size + a 10 B file in a subdir — recursion); the render
#     «12.0 GiB (бюджет)» and «3.2 / 32.0 GiB (бюджет)». No keys → «—»
#     (covers scen_w2_plain). The w321-cache-env mutation (a cut of the
#     env line in collect) fails the scenario
scen_w2_cache_env() {
  new_stack w2cache; fresh_log
  # the tree under test — LCTL_TREE (the w321-cache-env mutation
  #     substitutes a copy): the panel runs from troot, the frame/fixtures
  #     — from ROOT
  local troot="${LCTL_TREE:-$ROOT}" \
        fx="$ROOT/engines/hipfire/tests/fixtures" out rc e1
  mkdir -p "$TMP/w2-cache/sub"
  python3 "$ROOT/engines/hipfire/tests/shims/make_w2_cache.py" "$TMP/w2-cache" || return 1
  out=$(timeout 120 env PATH="$FAUX_FULL:$PATH" \
    PYTHONPATH="$ROOT/core/tpl/python/watch" \
    LCTL_FAUX_LOG="$FAUXLOG" LCTL_FAUX_CNT="$FAUXCNT" \
    LCTL_WATCH_CONTAINER=hipfire \
    LCTL_FAUX_PODMAN_LOGS="$fx/watch_log.txt" \
    LCTL_FAUX_STATS="$fx/watch_stats.json" \
    LCTL_FAUX_METRICS="$fx/watch_metrics.txt" \
    LCTL_WATCH_PORT=11435 LCTL_WATCH_INTERVAL=0.01 LCTL_WATCH_TICKS=1 \
    LCTL_WATCH_HIPFIRE_CACHE_RAM=12884901888 \
    LCTL_WATCH_HIPFIRE_CACHE_DISK=34359738368 \
    LCTL_WATCH_HIPFIRE_CACHE_DIR="$TMP/w2-cache" \
    python3 "$troot/engines/hipfire/tpl/python/watch_tui.py" 2>&1); rc=$?
  [ "$rc" = 0 ] || { echo "DBG-w2cache rc=$rc: $(tail -3 <<<"$out")" >&2; return 1; }
  e1=$(grep ' \[движок\] ' <<<"$out" | sed -n 1p)
  printf '%s' "$e1" | grep -qF 'кэш-ram 12.0 GiB (бюджет)' || return 1
  printf '%s' "$e1" | grep -qF 'кэш-диск 3.2 / 32.0 GiB (бюджет)' || return 1
  return 0
}

# the section registration (the runner calls by the ADAPTER_FUNCS list)
ADAPTER_FUNCS+=" hipfire_scenarios"
hipfire_scenarios() {
  if scen_a_registry; then ok "A1: реестр/алиасы — resolve_profile канон+отказ, PROFILE_DEFAULT, поля формата"; else bad "A1 реестр/алиасы"; fi
  if scen_a_health; then ok "A2: health-диалект — ok→healthy, loading_model→не здоров, мусор→1"; else bad "A2 health-диалект"; fi
  if scen_a_smoke; then ok "A3: engine_smoke — 5 запросов core_smoke (3 текста + стрим + tools, fix:w42) через faux curl, SMOKE: OK"; else bad "A3 смоук"; fi
  if scen_a_smoke_vision; then ok "A3v: смоук-vision гейт — vision.hfq в сете → 6-й запрос с image_url, SMOKE: OK (fix:w43)"; else bad "A3v смоук-vision"; fi
  if scen_a_smoke_novision; then ok "A3n: смоук без башни — image_url НЕТ (текстовый профиль не удорожается, fix:w43; на этом сценарии стоит мутация w43)"; else bad "A3n смоук-novision"; fi
  if scen_a_apply_profile; then ok "A4: engine_apply_profile 27b-parallel — cfgset dflash/slots/ctx/vmm в журнале, rc 0"; else bad "A4 apply_profile"; fi
  if scen_a_route; then ok "A5: engine_check_route 27b-parallel — строка «роут: multi_slot»"; else bad "A5 роут"; fi
  if scen_a_status_lines; then ok "A6: статусные строки — hline (health/модель/слоты) и JSON (profile/autostart)"; else bad "A6 статусные строки"; fi
  if scen_a_compose; then ok "A7: engine_write_compose — golden'ы с name: hipfire + DFlash-wiring в compose.local.yml; контракт этапа 8: с target-каталогом тройка пишется туда, без аргумента — прежнее место; OPS1: ports-строка на каноне LCTL_BIND (дефолт 0.0.0.0, HIPFIRE_BIND удалён), .env несёт LCTL_BIND"; else bad "A7 compose-файлы"; fi
  if scen_a_bench_extras; then ok "A8: engine_bench_extras (этап 7) — τ=13.18 из логов в JSON tau_s, ROUTE_SPEC, нет tau → null"; else bad "A8 bench-extras"; fi
  if scen_w2_panel; then ok "W2: hipfire-панель watch — ENGINE_WATCH_TUI существует (adapter.sh + файл + engine_watch_env-хук), selfcheck каркас 94/94 + движок ${W2_CNT:-?} на фикстурах (health/stats/metrics, « | »-парсер, scheme v2 W3.3: активное окно — ген-средн lat−ttft, mean-of-rates prefill, ttft dual, τ-окно, done-line ген-посл + done-parse, hold-семантика Δcount-гейтов, slot-branch e1, draft-агрегат, бюджеты, dead/пустой контейнер)"; else bad "W2 selfcheck панели"; fi
  if scen_w2_plain; then ok "W2: plain-стрим W3.2 — 3 тика: [движок] (аптайм 52 мин из /stats, mtp K=7, ctx 1 × 262 144 ток (лента 4), q8 (vmm), бюджеты «—», lost скрыт), [метрики] общий блок (ген —→1.7 и prefill-средн —→1.1: заморозки W3.2.2/W3.2.4 — тип 1 «—», тип 2 пересчёт при работе, тип 3 держит; prefill-посл: активный >0 → тихий держит; кэш 9.0k из 12.0k (75.0 %), τ 4.9 ток/цикл, оч 0 из 4, ttft 0.24 с, сген 5.0k), live-пульс +300/+500, done-пульс drafts +10 цикл/тик, логи с -t (штамп срезан), «?» нет; мёртвый /stats → dead-line ×2; мёртвый /metrics → метрики «—», оч «0 запросов»"; else bad "W2 plain-стрим W3.2"; fi
  if scen_w2_cache_env; then ok "W2-cache-env (W3.2.1 п.5): env-шов адаптера — бюджеты кэша из конфига (stub RAM/DISK, как доводит engine_watch_env из config.toml) + used диска СКАНОМ каталога-фикстуры (sparse 3.2 GiB st_size + подкаталог): «кэш-ram 12.0 GiB (бюджет)», «кэш-диск 3.2 / 32.0 GiB (бюджет)»; без ключей — «—» (W2-plain)"; else bad "W2 cache-env бюджеты"; fi
}
