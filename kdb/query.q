/ Per-query runner. Reads SQL from stdin, prints the result to stdout, and
/ writes the wall-clock runtime in fractional seconds to stderr's last
/ line — the contract expected by lib/benchmark-common.sh.

/ Load the SQL translator (defines .s.e) and memory-map the splayed
/ hits table.
system "l ",getenv[`HOME],"/.kx/mod/kx/sql.k_";
\l hits

/ read0 repeatedly from stdin until EOF, then join the lines so a
/ multi-line query is one logical statement for .s.e.
q_sql:"";
while[count line:read0 0;
    q_sql,:line," ";
    ];

t0:.z.p;
result:.s.e q_sql;
t1:.z.p;

show result;

/ Timing to stderr, fractional seconds.
dt:`long$(t1 - t0);
-2 string dt % 1e9;

exit 0;
