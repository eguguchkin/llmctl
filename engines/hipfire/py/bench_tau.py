#!/usr/bin/env python3
"""The bench-extras JSON line (a 1:1 port of the former inline
`python3 - <<PY` from bench.sh — the 0-python3-heredoc canon): argv 1
is tau ('' — absent), argv 2 the route spec ('' — unknown); tau_s null
= the metric honestly absent, not a run error."""

import json
import sys

tau, spec = sys.argv[1], sys.argv[2]
out = {"tau_s": float(tau) if tau else None,
       "tau_note": "последняя строка tau= в логах контейнера (не кумулятивная)",
       "route_spec": spec or None}
print(json.dumps(out, ensure_ascii=False))
