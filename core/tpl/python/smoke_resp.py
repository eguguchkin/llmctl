# Единый смоук-валидатор каркаса (fix:w42-smoke-core; перенесён из адаптеров —
# их копии были байт-идентичны). Проверяет ответ /v1/chat/completions на
# содержимое и эхо модели. Режимы (argv): [model] [stream|tools]
#   text   — дефолт: JSON, message.content непуст, d.model == model
#   tools  — контент непуст ИЛИ tool_calls непуст (движок принял форму
#            запроса с инструментами и ответил валидным choices)
#   stream — SSE-поток: есть data-чанки с delta.content, терминальный
#            [DONE], собранный контент непуст, model эхо на чанке
# rc 0 = проверка пройдена; rc 1 = провал (пусто/не то эхо/кривой поток)
import json, sys

model = sys.argv[1] if len(sys.argv) > 1 else ""
mode = sys.argv[2] if len(sys.argv) > 2 else "text"

if mode == "stream":
    chunks = 0
    done = False
    saw_model = False
    parts = []
    for line in sys.stdin:
        line = line.strip()
        if not line.startswith("data:"):
            continue
        payload = line[5:].strip()
        if payload == "[DONE]":
            done = True
            break
        try:
            d = json.loads(payload)
        except ValueError:
            continue
        if d.get("model") == model:
            saw_model = True
        ch = (d.get("choices") or [{}])[0].get("delta") or {}
        part = ch.get("content")
        if part:
            parts.append(part)
            chunks += 1
    body = "".join(parts)
    print("ответ(sse):", (body or "")[:60].strip() or "(ПУСТО)",
          "[%d чанков, DONE=%s, model=%s]" % (chunks, done, saw_model))
    sys.exit(0 if (body.strip() and done and saw_model) else 1)

d = json.load(sys.stdin)
if d.get("model") != model:
    print("ответ: ЭХО-МОДЕЛИ %r != %r" % (d.get("model"), model))
    sys.exit(1)
msg = (d.get("choices") or [{}])[0].get("message") or {}
if mode == "tools":
    calls = [tc.get("function", {}).get("name")
             for tc in (msg.get("tool_calls") or [])]
    body = (msg.get("content") or "").strip()
    print("ответ(tools):", body[:60] or ("tool_calls=" + str(calls)))
    sys.exit(0 if (body or calls) else 1)
c = (msg.get("content") or "").strip()
print("ответ:", c[:60] or "(ПУСТО)")
sys.exit(0 if c else 1)
