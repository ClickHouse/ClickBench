from google.cloud import bigquery
from google.cloud.bigquery.enums import JobCreationMode

import sys
from typing import TextIO, Any

def log(*objects: Any, sep: str = ' ', end: str = '\n', file: TextIO = sys.stderr, severity: str = 'INFO') -> None:
    """
    Mimics the built-in print() function signature but prepends a
    timestamp and a configurable severity level to the output.

    Args:
        *objects: The objects to be printed (converted to strings).
        sep (str): Separator inserted between values, default a space.
        end (str): String appended after the last value, default a newline.
        file (TextIO): Object with a write(string) method, default sys.stdout.
        severity (str): The log level (e.g., "INFO", "WARNING", "ERROR").
    """
    # 1. Prepare the standard print content
    # Use an f-string to join the objects with the specified separator
    message = sep.join(str(obj) for obj in objects)

    # 2. Prepare the log prefix
    timestamp = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    prefix = f"[{timestamp}] [{severity.upper()}]: "

    # 3. Combine the prefix and the message
    full_message = prefix + message

    # 4. Use the file.write method to output the content
    # The 'end' argument is handled explicitly here
    file.write(full_message + end)
    
    # Ensure the buffer is flushed (important for file/stream output)
    if file is not sys.stdout and file is not sys.stderr:
        file.flush()


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
    log(f"\n[{i}]: {query}")
    try:
      query_job = client.query(query, job_config=job_config)
      results = query_job.result()
      execution_time = query_job.ended - query_job.started
      total_time = query_job.ended - query_job.created
      total_time_secs = total_time.total_seconds()
      endstr = "],\n" if i == 2 else ","
      print(f"{total_time_secs}", end=endstr)
      
      log(f"Job ID: **{query_job.job_id}**")
      log(f"Query ID: **{query_job.query_id}**")
      log(f"State: **{query_job.state}**")
      log(f"Results Fetched from Cache: {query_job.cache_hit}")
      log(f"Created Time: {query_job.created}")
      log(f"Start Time: {query_job.started}")
      log(f"End Time: {query_job.ended}")
      log(f"Execution Time: {execution_time}")
      log(f"Total Time: {total_time}")
      log(f"Total Rows Returned: {results.total_rows}")
      
    except Exception as e:
      log(f"Job failed with error: {e}", severity="ERROR")
      # Print error details from the job itself
      if query_job.error_result:
        log("\n--- Job Error Details ---")
        log(f"Reason: {query_job.error_result.get('reason')}")
        log(f"Message: {query_job.error_result.get('message')}")
