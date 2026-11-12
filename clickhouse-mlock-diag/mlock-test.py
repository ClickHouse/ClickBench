# Cold-cache cost of mlock of the executable segment of a binary, as the
# server does it, with different ways to read it ahead first.
# Usage: mlock-test.py <binary> <method>
import ctypes, os, struct, sys, time, threading

path, method = sys.argv[1], sys.argv[2]
with open(path, "rb") as f:
    hdr = f.read(64)
    phoff, = struct.unpack_from("<Q", hdr, 0x20)
    phentsize, phnum = struct.unpack_from("<HH", hdr, 0x36)
    f.seek(phoff)
    ph = f.read(phentsize * phnum)
segs = []
for i in range(phnum):
    p_type, p_flags, p_offset, p_vaddr, p_paddr, p_filesz = struct.unpack_from("<IIQQQQ", ph, i * phentsize)
    if p_type == 1 and p_flags & 1:
        segs.append((p_filesz, p_offset))
filesz, offset = max(segs)
page = os.sysconf("SC_PAGE_SIZE")
start = offset & ~(page - 1)
length = filesz + (offset - start)

libc = ctypes.CDLL(None, use_errno=True)
libc.mmap.restype = ctypes.c_void_p
libc.mmap.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_long]
for fn in (libc.mlock, libc.madvise):
    fn.argtypes = [ctypes.c_void_p, ctypes.c_size_t] + ([ctypes.c_int] if fn is libc.madvise else [])
fd = os.open(path, os.O_RDONLY)
PROT_READ, PROT_EXEC, MAP_PRIVATE = 1, 4, 2
addr = libc.mmap(None, length, PROT_READ | PROT_EXEC, MAP_PRIVATE, fd, start)
assert addr not in (None, ctypes.c_void_p(-1).value), os.strerror(ctypes.get_errno())

def check(rc, what):
    if rc != 0:
        raise OSError(ctypes.get_errno(), f"{what}: {os.strerror(ctypes.get_errno())}")

t0 = time.monotonic()
if method == "willneed":
    check(libc.madvise(addr, length, 3), "MADV_WILLNEED")
elif method == "populate":
    check(libc.madvise(addr, length, 22), "MADV_POPULATE_READ")
elif method == "fadvise":
    os.posix_fadvise(fd, start, length, os.POSIX_FADV_WILLNEED)
elif method == "threads":
    # Read the range with 8 threads, as a userspace readahead.
    n, chunk = 8, (length + 7) // 8
    def rd(i):
        os.pread(fd, min(chunk, length - i * chunk), start + i * chunk)
    ts = [threading.Thread(target=rd, args=(i,)) for i in range(n)]
    [t.start() for t in ts]; [t.join() for t in ts]
elif method != "plain":
    sys.exit(f"unknown method {method}")
t1 = time.monotonic()
check(libc.mlock(addr, length), "mlock")
t2 = time.monotonic()
print(f"{method:9s} segment {length / 2**20:.1f} MiB: readahead {t1 - t0:.3f} s + mlock {t2 - t1:.3f} s = {t2 - t0:.3f} s")
