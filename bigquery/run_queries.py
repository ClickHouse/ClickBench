from google.cloud import bigquery
from google.cloud.bigquery.enums import JobCreationMode

import sys

job_config = bigquery.QueryJobConfig()
job_config.use_query_cache = False
client = bigquery.Client(
    default_job_creation_mode=JobCreationMode.JOB_CREATION_OPTIONAL
)

file = open('queries.sql', 'r')
TRIES = 3
for query in file:
  query = query.strip()
  print("[", end='')
  for i in range(TRIES):
    print(f"\n[{i}]: {query}", file=sys.stderr)
    try:
      query_job = client.query(query, job_config=job_config)
      results = query_job.result()
      print(f"Job ID: **{query_job.job_id}**", file=sys.stderr)
      print(f"State: **{query_job.state}**", file=sys.stderr)
      print(f"Results Fetched from Cache: {query_job.cache_hit}", file=sys.stderr)
      print(f"Created Time: {query_job.created}", file=sys.stderr)
      print(f"Start Time: {query_job.started}", file=sys.stderr)
      print(f"End Time: {query_job.ended}", file=sys.stderr)
      totalTime = query_job.ended - query_job.started
      execTime = query_job.ended - query_job.created
      print(f"Execution Time: {totalTime}", file=sys.stderr)
      print(f"Total Time: {execTime}", file=sys.stderr)
      print(f"Total Rows Returned: {results.total_rows}", file=sys.stderr)
      
      execSeconds = execTime.total_seconds()
      endstr = "],\n" if i == 2 else ","
      print(f"{execSeconds}", end=endstr)
    except Exception as e:
      print(f"Job failed with error: {e}", file=sys.stderr)
      # Print error details from the job itself
      if query_job.error_result:
        print("\n--- Job Error Details ---", file=sys.stderr)
        print(f"Reason: {query_job.error_result.get('reason')}", file=sys.stderr)
        print(f"Message: {query_job.error_result.get('message')}", file=sys.stderr)
