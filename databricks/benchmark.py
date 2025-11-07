#!/usr/bin/env python3

from databricks import sql
import json
import os
import sys
import subprocess
import time
import requests

def write_result_to_file(run_metadata, query_results):
    # Ensure results directory exists
    os.makedirs('results', exist_ok=True)

    # Get instance type and convert to lowercase for filename
    instance_type = os.getenv('databricks_instance_type')
    if not instance_type:
        raise Exception("Missing required environment variable: databricks_instance_type")
    filename = os.path.join('results', instance_type.lower() + ".json")
    with open(filename, 'w') as f:
        print("{", file=f)
        for key in run_metadata:
            print(f'\t"{key}": {json.dumps(run_metadata[key])},', file=f)

        print('\t"result": [', file=f)
        num_lines = len(query_results)
        for i in range(num_lines):
            print(f"\t\t{query_results[i]}", end='', file=f)
            print("," if i < num_lines - 1 else "", file=f)

        print("\t]\n}", file=f)

def load_data(run_metadata):
    server_hostname = os.getenv('DATABRICKS_SERVER_HOSTNAME')
    http_path = os.getenv('DATABRICKS_HTTP_PATH')
    access_token = os.getenv('DATABRICKS_TOKEN')
    catalog = os.getenv('DATABRICKS_CATALOG')
    schema = os.getenv('DATABRICKS_SCHEMA')
    parquet_location = os.getenv('DATABRICKS_PARQUET_LOCATION')

    if not all([server_hostname, http_path, access_token, catalog, schema, parquet_location]):
        raise Exception("Missing required environment variables: DATABRICKS_SERVER_HOSTNAME, DATABRICKS_HTTP_PATH, DATABRICKS_TOKEN, DATABRICKS_CATALOG, DATABRICKS_SCHEMA, DATABRICKS_PARQUET_LOCATION")

    print(f'Connecting to Databricks; loading the data into {catalog}.{schema}', file=sys.stderr)

    connection = sql.connect(
        server_hostname=server_hostname,
        http_path=http_path,
        access_token=access_token
    )

    cursor = connection.cursor()

    # Create catalog and schema if they don't exist
    cursor.execute(f'CREATE CATALOG IF NOT EXISTS {catalog}')
    cursor.execute(f'USE CATALOG {catalog}')
    cursor.execute(f'CREATE SCHEMA IF NOT EXISTS {schema}')
    cursor.execute(f'USE SCHEMA {schema}')

    print(f'Creating table and loading data from {parquet_location}...', file=sys.stderr)

    # Drop table if exists
    cursor.execute(f'DROP TABLE IF EXISTS {catalog}.{schema}.hits')

    # Create table with explicit schema (EventTime as TIMESTAMP)
    create_query = f"""
        CREATE TABLE {catalog}.{schema}.hits (
            WatchID BIGINT NOT NULL,
            JavaEnable SMALLINT NOT NULL,
            Title STRING,
            GoodEvent SMALLINT NOT NULL,
            EventTime TIMESTAMP NOT NULL,
            EventDate DATE NOT NULL,
            CounterID INT NOT NULL,
            ClientIP INT NOT NULL,
            RegionID INT NOT NULL,
            UserID BIGINT NOT NULL,
            CounterClass SMALLINT NOT NULL,
            OS SMALLINT NOT NULL,
            UserAgent SMALLINT NOT NULL,
            URL STRING,
            Referer STRING,
            IsRefresh SMALLINT NOT NULL,
            RefererCategoryID SMALLINT NOT NULL,
            RefererRegionID INT NOT NULL,
            URLCategoryID SMALLINT NOT NULL,
            URLRegionID INT NOT NULL,
            ResolutionWidth SMALLINT NOT NULL,
            ResolutionHeight SMALLINT NOT NULL,
            ResolutionDepth SMALLINT NOT NULL,
            FlashMajor SMALLINT NOT NULL,
            FlashMinor SMALLINT NOT NULL,
            FlashMinor2 STRING,
            NetMajor SMALLINT NOT NULL,
            NetMinor SMALLINT NOT NULL,
            UserAgentMajor SMALLINT NOT NULL,
            UserAgentMinor STRING NOT NULL,
            CookieEnable SMALLINT NOT NULL,
            JavascriptEnable SMALLINT NOT NULL,
            IsMobile SMALLINT NOT NULL,
            MobilePhone SMALLINT NOT NULL,
            MobilePhoneModel STRING,
            Params STRING,
            IPNetworkID INT NOT NULL,
            TraficSourceID SMALLINT NOT NULL,
            SearchEngineID SMALLINT NOT NULL,
            SearchPhrase STRING,
            AdvEngineID SMALLINT NOT NULL,
            IsArtifical SMALLINT NOT NULL,
            WindowClientWidth SMALLINT NOT NULL,
            WindowClientHeight SMALLINT NOT NULL,
            ClientTimeZone SMALLINT NOT NULL,
            ClientEventTime TIMESTAMP NOT NULL,
            SilverlightVersion1 SMALLINT NOT NULL,
            SilverlightVersion2 SMALLINT NOT NULL,
            SilverlightVersion3 INT NOT NULL,
            SilverlightVersion4 SMALLINT NOT NULL,
            PageCharset STRING,
            CodeVersion INT NOT NULL,
            IsLink SMALLINT NOT NULL,
            IsDownload SMALLINT NOT NULL,
            IsNotBounce SMALLINT NOT NULL,
            FUniqID BIGINT NOT NULL,
            OriginalURL STRING,
            HID INT NOT NULL,
            IsOldCounter SMALLINT NOT NULL,
            IsEvent SMALLINT NOT NULL,
            IsParameter SMALLINT NOT NULL,
            DontCountHits SMALLINT NOT NULL,
            WithHash SMALLINT NOT NULL,
            HitColor STRING NOT NULL,
            LocalEventTime TIMESTAMP NOT NULL,
            Age SMALLINT NOT NULL,
            Sex SMALLINT NOT NULL,
            Income SMALLINT NOT NULL,
            Interests SMALLINT NOT NULL,
            Robotness SMALLINT NOT NULL,
            RemoteIP INT NOT NULL,
            WindowName INT NOT NULL,
            OpenerName INT NOT NULL,
            HistoryLength SMALLINT NOT NULL,
            BrowserLanguage STRING,
            BrowserCountry STRING,
            SocialNetwork STRING,
            SocialAction STRING,
            HTTPError SMALLINT NOT NULL,
            SendTiming INT NOT NULL,
            DNSTiming INT NOT NULL,
            ConnectTiming INT NOT NULL,
            ResponseStartTiming INT NOT NULL,
            ResponseEndTiming INT NOT NULL,
            FetchTiming INT NOT NULL,
            SocialSourceNetworkID SMALLINT NOT NULL,
            SocialSourcePage STRING,
            ParamPrice BIGINT NOT NULL,
            ParamOrderID STRING,
            ParamCurrency STRING,
            ParamCurrencyID SMALLINT NOT NULL,
            OpenstatServiceName STRING,
            OpenstatCampaignID STRING,
            OpenstatAdID STRING,
            OpenstatSourceID STRING,
            UTMSource STRING,
            UTMMedium STRING,
            UTMCampaign STRING,
            UTMContent STRING,
            UTMTerm STRING,
            FromTag STRING,
            HasGCLID SMALLINT NOT NULL,
            RefererHash BIGINT NOT NULL,
            URLHash BIGINT NOT NULL,
            CLID INT NOT NULL
        )
    """
    cursor.execute(create_query)

    # Insert data from parquet file with type conversions
    load_query = f"""
        INSERT INTO {catalog}.{schema}.hits
        SELECT
            WatchID,
            JavaEnable,
            Title,
            GoodEvent,
            CAST(FROM_UNIXTIME(EventTime) AS TIMESTAMP) AS EventTime,
            DATE_FROM_UNIX_DATE(EventDate) AS EventDate,
            CounterID,
            ClientIP,
            RegionID,
            UserID,
            CounterClass,
            OS,
            UserAgent,
            URL,
            Referer,
            IsRefresh,
            RefererCategoryID,
            RefererRegionID,
            URLCategoryID,
            URLRegionID,
            ResolutionWidth,
            ResolutionHeight,
            ResolutionDepth,
            FlashMajor,
            FlashMinor,
            FlashMinor2,
            NetMajor,
            NetMinor,
            UserAgentMajor,
            UserAgentMinor,
            CookieEnable,
            JavascriptEnable,
            IsMobile,
            MobilePhone,
            MobilePhoneModel,
            Params,
            IPNetworkID,
            TraficSourceID,
            SearchEngineID,
            SearchPhrase,
            AdvEngineID,
            IsArtifical,
            WindowClientWidth,
            WindowClientHeight,
            ClientTimeZone,
            CAST(FROM_UNIXTIME(ClientEventTime) AS TIMESTAMP) AS ClientEventTime,
            SilverlightVersion1,
            SilverlightVersion2,
            SilverlightVersion3,
            SilverlightVersion4,
            PageCharset,
            CodeVersion,
            IsLink,
            IsDownload,
            IsNotBounce,
            FUniqID,
            OriginalURL,
            HID,
            IsOldCounter,
            IsEvent,
            IsParameter,
            DontCountHits,
            WithHash,
            HitColor,
            CAST(FROM_UNIXTIME(LocalEventTime) AS TIMESTAMP) AS LocalEventTime,
            Age,
            Sex,
            Income,
            Interests,
            Robotness,
            RemoteIP,
            WindowName,
            OpenerName,
            HistoryLength,
            BrowserLanguage,
            BrowserCountry,
            SocialNetwork,
            SocialAction,
            HTTPError,
            SendTiming,
            DNSTiming,
            ConnectTiming,
            ResponseStartTiming,
            ResponseEndTiming,
            FetchTiming,
            SocialSourceNetworkID,
            SocialSourcePage,
            ParamPrice,
            ParamOrderID,
            ParamCurrency,
            ParamCurrencyID,
            OpenstatServiceName,
            OpenstatCampaignID,
            OpenstatAdID,
            OpenstatSourceID,
            UTMSource,
            UTMMedium,
            UTMCampaign,
            UTMContent,
            UTMTerm,
            FromTag,
            HasGCLID,
            RefererHash,
            URLHash,
            CLID
        FROM parquet.`{parquet_location}`
    """

    cursor.execute(load_query)
    load_query_id = cursor.query_id

    # Get load time from REST API
    print(f"Getting load time for query {load_query_id}...", file=sys.stderr)
    max_retries = 3

    for retry in range(max_retries):
        time.sleep(2)

        url = f"https://{server_hostname}/api/2.0/sql/history/queries/{load_query_id}"
        headers = {
            "Authorization": f"Bearer {access_token}",
            "Content-Type": "application/json"
        }

        try:
            response = requests.get(url, headers=headers, timeout=10)
            if response.status_code == 200:
                data = response.json()
                if 'duration' in data:
                    load_duration = round(data['duration'] / 1000.0, 3)
                    run_metadata["load_time"] = load_duration
                    print(f"Table created successfully in {load_duration}s", file=sys.stderr)
                    break
        except Exception as api_error:
            print(f"API error on retry {retry + 1}: {api_error}", file=sys.stderr)

    # Get table size from DESCRIBE DETAIL
    cursor.execute(f"DESCRIBE DETAIL {catalog}.{schema}.hits")
    result = cursor.fetchone()
    run_metadata["data_size"] = result[10]  # sizeInBytes column
    print(f"Table size: {run_metadata['data_size']} bytes", file=sys.stderr)

    print(f'Finished loading the data in {run_metadata["load_time"]}s; data size = {run_metadata["data_size"]} bytes', file=sys.stderr)

    cursor.close()
    connection.close()

def run_queries():
    # Run the benchmark script
    result = subprocess.run(
        ["./run.sh"],
        stdout=subprocess.PIPE,
        text=True,
        timeout=3600,  # 1 hour timeout
    )

    if result.returncode != 0:
        raise Exception(f"Benchmark failed with return code {result.returncode}")

    return result.stdout

if __name__ == "__main__":
    instance_type = os.getenv('databricks_instance_type')
    if not instance_type:
        raise Exception("Missing required environment variable: databricks_instance_type")

    run_metadata = {
        "system": "Databricks",
        "date": time.strftime("%Y-%m-%d"),
        "machine": f"Databricks: {instance_type}",
        "cluster_size": "<Lookup here: https://docs.databricks.com/aws/en/compute/sql-warehouse/warehouse-behavior>",
        "proprietary": "yes",
        "tuned": "no",
        "tags": ["managed", "column-oriented"],
    }

    load_data(run_metadata)

    query_output = run_queries()

    write_result_to_file(run_metadata, query_output.strip().split('\n'))
