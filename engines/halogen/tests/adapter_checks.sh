# shellcheck shell=bash
# adapter_checks.sh — llmctl battery's halogen section (sourced by the
# tests/run_checks.sh runner; registers halogen_scenarios in
# ADAPTER_FUNCS). The halogen-dialect faux curl — a SEPARATE $FAUX_HAL dir
# (the FAUX_GUFO pattern): /health → JSON (engine_version/vision),
# /v1/models → the modalities, /slots → 2×262144, chat-completions → the
# model echo + SSE on stream:true (the core_smoke seams). The scenarios:
# the registry/pins (H1), the delivery (H2), the vision-on/off compose
# render (H3), the env render (H4), the health dialect/statuses (H5), the
# 5/6-request smoke (H6).

# the halogen-dialect faux curl — the $FAUX_HAL dir (see the header)
FAUX_HAL="$TMP/faux-hal"; mkdir -p "$FAUX_HAL"
for b in "$FAUX_FULL"/*; do ln -sf "$b" "$FAUX_HAL/$(basename "$b")" 2>/dev/null || true; done
cp "$ROOT/engines/halogen/tests/shims/curl" "$FAUX_HAL/curl"
chmod +x "$FAUX_HAL/curl"

# ── H1: the registry/pins — one profile, the aliases, the fields 1-9, the ladder, the pin sums ──
scen_h1_registry() {
  local out
  out=$(LCTL_TEST_ENGINE=halogen hf 'echo "$(resolve_profile flash-single)/$(resolve_profile solo)/$(resolve_profile flash)"') || return 1
  [ "$out" = "flash/flash/flash" ] || return 1
  LCTL_TEST_ENGINE=halogen hf 'resolve_profile nope' >/dev/null 2>&1 && return 1   # неизвестный — rc 1
  out=$(LCTL_TEST_ENGINE=halogen hf 'echo "$PROFILE_DEFAULT|$PROFILE_LIST"') || return 1
  [ "$out" = "flash|flash" ] || return 1
  # the registry fields: 1 main, 4 the 110 gate, 6 sessions=KV_SLOTS, 7 ctx, 8 the cache tiers, 9 '-' (an env config)
  out=$(LCTL_TEST_ENGINE=halogen hf 'echo "$(profile_field flash 1)|$(profile_field flash 3)|$(profile_field flash 4)|$(profile_field flash 6)|$(profile_field flash 7)|$(profile_field flash 8)|$(profile_field flash 9)"') || return 1
  [ "$out" = "qwen38-flash-next-v2.hgn|qwen38-flash-next-drafter-r2-ht4.hgn|110|4|262144|0/68719476736|-" ] || return 1
  # field 2 — exactly 10 files (4 weights + 6 tokenizer), ladder '-', the ref not taken
  out=$(LCTL_TEST_ENGINE=halogen hf 'echo "$(profile_field flash 2 | wc -w)|$(profile_ladder flash)|$(ref_get flash session)"') || return 1
  [ "$out" = "10|-|17.69" ] || return 1   # refs сняты 2026-11-26 (agent-check живьём)
  # the model set is isolated from the gufo sets
  out=$(LCTL_TEST_ENGINE=halogen hf 'echo "$(engine_model_set flash)"') || return 1
  [ "$out" = "halogen_flash" ] || return 1
  # the API model canon — an adapter constant (the agent's card does not change)
  out=$(LCTL_TEST_ENGINE=halogen hf 'echo "$HALOGEN_MODEL_CANON"') || return 1
  [ "$out" = "qwen3.8-flash-next" ] || return 1
  # the pins: an int size, a 64-hex sha, the extended-set roles; the set's
  # sum — a carry trap: 120 297 030 276 B (4 weights + 6 tokenizer, HF
  # 2026-11-25)
  out=$(LCTL_TEST_ENGINE=halogen hf 'weights_for halogen_flash | awk -F"|" "{s+=\$2} END{printf \"%.0f\", s+0}"') || return 1
  [ "$out" = "120297030276" ] || return 1
  LCTL_TEST_ENGINE=halogen hf 'weights_for halogen_flash | awk -F"|" "{ if (\$2 !~ /^[0-9]+\$/ || \$3 !~ /^[0-9a-f]{64}\$/ || \$5 !~ /^(main|draft|mmproj|ngram|tokenizer)\$/) exit 1 }" || exit 1' >/dev/null 2>&1 || return 1
  # the roles: exactly one main (v2), exactly one mmproj, draft = drafter-r2-ht4
  out=$(LCTL_TEST_ENGINE=halogen hf 'echo "$(set_file_role halogen_flash main)|$(set_file_role halogen_flash draft)|$(set_file_role halogen_flash mmproj)"') || return 1
  [ "$out" = "qwen38-flash-next-v2.hgn|qwen38-flash-next-drafter-r2-ht4.hgn|qwen38-flash-next-vision.hgn" ] || return 1
  # the contract globals: the image pin = the version (not latest), a fail-pattern set
  out=$(LCTL_TEST_ENGINE=halogen hf 'echo "$ENGINE_VERSION|$ENGINE_IMAGE|$ENGINE_HEALTH_PATH|$ENGINE_FAIL_PATTERN"') || return 1
  [ "$out" = "0.20.7|ghcr.io/peonist-ai/halogen-flash-server:0.20.7|/health|fatal|refusing" ] || return 1
  return 0
}

# ── H2: the delivery — a file:// sha PASS, a SKIP by size, the tokenizer/ dirname,
#     an unknown pull → die; a SHA-MISMATCH with removal ──────────────────────
scen_h2_pins_download() {
  new_stack h2pins; fresh_log   # свой стек: не наследуем LCTL_TEST_STACK чужих сценариев (G18 и др.)
  local d="$TMP/hpins" out rc
  rm -rf "$d"; mkdir -p "$d"
  local src="$d/src.bin"; printf 'halogen-pin-bytes' > "$src"
  local sha; sha=$(sha256sum "$src" | awk '{print $1}')
  LCTL_TEST_ENGINE=halogen MODELS_DIR="$d" hf "download_file \"file://$src\" \"$d/tok/pin.bin\" \$(stat -c %s \"$src\") $sha" >/dev/null 2>&1 || return 1
  cmp -s "$d/tok/pin.bin" "$src" || return 1            # dirname (tok/) создан pre-flight'ом
  out=$(LCTL_TEST_ENGINE=halogen MODELS_DIR="$d" hf "download_file \"file://$src\" \"$d/tok/pin.bin\" \$(stat -c %s \"$src\") $sha" 2>&1) || return 1
  grep -qF 'SKIP: pin.bin' <<<"$out" || return 1          # SKIP по размеру — без сети
  local badsha; badsha="0000000000000000000000000000000000000000000000000000000000000000"
  LCTL_TEST_ENGINE=halogen MODELS_DIR="$d" hf "download_file \"file://$src\" \"$d/bad.bin\" 6 $badsha" >/dev/null 2>&1 && return 1
  [ ! -f "$d/bad.bin" ] || return 1                       # SHA-MISMATCH → файл удалён
  # a pull by name (the halogen_flash table) with a file:// mirror — fully
  #   offline: mirror-first substitutes the basename → the local
  #   chat_template.jinja fixture (the HF sha), the file lands in
  #   MODELS_DIR/tokenizer/; a PASS (sha OK)
  rm -rf "$d"; mkdir -p "$d/mirror" "$d/models"
  cp "$ROOT/engines/halogen/tests/fixtures/tokenizer_chat_template.jinja" "$d/mirror/chat_template.jinja"
  out=$(LCTL_TEST_ENGINE=halogen MODELS_DIR="$d/models" LCTL_MIRROR_BASE="file://$d/mirror" \
    hf 'engine_pull_model tokenizer/chat_template.jinja' 2>&1); rc=$?
  [ "$rc" = 0 ] && grep -qF 'PASS: chat_template.jinja (sha OK)' <<<"$out" \
    && cmp -s "$LCTL_TEST_STACK/.data/halogen/models/halogen_flash/tokenizer/chat_template.jinja" "$ROOT/engines/halogen/tests/fixtures/tokenizer_chat_template.jinja" || return 1
  # the 51.2G pin (ngram) — the pre-flight «мало места» BEFORE the traffic
  # (the pin resolved; curl was not called: the TMP disk is always < 51G)
  fresh_log
  out=$(LCTL_TEST_ENGINE=halogen MODELS_DIR="$d/models" hf 'engine_pull_model qwen38-flash-next-ngram.hgn' 2>&1); rc=$?
  [ "$rc" = 1 ] && grep -q 'мало места' <<<"$out" || return 1
  ! grep -q '^curl' "$FAUXLOG" || return 1
  # an unknown name → die
  LCTL_TEST_ENGINE=halogen MODELS_DIR="$d/models" hf 'engine_pull_model net-takogo.hgn' >/dev/null 2>&1 && return 1
  return 0
}

# ── H3: the compose render — the golden with env, the vision off/on (a file on disk),
#     the determinism, the target dir (the stage-8 contract) ─────────────────
scen_h3_compose() {
  local out
  new_stack h3; fresh_log
  # vision off: the sidecar not downloaded → an empty VISION_TOWER (a text-only raise)
  out=$(LCTL_TEST_ENGINE=halogen hf 'set_models_dir flash; halogen_render_compose flash; cat "$STACK_DIR/compose.yml"' 2>&1) || return 1
  printf '%s' "$out" | grep -qF 'name: halogen' || return 1
  printf '%s' "$out" | grep -qF 'ghcr.io/peonist-ai/halogen-flash-server:0.20.7' || return 1
  printf '%s' "$out" | grep -qF 'HALOGEN_API_PORT: "11435"' || return 1   # fix:halogen-api-port — фронт внутри = внешнему (иначе health ведёт в пустоту)
  printf '%s' "$out" | grep -qF 'HALOGEN_CHECKPOINT: "/models/qwen38-flash-next-v2.hgn"' || return 1
  printf '%s' "$out" | grep -qF 'HALOGEN_MODEL_ID: "qwen3.8-flash-next"' || return 1
  printf '%s' "$out" | grep -qF 'HALOGEN_KV_SLOTS: "4"' || return 1
  printf '%s' "$out" | grep -qF 'HALOGEN_VISION_TOWER: ""' || return 1
  printf '%s' "$out" | grep -qF '__BIND__:__PORT__:__PORT__' && return 1   # плейсхолдер не раскрыт → die-ветка не прошла
  printf '%s' "$out" | grep -qF '11435:11435' || return 1
  printf '%s' "$out" | grep -qF '/models:ro' || return 1
  # determinism: a re-render is byte-for-byte (the hook takes a DIR — stage 8)
  mkdir -p "$TMP/h3-t1" "$TMP/h3-t2"
  LCTL_TEST_ENGINE=halogen LCTL_FAUX_TMP="$TMP" hf 'halogen_render_compose flash "$LCTL_FAUX_TMP/h3-t1"' >/dev/null 2>&1 || return 1
  LCTL_TEST_ENGINE=halogen LCTL_FAUX_TMP="$TMP" hf 'halogen_render_compose flash "$LCTL_FAUX_TMP/h3-t2"' >/dev/null 2>&1 || return 1
  cmp -s "$TMP/h3-t1/compose.yml" "$TMP/h3-t2/compose.yml" || return 1
  # vision on: the sidecar on disk → VISION_TOWER "1"; the engine_write_compose target dir
  mkdir -p "$TMP/h3-target"
  out=$(LCTL_TEST_ENGINE=halogen LCTL_FAUX_TMP="$TMP" hf 'set_models_dir flash; : > "$MODELS_DIR/qwen38-flash-next-vision.hgn"; engine_write_compose "$LCTL_FAUX_TMP/h3-target"; cat "$LCTL_FAUX_TMP/h3-target/compose.yml"' 2>&1) || return 1
  printf '%s' "$out" | grep -qF 'HALOGEN_VISION_TOWER: "1"' || return 1
  return 0
}

# ── H4: the env render — the core LCTL_* canon + the HALOGEN_* display ───────
scen_h4_env() {
  new_stack h4; fresh_log
  local out
  out=$(LCTL_TEST_ENGINE=halogen hf 'set_models_dir flash; write_env flash qwen38-flash-next-v2.hgn; cat "$STACK_DIR/.env"' 2>&1) || return 1
  printf '%s' "$out" | grep -qF 'LCTL_ENGINE=halogen' || return 1
  printf '%s' "$out" | grep -qF 'LCTL_PROFILE=flash' || return 1
  printf '%s' "$out" | grep -qF 'LCTL_MODEL=qwen38-flash-next-v2.hgn' || return 1
  printf '%s' "$out" | grep -qF 'HALOGEN_MODELS=' || return 1
  printf '%s' "$out" | grep -qF 'HALOGEN_IMAGE=ghcr.io/peonist-ai/halogen-flash-server:0.20.7' || return 1
  return 0
}

# ── H5: the health dialect — engine_health_ok, route-info, the status lines ──
scen_h5_health() {
  local out rc
  # engine_health_ok: a non-empty body — ok, empty — a refusal (curl -f has already filtered the 5xx)
  LCTL_TEST_ENGINE=halogen hf 'printf "{\"status\":\"ok\"}" | engine_health_ok' >/dev/null 2>&1 || return 1
  LCTL_TEST_ENGINE=halogen hf 'printf "" | engine_health_ok' >/dev/null 2>&1 && return 1
  # route-info: the JSON /health + /v1/models + /slots → a line with the version/slots/ctx/vision
  out=$(LCTL_TEST_ENGINE=halogen LCTL_TEST_PATH="$FAUX_HAL:$PATH" hf 'halogen_route_info' 2>&1) || return 1
  printf '%s' "$out" | grep -qF 'роут: halogen 0.20.7, slots 2, ctx 262144, vision on, вход: text,image' || return 1
  # a nested version (the live /health 0.20.7: version.engine) — not a dict-repr in the line
  printf '{"status":"ok","version":{"api":"0.20.7","engine":"0.20.7"},"vision":{"enabled":true}}' > "$TMP/hal-health-nested.json"
  LCTL_FAUX_HAL_HEALTH_BODY="$TMP/hal-health-nested.json" \
    out=$(LCTL_TEST_ENGINE=halogen LCTL_TEST_PATH="$FAUX_HAL:$PATH" hf 'halogen_route_info' 2>&1) || return 1
  printf '%s' "$out" | grep -qF 'роут: halogen 0.20.7,' || return 1
  printf '%s' "$out" | grep -qF "'api'" && return 1   # dict-repr не просочился
  # engine_check_route: printing without die
  out=$(LCTL_TEST_ENGINE=halogen LCTL_TEST_PATH="$FAUX_HAL:$PATH" hf 'engine_check_route flash' 2>&1) || return 1
  printf '%s' "$out" | grep -qF 'роут: halogen 0.20.7' || return 1
  # the server not answering → a warn, not die
  out=$(LCTL_TEST_ENGINE=halogen LCTL_FAUX_CURL_FAILALL=1 LCTL_TEST_PATH="$FAUX_HAL:$PATH" hf 'engine_check_route flash' 2>&1); rc=$?
  [ "$rc" = 0 ] && printf '%s' "$out" | grep -qF 'роут недоступен' || return 1
  # the status line + JSON
  new_stack h5; fresh_log
  mkdir -p "$LCTL_TEST_STACK/.data/halogen/profiles/flash"
  out=$(LCTL_TEST_ENGINE=halogen LCTL_TEST_PATH="$FAUX_HAL:$PATH" hf 'engine_status_health' 2>&1) || return 1
  printf '%s' "$out" | grep -qF 'health: ok | профиль: flash |' || return 1
  out=$(LCTL_TEST_ENGINE=halogen LCTL_TEST_PATH="$FAUX_HAL:$PATH" \
    PROFILE="flash" AUTO="enabled" WDOG="disabled" hf 'engine_status_json' 2>&1) || return 1
  printf '%s' "$out" | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d["engine"] == "halogen", d
assert d["profile"] == "flash", d
assert d["health"] == "ok", d
assert d["route"]["model"] == "qwen3.8-flash-next", d
assert d["route"]["slots"] == 2, d
assert d["route"]["context"] == 262144, d
assert d["autostart"] is True, d' || return 1
  return 0
}

# ── H6: the smoke — the model from the canon (not the log), the vision off → 5 requests,
#     the vision on (a sidecar on disk) → the 6th with image_url, SMOKE: OK ──
scen_h6_smoke() {
  local out rc n
  # vision off: the sidecar not downloaded — exactly 5 core_smoke requests (the fix:w42 pattern)
  new_stack h6off; fresh_log
  out=$(LCTL_TEST_ENGINE=halogen LCTL_SMOKE_RETRY_S=0 LCTL_TEST_PATH="$FAUX_HAL:$PATH" \
    hf 'set_models_dir flash; engine_smoke' 2>&1); rc=$?
  [ "$rc" = 0 ] && printf '%s' "$out" | grep -q 'SMOKE: OK' || return 1
  n=$(grep -c 'chat/completions' "$FAUXLOG")
  [ "$n" = 5 ] || return 1
  # the reasoning dialect: core_smoke carries none (ENGINE_SMOKE_REASONING), not off
  grep -qF '"reasoning_effort":"none"' "$FAUXLOG" || return 1
  ! grep -qF '"reasoning_effort":"off"' "$FAUXLOG" || return 1
  # the canon echo: the faux answers with the payload's model — the smoke validator cross-checked it
  grep -q '"model":"qwen3.8-flash-next"' "$FAUXLOG" || return 1
  # vision on: the sidecar on disk — the 6th request with image_url
  new_stack h6on; fresh_log
  out=$(LCTL_TEST_ENGINE=halogen LCTL_SMOKE_RETRY_S=0 LCTL_TEST_PATH="$FAUX_HAL:$PATH" \
    hf 'set_models_dir flash; : > "$MODELS_DIR/qwen38-flash-next-vision.hgn"; engine_smoke' 2>&1); rc=$?
  [ "$rc" = 0 ] \
    && printf '%s' "$out" | grep -q 'SMOKE: OK' \
    && grep -q 'image_url' "$FAUXLOG" \
    && [ "$(grep -c 'chat/completions' "$FAUXLOG")" = 6 ]
}

# ── B1/B2 (Ф3): the bench hooks — the model from the canon; the extras — a /metrics snapshot ─
scen_h7_bench() {
  local out
  # bench_model: the canon constant (halogen has no load_completed in its log)
  out=$(LCTL_TEST_ENGINE=halogen hf 'engine_bench_model') || return 1
  [ "$out" = "qwen3.8-flash-next" ] || return 1
  # bench_extras: a /metrics snapshot + the ROUTE_* → JSON with the derivatives
  new_stack h7b; fresh_log
  out=$(LCTL_TEST_ENGINE=halogen LCTL_TEST_PATH="$FAUX_HAL:$PATH" \
    hf 'engine_bench_extras "$LCTL_FAUX_TMP"' 2>&1) || return 1
  printf '%s\n' "$out" | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d["route_spec"] == "halogen 0.20.7", d
assert d["slots"] == 2 and d["context"] == 262144, d
assert d["requests_total"] == 42, d
assert d["cache_hits_total"] == 30 and d["cache_misses_total"] == 10, d
assert d["cache_hit_pct"] == 75.0, d
assert d["draft_accept_pct"] == 80.0, d
assert d["kv_reserved_pct"] == 25.0, d
assert d["cache_disk_budget_bytes"] == 68719476736, d
assert "кумулятивные" in d["metrics_note"], d' || return 1
  grep -q '/metrics' "$FAUXLOG" || return 1
  return 0
}

# ── D1 (Ф3): doctor — the inventory, the honest .hgn types, the prompt cache, the gpu-lock ──
scen_h8_doctor() {
  local out d
  new_stack h8d; fresh_log
  d="$LCTL_TEST_STACK/.data/halogen/models/halogen_flash"
  mkdir -p "$d/tokenizer"
  cp "$ROOT/engines/halogen/tests/fixtures/tokenizer_chat_template.jinja" "$d/tokenizer/chat_template.jinja"
  out=$(LCTL_TEST_ENGINE=halogen LCTL_TEST_PATH="$FAUX_HAL:$PATH" hf 'engine_doctor' 2>&1) || return 1
  printf '%s' "$out" | grep -qF 'веса (сет halogen_flash): инвентарь' || return 1
  printf '%s' "$out" | grep -qF 'есть, размер OK, sha OK' || return 1          # честный sha (фикстура = пин-размер)
  printf '%s' "$out" | grep -qF 'НЕТ (тяни: lctl pull halogen flash)' || return 1
  printf '%s' "$out" | grep -qF 'типы не проверяются: формат .hgn закрытый' || return 1
  printf '%s' "$out" | grep -qF 'prompt-cache: entries 2 | RAM 114 MB | диск 1.0 / 64.0 GiB | hits 30 / misses 10' || return 1
  printf '%s' "$out" | grep -qF 'kv/очередь: reserved 131072 / 524288 позиций' || return 1
  printf '%s' "$out" | grep -qF 'gpu-lock' || return 1
  # an empty set — «весов нет» without die
  out=$(LCTL_TEST_ENGINE=halogen LCTL_MODELS="$TMP/h8empty" LCTL_TEST_PATH="$FAUX_HAL:$PATH" \
    hf 'set_models_dir flash; engine_doctor' 2>&1) || return 1
  printf '%s' "$out" | grep -qF '(весов нет — проверка типов пропущена)' || return 1
  return 0
}

# ── W1h (Ф3b): the watch panel — a plain stream on the fixtures, dead, the selfcheck, ─
#     a run through the real dispatcher
LOGHAL="$TMP/glog-hal-tz"
cp "$ROOT/engines/halogen/tests/fixtures/glog-hal-tz.txt" "$LOGHAL"   # printf'ом нельзя — в логе есть «%»
M1="$ROOT/engines/halogen/tests/fixtures/hal-metrics-1.txt"
M2="$ROOT/engines/halogen/tests/fixtures/hal-metrics-2.txt"
HALHEALTH="$ROOT/engines/halogen/tests/fixtures/hal-health.json"
HALCACHE="$ROOT/engines/halogen/tests/fixtures/hal-cache.json"

wrun_hal() {  # stdout+stderr наружу; env-префикс задан caller'ом
  env PATH="$FAUX_HAL:$PATH" PYTHONPATH="$ROOT/core/tpl/python/watch" \
    LCTL_FAUX_LOG="$FAUXLOG" LCTL_FAUX_CNT="$FAUXCNT" LCTL_WATCH_CONTAINER=halogen \
    "$@" python3 "$ROOT/engines/halogen/tpl/python/watch.py" 2>&1
}

scen_w1h_plain() {
  new_stack w1h; fresh_log
  local out rc m1 m2
  out=$(wrun_hal LCTL_FAUX_HAL_HEALTH_BODY="$HALHEALTH" \
    LCTL_FAUX_HAL_CACHE_BODY="$HALCACHE" \
    LCTL_FAUX_METRICS_SEQ="$M1:$M2:$M2" LCTL_FAUX_PODMAN_LOGS="$LOGHAL" \
    LCTL_WATCH_PORT=8080 LCTL_WATCH_INTERVAL=0.01 LCTL_WATCH_TICKS=3); rc=$?
  printf '%s' "$out" > /tmp/w1h-plain.out; cat "$FAUXLOG" >> /tmp/w1h-plain.out
  [ "$rc" = 0 ] || { echo "DBG-w1h rc=$rc: $(tail -3 <<<"$out")" >&2; return 1; }
  [ "$(grep -c '/metrics' "$FAUXLOG")" = 3 ] || return 1
  [ "$(grep -c '/health' "$FAUXLOG")" = 3 ] || return 1
  [ "$(grep -c '/cache' "$FAUXLOG")" = 1 ] || return 1   # резерв max_entries — 1 запрос на сессию (idle-лог без GET /cache)
  grep -q 'podman logs --tail 200 -t' "$FAUXLOG" || return 1   # сид С -t (W3.2.1-D1)
  grep -q 'podman logs -t halogen' "$FAUXLOG" || return 1   # _boot_merge: полный скан без лимита, редукция после (зеркало gufo w38)
  local e1=$(grep ' \[движок\] ' <<<"$out" | sed -n 1p)
  printf '%s' "$e1" | grep -q 'аптайм ' || return 1            # от первой -t-метки (пин по presence)
  printf '%s' "$e1" | grep -qF 'спек mtp+ngram K=7 | ctx 4 × 262 144 ток | kv bf16 (16 бит)' || return 1
  printf '%s' "$e1" | grep -qF 'кэш-ram 14 из 28 записей · 809 из ~1624 MB | кэш-диск 3.7 / 64.0 GiB' || return 1   # потолок из boot-строки (28×58 MiB)
  m1=$(grep ' \[метрики\] ' <<<"$out" | sed -n 1p)
  # tick1: (посл) already alive (a line in the log seed — the «new line»
  #     gate, not a hold); (средн) — a session, no base → «—»
  printf '%s' "$m1" | grep -qF 'ген — (средн) · 67.0 (посл) tok/s' || { printf '%s' "$out" > /tmp/w1h-plain.out; return 1; }
  printf '%s' "$m1" | grep -qF 'prefill — (средн) · 177.8 (посл) tok/s' || { printf '%s' "$out" > /tmp/w1h-plain.out; return 1; }
  printf '%s' "$m1" | grep -qF 'кэш 30.0k из 67.1k ток из кэша (44.7 %)' || { printf '%s' "$out" > /tmp/w1h-plain.out; return 1; }
  printf '%s' "$m1" | grep -qF 'спек принято 80.0 % · τ 2.3 ток/цикл' || { printf '%s' "$out" > /tmp/w1h-plain.out; return 1; }
  printf '%s' "$m1" | grep -qF 'ttft 1.00 с (средн) · — (окно)' || { printf '%s' "$out" > /tmp/w1h-plain.out; return 1; }
  printf '%s' "$m1" | grep -qF 'сген 1.6k ток · принято 67.1k' || { printf '%s' "$out" > /tmp/w1h-plain.out; return 1; }   # оба кумулятивы (gufo-семантика)
  printf '%s' "$m1" | grep -qF 'оч 0 из 4 запросов' || return 1
  m2=$(grep ' \[метрики\] ' <<<"$out" | sed -n 2p)
  # tick2: (средн) from the Δ counters (the calibration: = Δtokens/Δseconds)
  printf '%s' "$m2" | grep -qF 'ген 80.0 (средн) · 67.0 (посл) tok/s' || { printf '%s' "$out" > /tmp/w1h-plain.out; return 1; }   # Δ400/Δ5.0с
  printf '%s' "$m2" | grep -qF 'prefill 2000.0 (средн) · 177.8 (посл) tok/s' || { printf '%s' "$out" > /tmp/w1h-plain.out; return 1; }   # Δ16000/Δ8с
  printf '%s' "$m2" | grep -qF 'кэш 46.0k из 99.1k ток из кэша (46.4 %)' || { printf '%s' "$out" > /tmp/w1h-plain.out; return 1; }
  printf '%s' "$m2" | grep -qF 'принято 83.3 % · τ 2.3 ток/цикл' || { printf '%s' "$out" > /tmp/w1h-plain.out; return 1; }   # 2040/2450 кумулятив
  printf '%s' "$m2" | grep -qF 'ttft 1.64 с (средн) · 8.00 с (окно)' || { printf '%s' "$out" > /tmp/w1h-plain.out; return 1; }   # Δ8с/Δ1запр
  printf '%s' "$m2" | grep -qF 'сген 2.0k ток · принято 99.1k' || { printf '%s' "$out" > /tmp/w1h-plain.out; return 1; }
  printf '%s' "$m2" | grep -qF 'оч 1 из 4 запросов' || return 1
  grep -qF 'decode +400 · prefill +16000 (ток/тик) · drafts +400 (черн. ток/тик)' \
    <<<"$(grep ' \[скорость\] ' <<<"$out" | sed -n 2p)" || return 1   # Δaccepted/prompt/draft
  ! grep -q '?' <<<"$out" || return 1                        # инвариант W3: «?» не существует
  return 0
}

scen_w1h_dead() {
  new_stack w1hd; fresh_log
  local out rc
  out=$(wrun_hal LCTL_FAUX_CURL_FAILALL=1 \
    LCTL_WATCH_PORT=8080 LCTL_WATCH_INTERVAL=0.01 LCTL_WATCH_TICKS=3); rc=$?
  [ "$rc" = 0 ] || { printf '%s' "$out" > /tmp/w1h-dead.out; return 1; }
  [ "$(grep -c 'недоступен' <<<"$out")" = 3 ] || { printf '%s' "$out" > /tmp/w1h-dead.out; return 1; }   # ровно одна строка на тик
  [ "$(grep -c '/health' "$FAUXLOG")" = 3 ] || { printf '%s' "$out" > /tmp/w1h-dead.out; return 1; }   # тик = 1 curl (health-first)
  [ "$(grep -c '/metrics' "$FAUXLOG")" = 0 ] || { printf '%s' "$out" > /tmp/w1h-dead.out; return 1; }  # фейл-фаст: мёртвый health → /metrics не зовётся
  [ "$(grep -c '/cache' "$FAUXLOG")" = 0 ] || { printf '%s' "$out" > /tmp/w1h-dead.out; return 1; }
  ! grep -qi 'traceback' <<<"$out" || { printf '%s' "$out" > /tmp/w1h-dead.out; return 1; }
  return 0
}

scen_w1h_selfcheck() {
  local troot="${LCTL_TREE:-$ROOT}" out rc
  out=$(LCTL_WATCH_SELFCHECK=1 PYTHONPATH="$troot/core/tpl/python/watch" \
    timeout 120 python3 "$troot/engines/halogen/tpl/python/watch.py" 2>&1); rc=$?
  [ "$rc" = 0 ] \
    && printf '%s' "$out" | grep -q 'selfcheck: 104/104 ok' \
    && printf '%s' "$out" | grep -q 'selfcheck engine: 43/43 ok' || return 1
  return 0
}

scen_w1h_dispatcher() {
  new_stack w1disp; fresh_log
  local out rc
  out=$(env PATH="$FAUX_HAL:$PATH" HOME="$TMP/home" USER=tester \
    LCTL_DIR="$LCTL_TEST_STACK" LCTL_ENGINE=halogen \
    LCTL_FAUX_LOG="$FAUXLOG" LCTL_FAUX_CNT="$FAUXCNT" \
    LCTL_FAUX_PODMAN_LOGS="$LOGHAL" LCTL_FAUX_HAL_HEALTH_BODY="$HALHEALTH" \
    LCTL_FAUX_METRICS="$M1" \
    LCTL_WATCH_TICKS=1 \
    bash "$ROOT/lctl" watch --interval 1 2>&1); rc=$?
  [ "$rc" = 0 ] || { echo "DBG-w1hdisp rc=$rc: $(tail -4 <<<"$out")" >&2; return 1; }
  printf '%s' "$out" | grep -q ' \[движок\] ' || return 1
  return 0
}

# ── G3h (Ф3c): agent-check — cmp_ref, happy (the references not taken → WARNs), ──
#     fail (cache_n=0 → FAIL rc 1)
scen_g3h_cmp_ref() {
  local v
  v=$(LCTL_TEST_ENGINE=halogen hf 'cmp_ref "метка" "3.20" ""') || return 1
  [[ "$v" == 'WARN: метка 3.2s — референс не снят (EXP-007)' ]] || return 1
  v=$(LCTL_TEST_ENGINE=halogen hf 'cmp_ref "метка" "3.20" "3.00"') || return 1
  [[ "$v" == 'PASS: метка 3.2s (референс 3.0s)' ]] || return 1
  v=$(LCTL_TEST_ENGINE=halogen hf 'cmp_ref "метка" "4.50" "3.00" "проверь кэш"') || return 1
  [[ "$v" == 'WARN: метка 4.5s — регрессия >25% к 3.0s (проверь кэш)' ]] || return 1
  return 0
}

scen_g3h_agent() {
  new_stack g3hac1; fresh_log
  LCTL_TEST_ENGINE=halogen hf 'hf_up_locked' >/dev/null 2>&1 || return 1
  local out rc
  out=$(LCTL_TEST_ENGINE=halogen LCTL_SMOKE_RETRY_S=0 \
    LCTL_FAUX_CURL_CACHEN=42 LCTL_FAUX_PORTOPEN=1 LCTL_TEST_PATH="$FAUX_HAL:$PATH" \
    hf 'engine_agent_check' 2>&1); rc=$?
  [ "$rc" = 0 ] || { printf '%s\n' "$out" | tail -25 >&2; return 1; }
  printf '%s' "$out" | grep -q 'AGENT-CHECK: PASS=4 WARN=0 FAIL=0' || return 1   # refs flash сняты (2026-11-26) — фасадные walls 0.0 в окне ±25%
  printf '%s' "$out" | grep -q 'PASS: сессия 15 ходов' \
    && printf '%s' "$out" | grep -q 'PASS: follow-up 25k' \
    && printf '%s' "$out" | grep -q 'PASS: \[док 25k\] q2' \
    && printf '%s' "$out" | grep -q 'PASS: рестарт-restore' || return 1
  printf '%s' "$out" | grep -q 'restore: cache_n=42 — disk-restore работает' || return 1
  printf '%s' "$out" | grep -q 'рестарт-restore ПЕРЕЗАПУСКАЕТ контейнер' || return 1
  printf '%s' "$out" | grep -q 'CHECK followup k5=' && printf '%s' "$out" | grep -q 'CHECK docq q2=' || return 1
  [ "$(grep -c 'chat/completions' "$FAUXLOG")" = 25 ] || return 1   # stage1 24 + stage2 1
  [ ! -f "$LCTL_TEST_STACK/.data/halogen/logs/agent-check-restore.json" ] || return 1
  return 0
}

scen_g3h_agent_fail() {
  new_stack g3hac2; fresh_log
  LCTL_TEST_ENGINE=halogen hf 'hf_up_locked' >/dev/null 2>&1 || return 1
  local out rc
  out=$(LCTL_TEST_ENGINE=halogen LCTL_SMOKE_RETRY_S=0 \
    LCTL_FAUX_CURL_CACHEN=0 LCTL_FAUX_PORTOPEN=1 LCTL_TEST_PATH="$FAUX_HAL:$PATH" \
    hf 'engine_agent_check' 2>&1); rc=$?
  [ "$rc" = 1 ] || { printf '%s\n' "$out" | tail -8 >&2; return 1; }
  printf '%s' "$out" | grep -q 'AGENT-CHECK: PASS=4 WARN=0 FAIL=1' || return 1
  printf '%s' "$out" | grep -q 'FAIL: disk-restore не сработал (cache_n=0)' || return 1
  return 0
}

# the section registration (the runner calls by the ADAPTER_FUNCS list)
ADAPTER_FUNCS+=" halogen_scenarios"
halogen_scenarios() {
  # on LCTL_HDBG=1 a failed scenario is re-run with an output tail (stderr)
  local _d=${LCTL_HDBG:-}
  if scen_h1_registry; then ok "H1: реестр halogen — профиль один (flash), алиасы, поля 1-9 (гейт 110, KV_SLOTS 4, ctx 262144, поле 9 '-'), 10 файлов поля 2, канон qwen3.8-flash-next, пины (сумма 120297030276), пин образа = 0.20.7"; else bad "H1 реестр/пины"; [ -n "$_d" ] && scen_h1_registry 2>&1 | tail -20 >&2; fi
  if scen_h2_pins_download; then ok "H2: доставка — file:// PASS sha, SKIP по размеру, tokenizer/ dirname pre-flight'ом, SHA-MISMATCH с удалением, pull по имени (unknown → die)"; else bad "H2 доставка"; [ -n "$_d" ] && scen_h2_pins_download 2>&1 | tail -15 >&2; fi
  if scen_h3_compose; then ok "H3: compose-золотой — name: halogen, env-литералы (CHECKPOINT/MODEL_ID/KV_SLOTS), порт 11435:11435, /models:ro, vision off→пусто/on→\"1\" (файл на диске), детерминизм, target-каталог (этап 8)"; else bad "H3 compose-рендер"; [ -n "$_d" ] && scen_h3_compose 2>&1 | tail -15 >&2; fi
  if scen_h4_env; then ok "H4: env-рендер — LCTL_* канон + HALOGEN_* display (MODELS/IMAGE)"; else bad "H4 env"; fi
  if scen_h5_health; then ok "H5: health-диалект — engine_health_ok (пустое тело = отказ), route-info из /health+/v1/models+/slots (версия/slots/ctx/vision/модальности), не-ответ → warn, hline+JSON"; else bad "H5 health"; [ -n "$_d" ] && scen_h5_health 2>&1 | tail -25 >&2; fi
  if scen_h6_smoke; then ok "H6: смоук — модель из канона (HALOGEN_MODEL_ID эхо), vision off → 5 запросов, vision on → 6-й с image_url (parity w43), SMOKE: OK"; else bad "H6 смоук"; fi
  if scen_h7_bench; then ok "B1/B2 (Ф3): bench — модель из канона-константы; extras — /metrics снапшот + ROUTE_* с производными (cache 75.0, draft 80.0, kv 25.0), curl в журнале"; else bad "B1/B2 bench"; [ -n "$_d" ] && scen_h7_bench 2>&1 | tail -20 >&2; fi
  if scen_h8_doctor; then ok "D1 (Ф3): doctor — sha-инвентарь (PASS/НЕТ), честные типы .hgn, prompt-cache live (/metrics: entries/RAM/диск 1.0/64.0/hits), kv/очередь, gpu-lock, пустой сет без die"; else bad "D1 doctor"; [ -n "$_d" ] && scen_h8_doctor 2>&1 | tail -20 >&2; fi
  if scen_w1h_plain; then ok "W1h (Ф3b, калибровка): панель plain ×3 тика — движок (mtp+ngram K=7, кэш-ram N из 28 записей·резерв из /cache 1 раз на сессию, гейджи из /metrics), метрики тик1 (посл) живые из req-строки (ген 67.0/префилл 177.8/τ 2.3/кэш 44.7 %/ttft кумулятив 1.00с), тик2 (средн) из Δ-счётчиков (80.0/2000.0/кэш 46.4 %/ttft окно 8.00с/сген 400), пульсы decode+400/prefill+16000/drafts+400 (черн. ток/тик), «?» нет"; else bad "W1h plain"; [ -n "$_d" ] && scen_w1h_plain 2>&1 | tail -20 >&2; fi
  if scen_w1h_dead; then ok "W1h dead — ровно 3 строки «недоступен», без traceback"; else bad "W1h dead"; fi
  if scen_w1h_selfcheck; then ok "W1h selfcheck — каркас 104/104 + движковая 43/43"; else bad "W1h selfcheck"; fi
  if scen_w1h_dispatcher; then ok "W1h диспетчер — lctl watch exec'ает панель (ENGINE_WATCH_TUI, engine_watch_env → PYTHONPATH каркаса), стрим rc 0"; else bad "W1h диспетчер"; [ -n "$_d" ] && scen_w1h_dispatcher 2>&1 | tail -12 >&2; fi
  if scen_g3h_cmp_ref; then ok "G3h (Ф3c): cmp_ref halogen — неснятый референс → WARN, окно ±25% → PASS, регрессия → WARN+hint"; else bad "G3h cmp_ref"; fi
  if scen_g3h_agent; then ok "G3h agent-check happy — 25 chat-POST (stage1 24 + stage2 1), refs flash → PASS=4 WARN=0 FAIL=0 rc 0, state-файл удалён, cache_n-вердикт restore"; else bad "G3h agent"; [ -n "$_d" ] && scen_g3h_agent 2>&1 | tail -20 >&2; fi
  if scen_g3h_agent_fail; then ok "G3h agent-check fail — cache_n=0 → FAIL-строка, rc 1"; else bad "G3h agent-fail"; [ -n "$_d" ] && scen_g3h_agent_fail 2>&1 | tail -12 >&2; fi
}
