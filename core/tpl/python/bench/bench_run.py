#!/usr/bin/env python3
# Назначение: раннер сценариев bench (этап 7; вызывается cmd_bench по одному
#   разу на сценарий) — HTTP-транспорт на curl-субпроцессе (шов faux-батареи),
#   конверт сравнимости (temperature 0, reasoning_effort "none" — thinking-
#   бюджет не съедает короткие max_tokens), построчный JSONL-журнал замеров,
#   дедлайн прогона LCTL_BENCH_MAX_S (bash передаёт epoch; перед КАЖДЫМ
#   запросом проверка — раннер дописывает маркер truncated и завершается rc 0,
#   bash пропускает остальные сценарии). Медианы/таблицы считает bench_report.
#
# Сценарии (argv[1]):
#   solo      — прогрев (1 незамеряемый запрос max_tokens 16; холодные ядра —
#               F15-урок, строка не пишется) + RUNS прогонов на канон-фикстуре
#               (argv[7]), max_tokens 400;
#   prose     — RUNS прогонов «Напиши развёрнутое эссе о истории письменности»,
#               max_tokens 400;
#   session   — агентская сессия 15 ходов (документ из 16 НЕЙТРАЛЬНЫХ фактов
#               домена LLM-инфраструктуры ×11 ≈ 35k символов ≈ 6.6k ток —
#               байт-в-байт одинаковый на всех движках = канон сравнения
#               префилла; факты/вопросы — литералы файла и проходят R6-грепп),
#               max_tokens 128, строка на ход;
#   followup  — follow-up-кэш: turn1 (документ ~25k ток + вопрос, max_tokens
#               128) → turn2 (follow-up, max_tokens 64); строки k=25, turn=1|2;
#   parallel  — N одновременных POST (ThreadPoolExecutor; I/O-потоки, дети —
#               curl) с чередованием проза/фикстура, max_tokens 300; ОДНА
#               строка батча.
#
# Строка замера (порядок ключей — контракт отчёта):
#   {"scenario","run"|"turn"|"n","wall_s","prompt_tokens","completion_tokens",
#    "tok_s","timings","error"} — timings = тело timings ответа VERBATIM
#   (нет у движка → null); usage нет / пустой content → строка с error +
#   warn в stderr, прогон пропущен (медианы по успешным).
#
# Побочные эффекты: http-запросы генерации на 127.0.0.1:<port>; дозапись
#   (append) в <out>.jsonl; ничего больше.
#
# Ограничения/допущения: stdlib only; сервер уже healthy (гейт ядра);
#   неудачный ход сессии прерывает сценарий (история без ответа
#   невоспроизводима — честная частичность вместо выдуманных ходов);
#   wall — time.time() вокруг curl (включая разбор — шум ниже разброса
#   движка); ответ не JSON → error-строка. Аргументы кривые → rc 2 (usage).
#
# @param 1: solo|prose|session|followup|parallel
# @param 2: /^[0-9]+$/        # порт сервера
# @param 3: string            # id модели (ядро: хук engine_bench_model или cur_model)
# @param 4: /^[0-9]+$/        # runs (solo/prose); session/followup игнорируют
# @param 5: /^[0-9]+$/        # deadline — epoch-секунды дедлайна прогона
# @param 6: string            # путь out.jsonl (append)
# @param 7: string            # путь фикстуры (только solo)
# @returns integer            # 0 — прогон дошёл до конца или оборван дедлайном;
#                             # 2 — кривые аргументы
import json
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor

PROSE_PROMPT = "Напиши развёрнутое эссе о истории письменности"
WARM_PROMPT = "Ответь одним предложением: прогрев бенча"
FOLLOWUP_MARKER = "lctl-bench-25k"
FOLLOWUP_Q1 = "Перечисли ключевые структуры списком."
FOLLOWUP_Q2 = "Теперь главное ограничение одним предложением."
SESSION_SYS = ("Ты — инженер-эксперт по инфраструктуре LLM. Отвечай по записке, "
               "кратко, без рассуждений.")
# Таймауты по классам (бюджет запроса с длинным префиллом / короткие):
TIMEOUTS = {"warm": 120, "solo": 300, "prose": 300, "session": 1200,
            "followup": 600, "parallel": 300}

# 16 нейтральных фактов сессии — общий домен LLM-инфраструктуры, БЕЗ имён
# движков/машин/IP: одинаковые байты промпта = одинаковый префилл = канон
# сравнения движков (решение 2026-11-22, task 7.1; гигиена-грепп ядра).
FACTS = [
    "KV-кэш хранит состояния внимания обработанных токенов: повторное использование префилла экономит и время, и память.",
    "квантование весов снижает объём модели ценой точности: форматы различаются разрядностью матрицы и блока.",
    "спекулятивный декод предлагает черновые токены малой моделью, а большая проверяет их за один проход.",
    "батчинг объединяет запросы в один шаг генерации: пропускная способность растёт, латентность одного запроса — не обязательно.",
    "rootless-контейнеры запускают сервер без привилегий суперпользователя; доступ к устройству даётся группами пользователя.",
    "prefill обрабатывает весь промпт разом, decode порождает токены по одному — у фаз разный профиль нагрузки.",
    "токенизатор переводит текст в идентификаторы: длина в токенах зависит от языка и домена, а не от числа символов.",
    "контекстное окно ограничивает суммарный объём промпта и ответа; его превышение приводит к отказу или усечению.",
    "paging делит KV-кэш на страницы: фрагментация падает, но растёт накладной расход на таблицы отображения.",
    "очередь запросов сглаживает пики: позиция в очереди видна в латентности отдельных запросов при серийном исполнении.",
    "кэш дискового тира переживает рестарт сервера: первый ход разговора восстанавливается быстрее полного префилла.",
    "greedy-декод при нулевой температуре даёт детерминированный ответ — база для сравнимых замеров движков.",
    "повторный ход того же разговора может попасть в живой кэш: wall падает, хотя скорость генерации не изменилась.",
    "system-промпт участвует в ключе кэша: его смена обнуляет переиспользование префилла разговора.",
    "агрегатная скорость параллельной нагрузки может быть выше соло-скорости; интерпретация зависит от роута исполнения.",
    "таймаут запроса нужно соразмерять с длиной генерации: длинный ответ на медленном движке честнее обрывать лимитом.",
]
SESSION_QUESTIONS = [
    "Что хранит KV-кэш и зачем он нужен?",
    "Чем квантование весов помогает и чем платит?",
    "Как работает спекулятивный декод?",
    "Что даёт батчинг и чем он рискует для латентности?",
    "Почему rootless-контейнер безопаснее и что ему нужно от групп?",
    "Чем prefill отличается от decode по профилю нагрузки?",
    "Почему длина промпта в токенах не равна числу символов?",
    "Что происходит при переполнении контекстного окна?",
    "Как paging меняет экономику KV-кэша?",
    "Как очередь запросов влияет на латентность при серийном исполнении?",
    "Что даёт дисковый тир кэша после рестарта?",
    "Зачем для замеров greedy-декод при нулевой температуре?",
    "Почему wall повторного хода падает без роста скорости генерации?",
    "Что происходит с кэшем при смене system-промпта?",
    "Почему агрегат параллельной нагрузки нельзя читать без знания роута?",
]
SESSION_DOC_SYS = ("Ты — инженер-эксперт. Отвечай по записке, кратко, без рассуждений.")
UNIT = ("Опиши подробно структуру связного списка, стека и очереди, с примерами "
        "операций и оценкой сложности каждой операции. ")


def warn(msg):
    # @param 1: string  # текст
    # @returns integer # всегда 0 — только печать
    print("WARN: %s" % msg, file=sys.stderr, flush=True)


class Journal:
    """JSONL-журнал замеров: append-режим (перезапуск без bash-перезаписи не
    портит файл), flush на каждой строке (частичный прогон виден)."""

    def __init__(self, path):
        self.fh = open(path, "a", encoding="utf-8")

    def measure(self, **kw):
        # Строка замера: фиксированный порядок ключей — контракт bench_report.
        row = {"scenario": kw["scenario"]}
        for key in ("run", "turn", "k", "n"):
            if key in kw:
                row[key] = kw[key]
        row.update({"wall_s": kw.get("wall_s"), "prompt_tokens": kw.get("prompt_tokens"),
                    "completion_tokens": kw.get("completion_tokens"),
                    "tok_s": kw.get("tok_s"), "timings": kw.get("timings"),
                    "error": kw.get("error")})
        for key in ("sum_completion_tokens", "agg_tok_s", "walls_s", "fails"):
            if key in kw:
                row[key] = kw[key]
        self.fh.write(json.dumps(row, ensure_ascii=False) + "\n")
        self.fh.flush()

    def truncated(self):
        # Маркер обрыва по дедлайну — bash по нему пропускает остальные
        # сценарии, bench_report ставит пометку в отчёте.
        self.fh.write('{"truncated":true,"reason":"deadline"}\n')
        self.fh.flush()


def deadline_hit(deadline, jl):
    # @returns bool  # True — дедлайн прошёл: маркер дописан, вызывающий
    #   завершает сценарий (rc 0 — это не ошибка)
    if time.time() > deadline:
        jl.truncated()
        return True
    return False


def post(port, model, messages, max_tokens, timeout):
    # Один запрос: curl-субпроцесс (-m по классу сценария), конверт
    # temperature 0 + reasoning_effort none.
    #
    # @returns (ok, wall_s, ptok, ctok, timings, content, err)
    #   ok=False → ptok/ctok/timings/content = None, err — причина (warn
    #   и error-строка на вызывающем)
    body = json.dumps({"model": model, "messages": messages, "max_tokens": max_tokens,
                       "temperature": 0, "reasoning_effort": "none"}).encode()
    t0 = time.time()
    try:
        p = subprocess.run(
            ["curl", "-fsS", "-m", str(timeout), "-H", "Content-Type: application/json",
             "--data-binary", "@-", "http://127.0.0.1:%s/v1/chat/completions" % port],
            input=body, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    except OSError as e:
        return False, time.time() - t0, None, None, None, None, "curl не запущен: %s" % e
    wall = time.time() - t0
    if p.returncode != 0 or not p.stdout.strip():
        return False, wall, None, None, None, None, "curl rc=%s (нет ответа)" % p.returncode
    try:
        d = json.loads(p.stdout.decode("utf-8", "replace"))
    except ValueError:
        return False, wall, None, None, None, None, "ответ не JSON (битое тело)"
    usage = d.get("usage") or {}
    ctok = usage.get("completion_tokens")
    if not isinstance(ctok, int):
        return False, wall, None, None, None, None, "usage.completion_tokens нет в ответе"
    ptok = usage.get("prompt_tokens")
    if not isinstance(ptok, int):
        ptok = 0
    try:
        content = d["choices"][0]["message"]["content"]
    except (KeyError, IndexError, TypeError):
        content = None
    if not (content or "").strip():
        return False, wall, ptok, ctok, None, None, "пустой content в ответе"
    timings = d.get("timings") if isinstance(d.get("timings"), dict) else None
    return True, wall, ptok, ctok, timings, content, None


def measure_line(port, model, messages, max_tokens, timeout, jl, **kw):
    # Один замер + строка журнала. @returns (ok, content) — ok=False: прогон
    # пропущен (error-строка + warn написаны).
    scenario = kw.pop("scenario")
    ok, wall, ptok, ctok, timings, content, err = post(port, model, messages, max_tokens, timeout)
    jl.measure(scenario=scenario, wall_s=round(wall, 3),
               prompt_tokens=ptok if ok else None,
               completion_tokens=ctok if ok else None,
               tok_s=round(ctok / wall, 2) if ok and wall > 0 else None,
               timings=timings if ok else None,
               error=err, **kw)
    if not ok:
        warn("%s: прогон не удался (%s) — пропущен" % (scenario, err))
    return ok, content


def scen_solo(port, model, runs, deadline, out, fixture_path):
    jl = Journal(out)
    if deadline_hit(deadline, jl):
        return
    # прогрев: 1 незамеряемый запрос (строка не пишется; неудача — warn)
    _, _, _, _, _, _, err = post(port, model, [{"role": "user", "content": WARM_PROMPT}],
                                 16, TIMEOUTS["warm"])
    if err:
        warn("прогрев не удался (%s) — цифры первого сценария могут быть занижены" % err)
    try:
        with open(fixture_path, encoding="utf-8") as fh:
            prompt = fh.read()
    except OSError as e:
        warn("фикстура не читается (%s) — сценарий пропущен" % e)
        return
    msgs = [{"role": "user", "content": prompt}]
    for i in range(1, runs + 1):
        if deadline_hit(deadline, jl):
            return
        measure_line(port, model, msgs, 400, TIMEOUTS["solo"], jl,
                     scenario="solo", run=i)


def scen_prose(port, model, runs, deadline, out):
    jl = Journal(out)
    msgs = [{"role": "user", "content": PROSE_PROMPT}]
    for i in range(1, runs + 1):
        if deadline_hit(deadline, jl):
            return
        measure_line(port, model, msgs, 400, TIMEOUTS["prose"], jl,
                     scenario="prose", run=i)


def scen_session(port, model, deadline, out):
    # 15 ходов: документ фактов ×11 (~35k симв ≈ 6.6k ток) + system + растущая
    # история. Неудачный ход — warn + стоп сценария (история без ответа
    # невоспроизводима; ходы до отказа честны в отчёте).
    jl = Journal(out)
    doc = "\n".join("Факт %d: %s" % (i + 1, f) for i, f in enumerate(FACTS)) * 11
    msgs = [{"role": "system", "content": SESSION_SYS},
            {"role": "user", "content":
             "Вот рабочая записка:\n%s\n\nОтвечай на вопросы только по ней." % doc}]
    for i, q in enumerate(SESSION_QUESTIONS, 1):
        if deadline_hit(deadline, jl):
            return
        full = msgs + [{"role": "user", "content": q}]
        ok, ans = measure_line(port, model, full, 128, TIMEOUTS["session"], jl,
                               scenario="session", turn=i)
        if not ok:
            warn("session: ход %d не удался — сессия остановлена (частичная)" % i)
            return
        msgs = full + [{"role": "assistant", "content": ans}]


def scen_followup(port, model, deadline, out):
    jl = Journal(out)
    doc = UNIT * (25 * 40)   # ~25k ток: единица × 40 × 25 (порт agent_check)
    base = [{"role": "system", "content": SESSION_DOC_SYS},
            {"role": "user", "content":
             "%s\n[маркер %s]\n%s" % (doc, FOLLOWUP_MARKER, FOLLOWUP_Q1)}]
    if deadline_hit(deadline, jl):
        return
    ok1, ans = measure_line(port, model, base, 128, TIMEOUTS["followup"], jl,
                            scenario="followup", k=25, turn=1)
    if not ok1:
        warn("followup: turn1 не удался — turn2 пропущен")
        return
    if deadline_hit(deadline, jl):
        return
    measure_line(port, model,
                 base + [{"role": "assistant", "content": ans},
                         {"role": "user", "content": FOLLOWUP_Q2}],
                 64, TIMEOUTS["followup"], jl, scenario="followup", k=25, turn=2)


def scen_parallel(port, model, n, deadline, out, fixture_path):
    # N одновременных POST с чередованием проза/фикстура (нечётные — проза);
    # ОДНА строка батча. Дедлайн проверяется перед запуском батча: начатые
    # запросы доигрывают (таймаут ограничивает), честные walls публикуются.
    jl = Journal(out)
    if deadline_hit(deadline, jl):
        return
    try:
        with open(fixture_path, encoding="utf-8") as fh:
            fixture_text = fh.read()
    except OSError as e:
        warn("фикстура не читается (%s) — сценарий пропущен" % e)
        return
    payloads = []
    for i in range(1, n + 1):
        text = PROSE_PROMPT if i % 2 == 1 else fixture_text
        payloads.append(json.dumps({"model": model,
                                    "messages": [{"role": "user", "content": text}],
                                    "max_tokens": 300, "temperature": 0,
                                    "reasoning_effort": "none"}).encode())

    def one(body):
        t0 = time.time()
        try:
            p = subprocess.run(
                ["curl", "-fsS", "-m", str(TIMEOUTS["parallel"]), "-H",
                 "Content-Type: application/json", "--data-binary", "@-",
                 "http://127.0.0.1:%s/v1/chat/completions" % port],
                input=body, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        except OSError:
            return time.time() - t0, None
        wall = time.time() - t0
        if p.returncode != 0 or not p.stdout.strip():
            return wall, None
        try:
            d = json.loads(p.stdout.decode("utf-8", "replace"))
        except ValueError:
            return wall, None
        ctok = (d.get("usage") or {}).get("completion_tokens")
        return wall, ctok if isinstance(ctok, int) else None

    t0 = time.time()
    with ThreadPoolExecutor(max_workers=n) as ex:
        results = list(ex.map(one, payloads))
    batch = time.time() - t0
    walls = [round(w, 2) for w, _ in results]
    toks = [c for _, c in results if c is not None]
    fails = n - len(toks)
    if fails:
        warn("parallel-%d: %d из %d запросов не удались (curl/usage)" % (n, fails, n))
    jl.measure(scenario="parallel", n=n, wall_s=round(batch, 3),
               prompt_tokens=None,
               completion_tokens=sum(toks),
               tok_s=None,
               timings=None, error=None,
               sum_completion_tokens=sum(toks),
               agg_tok_s=round(sum(toks) / batch, 2) if batch > 0 else None,
               walls_s=walls, fails=fails)


def main(argv):
    usage = ("usage: bench_run.py <solo|prose|session|followup|parallel> "
             "<port> <model> <runs> <deadline_epoch> <out.jsonl> [fixture]")
    if len(argv) < 6:
        print(usage, file=sys.stderr)
        return 2
    scenario, port, model, runs_s, deadline_s, out = argv[:6]
    fixture = argv[6] if len(argv) > 6 else ""
    if scenario not in ("solo", "prose", "session", "followup", "parallel"):
        print(usage, file=sys.stderr)
        return 2
    if not (port.isdigit() and runs_s.isdigit() and deadline_s.isdigit()):
        print(usage, file=sys.stderr)
        return 2
    if scenario == "solo" and not fixture:
        print("bench_run: solo требует путь фикстуры (argv[7])", file=sys.stderr)
        return 2
    deadline = float(deadline_s)
    if scenario == "solo":
        scen_solo(port, model, int(runs_s), deadline, out, fixture)
    elif scenario == "prose":
        scen_prose(port, model, int(runs_s), deadline, out)
    elif scenario == "session":
        scen_session(port, model, deadline, out)
    elif scenario == "followup":
        scen_followup(port, model, deadline, out)
    else:
        if not fixture:
            print("bench_run: parallel требует путь фикстуры (argv[7])", file=sys.stderr)
            return 2
        scen_parallel(port, model, int(runs_s), deadline, out, fixture)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
