# Shared config + helpers for the CtrlB ClickBench system dir.
# Sourced (not executed) by every hook script: `source "$(dirname "$0")/config.sh"`.

# Absolute path to THIS system directory — where the harness downloads
# hits.parquet and runs the hook scripts from.
CTRLB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---- lake (docker) ----------------------------------------------------------
# CtrlB runs as a Docker container (image pulled in ./install). The image serves
# the HTTP API on 5080. We publish that to the host and mount THIS system
# directory into the container at the SAME path, so the hits.parquet the harness
# downloads to $PARQUET_PATH is visible inside the container at the identical
# path and the CREATE EXTERNAL TABLE LOCATION resolves unchanged.
CTRLB_IMAGE="${CTRLB_IMAGE:-ghcr.io/ctrlb-hq/ctrlb-public:c8eead4}"
CONTAINER_NAME="${CONTAINER_NAME:-ctrlb}"
LAKE_STARTUP="${LAKE_STARTUP:-30}"

# ---- query endpoint --------------------------------------------------------
BASE_URL="${BASE_URL:-http://localhost:5080}"
ORG_ID="${ORG_ID:-default}"
SEARCH_URL="${SEARCH_URL:-${BASE_URL}/api/${ORG_ID}/_search_parquet?type=logs}"
START_TIME="${START_TIME:-1}"
END_TIME="${END_TIME:-9999999999999999}"

# ---- data ------------------------------------------------------------------
# The harness downloads into the system dir (its cwd during bench_download).
PARQUET_PATH="${PARQUET_PATH:-$CTRLB_DIR/hits.parquet}"

# post_sql <sql> -> runs a statement and prints the endpoint's server-side
# execution_time on stdout, non-zero (diagnostics to stderr) on failure. Used
# ONLY for the untimed session setup in ./start (CREATE EXTERNAL TABLE / VIEW);
# the presence of execution_time in the response is just a success signal here.
# Benchmark queries are measured by time_sql (below), not this.
post_sql() {
  local sql="$1" response et
  response="$(curl -s -X POST "$SEARCH_URL" \
    -H 'Content-Type: application/json' \
    -d "$(printf '{"sql": %s, "start_time": %s, "end_time": %s}' \
           "$(printf '%s' "$sql" | jq -Rs .)" "$START_TIME" "$END_TIME")")"
  et="$(printf '%s' "$response" | jq -r '.execution_time // empty' 2>/dev/null)"
  if [ -z "$et" ]; then
    echo "post_sql failed: $sql" >&2
    echo "resp: $(printf '%s' "$response" | head -c 300)" >&2
    return 1
  fi
  printf '%s' "$et"
}

# time_sql <sql> <response_file> -> prints the CLIENT-SIDE WALL time (seconds) of
# the full HTTP round-trip on stdout, and writes the FULL response body to
# <response_file>. The wall time (curl %{time_total}) covers sending the query,
# the server processing it, AND receiving the entire result body.
#
# The body is downloaded in full (so the result really is sent back over the wire
# — no server-side output suppression) and then VALIDATED as a genuine success
# payload: a non-200 status, OR a body that does not parse / is missing the
# expected fields (.success == true, .execution_time present) fails the try. We
# do NOT use .execution_time as the timing — it is only a structural sanity check
# so an error that somehow arrives with a 200 is not counted as a success.
# LC_ALL=C forces a '.' decimal so the harness's number parser accepts the time.
time_sql() {
  local sql="$1" outfile="$2" out http_code time_total
  out="$(LC_ALL=C curl -s -o "$outfile" -w '%{http_code} %{time_total}' \
    -X POST "$SEARCH_URL" \
    -H 'Content-Type: application/json' \
    -d "$(printf '{"sql": %s, "start_time": %s, "end_time": %s}' \
           "$(printf '%s' "$sql" | jq -Rs .)" "$START_TIME" "$END_TIME")")"
  http_code="${out%% *}"
  time_total="${out##* }"
  if [ "$http_code" != "200" ]; then
    echo "time_sql failed (HTTP ${http_code:-none}): $sql" >&2
    return 1
  fi
  if ! jq -e '.success == true and (.execution_time != null)' "$outfile" > /dev/null 2>&1; then
    echo "time_sql: HTTP 200 but response is not a valid success payload for: $sql" >&2
    echo "resp: $(head -c 300 "$outfile" 2>/dev/null)" >&2
    return 1
  fi
  printf '%s' "$time_total"
}

# Poll until the lake answers a health check, or LAKE_STARTUP seconds elapse.
wait_for_health() {
  local waited=0
  while [ "$waited" -lt "$LAKE_STARTUP" ]; do
    if curl -s -o /dev/null "$BASE_URL/healthz" 2>/dev/null \
       || curl -s -o /dev/null "$BASE_URL/api/health" 2>/dev/null; then
      return 0
    fi
    sleep 1
    waited=$((waited + 1))
  done
  return 1
}

# Run docker the right way: directly if this user can reach the daemon, else via
# sudo (we already require passwordless sudo). This makes every docker call work
# whether or not the invoking user is in the 'docker' group — no group setup and
# no re-login needed, which matters on a fresh VM (a `usermod -aG docker` would
# not even take effect in the current session). The direct-vs-sudo decision is
# made once and cached per process in _DKR.
dkr() {
  if [ -z "${_DKR:-}" ]; then
    if docker info > /dev/null 2>&1; then
      _DKR=direct
    else
      _DKR=sudo
    fi
  fi
  if [ "$_DKR" = sudo ]; then
    sudo docker "$@"
  else
    docker "$@"
  fi
}

# Stop and remove the CtrlB container (idempotent; -f also kills a running one).
stop_container() {
  dkr rm -f "$CONTAINER_NAME" > /dev/null 2>&1 || true
}

# Run the CtrlB container detached: use host networking so the lake's HTTP API on
# 5080 is reachable no matter which interface it binds inside the container, and
# mount this system dir read-only so the downloaded hits.parquet is readable
# inside at the same $PARQUET_PATH. The image has the benchmark env vars baked in.
# --rm so each restart begins from clean state.
start_container() {
  dkr run -d --rm --name "$CONTAINER_NAME" \
    --network host \
    -v "$CTRLB_DIR":"$CTRLB_DIR":ro \
    "$CTRLB_IMAGE" > /dev/null
}
