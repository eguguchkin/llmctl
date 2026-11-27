# shellcheck shell=bash
# adapter_checks.sh — llmctl battery's gufo section (sourced by the
# tests/run_checks.sh runner; the engines/*/ order does not matter: the
# gufo faux curl lives in a SEPARATE $FAUX_GUFO dir — symlinks to
# $FAUX_FULL + its own curl superset; the scenarios call it via
# LCTL_TEST_PATH="$FAUX_GUFO:$PATH", the hipfire FAUX_FULL is not
# clobbered). The gufo curl — a SUPERSET of the hipfire dialect: /health →
# the hipfire ok-JSON, /ready → rc 0, /metrics → fixtures/SEQ,
# chat-completions → content-JSON (+TIMINGS/reuse/EMPTYN — the
# agent-check/smoke seams). The adapter scenarios: the 9-field registry/
# aliases/pins (G0), compose+serve_args+the probe ladder (G1), the health
# dialect+doctor (G2), agent-check+switch (G3), the watch stream (W1) —
# the task 3.1 §4 contracts.

# the gufo-dialect faux curl — the $FAUX_GUFO dir (see the header)
FAUX_GUFO="$TMP/faux-gufo"; mkdir -p "$FAUX_GUFO"
for b in "$FAUX_FULL"/*; do ln -sf "$b" "$FAUX_GUFO/$(basename "$b")"; done
cp "$ROOT/engines/gufo/tests/shims/curl" "$FAUX_GUFO/curl"
chmod +x "$FAUX_GUFO/curl"

# ── the engine fixture logs (the IX/FX windows format: event=load_completed …) ─
GLOGOK="$TMP/glog-ok"
printf 'event=listening address=http://0.0.0.0:8080\nspeculative=dflash2 draft ready\n' > "$GLOGOK"
printf 'event=load_completed speculative=dflash2 sessions=1 context_tokens=262144 model=qwen3.8-27b-IQ4_XS-pure\n' >> "$GLOGOK"
GLOG1638="$TMP/glog-1638"    # успешная ступень 163840 (сверка заказа с фактом)
printf 'event=load_completed speculative=dflash2 sessions=2 context_tokens=163840 model=qwen3.8-27b-IQ4_XS-pure\n' > "$GLOG1638"
GLOG196="$TMP/glog-196"
printf 'event=load_completed speculative=dflash2 sessions=2 context_tokens=196608 model=qwen3.8-27b-IQ4_XS-pure\n' > "$GLOG196"
GLOGFAIL="$TMP/glog-fail"    # отказ ступени (load_failed → ранний выход probe)
printf 'event=listening address=http://0.0.0.0:8080\nmodel load error: OOM\n event=load_failed reason=oom\n' > "$GLOGFAIL"
# 2.1-F3 (EXP-005 live): a name WITH SPACES in the middle of a load_completed line
GLOGSP="$TMP/glog-spaces"
printf 'event=listening address=http://0.0.0.0:8080\n' > "$GLOGSP"
printf '2026-11-17 [INFO] [loader] event=load_completed kind=text elapsed_ms=97399 monotonic_us=622886939311 model=Qwen3.8 Flash Next sessions=2 context_tokens=262144 speculative=mtp draft_limit=7 disk_cache=enabled rss_mib=2648\n' >> "$GLOGSP"
GLOGCONF="$TMP/glog-conf"    # configured-строка (doctor/статус)
printf '2026-11-18 07:27:02 [INFO] [cache] schema=component-cache-v1 event=configured sessions=1 ram_cache=on capacity_bytes=12884901888 automatic_bytes=4294967296 disk_capacity_bytes=68719476736\n' > "$GLOGCONF"

# ── the adapter scenarios (return 0 = all the asserts hold) ─────────────────

# G0-registry: the fields 1–9 = the task 3.1 §1.1 literals; the resolve
# aliases (R1+gfctl legacy); the ladders; ref_get (EXP-007 verbatim); the
# default; the pin sums (OQ-3: flash = 111 334 654 778 B — catches a pin
# carry typo)
scen_g0_registry() {
  local out
  hf 'echo "$(resolve_profile 27b-single)/$(resolve_profile single)/$(resolve_profile 27b)"' >/dev/null 2>&1 || return 1
  out=$(LCTL_TEST_ENGINE=gufo hf 'echo "$(resolve_profile 27b-single)/$(resolve_profile 27b-multi)/$(resolve_profile multi)/$(resolve_profile flash-multi)/$(resolve_profile flash)"') || return 1
  [ "$out" = "27b/27b-parallel/27b-parallel/flash/flash" ] || return 1
  LCTL_TEST_ENGINE=gufo hf 'resolve_profile nope' >/dev/null 2>&1 && return 1   # неизвестный — rc 1
  out=$(LCTL_TEST_ENGINE=gufo hf 'echo "$PROFILE_DEFAULT"') || return 1
  [ "$out" = "27b" ] || return 1
  # 27b — all 9 fields (w43-vision: field 2 carries the mmproj, field 9 — @MMPROJ@)
  out=$(LCTL_TEST_ENGINE=gufo hf 'echo "$(profile_field 27b 1)|$(profile_field 27b 2)|$(profile_field 27b 3)|$(profile_field 27b 4)|$(profile_field 27b 5)|$(profile_field 27b 6)|$(profile_field 27b 7)|$(profile_field 27b 8)|$(profile_field 27b 9)"') || return 1
  [ "$out" = "qwen3.8-27b-IQ4_XS-pure.gguf|qwen3.8-27b-IQ4_XS-pure.gguf mmproj-BF16.gguf|Qwen3.8-27B-DFlash2-Q4_K_M.gguf|56|solo DFlash2 (максимум соло-скорости)|1|262144|12884901888/68719476736|--speculative dflash2 --dflash-model @DRAFT@ --mmproj @MMPROJ@ --log-progress --served-model-name qwen3.8-27b --served-model-name Qwen3.8-27B --served-model-name qwen3.8:27b-mq4-xts" ] || return 1
  # 27b-parallel — the key fields
  out=$(LCTL_TEST_ENGINE=gufo hf 'echo "$(profile_field 27b-parallel 6)|$(profile_field 27b-parallel 7)|$(profile_field 27b-parallel 8)"') || return 1
  [ "$out" = "2|210000|12884901888/68719476736" ] || return 1
  # flash — the shard list (6 files with the mmproj), the mtp in field 3, the 110 threshold
  out=$(LCTL_TEST_ENGINE=gufo hf 'echo "$(profile_field flash 4)|$(profile_field flash 6)|$(profile_field flash 7)|$(profile_field flash 2 | wc -w)"') || return 1
  [ "$out" = "110|2|131072|6" ] || return 1
  # the ladders
  out=$(LCTL_TEST_ENGINE=gufo hf 'echo "[$(profile_ladder 27b)] [$(profile_ladder 27b-parallel)] [$(profile_ladder flash)]"') || return 1
  [ "$out" = "[-] [210000 196608 163840 131072] [262144 229376 196608 163840 131072]" ] || return 1
  # the EXP-007 references verbatim; 27b-parallel — not taken ('')
  out=$(LCTL_TEST_ENGINE=gufo hf 'echo "$(ref_get 27b session)/$(ref_get 27b followup)/$(ref_get 27b docq)/$(ref_get 27b restore)/$(ref_get flash session)/$(ref_get 27b-parallel session)"') || return 1
  [ "$out" = "30.44/3.00/3.60/2.85/17.22/" ] || return 1
  # the pin sums: the flash main roles = 111 334 654 778 B (SPEC §5, OQ-3 —
  # catches a pin carry typo); with mtp+mmproj (w43-vision) = 115 028 765 978;
  # the full 27b = 15 677 391 456 + mmproj 931 146 432 = 16 608 537 888
  out=$(LCTL_TEST_ENGINE=gufo hf 'echo "$(weights_for flash | awk -F"|" "\$5==\"main\"{s+=\$2} END{printf \"%.0f\", s+0}")|$(set_total_bytes flash)|$(set_total_bytes 27b)"') || return 1
  [ "$out" = "111334654778|115028765978|16608537888" ] || return 1
  LCTL_TEST_ENGINE=gufo hf 'for s in 27b flash; do weights_for "$s" | awk -F"|" "{ if (\$2 !~ /^[0-9]+\$/ || \$3 !~ /^[0-9a-f]{64}\$/ || \$5 !~ /^(main|draft|mtp|mmproj)\$/) exit 1 }" || exit 1; done' >/dev/null 2>&1 || return 1
  return 0
}

# G0-pins/delivery: download_file file:// — a sha PASS / a SKIP by size /
#     a SHA-MISMATCH with removal / the pre-flight «мало места»;
#     engine_pull_model resolves the pin by name (an unknown → die)
scen_g0_pins_download() {
  local d="$TMP/gdl" out rc sha1 sha2
  rm -rf "$d"; mkdir -p "$d"
  printf 'pin-content-fixture-bytes' > "$d/pin.gguf"
  sha1=$(sha256sum "$d/pin.gguf" | awk '{print $1}')
  printf 'other-content' > "$d/other.gguf"
  sha2=$(sha256sum "$d/other.gguf" | awk '{print $1}')
  # a PASS: file:// + the right sha
  out=$(LCTL_TEST_ENGINE=gufo hf "download_file 'file://$d/pin.gguf' '$d/D1.gguf' 25 $sha1" 2>&1); rc=$?
  [ "$rc" = 0 ] && grep -q 'PASS: D1.gguf (sha OK)' <<<"$out" && cmp -s "$d/pin.gguf" "$d/D1.gguf" || return 1
  # a SKIP: the dest is already pin-sized — the network not touched (no curl in the log)
  fresh_log
  out=$(LCTL_TEST_ENGINE=gufo hf "download_file 'file://$d/pin.gguf' '$d/D1.gguf' 25 $sha1" 2>&1); rc=$?
  [ "$rc" = 0 ] && grep -q 'SKIP: D1.gguf' <<<"$out" && ! grep -q curl <<<"$out" || return 1
  # a SHA-MISMATCH: the content is wrong → dest+part removed, rc 1
  out=$(LCTL_TEST_ENGINE=gufo hf "download_file 'file://$d/other.gguf' '$d/D2.gguf' 13 $sha1" 2>&1); rc=$?
  [ "$rc" = 1 ] && grep -q 'SHA-MISMATCH' <<<"$out" && [ ! -f "$d/D2.gguf" ] && [ ! -f "$d/D2.gguf.part" ] || return 1
  # a space shortage: the pin exceeds the free space — a refusal BEFORE the traffic (curl not called)
  fresh_log
  out=$(LCTL_TEST_ENGINE=gufo hf "download_file 'file://$d/pin.gguf' '$d/D3.gguf' 999999999999 $sha1" 2>&1); rc=$?
  [ "$rc" = 1 ] && grep -q 'мало места' <<<"$out" && ! grep -q '^curl' "$FAUXLOG" || return 1
  # engine_pull_model: a pin by name — a pin-sized file already in place →
  # a SKIP; an unknown name → die
  fresh_log
  out=$(LCTL_TEST_ENGINE=gufo MODELS_DIR="$d" hf 'engine_pull_model Qwen3.8-27B-DFlash2-Q4_K_M.gguf' 2>&1); rc=$?
  [ "$rc" = 1 ] && grep -q 'мало места' <<<"$out" || return 1   # 1.1 GB > места в tmpfs-фикстуре — pre-flight сработал (пин резолвился)
  out=$(LCTL_TEST_ENGINE=gufo MODELS_DIR="$d" hf 'engine_pull_model net-takogo.gguf' 2>&1); rc=$?
  [ "$rc" = 1 ] && grep -q 'не найден в таблицах пинов' <<<"$out" || return 1
  return 0
}

# G0-check_types: green (ffn IQ4_XS)/red (ffn IQ2_S)/«нечего проверять»
#     on the gguf_* fixtures (gfctl copies)
scen_g0_check_types() {
  local d="$TMP/gct" out rc
  rm -rf "$d"; mkdir -p "$d/27b"
  cp "$ROOT/engines/gufo/tests/fixtures/gguf_ffn_iq4_xs.gguf" "$d/27b/qwen3.8-27b-IQ4_XS-pure.gguf"
  out=$(LCTL_TEST_ENGINE=gufo LCTL_MODELS="$d" hf 'check_types 27b' 2>&1); rc=$?
  [ "$rc" = 0 ] && grep -q 'зелёный — сет 27b можно грузить' <<<"$out" || return 1
  cp "$ROOT/engines/gufo/tests/fixtures/gguf_ffn_iq2_s.gguf" "$d/27b/qwen3.8-27b-IQ4_XS-pure.gguf"
  out=$(LCTL_TEST_ENGINE=gufo LCTL_MODELS="$d" hf 'check_types 27b' 2>&1); rc=$?
  [ "$rc" = 1 ] && grep -q 'КРАСНЫЙ' <<<"$out" || return 1
  rm -rf "$d/27b"; mkdir -p "$d/27b"
  out=$(LCTL_TEST_ENGINE=gufo LCTL_MODELS="$d" hf 'check_types 27b' 2>&1); rc=$?
  [ "$rc" = 1 ] && grep -q 'нечего проверять' <<<"$out" || return 1
  return 0
}

# G1-serve_args: the 27b canon byte-for-byte (task 3.1 §1.3);
#     parallel/flash — the role tokens and the cache tiers; purity; a
#     foreign token → die
scen_g1_serve_args() {
  local a1 a2 r out
  a1=$(LCTL_TEST_ENGINE=gufo hf 'serve_args 27b 1 262144') || return 1
  [ "$a1" = "gufo serve llm --host 0.0.0.0 --port 11435 --model /models/qwen3.8-27b-IQ4_XS-pure.gguf --speculative dflash2 --dflash-model /models/Qwen3.8-27B-DFlash2-Q4_K_M.gguf --mmproj /models/mmproj-BF16.gguf --log-progress --served-model-name qwen3.8-27b --served-model-name Qwen3.8-27B --served-model-name qwen3.8:27b-mq4-xts --sessions 1 --context 262144 --cache-ram-bytes 12884901888 --cache-disk /cache --cache-disk-bytes 68719476736" ] || return 1
  a2=$(LCTL_TEST_ENGINE=gufo hf 'serve_args 27b 1 262144') || return 1
  [ "$a1" = "$a2" ] || return 1   # чистая (два вызова — идентичный вывод)
  a1=$(LCTL_TEST_ENGINE=gufo hf 'serve_args 27b-parallel 2 196608') || return 1
  grep -q -- '--sessions 2 --context 196608 --cache-ram-bytes 12884901888' <<<"$a1" || return 1
  a1=$(LCTL_TEST_ENGINE=gufo hf 'serve_args flash 2 131072') || return 1
  grep -q -- '--model /models/Qwen3.8-Flash-Next-UD-Q4_K_XL-00001-of-00004.gguf' <<<"$a1" || return 1
  grep -q -- '--mtp-model /models/mtp-Qwen3.8-Flash-Next-shared-Q8_0.gguf' <<<"$a1" || return 1
  grep -q -- '--mmproj /models/mmproj-flash-next-BF16.gguf' <<<"$a1" || return 1
  # a foreign token → die (v2: the registry is file-based, the former
  #     profile_bad="..." variable is not read; the temp profile = a 27b
  #     copy with @BOGUS@ in the serve flags)
  { grep -v '^P_SERVE_ARGS=' "$ROOT/engines/gufo/profiles/27b.env"; printf 'P_SERVE_ARGS="--speculative x --foo @BOGUS@"\n'; } > "$ROOT/engines/gufo/profiles/bad.env"
  out=$(LCTL_TEST_ENGINE=gufo hf 'serve_args bad 1 1024' 2>&1); r=$?
  rm -f "$ROOT/engines/gufo/profiles/bad.env"
  [ "$r" = 1 ] && grep -q 'неизвестный токен' <<<"$out" || return 1
  return 0
}


# G1-canon.env: an upsert (foreign keys kept, no duplicates), a read, an
#     unknown profile → ''
scen_g1_canon() {
  new_stack g1canon
  local c f
  LCTL_TEST_ENGINE=gufo hf 'gufo_write_canon 27b-parallel 196608' >/dev/null 2>&1 || return 1
  f="$LCTL_TEST_STACK/.data/gufo/profiles/canon.env"
  [ "$(cat "$f")" = "GUFO_CONTEXT_27b_parallel=196608" ] || return 1
  LCTL_TEST_ENGINE=gufo hf 'gufo_write_canon 27b 262144' >/dev/null 2>&1 || return 1
  LCTL_TEST_ENGINE=gufo hf 'gufo_write_canon 27b-parallel 163840' >/dev/null 2>&1 || return 1
  [ "$(grep -c '=' "$f")" = 2 ] || return 1                       # дублей ключа нет
  grep -q '^GUFO_CONTEXT_27b_parallel=163840$' "$f" || return 1   # upsert по значению
  grep -q '^GUFO_CONTEXT_27b=262144$' "$f" || return 1
  c=$(LCTL_TEST_ENGINE=gufo hf 'echo "$(gufo_canon_context 27b-parallel)/$(gufo_canon_context 27b)/$(gufo_canon_context flash)"') || return 1
  [ "$c" = "163840/262144/" ] || return 1
  return 0
}

# G1-compose: the render (name: gufo — the project pin; the F9 flags; the
#     mounts; the port) + the canon.env context in engine_write_compose +
#     the field-7 fallback + the LCTL_SESSIONS override (OQ-1, an adapter
#     env)
scen_g1_compose() {
  new_stack g1comp
  local y="$LCTL_TEST_STACK/compose.yml" c="$LCTL_TEST_STACK/.data/gufo/profiles/canon.env"
  LCTL_TEST_ENGINE=gufo hf 'set_models_dir 27b-parallel; write_env 27b-parallel "$(profile_field 27b-parallel 1)"; write_stack_files' >/dev/null 2>&1 || return 1
  grep -q '^name: gufo$' "$y" || return 1
  grep -qF 'ghcr.io/gufo-org/toolboxes/gufo-runtime:0.36' "$y" || return 1
  grep -q '      - /dev/kfd' "$y" && grep -q '      - /dev/dri' "$y" || return 1
  grep -q '      - keep-groups' "$y" || return 1
  grep -q '^    ipc: host$' "$y" || return 1
  grep -q '        soft: -1' "$y" && grep -q '        hard: -1' "$y" || return 1
  grep -q 'keep-id:uid=1000,gid=1000' "$y" || return 1
  grep -qF '"0.0.0.0:11435:11435"' "$y" || return 1
  grep -qF '".data/gufo/models/27b:/models:ro"' "$y" || return 1
  grep -qF '".data/gufo/profiles/27b-parallel:/cache"' "$y" || return 1
  grep -qF -e '--sessions 2 --context 210000' "$y" || return 1       # fallback поля 7 (canon.env нет)
  # the canon.env context beats field 7 on a re-render
  printf 'GUFO_CONTEXT_27b_parallel=196608\n' > "$c"
  LCTL_TEST_ENGINE=gufo hf 'set_models_dir 27b-parallel; engine_write_compose' >/dev/null 2>&1 || return 1
  grep -qF -e '--sessions 2 --context 196608' "$y" || return 1
  # LCTL_SESSIONS — an adapter env override (OQ-1), zero core surface
  LCTL_SESSIONS=4 LCTL_TEST_ENGINE=gufo hf 'gufo_render_compose 27b-parallel 163840' >/dev/null 2>&1 || return 1
  grep -qF -- '--sessions 4 --context 163840' "$y" || return 1
  # the stage-8 contract: the hook with a target dir renders compose.yml
  # THERE (the inputs — the tpl + the stack's canon.env, the canon left
  # untouched); without an argument — the former place (checked above:
  # "$y" == "$STACK_DIR/compose.yml")
  local d="$TMP/wt-gufo"; rm -rf "$d"; mkdir -p "$d"
  LCTL_TEST_ENGINE=gufo hf "engine_write_compose '$d'" >/dev/null 2>&1 || return 1
  grep -q '^name: gufo$' "$d/compose.yml" || return 1
  grep -qF -e '--sessions 2 --context 196608' "$d/compose.yml" || return 1
  grep -qF '".data/gufo/profiles/27b-parallel:/cache"' "$d/compose.yml" || return 1
  return 0
}

# G1-probe ok: 27b-parallel without a canon — the 210000 step (load_failed) →
#     196608 (the engine raised the 163840 fact — accepted, the ladder
#     STOPS): EXACTLY 2 ups, the 163840 canon, a journal with two
#     verdicts, the third steps (163840/131072) not reached
scen_g1_probe_ok() {
  new_stack g1probe1; fresh_log
  local out rc j="$LCTL_TEST_STACK/.data/gufo/logs/probe-27b-parallel-2.log"
  out=$(LCTL_TEST_ENGINE=gufo LCTL_LOADFAIL_AFTER=0 LCTL_FAUX_UP_LOGS="$GLOGFAIL:$GLOG1638" \
    hf 'engine_apply_profile 27b-parallel' 2>&1); rc=$?
  [ "$rc" = 0 ] || { echo "DBG-probe-ok rc=$rc: $(tail -3 <<<"$out")" >&2; return 1; }
  grep -q 'канона пары нет (27b-parallel × 2) — probe-подбор по лестнице: 210000 196608 163840 131072' <<<"$out" || return 1
  [ "$(ups_count)" = 2 ] || return 1
  grep -q '^GUFO_CONTEXT_27b_parallel=163840$' "$LCTL_TEST_STACK/.data/gufo/profiles/canon.env" || return 1
  grep -q 'ступень 210000: попытка загрузки (sessions 2)' "$j" && \
    grep -q 'ступень 210000: ОТКАЗ — load_failed (admission/отказ загрузки)' "$j" && \
    grep -q 'ступень 196608: движок поднял фактический 163840 — принимаю факт' "$j" || return 1
  ! grep -q 'ступень 131072' "$j" || return 1
  return 0
}

# G1-probe fact≠order (2.1-F4): the ordered 210000 (the ladder head), the
#     engine raised 163840 → the canon = the FACT + a WARN, the ladder
#     STOPS (exactly 1 up)
scen_g1_probe_fact() {
  new_stack g1probe2; fresh_log
  local out rc j="$LCTL_TEST_STACK/.data/gufo/logs/probe-27b-parallel-2.log"
  out=$(LCTL_TEST_ENGINE=gufo LCTL_LOADFAIL_AFTER=0 LCTL_FAUX_UP_LOGS="$GLOG1638" \
    hf 'engine_apply_profile 27b-parallel' 2>&1); rc=$?
  [ "$rc" = 0 ] || return 1
  grep -q 'ступень 210000: движок поднял фактический 163840 — принимаю факт' <<<"$out" || return 1
  grep -q 'WARN: probe: заказан контекст 210000, сервер поднялся на 163840' <<<"$out" || return 1
  grep -qF 'F21' <<<"$out" || return 1                            # WARN не обвиняет движок
  grep -q '^GUFO_CONTEXT_27b_parallel=163840$' "$LCTL_TEST_STACK/.data/gufo/profiles/canon.env" || return 1
  [ "$(ups_count)" = 1 ] || return 1                              # лестница СТОП
  ! grep -q 'ступень 196608: попытка' "$j" || return 1            # меньших ступеней не было
  return 0
}

# G1-probe a full failure: the whole ladder load_failed → die («это тоже
#     результат», OQ-2 — NOT the rc 1 branch), canon.env NOT created, a
#     journal with 4 refusals
scen_g1_probe_die() {
  new_stack g1probe3; fresh_log
  local out rc j="$LCTL_TEST_STACK/.data/gufo/logs/probe-27b-parallel-2.log"
  out=$(LCTL_TEST_ENGINE=gufo LCTL_LOADFAIL_AFTER=0 LCTL_FAUX_UP_LOGS="$GLOGFAIL" \
    hf 'engine_apply_profile 27b-parallel' 2>&1); rc=$?
  [ "$rc" != 0 ] || return 1
  grep -q 'это тоже результат' <<<"$out" || return 1
  grep -q 'FATAL: probe: все ступени лестницы отказали' <<<"$out" || return 1
  [ ! -f "$LCTL_TEST_STACK/.data/gufo/profiles/canon.env" ] || return 1
  [ "$(grep -c 'ОТКАЗ' "$j")" = 4 ] || return 1
  return 0
}

# G1-probe single: no ladder → the probe NOT called (0 ups), the canon =
#     field 7, the compose rendered for the final context
scen_g1_probe_single() {
  new_stack g1probe4; fresh_log
  local out rc
  out=$(LCTL_TEST_ENGINE=gufo hf 'engine_apply_profile 27b' 2>&1); rc=$?
  [ "$rc" = 0 ] && [ "$(ups_count)" = 0 ] || return 1
  grep -q '^GUFO_CONTEXT_27b=262144$' "$LCTL_TEST_STACK/.data/gufo/profiles/canon.env" || return 1
  grep -qF -e '--context 262144' "$LCTL_TEST_STACK/compose.yml" || return 1
  return 0
}

# ── G2: the health dialect (/ready + load_completed) + doctor ───────────────

# the gufo side of K-1: wait_health via the gufo adapter curls /ready (not /health)
scen_g2_health_path_gufo() {
  new_stack g2hp; fresh_log
  local out rc
  out=$(LCTL_TEST_ENGINE=gufo LCTL_TEST_PATH="$FAUX_GUFO:$PATH" hf 'wait_health 5' 2>&1); rc=$?
  [ "$rc" = 0 ] \
    && printf '%s' "$out" | grep -q 'HEALTHY' \
    && grep -qF 'curl -fsS -m 5 http://127.0.0.1:11435/ready' "$FAUXLOG" \
    && ! grep -qF 'http://127.0.0.1:11435/health' "$FAUXLOG"
}

# G2-dialect: parse_route (a name with spaces!) + engine_check_route +
#     engine_health_ok (a /ready body unconditionally) + the smoke
#     (exactly 1 retry) + the die branches + the status lines (hline + JSON)
scen_g2_health() {
  local out rc n
  # parse_route: a name with spaces in full (EXP-005 live — the GLOGSP fixture)
  LCTL_TEST_ENGINE=gufo LCTL_FAUX_PODMAN_LOGS="$GLOGSP" hf 'engine_check_route 27b' >/dev/null 2>&1 || return 1
  out=$(LCTL_TEST_ENGINE=gufo LCTL_FAUX_PODMAN_LOGS="$GLOGSP" LCTL_TEST_PATH="$FAUX_GUFO:$PATH" hf 'engine_check_route 27b' 2>&1) || return 1
  printf '%s' "$out" | grep -qF 'роут: mtp, sessions 2, ctx 262144 (модель: Qwen3.8 Flash Next)' || return 1
  # engine_health_ok: any /ready body — healthy (curl -f filtered the 5xx)
  LCTL_TEST_ENGINE=gufo hf 'printf "OK" | engine_health_ok' >/dev/null 2>&1 || return 1
  LCTL_TEST_ENGINE=gufo hf 'printf "" | engine_health_ok' >/dev/null 2>&1 || return 1
  # the smoke: 5 requests (3 texts + a stream + tools); a second empty one →
  #     EXACTLY ONE retry (the calls 2,3), SMOKE OK
  new_stack g2smoke; fresh_log
  out=$(LCTL_TEST_ENGINE=gufo ROUTE_MODEL="qwen3.8-27b-IQ4_XS-pure" ROUTE_SPEC=dflash2 ROUTE_SESSIONS=1 ROUTE_CTX=262144 \
    LCTL_SMOKE_RETRY_S=0 LCTL_FAUX_CURL_EMPTYN=2 LCTL_TEST_PATH="$FAUX_GUFO:$PATH" \
    hf 'engine_smoke' 2>&1); rc=$?
  [ "$rc" = 0 ] && printf '%s' "$out" | grep -q 'SMOKE: OK' || return 1
  n=$(grep -c 'chat/completions' "$FAUXLOG")
  [ "$n" = 6 ] || return 1   # 5 запросов (fix:w42-smoke-core) + 1 ретрай
  printf '%s' "$out" | grep -q 'повторяю через 0с' || return 1
  # the smoke: both prompt answers empty (EMPTYN 1,2) → die rc 1
  new_stack g2smoke2; fresh_log
  out=$(LCTL_TEST_ENGINE=gufo ROUTE_MODEL="qwen3.8-27b-IQ4_XS-pure" ROUTE_SPEC=dflash2 ROUTE_SESSIONS=1 ROUTE_CTX=262144 \
    LCTL_SMOKE_RETRY_S=0 LCTL_FAUX_CURL_EMPTYN=1,2 LCTL_TEST_PATH="$FAUX_GUFO:$PATH" \
    hf 'engine_smoke' 2>&1); rc=$?
  [ "$rc" = 1 ] && printf '%s' "$out" | grep -q 'смоук не прошёл' || return 1
  # the smoke without health (an empty ROUTE_MODEL) → die «health не выполнен»
  out=$(LCTL_TEST_ENGINE=gufo LCTL_TEST_PATH="$FAUX_GUFO:$PATH" hf 'engine_smoke' 2>&1); rc=$?
  [ "$rc" = 1 ] && printf '%s' "$out" | grep -q 'health не выполнен' || return 1
  # the status lines: the hline («health/профиль/роут/кэш») and the JSON (valid, route/autostart)
  cat "$GLOGOK" "$GLOGCONF" > "$TMP/glog-full"
  mkdir -p "$LCTL_TEST_STACK/.data/gufo/profiles/27b"
  truncate -s 104857600 "$LCTL_TEST_STACK/.data/gufo/profiles/27b/cache.bin"   # 0.1 GiB кэша для JSON-ассерта
  out=$(LCTL_TEST_ENGINE=gufo LCTL_FAUX_PODMAN_LOGS="$TMP/glog-full" LCTL_TEST_PATH="$FAUX_GUFO:$PATH" \
    hf 'engine_status_health' 2>&1) || return 1
  printf '%s' "$out" | grep -q 'health: ok | профиль: 27b | роут: dflash2, sessions 1, ctx 262144' || return 1
  printf '%s' "$out" | grep -q 'кэш: .*/27b (' || return 1
  out=$(LCTL_TEST_ENGINE=gufo LCTL_FAUX_PODMAN_LOGS="$TMP/glog-full" LCTL_TEST_PATH="$FAUX_GUFO:$PATH" \
    PROFILE="27b" AUTO="enabled" WDOG="disabled" hf 'engine_status_json' 2>&1) || return 1
  printf '%s' "$out" | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d["engine"] == "gufo", d
assert d["profile"] == "27b", d
assert d["health"] == "ok", d
assert d["route"] == {"speculative": "dflash2", "sessions": 1, "context": 262144,
                      "model": "qwen3.8-27b-IQ4_XS-pure"}, d
assert d["autostart"] is True and d["watchdog"] is False, d
assert d["cache"] and d["cache"]["gib"] > 0, d
' || return 1
  return 0
}

# G2-doctor: the inventory/types on a fixture (green), the configured line,
#     a best-effort /metrics, an empty set — «весов нет» without die, the
#     gpu-lock branch
# G2-vision (fix:w43-smoke-vision): an mmproj file in the set → the 6th
#     request (image_url in the faux log), SMOKE OK, exactly 6 calls (no
#     retry)
scen_g_smoke_vision() {
  new_stack g-smokev; fresh_log
  out=$(LCTL_TEST_ENGINE=gufo ROUTE_MODEL="qwen3.8-27b-IQ4_XS-pure" ROUTE_SPEC=dflash2 ROUTE_SESSIONS=1 ROUTE_CTX=262144 \
    LCTL_SMOKE_RETRY_S=0 LCTL_TEST_PATH="$FAUX_GUFO:$PATH" \
    hf 'mkdir -p "$MODELS_DIR"; : > "$MODELS_DIR/mmproj-BF16.gguf"; engine_smoke' 2>&1); rc=$?
  [ "$rc" = 0 ] \
    && printf '%s' "$out" | grep -q 'SMOKE: OK' \
    && grep -q 'image_url' "$FAUXLOG" \
    && [ "$(grep -c 'chat/completions' "$FAUXLOG")" = 6 ]
}

scen_g2_doctor() {
  local d="$TMP/gdoc" out rc
  rm -rf "$d"; mkdir -p "$d/27b"
  cp "$ROOT/engines/gufo/tests/fixtures/gguf_ffn_iq4_xs.gguf" "$d/27b/qwen3.8-27b-IQ4_XS-pure.gguf"
  cat "$GLOGOK" "$GLOGCONF" > "$TMP/glog-doc"
  out=$(LCTL_TEST_ENGINE=gufo LCTL_MODELS="$d" LCTL_FAUX_PODMAN_LOGS="$TMP/glog-doc" \
    LCTL_FAUX_METRICS="$ROOT/engines/gufo/tests/fixtures/metrics_snap1.txt" \
    LCTL_TEST_PATH="$FAUX_GUFO:$PATH" hf 'engine_doctor' 2>&1); rc=$?
  [ "$rc" = 0 ] || return 1
  printf '%s' "$out" | grep -q 'есть, РАЗМЕР ≠' || return 1             # инвентарь: фиксдура ≠ пин-размеру (честная ветка)
  printf '%s' "$out" | grep -q 'зелёный — сет 27b можно грузить' || return 1
  printf '%s' "$out" | grep -q 'configured: sessions 1 | ram-cache on | capacity 12.0 GiB | automatic 4.0 GiB | disk 64.0 GiB' || return 1
  printf '%s' "$out" | grep -q 'prompt_tokens_cached_total: 990000' || return 1   # /metrics best-effort
  printf '%s' "$out" | grep -q 'gpu-lock: контейнеров podman нет' || return 1
  # an empty set → «весов нет», rc 0 (check_types' die not reached)
  rm -rf "$d/27b"; mkdir -p "$d/27b"
  out=$(LCTL_TEST_ENGINE=gufo LCTL_MODELS="$d" LCTL_TEST_PATH="$FAUX_GUFO:$PATH" hf 'engine_doctor' 2>&1); rc=$?
  [ "$rc" = 0 ] && printf '%s' "$out" | grep -q '(весов нет — проверка типов пропущена)' || return 1
  return 0
}

# ── G3: agent-check (cmp_ref + engine_agent_check) + switch hipfire↔gufo ────

# G3-cmp_ref: a pure function — an untaken reference → a WARN; within the
#     ±25% window → a PASS; a regression → a WARN with a hint
scen_g3_cmp_ref() {
  local v
  v=$(LCTL_TEST_ENGINE=gufo hf 'cmp_ref "метка" "3.20" ""') || return 1
  [[ "$v" == 'WARN: метка 3.2s — референс не снят (EXP-007)' ]] || return 1
  v=$(LCTL_TEST_ENGINE=gufo hf 'cmp_ref "метка" "3.20" "3.00"') || return 1
  [[ "$v" == 'PASS: метка 3.2s (референс 3.0s)' ]] || return 1
  v=$(LCTL_TEST_ENGINE=gufo hf 'cmp_ref "метка" "4.50" "3.00" "проверь кэш"') || return 1
  [[ "$v" == 'WARN: метка 4.5s — регрессия >25% к 3.0s (проверь кэш)' ]] || return 1
  return 0
}

# G3-agent-check happy: the container running, the /ready+log fixtures —
#     exactly 25 chat POSTs, the PASS=4 WARN=0 FAIL=0 summary, the state
#     file removed
scen_g3_agent_happy() {
  new_stack g3ac1; fresh_log
  hf 'hf_up_locked' >/dev/null 2>&1 || return 1   # faux inspect: running после up
  local out rc
  out=$(LCTL_TEST_ENGINE=gufo ROUTE_MODEL="qwen3.8-27b-IQ4_XS-pure" ROUTE_SPEC=dflash2 ROUTE_SESSIONS=1 ROUTE_CTX=262144 \
    LCTL_SMOKE_RETRY_S=0 LCTL_FAUX_PODMAN_LOGS="$GLOGOK" LCTL_FAUX_CURL_TIMINGS=1 LCTL_FAUX_CURL_REUSE=live \
    LCTL_FAUX_PORTOPEN=1 LCTL_TEST_PATH="$FAUX_GUFO:$PATH" \
    hf 'engine_agent_check' 2>&1); rc=$?
  [ "$rc" = 0 ] || { printf '%s\n' "$out" | tail -25 >&2; return 1; }
  printf '%s' "$out" | grep -q 'AGENT-CHECK: PASS=4 WARN=0 FAIL=0' || return 1
  printf '%s' "$out" | grep -q 'PASS: сессия 15 ходов' && \
    printf '%s' "$out" | grep -q 'PASS: follow-up 25k' && \
    printf '%s' "$out" | grep -q 'PASS: \[док 25k\] q2' && \
    printf '%s' "$out" | grep -q 'PASS: рестарт-restore' || return 1
  printf '%s' "$out" | grep -q 'restore: reuse=live — disk-restore работает' || return 1
  printf '%s' "$out" | grep -q 'рестарт-restore ПЕРЕЗАПУСКАЕТ контейнер' || return 1
  [ "$(grep -c 'chat/completions' "$FAUXLOG")" = 25 ] || return 1   # stage1 24 + stage2 1
  [ ! -f "$LCTL_TEST_STACK/.data/gufo/logs/agent-check-restore.json" ] || return 1
  return 0
}

# G3-agent-check WARN references: the 27b-parallel profile — the references not taken →
#     PASS=0 WARN=4 FAIL=0, rc 0 (WARN ≠ FAIL)
scen_g3_agent_warn() {
  new_stack g3ac2; fresh_log
  hf 'hf_up_locked; write_env 27b-parallel "$(profile_field 27b-parallel 1)"' >/dev/null 2>&1 || return 1
  local out rc
  out=$(LCTL_TEST_ENGINE=gufo ROUTE_MODEL="qwen3.8-27b-IQ4_XS-pure" ROUTE_SPEC=dflash2 ROUTE_SESSIONS=2 ROUTE_CTX=163840 \
    LCTL_SMOKE_RETRY_S=0 LCTL_FAUX_PODMAN_LOGS="$GLOGOK" LCTL_FAUX_CURL_TIMINGS=1 LCTL_FAUX_CURL_REUSE=disk \
    LCTL_FAUX_PORTOPEN=1 LCTL_TEST_PATH="$FAUX_GUFO:$PATH" \
    hf 'engine_agent_check' 2>&1); rc=$?
  [ "$rc" = 0 ] || return 1
  printf '%s' "$out" | grep -q 'AGENT-CHECK: PASS=0 WARN=4 FAIL=0' || return 1
  printf '%s' "$out" | grep -q 'WARN: сессия 15 ходов .* — референс не снят (EXP-007)' || return 1
  printf '%s' "$out" | grep -q 'restore: reuse=disk — disk-restore работает' || return 1
  return 0
}

# G3-agent-check FAIL: a restore reuse=none → a FAIL line, rc 1 (the structure intact)
scen_g3_agent_fail() {
  new_stack g3ac3; fresh_log
  hf 'hf_up_locked' >/dev/null 2>&1 || return 1
  local out rc
  out=$(LCTL_TEST_ENGINE=gufo ROUTE_MODEL="qwen3.8-27b-IQ4_XS-pure" ROUTE_SPEC=dflash2 ROUTE_SESSIONS=1 ROUTE_CTX=262144 \
    LCTL_SMOKE_RETRY_S=0 LCTL_FAUX_PODMAN_LOGS="$GLOGOK" LCTL_FAUX_CURL_TIMINGS=1 LCTL_FAUX_CURL_REUSE=none \
    LCTL_FAUX_PORTOPEN=1 LCTL_TEST_PATH="$FAUX_GUFO:$PATH" \
    hf 'engine_agent_check' 2>&1); rc=$?
  [ "$rc" = 1 ] || return 1
  printf '%s' "$out" | grep -q 'AGENT-CHECK: PASS=4 WARN=0 FAIL=1' || return 1
  printf '%s' "$out" | grep -q 'FAIL: disk-restore не сработал (reuse=none)' || return 1
  return 0
}

# G3-switch (§А-1, the faux hipfire↔gufo): the hipfire units active, the
#     hipfire canon → `lctl start gufo flash` = an honest hipfire off (a
#     podman stop BEFORE the first gufo up) → the gufo bootstrap (the pin
#     weights SKIP by size — sparse fixtures, a pre-seeded canon.env = the
#     probe skipped) → the gufo-compose units
scen_g3_switch() {
  new_stack g3sw; fresh_log
  rm -rf "$TMP/home"; mkdir -p "$TMP/home"
  local tree="$TMP/gsw-tree"
  rm -rf "$tree"; mkdir -p "$tree"
  cp -a "$ROOT/lctl" "$ROOT/core" "$ROOT/engines" "$tree/" || return 1
  # the canon: hipfire deployed (a former window), the units active
  printf 'LCTL_ENGINE=hipfire\nLCTL_PROFILE=27b\nLCTL_MODEL=qwen3.8:27b-mq4-xts\nLCTL_PORT=11435\nLCTL_BIND=0.0.0.0\n' > "$LCTL_TEST_STACK/.env"
  # the weights in place (sparse fixtures of the pin sizes: a fetch = a SKIP without the network)
  local m="$LCTL_TEST_STACK/.data/gufo/models"
  mkdir -p "$m/27b" "$m/flash"
  truncate -s 14534384640 "$m/27b/qwen3.8-27b-IQ4_XS-pure.gguf"
  truncate -s 1143006816 "$m/27b/Qwen3.8-27B-DFlash2-Q4_K_M.gguf"
  truncate -s 10946618    "$m/flash/Qwen3.8-Flash-Next-UD-Q4_K_XL-00001-of-00004.gguf"
  truncate -s 49720539552 "$m/flash/Qwen3.8-Flash-Next-UD-Q4_K_XL-00002-of-00004.gguf"
  truncate -s 32803030176 "$m/flash/Qwen3.8-Flash-Next-UD-Q4_K_XL-00003-of-00004.gguf"
  truncate -s 28800138432 "$m/flash/Qwen3.8-Flash-Next-UD-Q4_K_XL-00004-of-00004.gguf"
  truncate -s 2786568256  "$m/flash/mtp-Qwen3.8-Flash-Next-shared-Q8_0.gguf"
  truncate -s 907542944   "$m/flash/mmproj-flash-next-BF16.gguf"   # fix:w43-vision — pull-лист flash 6-й файл
  # the former window's probe canon: the state survives a switch (§1.6)
  mkdir -p "$LCTL_TEST_STACK/.data/gufo/profiles"
  printf 'GUFO_CONTEXT_flash=131072\n' > "$LCTL_TEST_STACK/.data/gufo/profiles/canon.env"
  local lim="$TMP/limits-g3sw.conf"
  limits_bytes tester 1318060032 > "$lim"
  local out rc stop_ln up1_ln
  out=$(env PATH="$FAUX_GUFO:$PATH" HOME="$TMP/home" USER=tester \
    LCTL_DIR="$LCTL_TEST_STACK" LCTL_LIMITS="$lim" LCTL_KFD="$TMP/kfd-node" LCTL_DRI="$TMP/dri-node" \
    LCTL_FAUX_LINGER=1 LCTL_FAUX_UNITS="hipfire-compose" LCTL_FAUX_PODMAN_LOGS="$GLOGOK" \
    LCTL_FAUX_LOG="$FAUXLOG" LCTL_FAUX_CNT="$FAUXCNT" LCTL_FAUX_ORPHAN_ID="$ORPHAN_ID" LCTL_FAUX_TMP="$TMP" \
    bash "$tree/lctl" start gufo flash --yes --force 2>&1); rc=$?
  [ "$rc" = 0 ] || { echo "DBG-switch rc=$rc: $(tail -6 <<<"$out")" >&2; return 1; }
  printf '%s' "$out" | grep -q 'SMOKE: OK' || return 1
  printf '%s' "$out" | grep -q 'активно: gufo/flash' || return 1
  stop_ln=$(grep -n 'podman stop hipfire_hipfire_1' "$FAUXLOG" | head -1 | cut -d: -f1)
  up1_ln=$(grep -n 'up -d' "$FAUXLOG" | head -1 | cut -d: -f1)
  [ -n "$stop_ln" ] && [ -n "$up1_ln" ] && [ "$stop_ln" -lt "$up1_ln" ] || return 1
  grep -qF 'LCTL_ENGINE=gufo' "$LCTL_TEST_STACK/.env" && \
    grep -qF 'LCTL_PROFILE=flash' "$LCTL_TEST_STACK/.env" || return 1
  grep -q '^GUFO_CONTEXT_flash=131072$' "$LCTL_TEST_STACK/.data/gufo/profiles/canon.env" || return 1
  [ -f "$TMP/home/.config/systemd/user/gufo-compose.service" ] || return 1
  [ ! -e "$TMP/home/.config/systemd/user/hipfire-compose.service" ] || return 1
  grep -q 'канон пары (flash × 2): context 131072 — probe пропущен' <<<"$out" || return 1
  return 0
}

# ── W1: the gufo watch panel (a plain stream on the /metrics fixtures, a dead server,
#     the selfcheck aggregate, a run through the real dispatcher) ────────────
# W3.2: LOGTZ — the `podman logs -t` podman prefixes (F1: RFC3339 →
#     HH:MM:SS at the render, the engine stamp cut off); the buffer's
#     first stamp = the uptime source (fix:w32-uptime, the number is real
#     time → a presence pin)
LOGTZ="$TMP/glog-tz"
printf '2026-11-18T07:26:54.100000000Z 2026-11-18 07:26:54 [INFO] [gpu] event=queue_budget kind=llm observed=0 budget=8 expected_max=3 cap=2\n' > "$LOGTZ"
printf '2026-11-18T07:27:01.200000000Z 2026-11-18 07:27:01 [INFO] [loader] event=load_completed kind=text elapsed_ms=15234 model=qwen3.8-27b-IQ4_XS-pure sessions=1 context_tokens=262144 speculative=dflash2 draft_limit=7\n' >> "$LOGTZ"
printf '2026-11-18T07:27:02.300000000Z 2026-11-18 07:27:02 [INFO] [cache] schema=component-cache-v1 event=configured sessions=1 ram_cache=on capacity_bytes=12884901888 automatic_bytes=4294967296 disk_capacity_bytes=68719476736\n' >> "$LOGTZ"

# running the frame's python panel (common to the W1 scenarios); the
#     container is set by the scenario — the frame has had no engine
#     default since fix-round 2 (R6)
wrun() {  # wrun <env-префикс уже задан caller> — stdout+stderr наружу
  env PATH="$FAUX_GUFO:$PATH" PYTHONPATH="$ROOT/core/tpl/python/watch" \
    LCTL_FAUX_LOG="$FAUXLOG" LCTL_FAUX_CNT="$FAUXCNT" LCTL_WATCH_CONTAINER=gufo \
    "$@" python3 "$ROOT/engines/gufo/tpl/python/watch.py" 2>&1
}

scen_w1_plain() {
  new_stack w1; fresh_log
  local out rc lg e1 m1
  out=$(wrun LCTL_FAUX_PODMAN_LOGS="$LOGTZ" \
    LCTL_FAUX_METRICS_SEQ="$ROOT/engines/gufo/tests/fixtures/metrics_snap1.txt:$ROOT/engines/gufo/tests/fixtures/metrics_snap2.txt:$ROOT/engines/gufo/tests/fixtures/metrics_snap3.txt" \
    LCTL_WATCH_PORT=8080 LCTL_WATCH_INTERVAL=0.01 LCTL_WATCH_TICKS=3); rc=$?
  [ "$rc" = 0 ] || { echo "DBG-w1 rc=$rc: $(tail -3 <<<"$out")" >&2; return 1; }
  [ "$(grep -c '/metrics' "$FAUXLOG")" = 3 ] || return 1   # 1 вызов на тик
  [ "$(grep -c '/ready' "$FAUXLOG")" = 3 ] || return 1     # готовность
  grep -q 'podman logs --tail 200 -t' "$FAUXLOG" || return 1  # F1: сид С -t, окно 200 (W3.2.1-D1)
  lg=$(grep ' \[логи\] ' <<<"$out" | tail -1)
  printf '%s' "$lg" | grep -qE '\[логи\] [0-9]{2}:[0-9]{2}:[0-9]{2} \[INFO\] \[cache\]' || return 1
  ! printf '%s' "$lg" | grep -q '2026-11-18' || return 1   # podman-метка → HH:MM:SS, движковый штамп срезан (F1)
  e1=$(grep ' \[движок\] ' <<<"$out" | sed -n 1p)
  printf '%s' "$e1" | grep -q 'аптайм ' || return 1        # от первой -t-метки (значение — реальное время, пин по presence)
  printf '%s' "$e1" | grep -q 'спек dflash2 K=7 | ctx 1 × 262 144 ток | kv f16 (16 бит)' || return 1
  printf '%s' "$e1" | grep -q 'кэш-ram 12.0 GiB (бюджет) | кэш-диск 64.0 GiB (бюджет) | lost 0' || return 1
  ! grep -q 'готов' <<<"$out" || return 1                  # D4: ряда Статус нет — буллет шапки единственный индикатор
  ! grep -qE '\[(роут|счётчики|очередь)\]' <<<"$out" || return 1  # специфика ряда 2 удалена (лейаут §1)
  m1=$(grep ' \[метрики\] ' <<<"$out" | sed -n 1p)
  printf '%s' "$m1" | grep -q '· 21.4 (посл) tok/s' || return 1    # gen_last gauge
  printf '%s' "$m1" | grep -q '· 98.7 (посл) tok/s' || return 1    # prefill_last gauge
  printf '%s' "$m1" | grep -q 'кэш 990.0k из 1.0M ток из кэша (99.0 %)' || return 1
  printf '%s' "$m1" | grep -q 'принято 60.0 % · τ — ток/цикл' || return 1  # W3.3 v2: тик1 — база session → τ «—» (seed (а))
  printf '%s' "$m1" | grep -q 'оч 0 запросов | ttft — | сген 50.0k ток' || return 1
  grep -q '| RAM ' <<<"$(grep ' \[железо\] ' <<<"$out" | head -1)" || return 1
  ! grep -q 'lost' <<<"$(grep ' \[железо\] ' <<<"$out" | head -1)" || return 1  # W3: lost — в Конфигурации «Движка»
  ! grep -qi 'lookup' <<<"$out" || return 1                # prompt-lookup — ряда в схеме нет
  ! grep -q 'prompt_state' <<<"$out" || return 1           # не читаются (claim-раннеры)
  ! grep -q '?' <<<"$out" || return 1                      # инвариант W3: «?» не существует
  grep -q '· 53.3 (посл) tok/s' <<<"$(grep ' \[метрики\] ' <<<"$out" | sed -n 3p)" || return 1  # done-тик: gauge сменился
  grep -q 'decode +300 · prefill +512 (ток/тик) · drafts +0 (цикл/тик)' \
    <<<"$(grep ' \[скорость\] ' <<<"$out" | sed -n 2p)" || return 1
  grep -q 'decode +0 · prefill +0 (ток/тик) · drafts +60 (цикл/тик)' \
    <<<"$(grep ' \[скорость\] ' <<<"$out" | sed -n 3p)" || return 1  # ΔK_ROUNDS 5000→5060
  return 0
}

scen_w1_dead() {
  new_stack w1d; fresh_log
  local out rc
  out=$(wrun LCTL_FAUX_CURL_FAILALL=1 \
    LCTL_WATCH_PORT=8080 LCTL_WATCH_INTERVAL=0.01 LCTL_WATCH_TICKS=3); rc=$?
  [ "$rc" = 0 ] || return 1
  [ "$(grep -c 'недоступен' <<<"$out")" = 3 ] || return 1  # ровно одна строка на тик
  [ "$(grep -c '/metrics' "$FAUXLOG")" = 3 ] || return 1
  ! grep -qi 'traceback' <<<"$out" || return 1
  return 0
}

scen_w1_selfcheck() {
  local troot="${LCTL_TREE:-$ROOT}" out rc
  out=$(LCTL_WATCH_SELFCHECK=1 PYTHONPATH="$troot/core/tpl/python/watch" \
    timeout 120 python3 "$troot/engines/gufo/tpl/python/watch.py" 2>&1); rc=$?
  [ "$rc" = 0 ] \
    && printf '%s' "$out" | grep -q 'selfcheck: 104/104 ok' \
    && printf '%s' "$out" | grep -q 'selfcheck engine: 60/60 ok' || return 1
  return 0
}

scen_w1_dispatcher() {
  new_stack w1disp; fresh_log
  local out rc
  out=$(env PATH="$FAUX_GUFO:$PATH" HOME="$TMP/home" USER=tester \
    LCTL_DIR="$LCTL_TEST_STACK" LCTL_ENGINE=gufo \
    LCTL_FAUX_LOG="$FAUXLOG" LCTL_FAUX_CNT="$FAUXCNT" \
    LCTL_FAUX_PODMAN_LOGS="$LOGTZ" \
    LCTL_FAUX_METRICS="$ROOT/engines/gufo/tests/fixtures/metrics_snap1.txt" \
    LCTL_WATCH_TICKS=1 \
    bash "$ROOT/lctl" watch --interval 1 2>&1); rc=$?
  [ "$rc" = 0 ] || { echo "DBG-w1disp rc=$rc: $(tail -4 <<<"$out")" >&2; return 1; }
  printf '%s' "$out" | grep -q ' \[движок\] ' || return 1
  return 0
}

# fix-r1 (EXP-002): the engine's global compose options — gufo calls
#     `podman compose --in-pod false -f compose.yml <cmd>` (the flag
#     BEFORE -f and the subcommand, one seam on up/stop/down), hipfire —
#     WITHOUT the flag
scen_g19_inpod() {
  new_stack g19; fresh_log
  # hipfire: no global set → a call without --in-pod
  hf 'compose up -d; compose down' >/dev/null 2>&1 || return 1
  grep -q -- '--in-pod' "$FAUXLOG" && return 1
  grep -q 'podman compose -f compose.yml -f compose.halo.yml -f compose.local.yml up -d' "$FAUXLOG" || return 1
  # gufo: --in-pod false BEFORE -f, the stack paths on every compose call
  fresh_log
  LCTL_TEST_ENGINE=gufo hf 'compose up -d; compose stop; compose down' >/dev/null 2>&1 || return 1
  [ "$(grep -c 'podman compose --in-pod false -f compose.yml up -d' "$FAUXLOG")" = 1 ] || return 1
  grep -q 'podman compose --in-pod false -f compose.yml stop' "$FAUXLOG" || return 1
  grep -q 'podman compose --in-pod false -f compose.yml down' "$FAUXLOG" || return 1
  return 0
}

# G-bench hooks (stage 7): engine_bench_model — the name from
#     load_completed (on GLOGSP — with spaces as one value), an empty
#     route → die; engine_bench_extras — a /metrics snapshot
#     (metrics_snap1) + the uptime (LCTL_BENCH_UPTIME — the battery seam)
#     → JSON with a gen_avg 20.0 + the route_spec from the log; W3.2: the
#     -t log capture for the ratio-of-sums in the faux journal
scen_g_bench_hooks() {
  local out
  out=$(LCTL_TEST_ENGINE=gufo LCTL_FAUX_PODMAN_LOGS="$GLOGOK" hf 'engine_bench_model') || return 1
  [ "$out" = "qwen3.8-27b-IQ4_XS-pure" ] || return 1
  out=$(LCTL_TEST_ENGINE=gufo LCTL_FAUX_PODMAN_LOGS="$GLOGSP" hf 'engine_bench_model') || return 1
  [ "$out" = "Qwen3.8 Flash Next" ] || return 1
  LCTL_TEST_ENGINE=gufo hf 'engine_bench_model' >/dev/null 2>&1 && return 1   # пустой роут обязан умирать
  fresh_log
  out=$(LCTL_TEST_ENGINE=gufo LCTL_FAUX_PODMAN_LOGS="$GLOGOK" \
    LCTL_FAUX_METRICS="$ROOT/engines/gufo/tests/fixtures/metrics_snap1.txt" \
    LCTL_BENCH_UPTIME=2500 \
    LCTL_TEST_PATH="$FAUX_GUFO:$PATH" hf 'engine_bench_extras bench-runs-x' 2>&1) || return 1
  grep -q 'podman logs -t --tail 50' "$FAUXLOG" || return 1  # аптайм-захват W3.2 (ratio-of-sums §5)
  printf '%s' "$out" | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d["gen_avg"] == 20.0, d
assert d["tau"] == 12, d
assert d["route_spec"] == "dflash2", d
assert "cumulative" in d["metrics_note"], d' || return 1
  return 0
}

# the section registration (the runner calls by the ADAPTER_FUNCS list)
ADAPTER_FUNCS+=" gufo_scenarios"
gufo_scenarios() {
  if scen_g0_registry; then ok "G1: реестр gufo — 9 полей × 3 профиля литералам task 3.1, алиасы R1+legacy, лестницы, ref EXP-007, суммы пинов (flash=111334654778)"; else bad "G1 реестр/пины"; fi
  if scen_g0_pins_download; then ok "G2: пины/доставка — file:// PASS sha, SKIP без сети, SHA-MISMATCH с удалением, «мало места» до трафика, pull по имени (неизвестный → die)"; else bad "G2 пины/доставка"; fi
  if scen_g0_check_types; then ok "G3: check_types на фиксдурах gguf — зелёный/КРАСНЫЙ/«нечего проверять»"; else bad "G3 check_types"; fi
  if scen_g1_serve_args; then ok "G4: serve_args — канон 27b байт-в-байт (с --mmproj, fix:w43), parallel/flash токены ролей + кэш-тиры, чистота, чужой токен → die"; else bad "G4 serve_args"; fi
  if scen_g1_canon; then ok "G5: canon.env — upsert без дублей, чужие ключи целы, чтение, неизвестный → ''"; else bad "G5 canon.env"; fi
  if scen_g1_compose; then ok "G6: compose-золотой — name: gufo, F9-флаги, маунты/порт, fallback поля 7, canon.env-контекст побеждает, LCTL_SESSIONS-оверрайд; контракт этапа 8: target-каталог получает compose.yml (входы tpl+canon.env), без аргумента — \$STACK_DIR"; else bad "G6 compose-рендер"; fi
  if scen_g1_probe_ok; then ok "G7: probe-лестница ok — 196608(load_failed)→163840(ok): ровно 2 up, канон 163840, журнал с вердиктами, 131072 не достигнута"; else bad "G7 probe ok"; fi
  if scen_g1_probe_fact; then ok "G8: probe факт≠заказ (2.1-F4) — канон = факт 163840 + WARN F21, лестница СТОП (1 up)"; else bad "G8 probe факт"; fi
  if scen_g1_probe_die; then ok "G9: probe полный отказ — die «это тоже результат» (не rc1-ветка), canon.env не создан, журнал 3 отказа"; else bad "G9 probe die"; fi
  if scen_g1_probe_single; then ok "G10: single (лестница '-') — probe не зовётся (ups 0), канон = поле 7, compose отрендерен"; else bad "G10 probe single"; fi
  if scen_g2_health_path_gufo; then ok "G11: K-1 сторона gufo — wait_health curls /ready (ENGINE_HEALTH_PATH), /health не зовётся"; else bad "G11 health-path gufo"; fi
  if scen_g2_health; then ok "G12: health-диалект — parse_route имя-с-пробелами, engine_health_ok безусловно, смоук 3 промпта + ретрай ровно 1 + die-ветки, hline+JSON"; else bad "G12 health-диалект"; fi
  if scen_g2_doctor; then ok "G13: doctor gufo — инвентарь+типы зелёный, configured-строка, /metrics best-effort, пустой сет без die, gpu-lock"; else bad "G13 doctor"; fi
  if scen_g_smoke_vision; then ok "G2v: смоук-vision — mmproj в сете → 6-й запрос с image_url, SMOKE: OK, ровно 6 вызовов (fix:w43)"; else bad "G2v смоук-vision"; fi
  if scen_g3_cmp_ref; then ok "G14: cmp_ref — неснятый → WARN, окно ±25% → PASS, регрессия → WARN+hint"; else bad "G14 cmp_ref"; fi
  if scen_g3_agent_happy; then ok "G15: agent-check happy — 25 chat-POST, сводка PASS=4 WARN=0 FAIL=0, state удалён, рестарт-restore reuse=live"; else bad "G15 agent-check happy"; fi
  if scen_g3_agent_warn; then ok "G16: agent-check 27b-parallel — референсы не сняты: PASS=0 WARN=4 FAIL=0 rc 0, reuse=disk"; else bad "G16 agent-check WARN"; fi
  if scen_g3_agent_fail; then ok "G17: agent-check reuse=none — FAIL=1 rc 1 (disk-restore не сработал)"; else bad "G17 agent-check FAIL"; fi
  if scen_g3_switch; then ok "G18: switch hipfire↔gufo — off hipfire ДО первого up, bootstrap gufo flash (пины SKIP, canon предзасеян → probe пропущен), юниты gufo-compose, канон gufo"; else bad "G18 switch"; fi
  if scen_w1_plain; then ok "W1: gufo-панель plain W3.2 — 3 тика по метрик-фикстурам: [движок] (аптайм от -t-метки presence, dflash2 K=7, f16 (16 бит), бюджеты 12/64 GiB, lost 0; Статус-ряда нет — D4), [метрики] общий блок (посл 21.4/98.7 gauge, кэш 990.0k из 1.0M (99.0 %), принято 60.0 % · τ — (тик1 — база session, v2), оч 0 запросов, ttft —, сген 50.0k), специфика ряда 2 удалена, live-пульс +300/+512, done-пульс drafts +60 цикл/тик (ΔK_ROUNDS), логи с -t (штамп срезан), «?» нет"; else bad "W1 plain-стрим"; fi
  if scen_w1_dead; then ok "W1: dead-server — ровно 3 строки «недоступен» (одна на тик), /metrics = тикам, без traceback"; else bad "W1 dead-server"; fi
  if scen_w1_selfcheck; then ok "W1: selfcheck gufo-панели — каркас 104/104 + движок 60/60 (методики §5 v2 W3.3: активное окно — session ratio-of-sums по секундным счётчикам (ген/prefill/τ), анти-wall «2 мин из 5», гейджи-«посл», uptime_from_log, scheme v2, draft-пульс ΔK_ROUNDS, hold-семантика (Δseconds-гейты: seed «—», done → кэш, тихий → держит, recreate → сброс), парсеры+draft_limit, plain-пины)"; else bad "W1 selfcheck"; fi
  if scen_w1_dispatcher; then ok "W1: lctl watch через реальный диспетчер — exec python ENGINE_WATCH_TUI (engine_watch_env → PYTHONPATH каркаса, LCTL_WATCH_ENGINE от ядра), стрим rc 0"; else bad "W1 watch-диспетчер"; fi
  if scen_g19_inpod; then ok "fix-r1: compose-глобал адаптера — gufo: '--in-pod false' ДО -f на up/stop/down; hipfire: вызов без флага (EXP-002: pod-обёртка × --userns несовместимы)"; else bad "fix-r1 in-pod"; fi
  if scen_g_bench_hooks; then ok "G20: bench-хуки (этап 7) — engine_bench_model имя из load_completed (в т.ч. с пробелами), пустой роут → die; engine_bench_extras gen_avg 20.0 (аптайм-шов W3.2, -t-захват в журнале) + tau 12 + route_spec из лога"; else bad "G20 bench-хуки"; fi
}
