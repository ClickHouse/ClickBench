# Cold-run probe for chdb: wall time and root-device bytes read during the
# import, the session open (excluded from the chdb/query timing) and the query.
import sys, time
dev = sys.argv[1]
query = open(sys.argv[2]).read()
def rd():
    for l in open('/proc/diskstats'):
        f = l.split()
        if f[2] == dev:
            return int(f[5]) * 512
t = [time.perf_counter()]; b = [rd()]
import chdb
t.append(time.perf_counter()); b.append(rd())
sess = chdb.session.Session(".clickbench")
t.append(time.perf_counter()); b.append(rd())
res = sess.query(f"USE clickbench; {query}", "Pretty"); str(res)
t.append(time.perf_counter()); b.append(rd())
sess.close()
names = ["import", "open", "query"]
print(" ".join(f"{n}={t[i+1]-t[i]:.3f}s/{(b[i+1]-b[i])/1048576:.1f}MiB" for i, n in enumerate(names)))
