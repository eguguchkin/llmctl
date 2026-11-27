#!/usr/bin/env python3
"""gguf_type_check.py FILE... — a streaming pre-check of GGUF tensor types.

Parses ONLY the GGUF header (the weight data is not read — 49 GB shards
stay untouched): the GGUF magic → version u32 → n_tensors u64 → n_kv u64 →
the KV pairs (string/scalar/one-level-array values are skipped; a nested
array or an unknown value type = a format error) → the tensor table (name,
nd u32, dims u64×nd, type u32, offset u64).

The RED contract is NUMERIC, validated by F3 (unsloth UD-* do not load in
gufo) + EXP-005 live (UD-IQ4_XS RED on the ffn shards, the q4xl greens —
F20): RED = {16, 17, 18, 19, 22, 29} ∪ {t > 29}  on ffn_* tensors ONLY
    (16-22 — the low-bit IQ2_*/IQ3_XXS/IQ1_S; 29 — IQ1_M; t>29 — BF16/TQ/
    MXFP4/unknown revisions). A file's red verdict — if ANY tensor with
    "ffn_" in its name has a RED type.
Risky types outside ffn_* — an informational WARN line, the verdict is
    green (the BF16=30 indexer tensors load fine — F20).
The type names — the canonical llama.cpp ggml_type enum (display only;
    the contract is the numbers; "IQ3_XS" does not exist: 24=I8, 25=I16,
    26=I32, 27=I64, 28=F64, 29=IQ1_M, 30=BF16, 34=TQ1_0, 35=TQ2_0,
    39=MXFP4 — review 1.1 Q1 + F20) plus the engine fork enum
    41=Q1_0/42=Q2_0 (ggml.h:431–432).

Sanity: n_kv, n_tensors ≤ 1 000 000; a total metadata size > 64 MiB — a
format error (streaming read, a byte budget).

Output: RED:/WARN: detail lines + a verdict line per file
("<file>: КРАСНЫЙ (v3, tensors=N, kv=M)" / "<file>: зелёный (...)"); a
non-GGUF, truncated/corrupt metadata — a «ОШИБКА ФОРМАТА: <причина>» line.

Exit codes: 0 — all files green; 1 — there is a red one; 2 — a format/IO
error (of at least one file; an error dominates over red: an unparsed file
does not let the verdict be trusted). stdlib only (struct/sys).
"""

import struct
import sys

MAGIC = b"GGUF"
MAX_KV = 1_000_000
MAX_TENSORS = 1_000_000
MAX_META_BYTES = 64 * 1024 * 1024

# The RED set of low-bit IQ: IQ2_XXS/IQ2_XS/IQ3_XXS/IQ1_S/IQ2_S/IQ1_M
# (the numbers are the canonical ggml_type enum; they do not survive in
# FFN — F3/F20)
RED_TYPES = {16, 17, 18, 19, 22, 29}

# The canonical llama.cpp ggml_type enum (the names are display only;
# 4/5/Q4_0_4_4* — removed from GGUF, 31-33/36-38 — reserved; 41/42 — the
# engine fork, ggml.h:431–432)
TYPE_NAMES = {
    0: "F32", 1: "F16", 2: "Q4_0", 3: "Q4_1", 4: "Q4_2*", 5: "Q4_3*",
    6: "Q5_0", 7: "Q5_1", 8: "Q8_0", 9: "Q8_1",
    10: "Q2_K", 11: "Q3_K", 12: "Q4_K", 13: "Q5_K", 14: "Q6_K", 15: "Q8_K",
    16: "IQ2_XXS", 17: "IQ2_XS", 18: "IQ3_XXS", 19: "IQ1_S", 20: "IQ4_NL",
    21: "IQ3_S", 22: "IQ2_S", 23: "IQ4_XS", 24: "I8", 25: "I16", 26: "I32",
    27: "I64", 28: "F64", 29: "IQ1_M", 30: "BF16", 34: "TQ1_0", 35: "TQ2_0",
    39: "MXFP4", 40: "NVFP4", 41: "Q1_0", 42: "Q2_0",
}

# The metadata value sizes (the gguf_metadata_value_type enum; 8 = string,
# 9 = array — handled separately)
VALUE_SIZES = {0: 1, 1: 1, 2: 2, 3: 2, 4: 4, 5: 4, 6: 4, 7: 1, 10: 8, 11: 8, 12: 8}
VTYPE_STRING = 8
VTYPE_ARRAY = 9


class FormatError(Exception):
    """A corrupt/unsupported GGUF format — rc 2."""


class Reader:
    """A streaming header reader with a metadata byte budget (the 64 MiB cap)."""

    __slots__ = ("f", "budget")

    def __init__(self, f):
        self.f = f
        self.budget = MAX_META_BYTES

    def read(self, n):
        if n > self.budget:
            raise FormatError(f"метаданные > {MAX_META_BYTES // (1024 * 1024)} MiB")
        self.budget -= n
        b = self.f.read(n)
        if len(b) != n:
            raise FormatError("обрезанные метаданные")
        return b

    def u32(self):
        return struct.unpack("<I", self.read(4))[0]

    def u64(self):
        return struct.unpack("<Q", self.read(8))[0]

    def string(self):
        n = self.u64()
        if n > self.budget:
            raise FormatError(f"метаданные > {MAX_META_BYTES // (1024 * 1024)} MiB")
        self.budget -= n
        return self.f.read(n).decode("utf-8", "replace")


def skip_value(r, vtype):
    """Skip a KV value by type; a nested array/unknown type — an error."""
    if vtype == VTYPE_STRING:
        r.string()
    elif vtype == VTYPE_ARRAY:
        etype = r.u32()
        count = r.u64()
        if etype == VTYPE_ARRAY:
            raise FormatError("вложенный массив в KV — не поддерживается")
        if etype == VTYPE_STRING:
            for _ in range(count):
                r.string()
        elif etype in VALUE_SIZES:
            r.read(VALUE_SIZES[etype] * count)
        else:
            raise FormatError(f"неизвестный тип элемента массива KV: {etype}")
    elif vtype in VALUE_SIZES:
        r.read(VALUE_SIZES[vtype])
    else:
        raise FormatError(f"неизвестный тип значения KV: {vtype}")


def check_file(path):
    """Return (version, n_tensors, n_kv, reds, warns); FormatError propagates."""
    reds, warns = [], []
    with open(path, "rb") as f:
        if f.read(4) != MAGIC:
            raise FormatError("не GGUF (магия)")
        r = Reader(f)
        version = r.u32()
        n_tensors = r.u64()
        n_kv = r.u64()
        if n_kv > MAX_KV:
            raise FormatError(f"n_kv={n_kv} > {MAX_KV} (санити)")
        if n_tensors > MAX_TENSORS:
            raise FormatError(f"n_tensors={n_tensors} > {MAX_TENSORS} (санити)")
        for _ in range(n_kv):
            r.string()
            skip_value(r, r.u32())
        for _ in range(n_tensors):
            name = r.string()
            nd = r.u32()
            if nd > 8:
                raise FormatError(f"nd={nd} > 8 у тензора {name!r}")
            r.read(8 * nd)  # dims
            ttype = r.u32()
            r.read(8)  # offset
            tname = TYPE_NAMES.get(ttype, f"unknown({ttype})")
            if ttype in RED_TYPES or ttype > 29:
                if "ffn_" in name:
                    reds.append((name, tname))
                else:
                    warns.append((name, tname))
    return version, n_tensors, n_kv, reds, warns


def main(argv):
    if len(argv) < 2:
        print("usage: gguf_type_check.py FILE...", file=sys.stderr)
        return 2
    had_red = False
    had_err = False
    for path in argv[1:]:
        try:
            version, n_tensors, n_kv, reds, warns = check_file(path)
        except FormatError as e:
            print(f"{path}: ОШИБКА ФОРМАТА: {e}")
            had_err = True
            continue
        except OSError as e:
            print(f"{path}: ОШИБКА ЧТЕНИЯ: {e}")
            had_err = True
            continue
        for name, tname in reds:
            print(f"RED: {path}: ffn {name} = {tname}")
        for name, tname in warns:
            print(f"WARN: {path}: {name} = {tname} (вне ffn_* — информационно)")
        verdict = "КРАСНЫЙ" if reds else "зелёный"
        print(f"{path}: {verdict} (v{version}, tensors={n_tensors}, kv={n_kv})")
        if reds:
            had_red = True
    if had_err:
        return 2
    if had_red:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
