#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

config_file="/etc/postgresql/14/main/conf.d/hydra.conf"

write_config_file() {
  # config for a c6a.4xlarge
  cat >${config_file} << CONF
max_worker_processes = 32
max_parallel_workers = 16
work_mem = 64MB
shared_buffers = 8GB
effective_cache_size = 24GB
effective_io_concurrency = 100
hash_mem_multiplier = 8
shared_preload_libraries = 'columnar'
columnar.min_parallel_processes = 16
CONF
}

if [ ! ${EUID} -eq 0 ]; then
  echo "Please run as root or with sudo"
  exit 1
fi

# already ran this setup file
if [ -f "$config_file" ]; then
  # rewrite the file with any tweaks
  write_config_file
  service postgresql restart
  exit 0
fi

export DEBIAN_FRONTEND=noninteractive

# install pg14 from pgdg, install build deps
apt-get update
apt-get install gnupg postgresql-common -y
sh /usr/share/postgresql-common/pgdg/apt.postgresql.org.sh -y
apt-get update
apt-get upgrade -y
apt-get install lsb-release gcc make libssl-dev autoconf pkg-config \
    postgresql-14 postgresql-server-dev-14 libcurl4-gnutls-dev \
    liblz4-dev libzstd-dev -y

# build and install hydra columnar extension
if [ ! -d hydra ]; then
    git clone --depth 1 https://github.com/HydrasDB/hydra.git
fi
cd hydra/columnar
./configure
make
make install
cd ../..

write_config_file

service postgresql restart
