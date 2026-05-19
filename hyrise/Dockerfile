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
# Set NO_LTO=TRUE to disable Link Time Optimization (much faster build, slightly
# lower runtime performance — useful for development/testing). Default: LTO on.
ARG NO_LTO=FALSE

WORKDIR /opt
RUN git clone https://github.com/hyrise/hyrise.git \
    && cd hyrise \
    && git checkout "${HYRISE_REF}" \
    && git submodule update --jobs 8 --init --recursive --depth 1

WORKDIR /opt/hyrise/cmake-build-release
RUN cmake -GNinja -DCMAKE_BUILD_TYPE=Release -DNO_LTO=${NO_LTO} .. \
    && ninja hyriseServer

FROM ubuntu:25.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        libboost-system1.83.0 \
        libboost-thread1.83.0 \
        libhwloc15 \
        libnuma1 \
        libsqlite3-0 \
        libtbb12 \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

COPY --from=build /opt/hyrise/cmake-build-release/hyriseServer /usr/local/bin/hyriseServer
COPY --from=build /opt/hyrise/cmake-build-release/lib/libhyrise_impl.so /usr/local/lib/
COPY --from=build /opt/hyrise/cmake-build-release/third_party/jemalloc/lib/libjemalloc.so.2 /usr/local/lib/
RUN ldconfig

EXPOSE 5432
ENTRYPOINT ["/usr/local/bin/hyriseServer"]
CMD ["5432"]
