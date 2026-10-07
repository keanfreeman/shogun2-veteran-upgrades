"""Check a mod pack's DB rows for broken references, using RPFM's schema (is_reference).

Every referencing field in the pack's tables must point at a value that exists in the
referenced table (vanilla data.pack + the pack itself). Also flags duplicate keys.
Usage: python3 tools_validate.py <mod.pack>
"""
import collections, os, re, sys
from tools_db import SCHEMA, GAME_DATA, decode, schema
from tools_packread import read_index, extract

_refs = None


def references():
    """{table: {version: {field: (ref_table, ref_column)}}}"""
    global _refs
    if _refs is None:
        text = open(SCHEMA, encoding="utf-8").read()
        _refs = {}
        starts = [(m.group(1), m.end()) for m in re.finditer(r'^        "(\w+)": \[', text, re.M)]
        for i, (name, start) in enumerate(starts):
            end = starts[i + 1][1] if i + 1 < len(starts) else len(text)
            for chunk in re.split(r"\n\s*version: ", text[start:end])[1:]:
                ver = int(re.match(r"\d+", chunk).group())
                body = chunk.split("localised_fields:")[0]
                fields = {}
                for block in re.split(r'\n\s*\(\s*\n\s*name: ', body)[1:]:
                    fname = re.match(r'"([^"]+)"', block).group(1)
                    m = re.search(r'is_reference: Some\(\("([^"]+)", "([^"]+)"\)\)', block)
                    if m:
                        fields[fname] = (m.group(1), m.group(2))
                _refs.setdefault(name, {})[ver] = fields
    return _refs


def table_rows(pack_paths):
    """{table: [rows]} across the given packs (decodable files only)."""
    out = collections.defaultdict(list)
    for p in pack_paths:
        for n, _, _ in read_index(p):
            if not n.lower().startswith("db\\"):
                continue
            t = n.split("\\")[1]
            try:
                _, rows = decode(extract(p, n), t)
            except Exception:
                continue
            out[t] += rows
    return out


def version_of(data):
    import struct
    off = 0
    if data[:4] == b"\xfd\xfe\xfc\xff":
        off = 6 + 2 * struct.unpack_from("<H", data, 4)[0]
    if data[off:off + 4] == b"\xfc\xfd\xfe\xff":
        return struct.unpack_from("<I", data, off + 4)[0]
    return 0


def validate(mod_pack):
    vanilla = os.path.join(GAME_DATA, "data.pack")
    everything = table_rows([vanilla, mod_pack])
    problems = []
    for n, _, _ in read_index(mod_pack):
        if not n.lower().startswith("db\\"):
            continue
        t = n.split("\\")[1]
        data = extract(mod_pack, n)
        ver = version_of(data)
        _, rows = decode(data, t)
        refs = references().get(t, {}).get(ver, {})
        for field, (rt, rc) in refs.items():
            target = everything.get(rt + "_tables") or everything.get(rt)
            if target is None:
                problems.append(f"{n}: field {field} -> {rt}.{rc}: referenced table not decodable/known (unchecked)")
                continue
            valid = {r.get(rc) for r in target}
            for r in rows:
                v = r.get(field)
                if v not in (None, "") and v not in valid:
                    problems.append(f"{n}: {field}={v!r} not found in {rt}.{rc}")
        # duplicate key check against vanilla rows of the same table
        keys = [f for f, _ in schema()[t][ver]][:1]
        if keys:
            k = keys[0]
            counts = collections.Counter(r[k] for r in everything[t])
            for r in rows:
                if counts[r[k]] > 1 and t not in ("effect_bonus_value_unit_record_junctions_tables",):
                    problems.append(f"{n}: first column {k}={r[k]!r} appears {counts[r[k]]}x in {t} (possible duplicate key)")
    return problems


if __name__ == "__main__":
    probs = validate(sys.argv[1])
    seen = collections.Counter(p.split(":")[0] + ":" + p.split(":")[1].split("=")[0] for p in probs)
    for p in sorted(set(probs))[:200]:
        print(p)
    print(f"\n{len(probs)} problems")
