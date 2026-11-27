#!/usr/bin/env python3
# Назначение: сводная матрица движок×профиль из JSON-снапшотов bench
#   (bench_report.py argv[1], bench/reports/<combo>.json): берёт ПОСЛЕДНИЙ
#   снапшот каждой комбинации движок+профиль (max по meta.date — ISO-строки
#   сравниваются лексикографически; устаревшая версия комбинации молча
#   проигрывает), группирует по профилям и рендерит markdown-таблицы
#   (соло/проза/сессия/префилл/параллель) в stdout → cmd_bench пишет
#   bench/MATRIX.md после КАЖДОГО прогона — матрица всегда из последних
#   локальных замеров. Метрики — те же определения, что в отчёте
#   (import bench_report): медианы tok_s соло/прозы, Σwall сессии,
#   follow-up turn 1 (гарантированный cache miss — nonce) → с → tok/s по
#   prompt_tokens/wall, параллель — agg_tok_s строки батча.
#   Детерминирован: даты только из meta (не часы/mtimes), все выборки
#   сортированы. Хост в снапшотах отсутствует — в матрицу не попадает.
#
# Побочные эффекты: нет (чтение *.json каталога; печать: матрица — stdout,
#   warn о битых файлах — stderr).
#
# Ограничения/допущения: stdlib only; битый/не-JSON файл → комбинация
#   пропускается с warn (остальные рендерятся); сценарий отсутствует в
#   снапшоте → «-» в клетке (частичный прогон честен); колонки параллели —
#   union n по отобранным комбинациям (лестница настраивается --parallel);
#   даты отобранных снапшотов различаются → пометка (межсеансовое
#   сравнение условно — тёплый кэш/тепло железа, см. bench/README.md).
#
# @param 1: string      # каталог со снапшотами (дефолт bench/reports)
# @stdout string       # markdown-матрица
# @stderr string       # warn о пропущенных файлах
# @returns integer     # 0
import glob
import json
import os
import sys

import bench_report as br   # тот же каталог: run_rows/solo_median_toks/f2/md_table


def metrics(data):
    # Метрики комбинации — те же определения, что в отчёте.
    # @param 1: dict  # снапшот (meta + строки сценариев)
    # @returns dict   # {solo, prose, session, prefill_s, prefill_tps, par}
    solo_rows, _ = br.run_rows(data.get("solo") or [])
    prose_rows, _ = br.run_rows(data.get("prose") or [])
    sess_rows, _ = br.run_rows(data.get("session") or [])
    fu = [r for r in (data.get("followup") or [])
          if r.get("error") is None and isinstance(r.get("completion_tokens"), int)]
    fu1 = next((r for r in fu if r.get("turn") == 1), None)
    par = {r.get("n"): r.get("agg_tok_s") for r in (data.get("parallel") or [])
           if r.get("error") is None and r.get("agg_tok_s") is not None}
    tps = None
    if fu1 and fu1.get("wall_s") and fu1.get("prompt_tokens"):
        tps = fu1["prompt_tokens"] / fu1["wall_s"]   # ток/с честного cache miss
    return {
        "solo": br.solo_median_toks(solo_rows),
        "prose": br.solo_median_toks(prose_rows),
        "session": (sum(r["wall_s"] for r in sess_rows if r.get("wall_s") is not None)
                    if sess_rows else None),
        "prefill_s": fu1.get("wall_s") if fu1 else None,
        "prefill_tps": tps,
        "par": par,
    }


def prefill_cell(m):
    # @returns string  # «12.13 → 2 060 tok/s» | «12.13 → -» | «-»
    if not m["prefill_s"]:
        return "-"
    tps = "-"
    if m["prefill_tps"]:
        tps = "{:,}".format(int(round(m["prefill_tps"]))).replace(",", " ")
    return "%s → %s tok/s" % (br.f2(m["prefill_s"]), tps)


def main(argv):
    reports = argv[0] if argv else "bench/reports"
    combos = {}   # (engine, profile) → (date, data); max по date
    skipped = []
    for fp in sorted(glob.glob(os.path.join(reports, "*.json"))):
        try:
            with open(fp, encoding="utf-8") as fh:
                data = json.load(fh)
            key = (data["meta"]["engine"], data["meta"]["profile"])
            date = data["meta"]["date"]
        except (OSError, ValueError, KeyError, TypeError):
            skipped.append(os.path.basename(fp))
            continue
        if key not in combos or date > combos[key][0]:
            combos[key] = (date, data)
    # гранулярность «сеанса» — календарный день: минуты/часы внутри дня
    # (типичный сеанс матрицы) — это одно сравнение, а не «разнобой дат»;
    # полные ISO-штампы остаются в meta каждого .json
    dates = sorted({d[:10] for d, _ in combos.values()})
    out = ["# bench matrix — the latest run of every combination", "",
           "- snapshot dates: %s" % (", ".join(dates) if dates else "-")]
    if len(dates) > 1:
        out.append("- WARNING: snapshot dates span several days — a cross-session "
                   "comparison is conditional (cache/warm hardware)")
    out += ["- methodology and caveats: bench/README.md", ""]
    for prof in sorted({p for _, p in combos}):
        keys = sorted(k for k in combos if k[1] == prof)
        par_ns = sorted({n for _, d in (combos[k] for k in keys)
                         for n in metrics(d)["par"]})
        head = (["engine", "solo tok/s", "prose tok/s", "session 15, s",
                 "25k prefill (miss), s → tok/s"] +
                ["par-%d tok/s" % n for n in par_ns])
        rows = []
        for eng, _ in keys:
            _, data = combos[(eng, prof)]
            m = metrics(data)
            rows.append(["%s %s%s" % (eng, data["meta"].get("version", "?"),
                                      " (ОБОРВАН)" if data["meta"].get("truncated") else ""),
                         br.f2(m["solo"]), br.f2(m["prose"]), br.f2(m["session"]),
                         prefill_cell(m)] +
                        [br.f2(m["par"].get(n)) for n in par_ns])
        out += ["## profile %s" % prof, "", br.md_table(head, rows), ""]
    # чтение цифр — постоянные оговорки рядом с таблицами (детерминированный
    # футер; методика — bench/README.md)
    out += ["## How to read", "",
            "- the 15-turn session is **warm-cache** (the session document is "
            "not nonce'd): compare sessions within one matrix session "
            "only; the prefill column is not affected (the nonce = a "
            "guaranteed miss)",
            "- multi-slot profiles do not beat the solo profiles at parallel-2 — "
            "the multi-slot win appears at parallel-4",
            "- engines that emit no reuse marker (\"-\") are still measured "
            "honestly — the nonce guarantees the miss without the marker; "
            "a \"live\" on turn 2 additionally confirms the live cache",
            "- prefill: s → tok/s = prompt_tokens/wall of turn 1 (a guaranteed "
            "cache miss); the methodology and the cache trap — "
            "bench/README.md", ""]
    sys.stdout.write("\n".join(out) + "\n")
    for name in skipped:
        sys.stderr.write("bench_matrix: %s — не-JSON/битый, пропущен\n" % name)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
