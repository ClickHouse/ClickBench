## Disclaimer

When you use mongo then you need to prepare structure, indexes, queries even for normal
work. Especially when you work with legacy structure or big data. 
So in addition to converting SQL to mongo query language they are adapted to use indexes.

It may seem unfair to other benches that don't have same preparation but working with mongo 
require that all because you can't just make arbitrary queries on big collections in mongo.

If you search mongo analogues for your SQL queries then you can inspire by
`queries.js` but remember that these queries specially adapted to current benchmark
and may be work slower in your cases/environment. Especially if you have less than 100k docs.

---

The queries produce correct results and locally run to completion.

It's likely there are opportunities for optimization in the setup and the
queries!

Here are the steps to kick off a run via ssh session after a git clone, from the
root of the repository:

```
cd mongodb
chmod +x benchmark.sh
tmux
./benchmark.sh > ~/log.txt 2>&1
```

The ingestion times and data size will be in log.txt, and the raw results will
be in result.json. The node script 'formatResult.js' can transform the results
from result.json to the format expected for files in the results folder.
