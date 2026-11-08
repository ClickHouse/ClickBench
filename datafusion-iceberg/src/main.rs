//! DataFusion with an Iceberg REST catalog registered as `lake`, through the
//! DataFusion integration of iceberg-rust. The catalog and storage settings
//! come from the environment of lib/iceberg/env.sh.
//!
//! Usage:
//!     datafusion-iceberg run <file.sql>...  run the statements of the files
//!     datafusion-iceberg query              run one query from stdin: the result
//!                                           to stdout, the time in seconds to stderr

use std::collections::HashMap;
use std::env;
use std::io::Read;
use std::sync::Arc;
use std::time::Instant;

use datafusion::arrow::util::pretty::print_batches;
use datafusion::error::{DataFusionError, Result};
use datafusion::prelude::{SessionConfig, SessionContext};
use iceberg::CatalogBuilder;
use iceberg_catalog_rest::RestCatalogBuilder;
use iceberg_datafusion::IcebergCatalogProvider;
use iceberg_storage_opendal::OpenDalStorageFactory;

fn var(name: &str) -> String {
    env::var(name).unwrap_or_else(|_| panic!("the environment variable {name} is not set"))
}

fn external(e: iceberg::Error) -> DataFusionError {
    DataFusionError::External(Box::new(e))
}

async fn context(default_to_lake: bool) -> Result<SessionContext> {
    let props = HashMap::from([
        ("uri".to_string(), var("LAKE_CATALOG_URI")),
        ("warehouse".to_string(), var("LAKE_WAREHOUSE")),
        (
            "credential".to_string(),
            format!("{}:{}", var("LAKE_CLIENT_ID"), var("LAKE_CLIENT_SECRET")),
        ),
        ("oauth2-server-uri".to_string(), var("LAKE_OAUTH_URI")),
        ("scope".to_string(), "catalog".to_string()),
        ("s3.endpoint".to_string(), var("LAKE_S3_ENDPOINT")),
        ("s3.path-style-access".to_string(), var("LAKE_S3_PATH_STYLE")),
        ("s3.region".to_string(), var("AWS_REGION")),
        ("s3.access-key-id".to_string(), var("AWS_ACCESS_KEY_ID")),
        ("s3.secret-access-key".to_string(), var("AWS_SECRET_ACCESS_KEY")),
    ]);
    let catalog = RestCatalogBuilder::default()
        .with_storage_factory(Arc::new(OpenDalStorageFactory::S3 {
            customized_credential_load: None,
        }))
        .load("lake", props)
        .await
        .map_err(external)?;
    let provider = IcebergCatalogProvider::try_new(Arc::new(catalog))
        .await
        .map_err(external)?;

    // For the queries, `hits` is `lake.clickbench.hits`. For the load, the
    // default catalog stays the in-memory one, which keeps the external
    // table over the source Parquet files.
    let mut config = SessionConfig::new();
    if default_to_lake {
        config = config
            .with_create_default_catalog_and_schema(false)
            .with_default_catalog_and_schema("lake", var("LAKE_NAMESPACE"));
    }
    let ctx = SessionContext::new_with_config(config);
    ctx.register_catalog("lake", Arc::new(provider));
    Ok(ctx)
}

#[tokio::main]
async fn main() -> Result<()> {
    let args: Vec<String> = env::args().collect();
    match args.get(1).map(String::as_str) {
        Some("run") => {
            let ctx = context(false).await?;
            for path in &args[2..] {
                let text = std::fs::read_to_string(path)?;
                for statement in text.split(';').map(str::trim).filter(|s| !s.is_empty()) {
                    let batches = ctx.sql(statement).await?.collect().await?;
                    print_batches(&batches)?;
                }
            }
        }
        Some("query") => {
            let mut query = String::new();
            std::io::stdin().read_to_string(&mut query)?;
            let ctx = context(true).await?;
            let start = Instant::now();
            let batches = ctx.sql(&query).await?.collect().await?;
            let elapsed = start.elapsed().as_secs_f64();
            print_batches(&batches)?;
            eprintln!("{elapsed:.6}");
        }
        _ => {
            eprintln!("usage: datafusion-iceberg run <file.sql>... | query");
            std::process::exit(1);
        }
    }
    Ok(())
}
