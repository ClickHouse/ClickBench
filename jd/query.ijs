NB. Per-query runner. Reads a J expression (typically wrapping a `jd`
NB. call) from stdin, evaluates it, prints the result to stdout, and
NB. writes the wall-clock runtime in fractional seconds to stderr's
NB. last line — the contract expected by lib/benchmark-common.sh.

load 'data/jd/jd'
NB. csvload (in ./load) stages the dataset in the Jd `csvload`
NB. database under ~temp/jd/csvload. Open it here so subsequent
NB. `jd 'reads … from hits'` queries find the table.
jdadmin 'csvload'

q =. 1!:1 (3)   NB. slurp stdin as a list of characters
q =. ((10{a.),(13{a.)) -.~ q   NB. strip LF/CR — J's "." rejects them

t0 =. 6!:1''
result =. ". q
t1 =. 6!:1''

echo ": result

((": t1 - t0), 10{a.) 1!:2 (5)   NB. timing + newline to stderr (id 5)

exit ''
