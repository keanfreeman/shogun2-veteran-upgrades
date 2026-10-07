"""Minimal Shogun 2 PFH3 pack writer (no compression, no per-file timestamps)."""
import struct, sys, time

PACK_TYPE = {"boot": 0, "release": 1, "patch": 2, "mod": 3, "movie": 4}

def write_pack(path, files, pack_type="movie"):
    """files: list of (internal_path_with_backslashes, bytes)."""
    # The game builds its folder tree assuming a sorted index (as in CA's packs); an unsorted
    # one (e.g. db\\x after text\\y) crashes at launch in empire.retail.dll+0x12A99E4.
    files = sorted(files, key=lambda f: f[0].lower())
    index = b"".join(struct.pack("<I", len(data)) + name.encode("latin1") + b"\0"
                     for name, data in files)
    # PFH3 header: magic, type, pack-index count/size, file count, file-index size, 8-byte FILETIME
    filetime = int((time.time() + 11644473600) * 10_000_000)
    header = struct.pack("<4s5IQ", b"PFH3", PACK_TYPE[pack_type], 0, 0, len(files), len(index), filetime)
    with open(path, "wb") as f:
        f.write(header + index)
        for _, data in files:
            f.write(data)

if __name__ == "__main__":
    out = sys.argv[1]
    names = sys.argv[2:]
    write_pack(out, [(n, b"") for n in names])
