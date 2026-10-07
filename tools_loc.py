"""Read/write Total War .loc files (Shogun 2 format: BOM, 'LOC\\0', version, count, entries)."""
import struct

def _s(data, off):
    n = struct.unpack_from("<H", data, off)[0]; off += 2
    return data[off:off + 2 * n].decode("utf-16-le"), off + 2 * n

def read_loc(data):
    assert data[:6] == b"\xff\xfeLOC\0", data[:8]
    ver, count = struct.unpack_from("<II", data, 6)
    off, rows = 14, []
    for _ in range(count):
        key, off = _s(data, off); text, off = _s(data, off)
        tooltip = data[off]; off += 1
        rows.append((key, text, tooltip))
    return ver, rows

def write_loc(rows, ver=1):
    out = bytearray(b"\xff\xfeLOC\0" + struct.pack("<II", ver, len(rows)))
    for key, text, tooltip in rows:
        for s in (key, text):
            b = s.encode("utf-16-le"); out += struct.pack("<H", len(b) // 2) + b
        out.append(tooltip)
    return bytes(out)
