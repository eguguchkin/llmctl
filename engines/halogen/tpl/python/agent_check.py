#!/usr/bin/env python3
# Purpose: the HTTP/math of the halogen `lctl agent-check` (Ф3c; SPEC §7)
#   — deterministic POST /v1/chat/completions with the FX/CX window
#   envelope (temperature 0 = greedy, reasoning_effort "none", max_tokens
#   per scenario; NOT /no_think and NOT chat_template_kwargs). The timings
#   are read FROM THE RESPONSE BODY — halogen has timings in EVERY
#   response (the llama-server form: prompt_n/predicted_n/prompt_ms/
#   predicted_ms/cache_n/draft_n/draft_n_accepted, docs/api.md); a missing
#   timings → a structural FAIL (rc 1, the stderr reason) — this is how a
#   halogen revision change degrades, not silently. The orchestration/
#   references/rc — bash (agentcheck.sh, commands.sh); here only the
#   transport, the prompt generation (this file's literals; the bench
#   fixture has nothing to do with agent-check) and printing the
#   `CHECK <имя> key=val…` lines that bash parses. The difference from the
#   gufo harness: there is no component_cache reuse field in the body —
#   the cache hit is counted by cache_n (after a recreate the RAM is empty
#   → cache_n>0 proves a disk restore; documented in agentcheck.sh); the
#   cacheverify* modes are not carried over (`lctl cache` does not exist).
#
# Modes (argv[1]):
#   stage1 — the agent-check before the restart: a session of 15 turns (a
#            doc of ~6.6k from 16 facts ×11, the history grows) + the
#            follow-up ladder 5k/25k/100k (turn1+turn2 = 6 requests) +
#            [doc 25k][q1→q2] + the turn1 of the restore conversation (the
#            state → $LCTL_AGENT_STATE); 24 requests; prints CHECK
#            session/followup/docq.
#   stage2 — the agent-check after the restart: a run of the same restore
#            conversation (the first request after a recreate — ONE retry,
#            F15); prints CHECK restore turn2=… cache_n=….
#
# Side effects: http requests (the transport — curl from PATH, -m 1200 as
#   in the windows; the battery's faux-bin seam); writing
#   $LCTL_AGENT_STATE (a JSON of messages+answers) in stage1 — bash
#   provides the path.
#
# Limitations/assumptions: stdlib only; the port — argv[2] (the env
#   fallback LCTL_AGENT_PORT, default 11435 — the Round 6 single port),
#   the model — argv[3] (ROUTE_MODEL); the retry is EXACTLY ONE and only
#   for the run's first request (the core warm-up, F15; the
#   LCTL_SMOKE_RETRY_S pause, default 15); the prompts have no IPs/hosts.
#
# @param 1: stage1|stage2
# @param 2: /^[0-9]+$/     # the server port
# @param 3: string         # the model name (ROUTE_MODEL)
# @stdout string           # progress lines + CHECK lines
# @returns integer         # 0 — all requests worked; 1 — a structural
#   failure (transport/JSON/timings/state), 2 — bad arguments
import json
import os
import subprocess
import sys
import time

TIMEOUT_S = 1200          # the FX/CX windows: the request budget with a long prefill
TAG = "lctl-agentcheck"   # a fixed conversation marker (determinism)
UNIT = ("Опиши подробно структуру связного списка, стека и очереди на Python, "
        "с примерами операций и оценкой сложности каждой операции. ")

# The session's working note (the HX-A window's agent_bench protocol:
# 16 facts ×11 ≈ 35k chars ≈ 6.6k tokens) — facts about the halogen/llmctl
# domain, no hosts/IPs; the sources — the halogen-flash-server 0.20.7 docs
# (FLAGS/api/codex) and the Ф2/Ф3 window facts of llm-lab.
FACTS = [
    "halogen-flash-server — движок вывода для чекпойнта flash-next; на машине живёт в rootless podman, порт 11435.",
    "каждый ответ несёт timings в форме llama-server: prompt_n, predicted_n, prompt_ms, predicted_ms, cache_n, draft_n, draft_n_accepted.",
    "cache_n в timings — сколько prompt-токенов отвечено из кэша; полный префилл даёт cache_n=0.",
    "prompt-cache двухтирный: записи в RAM плюс disk-тир HALOGEN_CACHE_DIR; разговор, которого нет в памяти, восстанавливается с диска на следующем ходе, байт-в-байт.",
    "после рестарта RAM-кэш пуст: любой cache_n больше нуля на первом ходе того же разговора — восстановление из disk-тира.",
    "KV-пул: HALOGEN_KV_POOL_POSITIONS позиций на все разговоры сразу; дефолт 2×HALOGEN_CTX с шапкой 1048576; admission резервирует prompt плюс max_tokens.",
    "KV_SLOTS — сколько разговоров живут в пуле (latency-policy); прод — 4 слота над одним пулом 524288 позиций.",
    "HALOGEN_KV8=1 хранит KV в int8: та же память держит вдвое больше позиций; /health показывает формат как kv_cache=bf16|int8.",
    "спекуляция halogen: MTP-drafter depth-2 (до 7, cost rule) плюс ngram prompt-lookup; draft_n считает предложения обоих механизмов.",
    "temperature 0 даёт байт-в-байт тот же вывод, что серийный greedy-декод — один запрос или батч, с кэшем или без.",
    "reasoning_effort none отключает рассуждения; значение off сервер отвергает с кодом 400.",
    "у halogen есть /health, /v1/models, /slots и Prometheus /metrics с именами llama-server плюс собственные счётчики halogen:*.",
    "канон модели задаёт env HALOGEN_MODEL_ID; строки load_completed в логе нет — имя модели берут из константы, роут — из /health.",
    "per-request строка лога serve_api: mtp N tok = T t/s | rounds, commit/round | prefill — источник живых скоростей watch.",
    "HALOGEN_HOST_RESERVE_GIB (дефолт 20) — сколько RAM сервер оставляет свободным при размере KV-пула; ngram-таблица читается через файловый кэш.",
    "watchdog поднимает сервер раз в минуту при отсутствии маркера остановки; smoke после recreate делает один ретрай на прогреве ядер.",
]
QUESTIONS = [
    "Как устроен prompt-cache halogen и из каких тиров он состоит?",
    "Какие поля у timings и что означает cache_n?",
    "Как по ответу понять, что разговор восстановился с диска после рестарта?",
    "Как устроен KV-пул и что резервирует admission?",
    "Сколько слотов в проде и над каким пулом?",
    "Что делает HALOGEN_KV8=1 и как это видно в /health?",
    "Из чего состоит спекуляция halogen и что считает draft_n?",
    "Какой конверт запроса даёт greedy-декод без рассуждений?",
    "Какие эндпоинты наблюдаемости у halogen?",
    "Где задан канон модели и почему имя не читают из лога?",
    "Что источник живых скоростей watch?",
    "На что влияет HALOGEN_HOST_RESERVE_GIB?",
    "Как поднимается стек halogen на машине?",
    "Зачем smoke делает ретрай после recreate?",
    "Как устроены follow-up-запросы в кэше: что переиспользуется?",
]
SYS_SHORT = "Ты — инженер-эксперт. Отвечай кратко."
RESTORE_Q1 = "Дай план из пяти пунктов."
RESTORE_Q2 = "Сократи план до одного пункта."


class StructFail(Exception):
    """A structural failure: transport/JSON/timings/state — rc 1 at the caller."""


def retry_pause():
    # @returns float  # the retry pause (env LCTL_SMOKE_RETRY_S; default 15, F15)
    try:
        return float(os.environ.get("LCTL_SMOKE_RETRY_S") or 15)
    except ValueError:
        return 15.0


def post(url, model, messages, max_tokens, allow_retry):
    # @param 4: integer  # the scenario's max_tokens (session 128,
    #   follow-up/docq 64–96)
    # @param 5: bool     # True — the run's first request gets ONE retry (F15)
    # @returns (float, str, dict)  # (wall s, content, timings from the body)
    body = json.dumps({"model": model, "messages": messages,
                       "max_tokens": max_tokens, "temperature": 0,
                       "reasoning_effort": "none"}).encode()
    pause = retry_pause()
    for attempt in (1, 2):
        t0 = time.time()
        p = subprocess.run(
            ["curl", "-fsS", "-m", str(TIMEOUT_S),
             "-H", "Content-Type: application/json",
             "--data-binary", "@-", url],
            input=body, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        wall = time.time() - t0
        if p.returncode == 0 and p.stdout.strip():
            try:
                d = json.loads(p.stdout.decode("utf-8", "replace"))
            except ValueError:
                raise StructFail("ответ не JSON (битое тело) — смотри lctl logs")
            t = d.get("timings")
            if not isinstance(t, dict):
                raise StructFail("timings отсутствует в ответе — проверь ревизию halogen "
                                 "(timings в каждом ответе, docs/api.md)")
            try:
                ans = d["choices"][0]["message"]["content"]
            except (KeyError, IndexError, TypeError):
                raise StructFail("в ответе нет choices[0].message.content")
            if not (ans or "").strip():
                raise StructFail("пустой content в ответе (прогрев? ретрай не помог)")
            return wall, ans, t
        if attempt == 1 and allow_retry:
            print("первый запрос не ответил (curl rc=%s) — повторяю через %.0fs (F15)"
                  % (p.returncode, pause), flush=True)
            if pause > 0:
                time.sleep(pause)
            continue
        raise StructFail("запрос не ответил (curl rc=%s) — сервер жив? смотри lctl logs"
                         % p.returncode)
    raise StructFail("unreachable")  # the loop always exits via return/raise


def cache_n_of(timings):
    # @returns integer  # cache_n from the timings (the cache hit in
    #   prompt tokens); missing → 0. halogen does not return a reuse
    #   (live|disk) field in the body: after a recreate the RAM is empty,
    #   so cache_n>0 in stage2 proves a disk restore (bash).
    try:
        return int(timings.get("cache_n") or 0)
    except (TypeError, ValueError):
        return 0


def doc_k(approx_k):
    # @returns string  # a deterministic document of ~25k tokens × 40-char repetitions
    return UNIT * int(approx_k * 40)


def save_state(path, messages):
    # @raises StructFail  # a write failure → a structural failure (the caller dies)
    try:
        with open(path, "w", encoding="utf-8") as fh:
            json.dump({"messages": messages}, fh, ensure_ascii=False)
    except OSError as e:
        raise StructFail("состояние не записано в %s: %s" % (path, e))


def load_state(path):
    # @returns list     # the conversation's messages from stage1
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)["messages"]
    except (OSError, ValueError, KeyError, TypeError) as e:
        raise StructFail("состояние не читается из %s: %s (первый чанк не запускался?)"
                         % (path, e))


def stage_session(url, model):
    # A session of 15 turns: a doc of ~6.6k + system + Q→A, the history
    # grows (the agent_bench protocol); the total wall = the sum of the
    # turns' walls (the ref_flash_session reference in agentcheck.sh; the
    # value's source — a live run, the EXP-007 pattern).
    doc = "\n".join("Факт %d: %s" % (i + 1, f) for i, f in enumerate(FACTS)) * 11
    msgs = [{"role": "system", "content":
             "Ты — инженер-эксперт по движкам вывода. Отвечай по записке, кратко, без рассуждений."},
            {"role": "user", "content":
             "Вот рабочая записка:\n%s\n\nОтвечай на вопросы только по ней." % doc}]
    total = 0.0
    for i, q in enumerate(QUESTIONS):
        full = msgs + [{"role": "user", "content": q}]
        w, ans, t = post(url, model, full, 128, allow_retry=(i == 0))
        total += w
        print("ход %d: wall=%.2fs prompt_ms=%s" % (i + 1, w, t.get("prompt_ms") or "?"), flush=True)
        msgs = full + [{"role": "assistant", "content": ans}]
    print("CHECK session total=%.2f" % total, flush=True)


def stage_ladder(url, model):
    # The follow-up ladder 5k/25k/100k: turn1 (doc+question) → turn2
    # (follow-up); the verdict is only for 25k (bash), all walls and
    # cache_n printed.
    walls = {}
    for k in (5, 25, 100):
        base = [{"role": "system", "content": SYS_SHORT},
                {"role": "user", "content":
                 "%s\n[маркер %s-%dk]\nПеречисли ключевые структуры списком." % (doc_k(k), TAG, k)}]
        w1, ans, _ = post(url, model, base, 128, allow_retry=False)
        w2, _, t2 = post(url, model,
                         base + [{"role": "assistant", "content": ans},
                                 {"role": "user", "content":
                                  "Теперь главное ограничение одним предложением."}],
                         64, allow_retry=False)
        walls[k] = w2
        print("лестница %dk: turn1=%.2fs follow-up=%.2fs (cache_n=%s)"
              % (k, w1, w2, cache_n_of(t2)), flush=True)
    print("CHECK followup k5=%.2f k25=%.2f k100=%.2f"
          % (walls[5], walls[25], walls[100]), flush=True)


def stage_docq(url, model):
    # [doc 25k][q1] → [doc 25k][q2]: the same document in TWO independent
    # requests — q2 is fast on the live cache (the cache effect; cache_n
    # is the signal).
    doc = doc_k(25)
    m1 = [{"role": "user", "content": "%s\n[маркер %s-docq]\nВопрос 1: назови три структуры." % (doc, TAG)}]
    w1, _, _ = post(url, model, m1, 96, allow_retry=False)
    m2 = [{"role": "user", "content": "%s\n[маркер %s-docq]\nВопрос 2: какая сложность у стека?" % (doc, TAG)}]
    w2, _, t2 = post(url, model, m2, 64, allow_retry=False)
    print("docq: q1=%.2fs q2=%.2fs (cache_n=%s)" % (w1, w2, cache_n_of(t2)), flush=True)
    print("CHECK docq q2=%.2f" % w2, flush=True)


def stage1(url, model, state_path):
    if not state_path:
        raise StructFail("LCTL_AGENT_STATE не задан — bash обязан дать путь state-файла")
    stage_session(url, model)
    stage_ladder(url, model)
    stage_docq(url, model)
    # (г)-turn1: a 25k conversation for the restart-restore; the state →
    # the state file
    msgs = [{"role": "system", "content": SYS_SHORT},
            {"role": "user", "content": "%s\n[маркер %s-restore]\n%s" % (doc_k(25), TAG, RESTORE_Q1)}]
    w, ans, _ = post(url, model, msgs, 64, allow_retry=False)
    save_state(state_path, msgs + [{"role": "assistant", "content": ans}])
    print("restore: разговор 25k сохранён (turn1=%.2fs) → %s" % (w, state_path), flush=True)


def stage2(url, model, state_path):
    # After the restart: a run of the same conversation. cache_n>0 — the
    # disk tier works (the RAM empty after a recreate); cache_n=0 — a FAIL
    # at the caller.
    full = load_state(state_path) + [{"role": "user", "content": RESTORE_Q2}]
    w, _, t = post(url, model, full, 64, allow_retry=True)  # the first after a recreate
    print("CHECK restore turn2=%.2f cache_n=%d" % (w, cache_n_of(t)), flush=True)


def main(argv):
    mode = argv[0] if argv else ""
    if mode not in ("stage1", "stage2"):
        print("usage: agent_check.py <stage1|stage2> [port] [model]",
              file=sys.stderr)
        return 2
    port = argv[1] if len(argv) > 1 and argv[1] else os.environ.get("LCTL_AGENT_PORT", "11435")  # Round 6: единый порт
    model = argv[2] if len(argv) > 2 else ""
    state_path = os.environ.get("LCTL_AGENT_STATE") or ""
    if not model:
        print("agent_check: модель не передана (argv[3]) — ROUTE_MODEL пуст?", file=sys.stderr)
        return 2
    url = "http://127.0.0.1:%s/v1/chat/completions" % port
    try:
        if mode == "stage1":
            stage1(url, model, state_path)
        else:
            stage2(url, model, state_path)
    except StructFail as e:
        print("agent_check: %s" % e, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
