#!/usr/bin/env python3
"""The model field from the chat POST body ('?' - absent/invalid); the bench curl shim appends it to
LCTL_FAUX_BENCH_BODY (the model asserts). A 1:1 port of the former inline python3 -c block.
"""

import json
import sys

try:
    m = json.loads(sys.stdin.read()).get("model", "?")
except Exception:
    m = "?"
print(m)
