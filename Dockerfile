# 1. Nutze das offizielle, stabile und schlanke Python-Abbild
FROM python:3.12-slim

# 2. Setze das Arbeitsverzeichnis innerhalb des Server-Containers
WORKDIR /app

# 3. Installiere grundlegende System-Abhängigkeiten
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    && rm -rf /var/lib/apt/lists/*

# 4. Installiere exakt die Polars- und PyArrow-Bibliotheken
RUN pip install --no-cache-dir polars pyarrow

# 5. Kopiere die finale run.py in das Arbeitsverzeichnis des Servers
COPY run.py /app/run.py

# 6. Der standardisierte Startbefehl, den das ClickBench-Testsystem triggert
CMD ["python", "run.py"]
