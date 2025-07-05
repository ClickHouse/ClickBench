# Hydra

Hydra is a high-performance Postgres database with serverless
online analytical processing (OLAP). It is designed for low-latency
applications built on time series and event data.

* [Homepage](https://hydra.so)

## Running the benchmark

The benchmark itself requires `psql` to execute. You will need to install `psql`, e.g.:

```
# Debian, Ubuntu, etc
apt-get install postgresql-client
# MacOS
brew install postgresql
```

Note that either option below will introduce additional latency depending on the location
from which the benchmark is run.

### Local Instance

In this configuration, you will run a Postgres instance locally and it will connect
to Hydra's serverless OLAP service. This will use the Hydra CLI which will manage
a Docker container for you.

1. Install Python, and if desired, your preferred Python management tools, like pipx, uv, etc.
2. Install Hydra CLI using `pip install hydra-cli` (or via `pipx`, `uv`, etc)
3. Install Docker.
4. Sign up for Hydra at https://start.hydra.so/get-started and copy the token to your clipboard
5. Run `hydra setup` and paste in your token
6. Run `hydra start` to start the local instance
7. Run `hydra config` to obtain the connection string and set it `DATABASE_URL` in your local environment,
   or pass it in when you run the benchmark.
8. Run the benchmark.

    ```
    DATABASE_URL="..." ./benchmark.sh
    ```

9.  Run `hydra stop` to stop the local instance

### Cloud Instance

In this configuration, you will connect to a Postgres instance already running in the cloud
which is already configured to connect to Hydra's serverless OLAP service.

1. Sign up for Hydra at https://start.hydra.so
2. Request access and complete onboarding
3. Create a project
4. Obtain the connection string and set it as `DATABASE_URL` in your local environment,
   or pass it in when you run the benchmark.
5. Run the benchmark.

    ```
    DATABASE_URL="..." ./benchmark.sh
    ```
