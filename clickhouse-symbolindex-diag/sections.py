# Sizes of the interesting ELF sections of a binary. Usage: sections.py <binary>
import struct, sys

with open(sys.argv[1], "rb") as f:
    h = f.read(64)
    shoff, = struct.unpack_from("<Q", h, 0x28)
    shentsize, shnum, shstrndx = struct.unpack_from("<HHH", h, 0x3A)
    f.seek(shoff)
    sh = f.read(shentsize * shnum)
    def hdr(i):
        name, typ, flags, addr, off, size = struct.unpack_from("<IIQQQQ", sh, i * shentsize)
        return name, typ, off, size
    _, _, stroff, strsize = hdr(shstrndx)
    f.seek(stroff)
    names = f.read(strsize)
    wanted = {".text", ".rodata", ".eh_frame", ".rela.dyn", ".symtab", ".strtab", ".clickhouse.symbols", ".dynsym", ".gnu_debugdata", ".debug_info"}
    for i in range(shnum):
        name, typ, off, size = hdr(i)
        n = names[name:names.index(b"\0", name)].decode()
        if n in wanted:
            print(f"{n:22s} {size / 2**20:9.1f} MiB")
