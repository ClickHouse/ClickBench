# Databend

[Databend](https://github.com/datafuselabs/databend) is an open-source Elastic and Workload-Aware modern cloud data warehouse.

Databend uses the latest techniques in vectorized query processing to allow you to do blazing-fast data analytics on object storage(S3, Azure Blob, Google Cloud Storage, Huawei Cloud OBS or MinIO).


It is written in Rust.

Update from @BohuTANG:

> Thanks for the benchmark!
> Databend is a cloud warehouse designed for object storage(like Amazon S3), not the local file system. The FS model is only used for testing for some cases, we didn't do any optimization, and we know it has some performance issues.
> I believe that ClickHouse is also being designed for the cloud, and looking forward to the S3 benchmark results :)
