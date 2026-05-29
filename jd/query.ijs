NB. Per-query runner. Reads a J expression (typically wrapping a `jd`
NB. call) from stdin, evaluates it, prints the result to stdout, and
NB. writes the wall-clock runtime in fractional seconds to stderr's
NB. last line.

load 'data/jd/jd'
jdadminx 'sandp'

q =. (1!:1) 3   NB. read all of stdin

t0 =. 6!:1''
result =. ". q
t1 =. 6!:1''

echo ":result

(": t1 - t0) 1!:2 [ 4

exit ''
