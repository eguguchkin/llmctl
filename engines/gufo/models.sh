# shellcheck shell=bash
# ── gufo: the weights — the pin tables + delivery (a port of gfctl lib/models.sh @ 462573f,
#    the names GFCTL_→LCTL_, TPL_DIR→$ADAPTER_DIR/tpl; 1:1 bodies) ──────────────
# A set entry's format: filename|size_bytes|sha256|url|role, role ∈ main|draft|mtp|mmproj.
# The pins — FULL 64-hex sha256 from the IX/FX windows' dl scripts (a sha-verify
# PASS): 27B — jpetrina pure-IQ4_XS + a z-lab DFlash2 draft (pinned to a
# commit); flash — the unsloth UD-Q4_K_XL 4 shards + the MTP shared-Q8_0.
# The unsloth UD-IQ4_XS (93.6 GB) is NOT related to the profiles — it does
# not load (F3), not pinned.
# The checksum control: flash shards+MTP = 111 334 654 778 B = 111.3 GB ✓ SPEC §5.
# mmproj (the mmproj role, window A/2026-11-25): the unsloth BF16 vision
# sidecar (gufo --mmproj, a ~0.9 GiB VRAM resident); it was previously
# excluded by the «SPEC §5 ban» — deliberately lifted when the vision was
# enabled (the pins from live machines).
#
# @typedef weight_set: '27b' | 'flash'

set_27b="qwen3.8-27b-IQ4_XS-pure.gguf|14534384640|ea5a3c45d407f9b9e5d2c0d647f0ea600f486f6b86b92b56d0823ba073dae675|https://huggingface.co/jpetrina/Qwen3.8-27B-IQ4_XS-pure-GGUF/resolve/main/qwen3.8-27b-IQ4_XS-pure.gguf|main
Qwen3.8-27B-DFlash2-Q4_K_M.gguf|1143006816|1a25c56858e1ebe93f2718ac1d49d1151f9323325c1bbfd6209370f4db131ebd|https://huggingface.co/z-lab/Qwen3.8-27B-DFlash2-GGUF/resolve/2d9571f8ce46e151f61c6499c99dee6079e1d610/Qwen3.8-27B-DFlash2-Q4_K_M.gguf|draft
mmproj-BF16.gguf|931146432|83ee4f4f205fa514161778c41df1ea14144faa0f713510893b63c2395f5c2d53|https://huggingface.co/unsloth/Qwen3.8-27B-GGUF/resolve/main/mmproj-BF16.gguf|mmproj"
set_flash="Qwen3.8-Flash-Next-UD-Q4_K_XL-00001-of-00004.gguf|10946618|acc44040f74d0e55fb89c3967056cce5dbda1bcc52e909c3ba6fc72b5e9c0858|https://huggingface.co/unsloth/Qwen3.8-Flash-Next-GGUF/resolve/main/UD-Q4_K_XL/Qwen3.8-Flash-Next-UD-Q4_K_XL-00001-of-00004.gguf|main
Qwen3.8-Flash-Next-UD-Q4_K_XL-00002-of-00004.gguf|49720539552|45792ae869072d8229384c51c7c73dd959e191505252b41dd71852d9746f5ce4|https://huggingface.co/unsloth/Qwen3.8-Flash-Next-GGUF/resolve/main/UD-Q4_K_XL/Qwen3.8-Flash-Next-UD-Q4_K_XL-00002-of-00004.gguf|main
Qwen3.8-Flash-Next-UD-Q4_K_XL-00003-of-00004.gguf|32803030176|8c76e79d444b16a663d9c8db54e585ed3b1da13eebd2619c37b0c355da803c82|https://huggingface.co/unsloth/Qwen3.8-Flash-Next-GGUF/resolve/main/UD-Q4_K_XL/Qwen3.8-Flash-Next-UD-Q4_K_XL-00003-of-00004.gguf|main
Qwen3.8-Flash-Next-UD-Q4_K_XL-00004-of-00004.gguf|28800138432|5de8b5dbf89409acc39468decafd4a4a95b13c29d88a14b0356107897829ec36|https://huggingface.co/unsloth/Qwen3.8-Flash-Next-GGUF/resolve/main/UD-Q4_K_XL/Qwen3.8-Flash-Next-UD-Q4_K_XL-00004-of-00004.gguf|main
mtp-Qwen3.8-Flash-Next-shared-Q8_0.gguf|2786568256|5ff54097406a905cf3a724c709124ceb0e3e10235ee862298969e91c96fa96e6|https://huggingface.co/unsloth/Qwen3.8-Flash-Next-GGUF/resolve/main/MTP/mtp-Qwen3.8-Flash-Next-shared-Q8_0.gguf|mtp
mmproj-flash-next-BF16.gguf|907542944|2e788f8c511d8093c7b43cb87b2fd7e14228340318057f8fb20c86df2efe2355|https://huggingface.co/unsloth/Qwen3.8-Flash-Next-GGUF/resolve/main/mmproj-BF16.gguf|mmproj"

# Purpose: a set's entries line by line from the header table (the '|'
#   separator: filename|size|sha256|url|role) — the only reader of the
#   table. A 1:1 gfctl weights_for port.
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

# Purpose: the set's file name with the given role (the @DRAFT@/@MTP@
#   substitution in serve_extra; main — for --model). A 1:1 gfctl
#   set_file_role port.
#
# @param 1: weight_set      # the set dir
# @param 2: main|draft|mtp  # the role from the table
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
#   dir when missing (mkdir -p). A 1:1 gfctl free_disk_gib port.
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
#   MIRROR-FIRST (gfctl 4.1-F1): a non-empty LCTL_MIRROR_BASE (the fallback
#   GFCTL_MIRROR_BASE — the live machines) → the first attempt fetches
#   "$MIRROR/<basename>"; a mirror failure (rc≠0 or http ≥400) → a WARN and
#   the pin URL in the same attempt. A 1:1 body port.
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
  if [ -f "$dest" ] && [ "$(stat -L -c %s "$dest")" = "$size" ]; then
    echo "SKIP: $(basename "$dest") (размер совпал — честный sha-статус даёт: lctl doctor)"
    return 0
  fi
  remaining="$size"
  ok=""
  if [ -f "$part" ]; then
    psz=$(stat -c %s "$part" 2>/dev/null || echo 0)
    if [ "$psz" -gt 0 ] && [ "$psz" -le "$size" ]; then remaining=$((size - psz)); fi
    # part>pin (gfctl review 1.1): the local .part is already of the FULL
    # pin size (an interruption between the download end and the mv) — the
    # network is not touched: the mv + the sha arbitration in the common
    # tail; a corrupt «full» .part will catch a SHA-MISMATCH and be
    # removed.
    if [ "$psz" = "$size" ]; then
      log "локальный $(basename "$part") уже полного размера ($size B) — сеть не нужна"
      ok=1
    fi
    if [ "$psz" -gt "$size" ]; then
      warn "$(basename "$part") БОЛЬШЕ пин-размера ($psz B > $size B) — докачка не завершится корректно (сервер может проигнорировать диапазон): SHA-арбитраж отбросит .part и модель перекачается; практический исход один — удали .part руками (rm \"$part\") и повтори"
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
            *)      mrc=1 ;;   # rc 0, но http ≥400 (или пустой) — фоллбэк
          esac
        fi
        # a corrupt/partial mirror tail must not break the pin URL's resume
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
#   its pin: resolve the filename across BOTH sets' tables (the core
#   iterates the registry's field 2 and field 3), deliver via download_file
#   into $MODELS_DIR (the active profile's set mount dir; cmd_pull sets it
#   with an env prefix). Idempotent: a pin-sized file in place → SKIP
#   without the network.
#
# Side effects: files in $MODELS_DIR (.part/dest), the network when
#   downloading; log/echo lines to stdout, warns to stderr.
#
# Limitations/assumptions: $MODELS_DIR already points at the target set dir
#   (the core's set_models_dir / cmd_pull's env prefix); a file not from
#   the pin tables → die (exit 1) — the registry contract broken at the
#   caller.
#
# @param 1: string    # a file name from the set's table (registry field 1/3)
# @returns integer   # 0 — the file in place (or fetched with sha OK); else
#   download_file's rc (space/network/sha); an unknown name — die
engine_pull_model() {
  local f="$1" set_name pf size sha url role found=""
  for set_name in 27b flash; do
    while IFS='|' read -r pf size sha url role; do
      if [ "$pf" = "$f" ]; then found=1; break 2; fi
    done < <(weights_for "$set_name") || true
  done
  [ -n "$found" ] || die "engine_pull_model: файл '$f' не найден в таблицах пинов gufo"
  log "тяну модель $f (сет $set_name)"
  download_file "$url" "$MODELS_DIR/$f" "$size" "$sha"
}

# Purpose: an honest set inventory — line by line «файл | size-пин B |
#   статус» (present, size OK, sha OK / sha ✗ / SIZE ≠ / MISSING) + the
#   unfinished .part lines. The sha is recomputed ALWAYS on a matched size
#   (stateless honesty, ~10 s for 27b, ~40 s for flash on NVMe). A 1:1
#   gfctl inventory port.
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
          status="есть, размер OK, sha ✗ (перекачай: lctl pull $ENGINE <профиль>)"
        fi
      else
        status="есть, РАЗМЕР ≠ (факт ${actual} B)"
      fi
    else
      status="НЕТ"
    fi
    printf '%s | %s B | %s\n' "$f" "$size" "$status"
  done < <(weights_for "$set")
  for part in "$dir"/*.part; do
    [ -e "$part" ] || continue
    psz=$(stat -c %s "$part" 2>/dev/null || echo 0)
    awk -v p="$(basename "$part")" -v b="$psz" 'BEGIN{printf "%s | — | незавершённый .part: %.1f GiB\n", p, b/1073741824}'
  done
  return 0
}

# Purpose: the set's pin sizes sum in bytes (for doctor's «нужно X GiB»).
#   A 1:1 gfctl set_total_bytes port.
#
# @param 1: weight_set      # the set dir
# @stdout integer           # the total size in bytes
# @returns integer          # 0; 1 — an unknown set
set_total_bytes() {
  weights_for "$1" | awk -F'|' '{s+=$2} END{printf "%.0f\n", s+0}'
}

# Purpose: a pre-check of the set's GGUF tensor types — for each downloaded
#   file from the set's table it calls tpl/python/gguf_type_check.py (a
#   streaming header parser, no GPU); the SET's verdict = red when ≥1 file
#   is red OR has a format error. A 1:1 gfctl check_types port
#   (TPL_DIR→the adapter).
#
# @param 1: weight_set      # the set dir
# @stdout string[]          # the files' verdicts + the set's final line
# @returns integer          # 0 — green; 1 — red / a format error /
#   nothing to check (die — exit 1)
check_types() {
  local set="$1" dir f rc_file out any=0 red=0 err=0
  dir="$MODELS_BASE/$set"
  while IFS='|' read -r f _size _sha _url role; do
    [ -n "$f" ] || continue
    [ "$role" = "mmproj" ] && continue   # the BF16 sidecar: check_types judges the TRUNK (FFN), the tower would be a false red
    [ -f "$dir/$f" ] || continue
    any=1
    rc_file=0
    out=$(python3 "$ADAPTER_DIR/tpl/python/gguf_type_check.py" "$dir/$f") || rc_file=$?
    printf '%s\n' "$out"
    if [ "$rc_file" = 1 ]; then
      red=1
    elif [ "$rc_file" != 0 ]; then
      err=1
    fi
  done < <(weights_for "$set")
  if [ "$any" = 0 ]; then
    die "нечего проверять — веса сета $set не скачаны ($dir)"
  fi
  if [ "$red" = 1 ] || [ "$err" = 1 ]; then
    echo "КРАСНЫЙ — не загрузится (FFN низкобитные IQ/BF16/MXFP4/неизвестные; SPEC §5)"
    return 1
  fi
  echo "зелёный — сет $set можно грузить"
  return 0
}
