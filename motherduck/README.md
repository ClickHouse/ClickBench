## Prerequisite

* Get a [MotherDuck token](https://motherduck.com/docs/key-tasks/authenticating-and-connecting-to-motherduck/authenticating-to-motherduck/#creating-an-access-token)


## Running the benchmark

Pass `motherduck_instance_type=<INSTANCE_TYPE>` to modify:
* the report filename name (log.json by default)
* "machine" field in the report ("Motherduck: unknown instance type" by default).

```
motherduck_instance_type=<INSTANCE_TYPE> motherduck_token=<TOKEN> bash benchmark.sh
```

By default, running `benchmark.sh` will try to install python.
To skip that step:
```
motherduck_instance_type=<INSTANCE_TYPE> motherduck_token=<TOKEN> bash benchmark.sh --skip-setup
```