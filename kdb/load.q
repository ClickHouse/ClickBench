/ Load hits.parquet via the kx.pq module, convert the epoch-encoded date
/ and timestamp columns to native kdb types, and persist as a splayed
/ table under ./hits/. KDB-X Community Edition is capped at 16 GB RAM,
/ which is well below the materialized size of the 100 M-row dataset, so
/ we stream the parquet row groups one at a time instead of holding the
/ whole table in memory.

.pq:use`kx.pq;

t:.pq.pq`:hits.parquet;
cn:exec c from meta t;
cn:cn except `RG__;
n:1+max exec RG__ from t;
-1 "Row groups: ", string n;

xform:{[x]
    update
        EventDate:1970.01.01 + EventDate,
        EventTime:1970.01.01D00:00:00 + 1000000000 * EventTime,
        ClientEventTime:1970.01.01D00:00:00 + 1000000000 * ClientEventTime,
        LocalEventTime:1970.01.01D00:00:00 + 1000000000 * LocalEventTime
      from x};

/ Row group 0 must be persisted with `set` so kdb stamps a fresh `.d`
/ (column descriptor) file; subsequent row groups use the splayed-table
/ append `.[`:hits/;();,;x]`.
r:?[t; enlist (=;`RG__;0); 0b; cn!cn];
r:xform r;
(`:hits/) set r;
delete r from `.;

failed:();
doOne:{[rg]
    r:?[t; enlist (=;`RG__;rg); 0b; cn!cn];
    r:xform r;
    / Per-row-group error capture so a single bad row group doesn't kill
    / the loop. Any failures are reported at the end.
    res:@[{.[`:hits/;();,;x];`ok};r;{x}];
    if[not `ok~res; `failed set failed,enlist (rg;res)];
    if[0=rg mod 25; -1 ("  rg ",(string rg)," done")];
    };
doOne each 1 + til n-1;

if[0<count failed; -1 ("FAILED row groups: ",string count failed)];

exit 0;
