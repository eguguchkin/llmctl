#!/usr/bin/env python3
# B-pin shim: bench_report.py argv[1] — the JSON snapshot structure and
# meta against tests/fixtures/bench_runs (the B_* env golden values).
# The rows must be verbatim (the runner's keys untouched), the extras —
# a dict. rc 0 = the snapshot is honest.
import json
import sys

with open(sys.argv[1], encoding="utf-8") as fh:
    data = json.load(fh)
m = data["meta"]
assert m["date"] == "2026-11-22T00:00:00+00", m
assert m["engine"] == "engine-x" and m["version"] == "1.0", m
assert m["profile"] == "prof-x" and m["model"] == "model-x", m
assert m["fixture_md5"] == "253c7ac50857fe6d0e10fb0d2c5e35c0", m
assert m["params"] == "runs=2, parallel=2,4", m
assert m["truncated"] is False, m
assert len(data["solo"]) == 3, len(data["solo"])
assert len(data["prose"]) == 1, len(data["prose"])
assert len(data["session"]) == 15, len(data["session"])
assert len(data["followup"]) == 2 and data["followup"][0]["turn"] == 1, data["followup"]
assert len(data["parallel"]) == 2, len(data["parallel"])
assert data["solo"][0]["timings"]["component_cache"]["reuse"] == "none"   # verbatim rows
assert data["parallel"][0]["agg_tok_s"] == 60.0, data["parallel"][0]
assert isinstance(data["extras"], dict) and data["extras"], data["extras"]
print("snap-ok")
