# 1. Use the official, stable, and lightweight Python image
FROM python:3.12-slim

# 2. Set the working directory within the server container
WORKDIR /app

# 3. Install basic system dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    && rm -rf /var/lib/apt/lists/*

# 4. Install exactly the Polars and PyArrow libraries
RUN pip install --no-cache-dir polars pyarrow

# 5. Copy the final run.py file to the server’s working directory
COPY run.py /app/run.py

# 6. The standardized startup command that triggers the ClickBench test system
CMD ["python", "run.py"]
