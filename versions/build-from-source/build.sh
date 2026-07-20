#!/usr/bin/env bash
# Build an early ClickHouse version from source into a runnable Docker image.
#
#   ./build.sh <version> [tag]
#
# Produces image  clickhouse-built:<version>  behaving like the official server
# images. <version> is e.g. 1.1.54011; the git tag defaults to v<version>-stable.
#
# Used to resurrect the handful of 1.1.x releases that were never published as
# an image or package (see ../list-versions.sh "unavailable" marker). The build
# environment (Ubuntu 16.04 + GCC 5) is pinned in Dockerfile.ubuntu1604.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

VERSION="${1:?usage: build.sh <version> [tag] [gcc]}"
TAG="${2:-v${VERSION}-stable}"
GCC="${3:-${GCC:-5}}"   # gcc-5 for the 2016 tags; gcc-6 for >= ~1.1.54318
IMAGE="clickhouse-built:${VERSION}"

echo "building ${VERSION} (tag ${TAG}, gcc-${GCC}) -> ${IMAGE}"
# Use BuildKit (buildx); Docker's legacy builder hangs on recent engines.
# --progress=plain streams the full build log; --load puts the image in the
# local docker store.
sudo docker buildx build --progress=plain --load \
    --build-arg "TAG=${TAG}" --build-arg "GCC=${GCC}" -t "${IMAGE}" \
    -f "${HERE}/Dockerfile.ubuntu1604" "${HERE}"

echo "built ${IMAGE}; smoke test:"
sudo docker rm -f chbuildtest >/dev/null 2>&1
sudo docker run -d --name chbuildtest --ulimit nofile=262144:262144 "${IMAGE}" >/dev/null
for i in $(seq 1 30); do
    sudo docker exec chbuildtest clickhouse client --query "SELECT version()" 2>/dev/null && break
    sleep 1
done
sudo docker rm -f chbuildtest >/dev/null 2>&1
