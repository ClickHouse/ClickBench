Bytehouse is a derivative of ClickHouse.
It is based on very old ClickHouse version (20.4.54418) and many features are unsupported.

https://bytehouse.cloud/signup

Sign Up. Only Asia-Pacific South-East 1 AWS region is available. Verify email.

Create virtual warehouse. XL.

Go to "Databases" and create database "test".

Go to "SQL Worksheet" and copy-paste create.sql query there.

Note: S3 import does not support public buckets. And it requires pasting secret access key, which we are not going to do. So, switch to using CLI.

Create a machine in ap-southeast-1 region and install Bytehouse CLI:

```
curl -o bytehouse-cli -L https://github.com/bytehouse-cloud/cli/releases/download/v1.5.21/bytehouse-linux-amd64
chmod +x bytehouse-cli
echo "alias bytehouse-cli=\"$(pwd)/bytehouse-cli\"" > ~/.bashrc
alias bytehouse-cli="$(pwd)/bytehouse-cli"
```

```
export user='aleksei.milovidov'
export password='bGm45*sn%4j' # No worries, I've changed it.
export account='AWSPPCOZ'
export warehouse='test'
```

Unfortunately, it refused to work.
```
$ ./bytehouse-cli --user "$user" --account "$account" --password "$password" --region ap-southeast-1 --secure
./bytehouse-cli: line 1: Not: command not found
```

So, the further testing is not possible. Good luck.

... after one minute.

No, I will not give up.

```
$ cat bytehouse-cli 
Not Foundubuntu@ip-172-31-22-83:~$
```

Looks like their documentation is wrong and the links are broken:

```
ubuntu@ip-172-31-22-83:~$ curl https://github.com/bytehouse-cloud/cli/releases/download/v1.5.21/bytehouse-linux-amd64
Not Foundubuntu@ip-172-31-22-83:~$
```

The GitHub repository https://github.com/bytehouse-cloud/cli/ is hilarious.

```
wget https://github.com/bytehouse-cloud/cli/releases/download/v1.5.34/bytehouse-cli_1.5.34_Linux_x86_64.tar.gz
tar xvf bytehouse-cli_1.5.34_Linux_x86_64.tar.gz
```

Wow, it started to work.

The CLI is using a well known Python command line toolkit and looks like a ~~christmas~~ Spring Festival tree.

It gives misleading and badly formatted error messages:
```
[code: 0, name: , no virtual warehouse selected, stack trace: ]
```

Ok, I can specify the warehouse in the command line: 

```
./bytehouse-cli --user "$user" --account "$account" --password "$password" --region ap-southeast-1 --secure --warehouse "$warehouse"
```

But it does not help. Not only activating the warehouse took 5 minutes, but it does not work regardless:

```
ByteHouse » SELECT 1;

SELECT 1

[log_id: f8af9bf5-8dc5-499a-8f02-8fdf36c76202]
Log: [Message: Turning on the virtual warehouse..., Time: 2022-07-15 21:20:05]
Log: [Message: Virtual warehouse resumed successfully, Time: 2022-07-15 21:25:12]
0 rows in set. Elapsed: 5m7.466406844s. Processed: 0 rows, 0.00 B (0.00 rows/s, 0.00 B/s).
[code: 910, name: DB::Exception, No local available worker group for vw-1092010213-test, stack trace: ]
─── End of Execution ───

▼ aleksei.milovidov@AWSPPCOZ « λ test « ap-southeast-1 « 2022-07-15T21:25:12Z ──
ByteHouse » 
ByteHouse » SELECT 1;

SELECT 1

[log_id: 522a9c0e-5b90-4d0f-8713-f43e840812b5]
─── End of Execution ───

send query: write tcp 172.31.22.83:40018->3.33.240.187:19000: i/o timeout
▼ aleksei.milovidov@AWSPPCOZ « λ test « ap-southeast-1 « 2022-07-15T21:44:57Z ──
ByteHouse » SELECT 1;

SELECT 1

[log_id: 81128728-0eba-417b-9a4c-cb9708d9724c]
─── End of Execution ───

send query: write tcp 172.31.22.83:40018->3.33.240.187:19000: i/o timeout
▼ aleksei.milovidov@AWSPPCOZ « λ test « ap-southeast-1 « 2022-07-15T21:45:02Z ──
```

> End of Execution

No, it is only the beginning of execution.

I will try to exit and start the CLI again.

Note: the CLI does not support history, so I have to type "SELECT 1" again which is annoying.

```
[dial] secure=true, skip_verify=false, strategy=random, ident=1, server=0 -> 3.33.240.187:19000
Server Information: ByteHouse 20.4.54418
cannot resolve from server dynamically, using default settings from driver
▼ aleksei.milovidov@AWSPPCOZ « λ test « ap-southeast-1 « 2022-07-15T22:00:52Z ──
ByteHouse » SELECT 1;

SELECT 1

[log_id: 79c8bdb2-c244-4b59-97d0-b090f9c01dc7]
Log: [Message: Turning on the virtual warehouse..., Time: 2022-07-15 22:00:57]
0 rows in set. Elapsed: 5m39.997921614s. Processed: 0 rows, 0.00 B (0.00 rows/s, 0.00 B/s).
[code: 0, name: , EOF, stack trace: ]
─── End of Execution ───

▼ aleksei.milovidov@AWSPPCOZ « λ test « ap-southeast-1 « 2022-07-15T22:06:37Z ──
ByteHouse » SELECT 1;

SELECT 1

[log_id: 22f63d36-1e4e-4b70-9a89-84422720645d]
─── End of Execution ───

send query: write tcp 172.31.22.83:40028->3.33.240.187:19000: i/o timeout
▼ aleksei.milovidov@AWSPPCOZ « λ test « ap-southeast-1 « 2022-07-15T22:06:47Z ──
```

Now the warehouse did not even create. Give up?

Let's try to run a query from the Web UI just to warm up the warehouse, then run a CLI in attempt to catch it...

Yes, it works.

But another attempt give the same error in the UI:

```
[code: 910, name: DB::Exception, No local available worker group for vw-1092010213-test, stack trace: ]
```

And it has stuck with this error.

Ok, I will destroy the "warehouse" and create another. Now with size L and with timeout 1 hour.

```
ubuntu@ip-172-31-22-83:~$ time ./bytehouse-cli --user "$user" --account "$account" --password "$password" --region ap-southeast-1 --secure --warehouse "$warehouse" --query "INSERT INTO test.hits FORMAT TSV" < hits.tsv[dial] secure=true, skip_verify=false, strategy=random, ident=1, server=0 -> 15.197.198.100:19000
Server Information: ByteHouse 20.4.54418

INSERT INTO test.hits
FORMAT TSV

[log_id: 5c1a1452-2b43-4b67-8f95-3e5e82c71d60]
─── End of Execution ───

insert: get format reader: driver-go(format.BlockStreamFmtReaderFactory): unrecognised input format: [TSV]

real    0m0.561s
user    0m0.295s
sys     0m0.007s
ubuntu@ip-172-31-22-83:~$ time ./bytehouse-cli --user "$user" --account "$account" --password "$password" --region ap-southeast-1 --secure --warehouse "$warehouse" --query "INSERT INTO test.hits FORMAT TabSeparated" < hits.tsv
[dial] secure=true, skip_verify=false, strategy=random, ident=1, server=0 -> 3.33.240.187:19000
Server Information: ByteHouse 20.4.54418

INSERT INTO test.hits
FORMAT TabSeparated

[log_id: 5fb9d1fe-2852-4530-bf29-441c98296297]
─── End of Execution ───

insert: get format reader: driver-go(format.BlockStreamFmtReaderFactory): unrecognised input format: [TABSEPARATED]

real    0m0.512s
user    0m0.286s
sys     0m0.017s
```

Trash.

Will try CSV.

```
wget --continue 'https://datasets.clickhouse.com/hits_compatible/hits.csv.gz'
gzip -d hits.csv.gz
```

Now it started to work:

```
time ./bytehouse-cli --user "$user" --account "$account" --password "$password" --region ap-southeast-1 --secure --warehouse "$warehouse" --query "INSERT INTO test.hits FORMAT CSV" < hits.csv
```

```
99,997,497 total rows sent, 0 rows/s (81.14 GB, 0.00 B/s)
total rows sent: 99,997,497, average speed = 134,320 rows/s
Elapsed: 12m24.754608947s. 81.14 GB (108.94 MB/s).
─── End of Execution ───

real    12m25.310s
```

But SELECT queries don't work at all:

```
▼ aleksei.milovidov@AWSPPCOZ « ▯ test « λ test « ap-southeast-1 « 2022-07-15T23:17:25Z ──
ByteHouse » SELECT count() FROM hits

SELECT count()
FROM hits

[log_id: af5f0930-6de3-49d3-bcaf-af90d272f8b0]
0 rows in set. Elapsed: 4.059µs. Processed: 0 rows, 0.00 B (0.00 rows/s, 0.00 B/s).
[code: 0, name: , EOF, stack trace: ]
─── End of Execution ───

▼ aleksei.milovidov@AWSPPCOZ « ▯ test « λ test « ap-southeast-1 « 2022-07-15T23:17:31Z ──
ByteHouse » SELECT count(*) FROM hits

SELECT count(*)
FROM hits

[log_id: 8ce7ebab-8387-4fc5-8cdb-7dbe4cb4f5ec]
0 rows in set. Elapsed: 670ns. Processed: 0 rows, 0.00 B (0.00 rows/s, 0.00 B/s).
[code: 0, name: , EOF, stack trace: ]
─── End of Execution ───

▼ aleksei.milovidov@AWSPPCOZ « ▯ test « λ test « ap-southeast-1 « 2022-07-15T23:17:35Z ──
```

They start to work if you exit from the CLI and start over again.

```
ByteHouse » SELECT count() FROM hits

SELECT count()
FROM hits

[log_id: 461e8fee-d256-4955-93e5-92ccd6b948bc]
┌─count()──┐
│ 99997497 │
└──────────┘
Profile Info: [Rows: 1, Bytes: 8, Blocks: 1, Applied Limit: false, Rows Before Limit: 0, Calculated Rows Before Limit: true]
Progress: 4.00 rows, 16.42 KB (0.00 rows/s, 0.00 B/s).
1 rows in set. Elapsed: 164.202317ms. Processed: 4 rows, 16.42 KB (24.36 rows/s, 99.97 KB/s).
End of Stream
─── End of Execution ───
```

```
./run.sh 2>&1 | tee log.txt 
```

The statistics of the number of rows, and bytes processed is wrong.
Also it shows 200 million records in the UI while I only have 100 million.

```
cat log.txt | grep --text -F 'Elapsed' | 
    grep --text -oP 'Elapsed: [\d\.]+(ms|s)\. Processed: \d+ row' | 
    sed -r -e 's/Elapsed: ([0-9\.]+)(ms|s)\. Processed: ([0-9]+) row/\1 \2 \3/' | 
    awk '{ if ($3 == 0) { print "null" } else if ($2 == "ms") { print $1 / 1000 } else { print $1 } }' |
    awk '{ if (i % 3 == 0) { printf "[" }; printf $1; if (i % 3 != 2) { printf "," } else { print "]," }; ++i; }'
```

TLDR: Bytehouse has some good and some bad parts. Everything good is derived from ClickHouse. And everything that they added on top of it is bad and makes the system almost unusable. 
