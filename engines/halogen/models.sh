# shellcheck shell=bash
# ── halogen: the weights — the pin tables + delivery (the gufo models.sh pattern) ──
# A set entry's format: filename|size_bytes|sha256|url|role. The roles:
# main|draft|mmproj|ngram|tokenizer — set_file_role reads main/draft/mmproj;
# ngram and tokenizer are service ones (the pull iterates the registry's
# field 2, the roles do not matter there).
# The pins — FULL 64-hex sha256, taken from the HF API (blobs) 2026-11-25 +
# the tokenizer files by sha256sum over resolve/main (non-LFS; the git-oid
# in the API is a sha1).
# The halogen-flash set (the v2 checkpoint + the mandatory sidecars, the
# weight 120.3 GB):
#   v2.hgn 66.7G (the trunk) + ngram.hgn 51.2G (an FP8 n-gram lookup —
#   required beside the checkpoint) + drafter-r2-ht4.hgn 1.39G (the 0.20.7
#   draft head) + vision.hgn 0.84G (an mmproj analog, HALOGEN_VISION_TOWER=1)
#   + tokenizer/ 6 files ~25.9M.
# The halogen-27b set (halogen-qwen3.8-27b-ht4, the 0.21.0+ checkpoint —
# the server picks the engine from the checkpoint, the repo README):
#   27b-ht4.hgn 13.8G (the 4-bit trunk — the draft head is INSIDE the
#   checkpoint: no separate draft/ngram file for this set) + vision.hgn
#   0.92G (BF16 tower, optional — HALOGEN_VISION_TOWER=1 when on disk) +
#   tokenizer/ 6 files ~25.9M (the base model's, byte-identical to
#   Flash-Next's per the repo README — the pins reused). Total 14.7 GB.
# We do NOT set HALOGEN_DOWNLOAD (the container has no outbound): the
# delivery — download_file (curl -C - + a sha-verify), identical to gufo.
#
# @typedef weight_set: 'halogen_flash' | 'halogen_27b'

set_halogen_27b="qwen38-27b-ht4.hgn|13786218048|cd2570dc985174ecbea82b65b2ed5c3125d56512fdf88ddd43f7b17c37cd5eff|https://huggingface.co/peonist-ai/halogen-qwen3.8-27b-ht4/resolve/main/qwen38-27b-ht4.hgn|main
qwen38-27b-vision.hgn|921514496|869fa7d2347c67f2a74a7cbb18fe271e73e4d8e359ced8e2548397343f001829|https://huggingface.co/peonist-ai/halogen-qwen3.8-27b-ht4/resolve/main/qwen38-27b-vision.hgn|mmproj
tokenizer/chat_template.jinja|8952|c3cf9e34abf4f9e36c2d72165aa9c132d3e2a725b6c2586aaa3a8af9d7a81041|https://huggingface.co/peonist-ai/halogen-qwen3.8-27b-ht4/resolve/main/tokenizer/chat_template.jinja|tokenizer
tokenizer/generation_config.json|202|e70c136c1b78ddc1fb0905bac8e733a4dc448d4f852a5dd75143fffc70be550e|https://huggingface.co/peonist-ai/halogen-qwen3.8-27b-ht4/resolve/main/tokenizer/generation_config.json|tokenizer
tokenizer/merges.txt|3353259|a9d356d7bdf1ef4949e3e748e95b8e10ad9d4e2e838eddc38a0a7b6b94d1db8d|https://huggingface.co/peonist-ai/halogen-qwen3.8-27b-ht4/resolve/main/tokenizer/merges.txt|tokenizer
tokenizer/tokenizer.json|12809320|0997f410c57a1f4e53b09e4be8f4a172d90edd9564368fb0847030937229b9f3|https://huggingface.co/peonist-ai/halogen-qwen3.8-27b-ht4/resolve/main/tokenizer/tokenizer.json|tokenizer
tokenizer/tokenizer_config.json|17928|b11349aafa7cdc6a320767cf7ceb29ed82f7eda5d65e8e0819e76f0ce947bf27|https://huggingface.co/peonist-ai/halogen-qwen3.8-27b-ht4/resolve/main/tokenizer/tokenizer_config.json|tokenizer
tokenizer/vocab.json|6722759|ce99b4cb2983d118806ce0a8b777a35b093e2000a503ebde25853284c9dfa003|https://huggingface.co/peonist-ai/halogen-qwen3.8-27b-ht4/resolve/main/tokenizer/vocab.json|tokenizer"

set_halogen_flash="qwen38-flash-next-v2.hgn|66687678432|71246c6ab3fc1de2cf06326f18e275fe9c2a18366d646ed3357d194c884fc687|https://huggingface.co/peonist-ai/halogen-qwen3.8-flash-next/resolve/main/qwen38-flash-next-v2.hgn|main
qwen38-flash-next-ngram.hgn|51200246144|3450acada94e19aabad88bd49b45eb70304820949c2240fc178067b20ae5dffe|https://huggingface.co/peonist-ai/halogen-qwen3.8-flash-next/resolve/main/qwen38-flash-next-ngram.hgn|ngram
qwen38-flash-next-drafter-r2-ht4.hgn|1488276864|6feed319c3d8fa6c4c6cb021131205c3e9ed3164446fe9d86b897cf514da00c8|https://huggingface.co/peonist-ai/halogen-qwen3.8-flash-next/resolve/main/qwen38-flash-next-drafter-r2-ht4.hgn|draft
qwen38-flash-next-vision.hgn|897916416|d62e0ae553fe88afd3833733d4a4c669f34d20fd8dfce4b9610525bed2134b10|https://huggingface.co/peonist-ai/halogen-qwen3.8-flash-next/resolve/main/qwen38-flash-next-vision.hgn|mmproj
tokenizer/chat_template.jinja|8952|c3cf9e34abf4f9e36c2d72165aa9c132d3e2a725b6c2586aaa3a8af9d7a81041|https://huggingface.co/peonist-ai/halogen-qwen3.8-flash-next/resolve/main/tokenizer/chat_template.jinja|tokenizer
tokenizer/generation_config.json|202|e70c136c1b78ddc1fb0905bac8e733a4dc448d4f852a5dd75143fffc70be550e|https://huggingface.co/peonist-ai/halogen-qwen3.8-flash-next/resolve/main/tokenizer/generation_config.json|tokenizer
tokenizer/merges.txt|3353259|a9d356d7bdf1ef4949e3e748e95b8e10ad9d4e2e838eddc38a0a7b6b94d1db8d|https://huggingface.co/peonist-ai/halogen-qwen3.8-flash-next/resolve/main/tokenizer/merges.txt|tokenizer
tokenizer/tokenizer.json|12809320|0997f410c57a1f4e53b09e4be8f4a172d90edd9564368fb0847030937229b9f3|https://huggingface.co/peonist-ai/halogen-qwen3.8-flash-next/resolve/main/tokenizer/tokenizer.json|tokenizer
tokenizer/tokenizer_config.json|17928|b11349aafa7cdc6a320767cf7ceb29ed82f7eda5d65e8e0819e76f0ce947bf27|https://huggingface.co/peonist-ai/halogen-qwen3.8-flash-next/resolve/main/tokenizer/tokenizer_config.json|tokenizer
tokenizer/vocab.json|6722759|ce99b4cb2983d118806ce0a8b777a35b093e2000a503ebde25853284c9dfa003|https://huggingface.co/peonist-ai/halogen-qwen3.8-flash-next/resolve/main/tokenizer/vocab.json|tokenizer"

# Purpose: a set's entries line by line from the header table — the only
#   reader of the table. A 1:1 weights_for port.
#
# @param 1: weight_set      # the set dir
# @stdout string[]          # the set's entries, one per file
# @returns integer          # 0 — the entries printed; 1 — an unknown set
weights_for() {
  local name="set_$1" v
  v="${!name:-}"
  [ -n "$v" ] || return 1
  printf '%s\n' "$v"
}

# Purpose: the set's file name with the given role (main — for CHECKPOINT,
#   mmproj — for the smoke's vision gate). A 1:1 set_file_role port.
#
# @param 1: weight_set      # the set dir
# @param 2: main|draft|mmproj # the role from the table
# @stdout string            # the file name (only on rc 0)
# @returns integer          # 0 — found; 1 — not found / an unknown set
set_file_role() {
  local set="$1" role="$2" f size sha url r
  while IFS='|' read -r f size sha url r; do
    if [ "$r" = "$role" ]; then printf '%s\n' "$f"; return 0; fi
  done < <(weights_for "$set") || return 1
  return 1
}

# Purpose: the free space in GiB (one decimal) on the dir's FS; creates the
#   dir when missing (mkdir -p). A 1:1 free_disk_gib port.
#
# @param 1: string          # the dir (its FS is probed)
# @stdout string           # GiB with one decimal or «?»
# @returns integer         # always 0 (a «?» print on a stat failure)
free_disk_gib() {
  local dir="$1" out
  mkdir -p "$dir"
  out=$(stat -f -c '%a %S' "$dir" 2>/dev/null) || { echo "?"; return 0; }
  awk -v line="$out" 'BEGIN{n=split(line,a," "); printf "%.1f", (n==2 ? a[1]*a[2] : 0)/1073741824}'
}

# Purpose: the download work unit — fetch one file with a pre-flight
#   «нужно X GiB (остаток), свободно Y Gi» BEFORE the traffic, with curl
#   resuming (-C - .part resume) and a sha256 verification after.
#   MIRROR-FIRST: a non-empty LCTL_MIRROR_BASE → the first attempt
#   "$MIRROR/<basename>"; a mirror failure → a WARN and the pin URL. A 1:1
#   body port (gufo models.sh).
#
# @param 1: string   # the url (https://… from the table or file:// for tests)
# @param 2: string   # dest — the full path of the final file
# @param 3: integer  # size — the size pin in bytes
# @param 4: /^[0-9a-f]{64}$/ # sha — the sha256 pin
# @returns integer   # 0 — the file in place and sha OK; 1 — a failure
#   (space/network/sha)
download_file() {
  local url="$1" dest="$2" size="$3" sha="$4"
  local part="$dest.part" attempt remaining psz need_gib have_gib ok got
  local mirror="${LCTL_MIRROR_BASE:-${GFCTL_MIRROR_BASE:-}}" try_url mrc http_code pre_size
  mkdir -p "$(dirname "$dest")"
  if [ -f "$dest" ] && [ "$(stat -L -c %s "$dest")" = "$size" ]; then
    echo "SKIP: $(basename "$dest") (размер совпал — честный sha-статус даёт: lctl doctor)"
    return 0
  fi
  remaining="$size"
  ok=""
  if [ -f "$part" ]; then
    psz=$(stat -c %s "$part" 2>/dev/null || echo 0)
    if [ "$psz" -gt 0 ] && [ "$psz" -le "$size" ]; then remaining=$((size - psz)); fi
    if [ "$psz" = "$size" ]; then
      log "локальный $(basename "$part") уже полного размера ($size B) — сеть не нужна"
      ok=1
    fi
    if [ "$psz" -gt "$size" ]; then
      warn "$(basename "$part") БОЛЬШЕ пин-размера ($psz B > $size B) — докачка не завершится корректно: SHA-арбитраж отбросит .part и модель перекачается; практический исход один — удали .part руками (rm \"$part\") и повтори"
    fi
  fi
  need_gib=$(awk -v b="$remaining" 'BEGIN{printf "%.1f", b/1073741824}')
  have_gib=$(free_disk_gib "$(dirname "$dest")")
  echo "нужно ${need_gib} GiB (остаток), свободно ${have_gib} GiB"
  if awk -v a="$need_gib" -v b="$have_gib" 'BEGIN{exit !(a>b)}'; then
    warn "мало места: нужно ${need_gib} GiB, свободно ${have_gib} GiB — отказ ДО трафика"
    return 1
  fi
  if [ -z "$ok" ]; then
    for attempt in 1 2 3; do
      if [ -n "$mirror" ] && [ "$attempt" = 1 ]; then
        try_url="$mirror/$(basename "$dest")"
        log "качаю (попытка 1/3, зеркало): $(basename "$dest") ← $try_url"
        pre_size=$(stat -c %s "$part" 2>/dev/null || echo 0)
        mrc=0; http_code=$(curl -sSL -C - --connect-timeout 10 -o "$part" -w '%{http_code}' "$try_url") || mrc=$?
        if [ "$mrc" = 0 ]; then
          case "$http_code" in
            2*|000) log "зеркало ответило годным файлом (http ${http_code:-?})"; ok=1; break ;;
            *)      mrc=1 ;;
          esac
        fi
        if [ "$pre_size" -gt 0 ]; then truncate -s "$pre_size" "$part" 2>/dev/null || true; else rm -f "$part"; fi
        warn "зеркало не ответило годным файлом (rc=$mrc, http=${http_code:-?}) — фоллбэк на пин-URL"
      fi
      log "качаю (попытка $attempt/3): $(basename "$dest") ← $url"
      if curl -sSL -C - --retry 4 --retry-delay 5 --connect-timeout 20 -o "$part" "$url"; then ok=1; break; fi
      [ "$attempt" -lt 3 ] && sleep 15
    done
  fi
  if [ -z "$ok" ]; then
    warn "скачивание не удалось за 3 попытки — $part сохранён для докачки"
    return 1
  fi
  mv -f "$part" "$dest"
  got=$(sha256sum "$dest" 2>/dev/null | awk '{print $1}' || true)
  if [ "$got" = "$sha" ]; then
    echo "PASS: $(basename "$dest") (sha OK)"
    return 0
  fi
  rm -f "$dest" "$part"
  warn "SHA-MISMATCH: $(basename "$dest") удалён (источник изменился или файл битый) — перекачай: lctl pull $ENGINE <профиль>"
  return 1
}

# Purpose: the engine_pull_model hook (contract §2.3) — fetch one file by
#   its pin: resolve the filename over the halogen-flash table, deliver via
#   download_file into $MODELS_DIR (the set's mount dir; cmd_pull sets it
#   with an env prefix). Idempotent: a pin-sized file in place → SKIP
#   without the network. Slash paths (tokenizer/…) are fine: download_file's
#   pre-flight creates the dirname.
#
# Side effects: files in $MODELS_DIR (.part/dest), the network when
#   downloading; log/echo lines to stdout, warns to stderr.
#
# @param 1: string    # a file name from the set's table
# @returns integer   # 0 — the file in place (or fetched with sha OK); else
#   download_file's rc; an unknown name — die
engine_pull_model() {
  local f="$1" set_name pf size sha url role found=""
  set_name=$(engine_model_set "$(cur_profile)" 2>/dev/null) || set_name=halogen-flash
  while IFS='|' read -r pf size sha url role; do
    if [ "$pf" = "$f" ]; then found=1; break; fi
  done < <(weights_for "$set_name") || true
  [ -n "$found" ] || die "engine_pull_model: файл '$f' не найден в таблице пинов halogen ($set_name)"
  log "тяну модель $f (сет $set_name)"
  download_file "$url" "$MODELS_DIR/$f" "$size" "$sha"
}

# Purpose: an honest set inventory — line by line «файл | size-пин B |
#   статус» + the unfinished .part lines. The sha is recomputed ALWAYS on a
#   matched size. A 1:1 inventory port.
#
# @param 1: weight_set      # the set dir
# @stdout string[]          # the inventory lines
# @returns integer          # always 0 (a report, not a check)
inventory() {
  local set="$1" dir f size sha got actual status part psz
  dir="$MODELS_BASE/$set"
  while IFS='|' read -r f size sha _url _role; do
    [ -n "$f" ] || continue
    if [ -f "$dir/$f" ]; then
      actual=$(stat -L -c %s "$dir/$f" 2>/dev/null || echo 0)
      if [ "$actual" = "$size" ]; then
        got=$(sha256sum "$dir/$f" 2>/dev/null | awk '{print $1}' || true)
        if [ "$got" = "$sha" ]; then
          status="есть, размер OK, sha OK"
        else
          status="есть, размер OK, sha ✗ (перекачай: lctl pull $ENGINE $(cur_profile 2>/dev/null || echo flash))"
        fi
      else
        status="есть, РАЗМЕР ≠ (факт ${actual} B)"
      fi
      printf '%s | %s B | %s\n' "$f" "$size" "$status"
    else
      printf '%s | %s B | НЕТ (тяни: lctl pull %s %s)\n' "$f" "$size" "$ENGINE" "$(cur_profile 2>/dev/null || echo flash)"
    fi
    for part in "$dir/$f.part"; do
      [ -f "$part" ] || continue
      psz=$(stat -c %s "$part" 2>/dev/null || echo 0)
      printf '%s.part | %s B | недокачан (докачка при следующем pull)\n' "$f" "$psz"
    done
  done < <(weights_for "$set")
}
