`benchmark.sh` will download and install the developer edition of `Kinetica` as well as its sql-client `kisql`, ingest the dataset and run the queries.
It requires `docker` to be already installed on your system.
All the queries will be executed on behalf of the user `admin` with the password `admin`.

`99991589` rows will be inserted. Errors of the following kind are expected to happen during ingestion:
`WARNING: (column: 'Referer', type: string', val: '"http://yandex.ru/domkadrov.irr.ru/catalog/92/women.aspx?group_cod_1s=16&msgid=1917057&lr=46&ps_userial=&only_news.ru/photo/nedelweissearch?text=?????-??? ?????') Quoted field must end with quote, column number: 15`

**NOTE**: only 19 queries will run successfully because of the very limited support of processing of unlimited size strings (https://kinetica-community.slack.com/archives/C01M29KDP51/p1671493126352899?thread_ts=1671486649.434019&cid=C01M29KDP51).
