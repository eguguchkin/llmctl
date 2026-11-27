# shellcheck shell=bash
# ── halogen: the doctor engine sections (Ф3; a port of the gufo doctor slice) ──
# The engine_doctor hook (contract §2.3) — extra `lctl doctor` sections on
# top of the core parts: the set's sha inventory (the models.sh inventory —
# honest), the types (not applicable to .hgn — an honest line), the live
# prompt cache (a du + the /metrics halogen:*), the gpu-lock (the gufo
# parity: a non-empty podman ps → a WARN «переключение через lctl
# start/stop»).

# Purpose: the engine diagnostic sections — read-only and printing.
#
# Side effects: podman ps (a read), a curl /metrics (5 s), sha256sum over
#   the set files (the inventory), a du of the cache dir; the sections
#   printed to stdout, warns to stderr. Creates/deletes nothing, calls no
#   sudo.
#
# Limitations/assumptions: requires the ENGINE, PORT, MODELS_BASE,
#   STATE_BASE, CONTAINER globals (dispatcher),
#   cur_profile/engine_model_set/inventory (the adapter). An unavailable
#   /metrics → a degradation line, not a refusal (doctor is a report).
#
# @stdout string   # the «веса»/«типы»/«кэш»/gpu-lock sections
# @returns integer # always 0
engine_doctor() {
  local prof set_name dir m cache_dir cache_b
  prof=$(cur_profile)
  set_name=$(engine_model_set "$prof")
  dir="$MODELS_BASE/$set_name"
  echo "── веса (сет $set_name): инвентарь ──"
  inventory "$set_name" || true
  echo "── типы ──"
  if [ -d "$dir" ] && [ -n "$(ls "$dir" 2>/dev/null)" ]; then
    echo "типы не проверяются: формат .hgn закрытый, не GGUF (числовой ffn-контракт — gufo-специфика); целостность — sha-инвентарь выше"
  else
    echo "(весов нет — проверка типов пропущена)"
  fi
  echo "── prompt-cache (профиль $prof) ──"
  cache_dir="$STATE_BASE/$prof"
  cache_b=$(du -sb "$cache_dir" 2>/dev/null | awk '{print $1}') || true
  printf 'каталог: %s (%s GiB)\n' "$cache_dir" \
    "$(awk -v b="${cache_b:-0}" 'BEGIN{printf "%.1f", b/1073741824}')"
  m=$(curl -fsS -m 5 "http://127.0.0.1:$PORT/metrics" 2>/dev/null) || true
  if [ -n "$m" ]; then
    printf 'prompt-cache: entries %s | RAM %s MB | диск %.1f / %.1f GiB | hits %s / misses %s | saved-tokens %s | evicted %s\n' \
      "$(awk -v n="halogen:cache_entries" '$1 == n {print $2; exit}' <<<"$m")" \
      "$(awk -v n="halogen:cache_bytes" '$1 == n {printf "%.0f", $2/1048576; exit}' <<<"$m")" \
      "$(awk -v n="halogen:cache_disk_bytes" '$1 == n {printf "%.1f", $2/1073741824; exit}' <<<"$m")" \
      "$(awk -v n="halogen:cache_disk_budget_bytes" '$1 == n {printf "%.1f", $2/1073741824; exit}' <<<"$m")" \
      "$(awk -v n="halogen:cache_hits_total" '$1 == n {print $2; exit}' <<<"$m")" \
      "$(awk -v n="halogen:cache_misses_total" '$1 == n {print $2; exit}' <<<"$m")" \
      "$(awk -v n="halogen:cache_prompt_tokens_saved_total" '$1 == n {print $2; exit}' <<<"$m")" \
      "$(awk -v n="halogen:cache_evicted_total" '$1 == n {print $2; exit}' <<<"$m")"
    printf 'kv/очередь: reserved %s / %s позиций | ждут места %s | очередь: ждавших %s, longest %s s, ушли %s\n' \
      "$(awk -v n="halogen:kv_pool_reserved_tokens" '$1 == n {print $2; exit}' <<<"$m")" \
      "$(awk -v n="halogen:kv_pool_positions" '$1 == n {print $2; exit}' <<<"$m")" \
      "$(awk -v n="halogen:kv_pool_waiting_for_room" '$1 == n {print $2; exit}' <<<"$m")" \
      "$(awk -v n="halogen:queue_waited_total" '$1 == n {print $2; exit}' <<<"$m")" \
      "$(awk -v n="halogen:queue_wait_longest_seconds" '$1 == n {print $2; exit}' <<<"$m")" \
      "$(awk -v n="halogen:queue_gave_up_total" '$1 == n {print $2; exit}' <<<"$m")"
  else
    echo "/metrics недоступен (сервер не отвечает — смотри 'lctl logs')"
  fi
  local names
  names=$(podman ps --format '{{.Names}}' 2>/dev/null || true)
  if [ -n "$names" ]; then
    warn "GPU может быть занят контейнерами: $(echo "$names" | tr '\n' ' ')— переключение движков через lctl start/stop (эксклюзив §А-1)"
  else
    echo "gpu-lock: контейнеров podman нет"
  fi
  return 0
}
