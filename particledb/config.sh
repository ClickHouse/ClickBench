#!/bin/bash
# Shared paths and an isolated native TCP client.
ENTRY=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
RUN="$ENTRY/current-run"
SERVICE=particledb-clickbench.service
VERSION=1.1.19-rc.16
export LC_ALL=C
NATIVE=(env -i PATH=/usr/bin:/bin LC_ALL=C HOME="$ENTRY/client-home"
        "$ENTRY/bin/$VERSION" cli --native --no-socket --sslmode disable
        -h 127.0.0.1 -p 55434 -U postgres
        -w -v ON_ERROR_STOP=1 -qAt)
