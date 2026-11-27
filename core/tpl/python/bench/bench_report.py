#!/usr/bin/env python3
# Назначение: рендер markdown-отчёта bench (этап 7) из каталога JSONL-замеров
#   bench_run.py + env-шапки. ДЕТЕРМИНИРОВАН: дата — B_TS из env (не часы
#   python), любые входы → байт-в-байт тот же отчёт (снапшот-тест батареи по
#   golden-фикстуре). Секции: соло-декод (канон-фикстура), проза, сессия 15
#   ходов + follow-up-кэш, параллельная нагрузка, движковые метрики адаптера
#   (extras.json), вывод. Отчёт — только числа из usage/wall/timings: никаких
#   выдуманных полей и никакой интерпретации роута (ярлыки FIFO/slots знает
#   адаптер/человек). Отсутствующий JSONL сценария → «не выполнен» (частичный
#   прогон честен); truncation-маркер → пометка обрыва.
#
# Побочные эффекты: нет (чтение файлов/env; печать: отчёт — stdout, одна
#   строка «кратко: …» — stderr как итоговая таблица-кратко для терминала).
#
# Ограничения/допущения: stdlib only; env B_TS/B_ENGINE/B_VERSION/B_PROFILE/
#   B_MODEL/B_MD5/B_PARAMS задаёт cmd_bench (пустые рендерятся как «?» —
#   шаблон не падает); LCTL_BENCH_MAX_S — лимит прогона в шапке (дефолт 3600).
#   extras.json: нет файла → «не предусмотрено адаптером», не-JSON/пустой →
#   «адаптер вернул не-JSON (пропущено)», объект → «ключ: значение» по
#   порядку (None → «-»).
#
# @param 1: string      # каталог замеров (solo.jsonl, prose.jsonl, …,
#                        parallel-*.jsonl, extras.json)
# @stdout string       # markdown-отчёт
# @stderr string       # строка «кратко: …»
# @returns integer     # 0
import glob
import json
import os
import sys

FIXTURE_NAME = "merge_sort_thinking_off.txt"
MAX_S = os.environ.get("LCTL_BENCH_MAX_S") or "3600"


def env(key):
    # @param 1: string     # имя переменной шапки
    # @returns string     # значение; пусто → «?» (шаблон честнее падения)
    v = os.environ.get(key) or ""
    return v if v else "?"


def median(vals):
    # @param 1: list[float]  # непустой список
    # @returns float         # медиана (чётный N — среднее двух средних)
    s = sorted(vals)
    n = len(s)
    if n % 2:
        return s[n // 2]
    return (s[n // 2 - 1] + s[n // 2]) / 2


def f2(v):
    # @returns string  # число с 2 знаками; None → «-»
    return "-" if v is None else "%.2f" % v


def scenario_files(scenario, runs_dir):
    # @param 1: string  # «solo»/… или «parallel*» (глоб батчей)
    # @returns list[string]  # пути jsonl (сортировка: parallel по N — имена
    #   single-digit, glob-порядка достаточно)
    if scenario == "parallel*":
        return sorted(glob.glob(os.path.join(runs_dir, "parallel-*.jsonl")))
    path = os.path.join(runs_dir, scenario + ".jsonl")
    return [path] if os.path.exists(path) else []


def load(scenario, runs_dir):
    # @returns list[dict]  # строки замеров (файла нет → [])
    rows = []
    for fp in scenario_files(scenario, runs_dir):
        try:
            with open(fp, encoding="utf-8") as fh:
                for line in fh:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        rows.append(json.loads(line))
                    except ValueError:
                        continue
        except OSError:
            continue
    return rows


def file_exists(scenario, runs_dir):
    # @returns bool  # jsonl сценария присутствует (даже если пуст/обрыв)
    return bool(scenario_files(scenario, runs_dir))


def truncated_any(runs_dir):
    # @returns bool  # truncation-маркер дедлайна есть хоть в одном jsonl
    for fp in glob.glob(os.path.join(runs_dir, "*.jsonl")):
        try:
            with open(fp, encoding="utf-8") as fh:
                if '"truncated":true' in fh.read():
                    return True
        except OSError:
            continue
    return False


def md_table(headers, rows):
    # @param 1: list[string]        # заголовки колонок
    # @param 2: list[list[string]]  # строки (уже отформатированные)
    # @stdout-часть string          # markdown-таблица
    out = ["| " + " | ".join(headers) + " |",
           "|---" * len(headers) + "|"]
    for r in rows:
        out.append("| " + " | ".join(str(c) for c in r) + " |")
    return "\n".join(out)


def run_rows(rows):
    # Соло/проза: успешные прогон-строки + счётчик пропусков. Строка замера
    # опознаётся по целому completion_tokens (truncated-маркер — не замер).
    # @returns (list[dict], int)  # (ok-строки по run, число error-строк)
    ok = [r for r in rows
          if r.get("error") is None and isinstance(r.get("completion_tokens"), int)]
    bad = len(rows) - len(ok)
    return sorted(ok, key=lambda r: r.get("run") or 0), bad


def solo_median_toks(rows):
    # @returns float|None  # медиана decode tok/s успешных прогонов
    vals = [r["tok_s"] for r in rows if r.get("tok_s") is not None]
    return median(vals) if vals else None


def scen_table(runs_dir, name, title, brief_parts):
    # Секция соло/проза (колонки run/wall/prompt/completion/tok_s + медиана).
    # @returns string  # markdown секции
    rows, _ = run_rows(load(name, runs_dir))
    head = "## %s\n" % title
    if not file_exists(name, runs_dir):
        return head + "\nне выполнен\n"
    if not rows:
        return head + "\nне выполнен (нет успешных прогонов)\n"
    t = [md_table(
        ["прогон", "wall,с", "prompt", "completion", "decode tok/s"],
        [[r.get("run"), f2(r.get("wall_s")), r.get("prompt_tokens"),
          r.get("completion_tokens"), f2(r.get("tok_s"))] for r in rows])]
    med_w = median([r["wall_s"] for r in rows if r.get("wall_s") is not None])
    med_t = solo_median_toks(rows)
    t.append("")
    t.append("медиана: wall %sс | decode %s tok/s (по %d прогонам)"
             % (f2(med_w), f2(med_t), len(rows)))
    brief_parts.append("%s: %s tok/s (медиана)" % (name, f2(med_t)))
    return head + "\n" + "\n".join(t) + "\n"


def reuse_of(timings):
    # @returns string  # component_cache.reuse; нет → «-»
    cc = (timings or {}).get("component_cache") or {}
    return cc.get("reuse") or "-"


def scen_session(runs_dir, brief_parts):
    # Секция 3: сессия (строка на ход, prompt_ms/reuse — из timings verbatim)
    # + follow-up-кэш (turn1/turn2/reuse).
    head = "## 3. Агентская сессия (15 ходов) + follow-up-кэш\n"
    rows, _ = run_rows(load("session", runs_dir))
    if not file_exists("session", runs_dir):
        body = "не выполнен\n"
    elif not rows:
        body = "не выполнен (нет успешных прогонов)\n"
    else:
        t = [md_table(
            ["ход", "wall,с", "prompt", "completion", "tok/s", "prompt_ms*", "reuse*"],
            [[r.get("turn"), f2(r.get("wall_s")), r.get("prompt_tokens"),
              r.get("completion_tokens"), f2(r.get("tok_s")),
              (r.get("timings") or {}).get("prompt_ms", "-"),
              reuse_of(r.get("timings"))] for r in rows])]
        t.append("")
        t.append("* из timings движка; «-» — движок timings не прислал")
        total = sum(r["wall_s"] for r in rows if r.get("wall_s") is not None)
        t.append("итого сессия: %d ход(ов), wall суммарный %sс"
                 % (len(rows), f2(total)))
        brief_parts.append("сессия %d ходов %.2fс" % (len(rows), total))
        body = "\n".join(t) + "\n"
    fu_rows = [r for r in load("followup", runs_dir)
               if r.get("error") is None and isinstance(r.get("completion_tokens"), int)]
    fu1 = next((r for r in fu_rows if r.get("turn") == 1), None)
    fu2 = next((r for r in fu_rows if r.get("turn") == 2), None)
    if not file_exists("followup", runs_dir):
        fu = "follow-up 25k: не выполнен\n"
    elif fu1 is None:
        fu = "follow-up 25k: не выполнен (нет успешных прогонов)\n"
    else:
        fu = ("follow-up 25k (turn 1 = a guaranteed cache miss, the "
              "per-run nonce prefix): turn1=%sс turn2=%sс reuse=%s\n" % (
            f2(fu1.get("wall_s")), f2(fu2.get("wall_s")) if fu2 else "-",
            reuse_of(fu2.get("timings")) if fu2 else "-"))
    return head + "\n" + body + "\n" + fu


def scen_parallel(runs_dir, solo_med, brief_parts):
    # Секция 4: параллельная нагрузка — одна строка на батч; % от соло =
    # agg/solo-медиана (интерпретация роута — НЕ ядро: числа без ярлыков).
    head = "## 4. Параллельная нагрузка\n"
    rows = [r for r in load("parallel*", runs_dir)
            if r.get("error") is None and isinstance(r.get("completion_tokens"), int)]
    if not file_exists("parallel*", runs_dir):
        return head + "\nне выполнен\n"
    if not rows:
        return head + "\nне выполнен (нет успешных прогонов)\n"
    rows = sorted(rows, key=lambda r: r.get("n") or 0)
    t = [md_table(
        ["N", "wall,с", "Σtok", "aggregate tok/s", "% от соло", "per-request walls,с"],
        [[r.get("n"), f2(r.get("wall_s")), r.get("sum_completion_tokens"),
          f2(r.get("agg_tok_s")),
          ("%.0f%%" % (r["agg_tok_s"] / solo_med * 100))
          if r.get("agg_tok_s") is not None and solo_med else "-",
          ", ".join("%.2f" % w for w in r.get("walls_s") or []) or "-"] for r in rows])]
    for r in rows:
        brief_parts.append("параллель %d: %s tok/s"
                           % (r.get("n"), f2(r.get("agg_tok_s"))))
    return head + "\n" + "\n".join(t) + "\n"


def scen_extras(runs_dir):
    # Секция «Движковые метрики (адаптер)»: extras.json одной JSON-строки
    # → «ключ: значение» по порядку; нет хука/файла → честная пометка.
    head = "## Движковые метрики (адаптер)\n"
    path = os.path.join(runs_dir, "extras.json")
    if not os.path.exists(path):
        return head + "\n- не предусмотрено адаптером\n"
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        return head + "\n- адаптер вернул не-JSON (пропущено)\n"
    if not isinstance(data, dict):
        return head + "\n- адаптер вернул не-JSON (пропущено)\n"
    lines = []
    for k, v in data.items():
        lines.append("- %s: %s" % (k, "-" if v is None else v))
    return head + "\n" + ("\n".join(lines) if lines else "- нет данных") + "\n"


def main(argv):
    if len(argv) < 1:
        print("usage: bench_report.py <runs_dir>", file=sys.stderr)
        return 2
    runs_dir = argv[0]
    solo_rows, _ = run_rows(load("solo", runs_dir))
    solo_med = solo_median_toks(solo_rows)
    brief = []
    parts = [
        "# bench %s %s — профиль %s" % (env("B_ENGINE"), env("B_VERSION"), env("B_PROFILE")),
        "",
        "- дата: %s | движок: %s (версия %s)" % (env("B_TS"), env("B_ENGINE"), env("B_VERSION")),
        "- профиль: %s | модель: %s" % (env("B_PROFILE"), env("B_MODEL")),
        "- фикстура: %s (md5 %s)" % (FIXTURE_NAME, env("B_MD5")),
        "- параметры: %s | лимит прогона: %sс" % (env("B_PARAMS"), MAX_S),
    ]
    if truncated_any(runs_dir):
        parts += ["", "ПРОГОН ОБОРВАН ПО ЛИМИТУ — цифры частичные"]
    parts += ["", scen_table(runs_dir, "solo",
                             "1. Соло-декод (канон-фикстура, reasoning off)", brief),
              scen_table(runs_dir, "prose", "2. Короткий проза-запрос", brief),
              scen_session(runs_dir, brief),
              scen_parallel(runs_dir, solo_med, brief),
              scen_extras(runs_dir),
              "## Вывод",
              "",
              "> (заполняется человеком после прогона)"]
    sys.stdout.write("\n".join(parts) + "\n")
    if brief:
        sys.stderr.write("кратко: " + " | ".join(brief) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
