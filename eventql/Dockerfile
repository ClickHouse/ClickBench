# EventQL hasn't been maintained since 2017 and won't compile against
# modern gcc — issue #367 traces the immediate failures to incomplete
# types in the vendored ZooKeeper 3.4.8 C client. Upstream's own Travis
# job built on Ubuntu 14.04 with clang+libc++ and that combination is
# the only known-good toolchain. Even there, the 2017 build was
# undocumented post-CI, so we don't attempt source build here; we use
# the official prebuilt 0.4.1 tarball that the upstream `contrib/docker`
# image and every third-party EventQL container in the wild also use.
#
# 18.04 (bionic) is recent enough to still pull from official mirrors
# and old enough to provide a glibc/libstdc++ compatible with the 2017
# binary (the binary's ELF marker says "for GNU/Linux 2.6.32" so any
# Ubuntu since 14.04 satisfies it; 18.04 is just the most convenient
# still-supported baseline).
FROM ubuntu:18.04

# The /etc/apt/sources.list for 18.04 already points at the (eol-rolled)
# old-releases mirror in fresh pulls; no rewrite needed at build time.
RUN apt-get update -y \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        ca-certificates curl \
 && rm -rf /var/lib/apt/lists/*

ARG EVQL_VERSION=v0.4.1
ARG EVQL_TARBALL=eventql-0.4.1-linux_x86_64.tgz

RUN curl -fL -o /tmp/evql.tgz \
        "https://github.com/eventql/eventql/releases/download/${EVQL_VERSION}/${EVQL_TARBALL}" \
 && tar -xzf /tmp/evql.tgz -C / \
 && rm /tmp/evql.tgz \
 && ldconfig

# Bundled libevqlclient.so lands in /usr/local/lib; the linker needs it
# visible for evql/evqlctl. /etc/ld.so.conf.d/usr-local-lib.conf doesn't
# exist on 18.04 by default — add it so ldconfig picks the lib up across
# rebuilds.
RUN echo /usr/local/lib > /etc/ld.so.conf.d/usr-local-lib.conf && ldconfig

# Standalone bootstrap quirk: evqld --standalone does NOT auto-create
# the `trash` subdirectory under --datadir. Its garbage-collector thread
# then errors every 30s trying to ls() the missing path, and the same
# code path keeps the metadata service from responding to insert/select
# (CREATE TABLE still succeeds because it writes directly to standalone.db).
# Pre-creating trash here makes the v0.4.1 binary actually serve inserts
# and queries. Pre-creating `data` too in case future versions of the
# binary check it the same way.
RUN mkdir -p /var/lib/eventql/trash /var/lib/eventql/data

# Data dir is bind-mounted from the host so ./data-size can `du` it
# without docker exec. The bind mount overlays whatever the image had,
# so ./start re-creates the trash/data subdirs on the host side.
VOLUME /var/lib/eventql

# Standalone single-node setup writes its data + WAL under /var/lib/eventql.
# Bind 0.0.0.0 so the host-side load/query scripts can reach the port via
# 127.0.0.1:<host-port>.
EXPOSE 9175

ENTRYPOINT ["/usr/local/bin/evqld", \
    "--standalone", \
    "--datadir", "/var/lib/eventql", \
    "--listen", "0.0.0.0:9175"]
