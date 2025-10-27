## Running Supabase Benchmark

```bash
$ export SUPABASE_CONNECTION_STRING="[...]"
$ ./benchmark.sh
```

By default, Supabase requires IPv6 connections.
This restriction can be bypassed using the "transaction pooler".
You can get its connection string from the Supabase "Connect to your project" UI.
It looks something like this: `postgresql://postgres.zlltjtdocmcqiqprpunq:[YOUR-PASSWORD]@aws-1-eu-north-1.pooler.supabase.com:6543/postgres`
