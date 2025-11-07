#!/usr/bin/env python3

from databricks import sql
import os
import sys
import time
import requests

query = sys.stdin.read()
print(f"running {query}", file=sys.stderr)

# Get connection parameters from environment variables
server_hostname = os.getenv('DATABRICKS_SERVER_HOSTNAME')
http_path = os.getenv('DATABRICKS_HTTP_PATH')
access_token = os.getenv('DATABRICKS_TOKEN')
catalog = os.getenv('DATABRICKS_CATALOG', 'main')
schema = os.getenv('DATABRICKS_SCHEMA', 'clickbench')

if not all([server_hostname, http_path, access_token]):
    print("Error: Missing required environment variables:", file=sys.stderr)
    print("  DATABRICKS_SERVER_HOSTNAME", file=sys.stderr)
    print("  DATABRICKS_HTTP_PATH", file=sys.stderr)
    print("  DATABRICKS_TOKEN", file=sys.stderr)
    sys.exit(1)

connection = sql.connect(
    server_hostname=server_hostname,
    http_path=http_path,
    access_token=access_token,
    catalog=catalog,
    schema=schema
)

print('[', end='')

for try_num in range(3):
    if try_num > 0:
        print(',', end='')

    try:
        cursor = connection.cursor()

        # Execute the query
        cursor.execute(query)
        results = cursor.fetchall()
        query_id = cursor.query_id

        # Get execution time from REST API
        duration = None
        max_retries = 3

        for retry in range(max_retries):
            # Wait a moment for query to complete and be available
            time.sleep(1 if retry == 0 else 2)

            # Call the query history API
            url = f"https://{server_hostname}/api/2.0/sql/history/queries/{query_id}"
            headers = {
                "Authorization": f"Bearer {access_token}",
                "Content-Type": "application/json"
            }

            try:
                response = requests.get(url, headers=headers, timeout=10)
                if response.status_code == 200:
                    data = response.json()
                    if 'duration' in data:
                        # Duration is in milliseconds, convert to seconds
                        duration = round(data['duration'] / 1000.0, 3)
                        break
            except Exception as api_error:
                print(f"API error on retry {retry + 1}: {api_error}", file=sys.stderr)

        if duration is None:
            # Fallback: if metrics aren't available after retries, use null
            duration = 'null'
            print(f"Could not retrieve metrics for query_id {query_id} after {max_retries} retries", file=sys.stderr)

        print(duration if isinstance(duration, str) else duration, end='')

        cursor.close()
    except Exception as e:
        print('null', end='')
        print(f"query <{query.strip()}> errored out on attempt <{try_num+1}>: {e}", file=sys.stderr)

print(']')

connection.close()
