FROM ubuntu:25.04 AS build

ENV DEBIAN_FRONTEND=noninteractive
ENV HYRISE_HEADLESS_SETUP=1

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        autoconf \
        bash-completion \
        bc \
        ca-certificates \
        clang-19 \
        clang-20 \
        cmake \
        curl \
        dos2unix \
        g++-13 \
        g++-15 \
        gcc-13 \
        gcc-15 \
        git \
        libboost-all-dev \
        libhwloc-dev \
        libncurses-dev \
        libnuma-dev \
        libnuma1 \
        libpq-dev \
        libreadline-dev \
        libsqlite3-dev \
        libtbb-dev \
        lld-20 \
        llvm-20 \
        lsb-release \
        make \
        ninja-build \
        parallel \
        postgresql-server-dev-all \
        python3 \
        python3-pip \
        software-properties-common \
        sudo \
    && update-alternatives --install /usr/bin/gcc gcc /usr/bin/gcc-15 90 --slave /usr/bin/g++ g++ /usr/bin/g++-15 \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Pin a specific Hyrise revision for reproducibility (defaults to master).
ARG HYRISE_REF=master
# LTO is off by default: GCC's `-flto=auto` link of libhyrise_impl.so spawns
# one lto1 per core, and on the 32 GB c6a.4xlarge runner 16 of them exhaust
# RAM+swap and get killed (earlyoom SIGTERM → "Terminated signal terminated
# program lto1"). Set NO_LTO=FALSE on machines with ≥4 GB/core to re-enable.
ARG NO_LTO=TRUE

WORKDIR /opt
RUN git clone https://github.com/hyrise/hyrise.git \
    && cd hyrise \
    && git checkout "${HYRISE_REF}" \
    && git submodule update --jobs 8 --init --recursive --depth 1

# hyriseConsole is shipped alongside the server because its `export` command
# reads tables via GetTable without the MVCC Validate wrapper — SQL `COPY TO`
# validates, and BinaryWriter materializes the resulting ReferenceSegments as
# unencoded value segments, which would make the snapshot raw-sized and make
# it re-import unencoded. See ./load.
WORKDIR /opt/hyrise/cmake-build-release
# ninja's default parallelism = nproc kills cc1plus on 16 GiB / 4-vCPU
# playground VMs: aggregate_hash.cpp under -O3 with heavy template
# instantiation peaks at ~4 GB per translation unit, so 4 concurrent
# cc1plus × ~4 GB > 16 GB and the guest kernel SIGKILLs the loser with
# "fatal error: Killed signal terminated program cc1plus". Cap to 2 —
# hyriseServer/hyriseConsole still build in ~15 min at that width.
# Auto-widen when the host has enough RAM per core to safely parallelize.
RUN cmake -GNinja -DCMAKE_BUILD_TYPE=Release -DNO_LTO=${NO_LTO} .. \
    && jobs=2 \
    && total_kb=$(awk '/MemTotal/{print $2}' /proc/meminfo) \
    && if [ "$total_kb" -gt $((24 * 1024 * 1024)) ]; then jobs=$(nproc); fi \
    && ninja -j"$jobs" hyriseServer hyriseConsole

FROM ubuntu:25.04
ENV DEBIAN_FRONTEND=noninteractive
# libboost-container/date-time: libhyrise_impl.so links them dynamically
# (they are not dependencies of boost-system/thread, so they must be listed).
# libreadline8t64 + libncurses6: hyriseConsole.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        libboost-container1.83.0 \
        libboost-date-time1.83.0 \
        libboost-system1.83.0 \
        libboost-thread1.83.0 \
        libhwloc15 \
        libncurses6 \
        libnuma1 \
        libreadline8t64 \
        libsqlite3-0 \
        libtbb12 \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

COPY --from=build /opt/hyrise/cmake-build-release/hyriseServer /usr/local/bin/hyriseServer
COPY --from=build /opt/hyrise/cmake-build-release/hyriseConsole /usr/local/bin/hyriseConsole
COPY --from=build /opt/hyrise/cmake-build-release/lib/libhyrise_impl.so /usr/local/lib/
COPY --from=build /opt/hyrise/cmake-build-release/third_party/jemalloc/lib/libjemalloc.so.2 /usr/local/lib/
RUN ldconfig

EXPOSE 5432
ENTRYPOINT ["/usr/local/bin/hyriseServer"]
CMD ["5432"]
