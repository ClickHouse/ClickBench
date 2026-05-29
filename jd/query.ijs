NB. Per-query runner. Reads a J expression (typically wrapping a `jd`
NB. call) from stdin, evaluates it, prints the result to stdout, and
NB. writes the wall-clock runtime in fractional seconds to stderr's
NB. last line — the contract expected by lib/benchmark-common.sh.

load 'data/jd/jd'
jdadminx 'sandp'

q =. fread 3     NB. read all of stdin (file id 3 = stdin)

t0 =. 6!:1''     NB. seconds since epoch (high resolution)
result =. ". q
t1 =. 6!:1''

echo ": result   NB. format and print result to stdout

NB. Timing to stderr (file id 4). 1!:2 writes to file id.
(": t1 - t0) 1!:2 (4)

exit ''
