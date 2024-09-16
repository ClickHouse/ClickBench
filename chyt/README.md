#### CHYT powered by ClickHouse

1.  Install YTsaurus cluster. Visit [YTsaurus Getting started webpage](https://ytsaurus.tech/docs/en/overview/try-yt)
2. Configure CPU, RAM and instance count of your benchmark clique using [CLI](https://ytsaurus.tech/docs/en/user-guide/data-processing/chyt/cliques/start) or YTsaurus UI (Menu -> Cliques).
3. After installation export nessasary parameters
```console
export YT_USE_HOSTS=0
export CHYT_ALIAS=*ch_public
```
In this case we will use default clique ``*ch_public``, but you can create your own
Also you need to export path to proxy using
```console
export YT_PROXY=path to your proxy
```
4. Now you can run benchmark by starting the ``run.sh`` script. It will create```//home/hits``` table, fill it with data from ClickBench dataset repository, sort it and run benchmark queries
