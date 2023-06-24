[ByConity](https://github.com/ByConity/ByConity)

Even though ByConity is a fork of ClickHouse, there are some
differences:

- it does not have some new features/optimizations since it was a fork of
  ClickHouse (21.8).
- it supports transactions
- this setup uses HDFS

But some of this has a cost, so let's see what is it.

The benchmark uses local in docker setup, so it is far from reality, but
still.

Note, that almost all setup was copied from the [ByConity repository](https://github.com/ByConity/ByConity/tree/master/docker/local-deploy),
and I did some modifications to use pre-built images.
