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
