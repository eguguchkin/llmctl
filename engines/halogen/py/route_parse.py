#!/usr/bin/env python3
"""The halogen route parsers (a 1:1 port of the former inline
`python3 -c` blocks from health.sh — the 0-python3-c canon): argv[1]
picks the parser, JSON on stdin, the result on stdout.

Hard modes (spec/vision/mods/slots/ctx) exit nonzero on a parse
failure — the shell keeps its fallback. The soft mode spec-health
prints nothing and stays rc 0 on garbage (parse_route does `|| true`).

Modes: spec-health | spec | vision | mods | slots | ctx
"""

import json
import sys


def main() -> None:
    mode = sys.argv[1]
    body = sys.stdin.read()
    if mode == "spec-health":
        try:
            d = json.loads(body)
            v = d.get("version")
            ev = d.get("engine_version") or (v.get("engine") if isinstance(v, dict) else v) or ""
            print(f"halogen {ev}".strip())
        except Exception:
            pass
        return
    d = json.loads(body)
    if mode == "spec":
        v = d.get("engine_version") or (d.get("version") or {}).get("engine") if isinstance(d.get("version"), dict) else d.get("engine_version")
        print("halogen", v or "?")
    elif mode == "vision":
        v = d.get("vision") or {}
        print("on" if (v.get("enabled") if isinstance(v, dict) else v) else "off")
    elif mode == "mods":
        d0 = (d.get("data") or [{}])[0]
        a = (d0.get("architecture") or {})
        print(",".join(a.get("input_modalities") or []))
    elif mode == "slots":
        print(len(d))
    elif mode == "ctx":
        print(d[0].get("n_ctx", "?") if d else "?")
    else:
        sys.exit(f"route_parse: unknown mode {mode!r}")


if __name__ == "__main__":
    main()
