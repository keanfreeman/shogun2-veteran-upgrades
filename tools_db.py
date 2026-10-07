"""Decode Shogun 2 DB tables using RPFM's schema (schemas/schema_sho2.ron).

Usage:
  python3 tools_db.py <table_name> [filter_substring]   # dump rows from the game's packs
"""
import os, re, struct, sys
from tools_packread import read_index, extract

HERE = os.path.dirname(os.path.abspath(__file__))


def _first_existing(paths):
    for p in paths:
        if p and os.path.exists(p):
            return p
    return None


# The game's data folder: SHOGUN2_DATA, else the default Steam locations (Linux, Windows).
GAME_DATA = _first_existing([
    os.environ.get("SHOGUN2_DATA"),
    os.path.expanduser("~/.local/share/Steam/steamapps/common/Total War SHOGUN 2/data"),
    os.path.expanduser("~/.steam/steam/steamapps/common/Total War SHOGUN 2/data"),
    r"C:\Program Files (x86)\Steam\steamapps\common\Total War SHOGUN 2\data",
]) or os.environ.get("SHOGUN2_DATA", "SHOGUN2_DATA-not-set")
# RPFM's Shogun 2 schema (not redistributed here): RPFM_SCHEMA, else ./schemas/, else RPFM's own folders.
SCHEMA = _first_existing([
    os.environ.get("RPFM_SCHEMA"),
    os.path.join(HERE, "schemas", "schema_sho2.ron"),
    os.path.expanduser("~/.var/app/io.github.frodo45127.rpfm/config/rpfm/schemas/schema_sho2.ron"),
    os.path.expanduser("~/.config/rpfm/schemas/schema_sho2.ron"),
    os.path.join(os.environ.get("APPDATA", ""), "FrodoWazEre", "rpfm", "config", "schemas", "schema_sho2.ron"),
]) or os.path.join(HERE, "schemas", "schema_sho2.ron")
PACKS = ["data.pack", "data_fots.pack"]

_schema = None

def schema():
    """{table_name: {version: [(field_name, field_type), ...]}}"""
    global _schema
    if _schema is None:
        if not os.path.exists(SCHEMA):
            raise SystemExit("RPFM schema not found: install RPFM and download its schemas, then set RPFM_SCHEMA "
                             "to schema_sho2.ron (or copy it to ./schemas/). See README.")
        text = open(SCHEMA, encoding="utf-8").read()
        _schema = {}
        starts = [(m.group(1), m.end()) for m in re.finditer(r'^        "(\w+)": \[', text, re.M)]
        for i, (name, start) in enumerate(starts):
            end = starts[i + 1][1] if i + 1 < len(starts) else len(text)
            versions = {}
            for chunk in re.split(r"\n\s*version: ", text[start:end])[1:]:
                ver = int(re.match(r"\d+", chunk).group())
                body = chunk.split("localised_fields:")[0]
                versions[ver] = re.findall(r'name: "([^"]+)",\s*\n\s*field_type: (\w+)', body)
            _schema[name] = versions
    return _schema

def decode(data, table):
    off = 0
    if data[:4] == b"\xfd\xfe\xfc\xff":  # GUID
        n = struct.unpack_from("<H", data, 4)[0]; off = 6 + 2 * n
    ver = 0
    if data[off:off + 4] == b"\xfc\xfd\xfe\xff":
        ver = struct.unpack_from("<I", data, off + 4)[0]; off += 8
    off += 1
    count = struct.unpack_from("<I", data, off)[0]; off += 4
    fields = schema()[table][ver]

    def rd(t):
        nonlocal off
        if t in ("StringU16", "StringU8"):
            n = struct.unpack_from("<H", data, off)[0]; off += 2
            w = 2 if t == "StringU16" else 1
            s = data[off:off + w * n].decode("utf-16-le" if w == 2 else "utf-8", "replace"); off += w * n
            return s
        if t.startswith("Optional"):
            flag = data[off]; off += 1
            return rd(t[8:]) if flag else None
        fmt = {"I32": "<i", "I64": "<q", "F32": "<f", "Boolean": "<?"}[t]
        v = struct.unpack_from(fmt, data, off)[0]; off += struct.calcsize(fmt)
        return v

    rows = [{n: rd(t) for n, t in fields} for _ in range(count)]
    if off != len(data):
        raise ValueError(f"{table} v{ver}: consumed {off} of {len(data)} bytes")
    return ver, rows

def header_of(data):
    """Raw header bytes (GUID + version markers) before the row-count block."""
    off = 0
    if data[:4] == b"\xfd\xfe\xfc\xff":
        n = struct.unpack_from("<H", data, 4)[0]; off = 6 + 2 * n
    if data[off:off + 4] == b"\xfc\xfd\xfe\xff":
        off += 8
    return data[:off]

def encode(table, ver, rows, header=b""):
    """Inverse of decode(). Pass header=header_of(vanilla_bytes) to keep GUID/version identical."""
    fields = schema()[table][ver]
    out = bytearray(header) + b"\x01" + struct.pack("<I", len(rows))

    def wr(t, v):
        if t in ("StringU16", "StringU8"):
            b = v.encode("utf-16-le" if t == "StringU16" else "utf-8")
            out.extend(struct.pack("<H", len(b) // (2 if t == "StringU16" else 1)) + b)
        elif t.startswith("Optional"):
            out.append(0 if v is None else 1)
            if v is not None: wr(t[8:], v)
        else:
            out.extend(struct.pack({"I32": "<i", "I64": "<q", "F32": "<f", "Boolean": "<?"}[t], v))

    for r in rows:
        for n, t in fields:
            wr(t, r[n])
    return bytes(out)

def load_file(pack, path):
    """(version, header, rows) for one table file inside a pack."""
    data = extract(pack, path)
    table = path.split("\\")[1]
    ver, rows = decode(data, table)
    return ver, header_of(data), rows

def load(table):
    """All rows of a table across the game's data packs."""
    rows = []
    for p in PACKS:
        path = os.path.join(GAME_DATA, p)
        for name, _, _ in read_index(path):
            if name.lower().startswith(f"db\\{table}\\"):
                rows += decode(extract(path, name), table)[1]
    return rows

if __name__ == "__main__":
    table = sys.argv[1]
    flt = sys.argv[2].lower() if len(sys.argv) > 2 else None
    rows = load(table)
    print(f"# {table}: {len(rows)} rows")
    for r in rows:
        line = " | ".join(f"{k}={v}" for k, v in r.items())
        if not flt or flt in line.lower():
            print(line)
