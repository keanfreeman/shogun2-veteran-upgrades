"""Minimal Shogun 2 PFH3 pack reader: list and extract files."""
import struct, sys

def read_index(path):
    with open(path, "rb") as f:
        magic, typ, _, pfsz, fc, fsz = struct.unpack("<4s5I", f.read(24))
        assert magic == b"PFH3", magic
        f.seek(32 + pfsz); data = f.read(fsz)
    entries, off, pos = [], 0, 32 + pfsz + fsz
    for _ in range(fc):
        size = struct.unpack_from("<I", data, off)[0]; off += 4
        if typ & 0x40: off += 4  # per-file timestamp
        end = data.index(b"\0", off)
        entries.append((data[off:end].decode("latin1"), pos, size))
        pos += size; off = end + 1
    return entries

def extract(path, name):
    for n, pos, size in read_index(path):
        if n.lower() == name.lower():
            with open(path, "rb") as f:
                f.seek(pos); return f.read(size)
    raise KeyError(name)

if __name__ == "__main__":
    if len(sys.argv) == 2:
        for n, _, s in read_index(sys.argv[1]): print(f"{s:>12}  {n}")
    else:
        sys.stdout.buffer.write(extract(sys.argv[1], sys.argv[2]))
