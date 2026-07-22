#!/bin/bash
# Reconstruct the build system for a pre-2016-03 ClickHouse snapshot.
#
# The public repo only became self-contained (root CMakeLists + contrib/) at
# 2016-03. Earlier snapshots have the *source* but no build system and no
# vendored libraries. This script runs inside a checkout where the target
# source is at /src and a donor commit's build system (root CMakeLists, all
# per-dir CMakeLists, cmake modules and contrib/) has already been overlaid on
# top (see Dockerfile.reconstruct). It then reconciles the donor build files
# with the older source:
#
#   * glob libcommon/libdaemon sources        -> absorbs file renames
#     (Daemon.cpp->BaseDaemon.cpp, Revision.cpp->ClickHouseRevision.cpp, ...)
#   * prune donor-listed files absent here    -> handles added/removed files
#   * disable the tests/ targets              -> they list snapshot-specific files
#   * QuickLZ  -> header-only stub  (dropped at open-sourcing; never imported.
#                 The quicklz codec is never produced/consumed with LZ4/ZSTD data)
#   * re2_st   -> generated from contrib/libre2 via the donor's create_st_headers.sh
#   * MongoDB  -> throwing stub (legacy mongoclient driver never vendored)
#
# Idempotent-ish: intended to run once on a fresh overlay.

set -eu
cd /src

# -- strip -Werror (and the clang-only -Wno-* flags that leak into the gcc build) --
find /src -name CMakeLists.txt -o -name '*.cmake' | xargs -r sed -i 's/-Werror//g'

# -- drop the tests/ subdirectories: they enumerate files that don't all exist
#    in an older snapshot, which is a fatal cmake configure error --
find /src -name CMakeLists.txt | xargs -r sed -i 's/add_subdirectory *( *tests *)//g'
sed -i 's/INCLUDE(add.test.cmake)//' CMakeLists.txt || true

# -- drop add_subdirectory(private): the Yandex-internal Metrica code was never
#    open-sourced (appears in the 2016-06+ trees). --
find /src -name CMakeLists.txt | xargs -r sed -i '/add_subdirectory *( *private *)/d'

# -- drop the utils/ subdirectory: standalone tools we don't need, some of which
#    reference sources absent in older snapshots (a fatal configure error). --
sed -i '/add_subdirectory *( *utils *)/d' CMakeLists.txt || true

# -- Old libstdc++ ABI: this era used the refcounted (COW) std::string (8 bytes),
#    which the code's sizing assumes (e.g. Field's DBMS_TOTAL_FIELD_SIZE=32).
#    Build with _GLIBCXX_USE_CXX11_ABI=0 to get that string back (see the CXX
#    flags injection below), rather than resizing structs for the new 32-byte ABI. --

# -- glob the two small libraries so renamed sources are still picked up --
cat > libs/libdaemon/CMakeLists.txt <<'EOF'
file(GLOB daemon_src src/*.cpp)
add_library(daemon ${daemon_src})
target_link_libraries(daemon dbms)
EOF

python3 - <<'PY'
import re, os, glob
# CMakeLists in this era carry UTF-8 (Russian) comments; the container's Python
# may default to ASCII, so read/write with an explicit codec that round-trips
# arbitrary bytes.
def rd(p): return open(p, encoding="utf-8", errors="surrogateescape").read()
def wr(p, s): open(p, "w", encoding="utf-8", errors="surrogateescape").write(s)

# libcommon: replace the explicit source list with a glob (handles renames like
# Revision.cpp -> ClickHouseRevision.cpp where the target has a file the donor
# build files don't list).
f = "libs/libcommon/CMakeLists.txt"; s = rd(f)
s = re.sub(r"add_library\s*\(\s*common.*?\)",
           "file(GLOB common_src src/*.cpp)\nadd_library(common ${common_src})",
           s, count=1, flags=re.S)
wr(f, s)

# libmysqlxx: same treatment. The donor lists sources explicitly (incl. Value.cpp)
# and omits String.cpp, but pre-2014-06 defines mysqlxx::String::throwException in
# String.cpp -> undefined reference at link. Glob so the target's own sources compile.
f = "libs/libmysqlxx/CMakeLists.txt"
if os.path.exists(f):
    s = rd(f)
    s = re.sub(r"add_library\s*\(\s*mysqlxx\b.*?\)",
               "file(GLOB mysqlxx_src src/*.cpp)\nadd_library(mysqlxx ${mysqlxx_src})",
               s, count=1, flags=re.S)
    # The donor CMakeLists has a POST_BUILD step running libmysqlxx/patch.sh to patch
    # the bundled mysqlclient. Newer target trees ship that script, but the oldest
    # (pre-2014) don't -- and the overlay only brings CMakeLists/.cmake, not patch.sh,
    # so the command fails with "not found" (Error 127). We link the *system*
    # libmysqlclient and never touch MySQL in the benchmark, so when the script is
    # absent just drop the custom command. Guarded on patch.sh existence -> no-op on
    # trees that ship it (they keep patching, as before).
    if not os.path.exists("libs/libmysqlxx/patch.sh"):
        s = re.sub(r"ADD_CUSTOM_COMMAND\s*\([^)]*patch\.sh[^)]*\)", "", s, flags=re.I|re.S)
    wr(f, s)

# Drop the (never-vendored) mongoclient link name wherever it appears.
f = "dbms/CMakeLists.txt"; wr(f, re.sub(r"\bmongoclient\b", "", rd(f)))

# The dbms library is one huge explicit source list in dbms/CMakeLists.txt.
# Replace it with a recursive glob so sources renamed/moved between the target
# snapshot and the donor are all compiled (Server/Client are separate
# executables, tests are disabled). cmake 3.5 has no list(FILTER), so filter in
# a foreach.
f = "dbms/CMakeLists.txt"; s = rd(f)
glob_block = (
    'file(GLOB_RECURSE dbms_all_sources src/*.cpp)\n'
    'set(dbms_sources "")\n'
    'foreach(f ${dbms_all_sources})\n'
    '  if((NOT f MATCHES "/(Server|ODBC|tests)/") AND (NOT f MATCHES "/Client/(Client|Benchmark).cpp"))\n'
    '    list(APPEND dbms_sources ${f})\n'
    '  endif()\n'
    'endforeach()\n'
    'add_library (dbms ${dbms_sources})'
)
# The dbms lib includes the Client library code (Connection*.cpp) but not the
# client executable mains (Client.cpp/Benchmark.cpp); all of Server/ is the
# server executable; ODBC is a separate driver; tests are disabled.
s = re.sub(r"add_library\s*\(\s*dbms\b.*?\)", glob_block, s, count=1, flags=re.S)
wr(f, s)

# Generic prune: the donor build files (2016-03) list sources that an *older*
# target snapshot doesn't have yet (files added later). For every add_library /
# add_executable in every CMakeLists, drop any listed source file that doesn't
# exist relative to that CMakeLists's directory — otherwise cmake configure
# fails with "Cannot find source file".
SRC_RE = re.compile(r".+\.(cpp|cc|cxx|c|h|hpp|inc)$", re.I)
def prune(cml):
    d = os.path.dirname(cml); s = rd(cml)
    dropped = set()
    def fix(m):
        head, body = m.group(1), m.group(2)
        toks = body.split()
        kept = [t for t in toks
                if not SRC_RE.match(t) or os.path.exists(os.path.join(d, t))]
        # If an executable listed source files but every one of them is absent in
        # this (older) snapshot -- e.g. clickhouse-benchmark before Benchmark.cpp
        # existed -- pruning would leave add_executable() with no sources, which
        # cmake rejects. Drop the whole target instead (its link/INSTALL lines are
        # removed below). We never build anything but clickhouse-server/-client.
        emptied = (any(SRC_RE.match(t) for t in toks)
                   and not any(SRC_RE.match(t) for t in kept))
        if "add_executable" in head.lower() and emptied:
            tm = re.search(r"\(\s*([^\s)]+)", head)
            if tm:
                dropped.add(tm.group(1))
            return ""
        if "add_library" in head.lower() and emptied:
            # A library whose every listed source is absent in this older snapshot
            # (e.g. zkutil before libzkutil had any .cpp). Unlike an executable it
            # can be a link dependency of dbms, so we can't drop it -- give it an
            # empty stub TU so cmake can determine a link language and build an
            # (empty) archive. This era has no calls into it, so no undefined refs.
            stub = os.path.join(d, "reconstruct_stub.cpp")
            open(stub, "w").write("// Added by reconstruct.sh: empty TU so this "
                                  "source-less library links.\n")
            kept.append("reconstruct_stub.cpp")
        return head + " " + " ".join(kept) + ")"
    s2 = re.sub(r"(add_(?:library|executable)\s*\(\s*[^\s)]+)(.*?)\)", fix, s, flags=re.S|re.I)
    for tgt in dropped:
        # a dropped target can't be linked or installed; strip those statements too.
        s2 = re.sub(r"target_link_libraries\s*\(\s*" + re.escape(tgt) + r"\b.*?\)", "", s2, flags=re.S|re.I)
        s2 = re.sub(r"INSTALL\s*\([^)]*\b" + re.escape(tgt) + r"\b[^)]*\)", "", s2, flags=re.S|re.I)
    # Drop add_subdirectory(X) when X isn't an existing directory: the donor build
    # lists component dirs (e.g. TableFunctions) that an older snapshot doesn't have
    # yet. cmake errors on a missing subdir; the code that would have linked its
    # library isn't present in this era's globbed dbms sources either, so no dangling
    # refs. Skip variable-driven forms -- only prune bare directory-name arguments.
    def fix_subdir(m):
        arg = m.group(1)
        if "$" in arg or "{" in arg:
            return m.group(0)
        return m.group(0) if os.path.isdir(os.path.join(d, arg)) else ""
    s2 = re.sub(r"add_subdirectory\s*\(\s*([^\s)]+)\s*\)", fix_subdir, s2, flags=re.I)
    if s2 != s: wr(cml, s2)
# os.walk (not glob(recursive=), which needs Python 3.5+; trusty ships 3.4).
for root, _dirs, files in os.walk("."):
    if "CMakeLists.txt" in files:
        prune(os.path.join(root, "CMakeLists.txt"))
PY

# -- QuickLZ compile/link stub (dead code path: our data is LZ4/ZSTD) --
mkdir -p contrib/quicklz-stub/quicklz
cat > contrib/quicklz-stub/quicklz/quicklz_level1.h <<'EOF'
#pragma once
#include <cstddef>
#include <cstdint>
#include <cstring>
// QuickLZ was removed at the 2016-03 open-sourcing and never imported to the public
// repo. Data is compressed with LZ4/ZSTD, not QuickLZ, so qlz_compress/qlz_decompress
// are never called and only need to link. BUT the compressed-block reader parses the
// block-size HEADER via qlz_size_compressed/qlz_size_decompressed for LZ4 blocks too
// (the pre-2015 CompressedWriteBuffer stores the LZ4 sizes in QuickLZ header layout),
// so those two must be real: read the little-endian sizes from the header -- 4-byte
// "long" form when the 0x02 bit is set, which is what ClickHouse always writes.
// (A no-op returning 0 here silently corrupts every read -> "Checksum doesn't match".)
struct qlz_state_compress { char scratch[1000000]; };
struct qlz_state_decompress { char scratch[1000000]; };
inline size_t qlz_size_compressed(const char * source)
{
    if (static_cast<unsigned char>(source[0]) & 2) { uint32_t n; std::memcpy(&n, source + 1, 4); return n; }
    return static_cast<unsigned char>(source[1]);
}
inline size_t qlz_size_decompressed(const char * source)
{
    if (static_cast<unsigned char>(source[0]) & 2) { uint32_t n; std::memcpy(&n, source + 5, 4); return n; }
    return static_cast<unsigned char>(source[2]);
}
inline size_t qlz_compress(const void *, char * dst, size_t size, qlz_state_compress *) { (void)dst; return size; }
inline size_t qlz_decompress(const char *, void *, qlz_state_decompress *) { return 0; }
EOF
cp contrib/quicklz-stub/quicklz/quicklz_level1.h contrib/quicklz-stub/quicklz/quicklz_level2.h
cp contrib/quicklz-stub/quicklz/quicklz_level1.h contrib/quicklz-stub/quicklz/quicklz_level3.h

# -- vendor Poco/Ext/ScopedTry.h: a Poco extension (scoped try-lock) the early
#    trees use but that isn't in the donor's Poco. Placed on Poco's include path. --
mkdir -p contrib/libpoco/Foundation/include/Poco/Ext
cat > contrib/libpoco/Foundation/include/Poco/Ext/ScopedTry.h <<'EOF'
#pragma once
// Scoped try-lock (default-construct, then lock(&mutex) attempts tryLock and
// returns success; the mutex is released on scope exit if held). Reconstructed
// to match the early-ClickHouse usage in MergeTreeData::grabOldParts.
namespace Poco
{
template <class M>
class ScopedTry
{
public:
    ScopedTry() : _mutex(0) {}
    ~ScopedTry() { if (_mutex) _mutex->unlock(); }
    bool lock(M * mutex) { if (mutex->tryLock()) { _mutex = mutex; return true; } return false; }
private:
    M * _mutex;
    ScopedTry(const ScopedTry &);
    ScopedTry & operator=(const ScopedTry &);
};
}
EOF

# -- statdaemons compat: the early trees pull several headers from an external
#    Yandex library ("statdaemons") that the donor split up and renamed:
#      * the embedded dictionaries -> DB/Dictionaries/Embedded/ (header-only), and
#      * the daemon base class Daemon -> libs/libdaemon's BaseDaemon.
#    Both were overlaid from the donor by the Dockerfile. Expose them at the old
#    <statdaemons/...> paths (dict headers forward to Embedded; daemon.h forwards
#    to BaseDaemon with a typedef for the old class name; Interests.h — legacy
#    OLAP interest categories, unused by the benchmark — is an empty stub). --
mkdir -p contrib/statdaemons-compat/statdaemons
# -- DB::Exception: in the oldest trees (pre ~2015-11) the class itself lived in the
#    never-public external <statdaemons/Exception.h> -- DB/Core/Exception.h merely
#    #includes it and adds free functions (throwFromErrno etc.). Later the class was
#    inlined in-repo (DB/Common/Exception.h). If the tree defines it we let the
#    auto-map below forward <statdaemons/Exception.h> there; otherwise vendor an
#    equivalent class (matching what 2015-12 inlined). It is created *before* the
#    auto-map so the auto-map leaves it untouched. Header-only, so it adds no link
#    symbols and the era's own Exception.cpp still provides the free functions. The
#    StackTrace it carries was external in that era too, so stub it (no-op
#    toString(); stack traces are diagnostic only, never needed by the benchmark). --
if ! grep -rqlE 'class Exception[[:space:]]*:[[:space:]]*public[[:space:]]+Poco::Exception' dbms/include 2>/dev/null; then
    cat > contrib/statdaemons-compat/statdaemons/Exception.h <<'EOF'
#pragma once
// Vendored DB::Exception + StackTrace for pre-2015-11 trees (both lived in the
// never-public external statdaemons library). Interface matches the version
// 2015-12 inlined into DB/Common/Exception.h.
#include <string>
#include <cerrno>
#include <Poco/Exception.h>

/// Stub: real stack capture was in the external lib; only toString() is ever used
/// (for diagnostics), so an empty trace is sufficient for the benchmark.
class StackTrace
{
public:
    StackTrace() {}
    std::string toString() const { return {}; }
};

namespace DB
{

class Exception : public Poco::Exception
{
public:
    Exception(int code = 0) : Poco::Exception(code) {}
    Exception(const std::string & msg, int code = 0) : Poco::Exception(msg, code) {}
    Exception(const std::string & msg, const std::string & arg, int code = 0) : Poco::Exception(msg, arg, code) {}
    Exception(const std::string & msg, const Exception & exc, int code = 0) : Poco::Exception(msg, exc, code), trace(exc.trace) {}
    Exception(const Exception & exc) : Poco::Exception(exc), trace(exc.trace) {}
    explicit Exception(const Poco::Exception & exc) : Poco::Exception(exc.displayText()) {}
    ~Exception() throw() {}
    Exception & operator = (const Exception & exc) { Poco::Exception::operator=(exc); trace = exc.trace; return *this; }
    const char * name() const throw() { return "DB::Exception"; }
    const char * className() const throw() { return "DB::Exception"; }
    DB::Exception * clone() const { return new DB::Exception(*this); }
    void rethrow() const { throw *this; }
    void addMessage(const std::string & arg) { extendedMessage(arg); }
    const StackTrace & getStackTrace() const { return trace; }
private:
    StackTrace trace;
};

/// Carries a saved errno; thrown by throwFromErrno(). (Also external in this era.)
class ErrnoException : public Exception
{
public:
    ErrnoException(int code = 0, int saved_errno_ = 0) : Exception(code), saved_errno(saved_errno_) {}
    ErrnoException(const std::string & msg, int code = 0, int saved_errno_ = 0) : Exception(msg, code), saved_errno(saved_errno_) {}
    ErrnoException(const std::string & msg, const std::string & arg, int code = 0, int saved_errno_ = 0) : Exception(msg, arg, code), saved_errno(saved_errno_) {}
    ErrnoException(const std::string & msg, const Exception & exc, int code = 0, int saved_errno_ = 0) : Exception(msg, exc, code), saved_errno(saved_errno_) {}
    ErrnoException(const ErrnoException & exc) : Exception(exc), saved_errno(exc.saved_errno) {}
    int getErrno() const { return saved_errno; }
private:
    int saved_errno;
};

}
EOF
fi
# Some back-ported (newer) headers -- NetException.h, and the PATCH_FILL
# CounterInFile.h -- include <DB/Common/Exception.h>; before the class was inlined
# there (2015-12) Exception lived at DB/Core. Forward the DB/Common path to it (only
# when the tree has no real DB/Common/Exception.h). This is independent of where the
# Exception *class* is defined -- pre-2015-11 trees keep it in DB/Core whether or not
# they vendor it -- so it lives outside the vendor-Exception guard above.
if [ ! -e dbms/include/DB/Common/Exception.h ] && [ -e dbms/include/DB/Core/Exception.h ]; then
    mkdir -p dbms/include/DB/Common
    {
        printf '#pragma once\n#include <DB/Core/Exception.h>\n'
        # tryLogCurrentException(Poco::Logger *) overload was added after 2015-03;
        # the back-ported ErrorHandlers.h calls it. Provide it (forwarding to the era's
        # name-based overload) only when the tree already has some tryLogCurrentException
        # to forward to but lacks the Poco::Logger* variant. The oldest snapshots
        # (pre-2014) have no tryLogCurrentException at all -- adding the overload there
        # would make its body call a non-existent function and recurse onto itself, and
        # nothing needs it anyway (they have no ErrorHandlers.h).
        if grep -q 'tryLogCurrentException' dbms/include/DB/Core/Exception.h 2>/dev/null \
           && ! grep -q 'tryLogCurrentException(Poco::Logger' dbms/include/DB/Core/Exception.h 2>/dev/null; then
            printf '#include <Poco/Logger.h>\n'
            printf 'namespace DB { inline void tryLogCurrentException(Poco::Logger * logger, const std::string & = "") { tryLogCurrentException(logger ? logger->name().c_str() : ""); } }\n'
        fi
    } > dbms/include/DB/Common/Exception.h
fi
# The back-ported SummingSortedBlockInputStream.h includes <DB/Core/FieldVisitors.h>;
# before that split the Field visitors (FieldVisitorSum etc.) lived in DB/Core/Field.h.
# Forward the newer path to Field.h when the split-out header is absent.
if [ ! -e dbms/include/DB/Core/FieldVisitors.h ] && [ -e dbms/include/DB/Core/Field.h ]; then
    printf '#pragma once\n#include <DB/Core/Field.h>\n' > dbms/include/DB/Core/FieldVisitors.h
fi

# -- PoolWithFailoverBase (pre-2015-07): the failover connection-pool base lived in
#    the never-public external statdaemons library and took TWO template args
#    <TNestedPool, TSettings>. It was reworked into a single-arg in-repo class in
#    2015-07; the back-ported (PATCH_FILL) 1-arg version is incompatible with this
#    era's ConnectionPoolWithFailover (wrong arity, needs Settings::skip_unavailable_shards).
#    Only ConnectionPoolWithFailover derives from it, and the single-node benchmark
#    never configures remote_servers, so the pool is never even constructed. Vendor a
#    minimal 2-arg base exposing just the surface the derived class uses (ctor,
#    nested_pools[].pool/.state.priority, get/getMany/tryGet); get/getMany simply
#    throw. Created before the auto-map so it wins over the 1-arg forward, which means
#    the incompatible filled base is never included. Guarded on the 2-arg form, so it
#    is skipped on 2015-07+ (their 1-arg ConnectionPoolWithFailover uses the fill). --
if [ -f dbms/include/DB/Client/ConnectionPoolWithFailover.h ] \
   && grep -qE 'PoolWithFailoverBase<[^,>]+,' dbms/include/DB/Client/ConnectionPoolWithFailover.h; then
    cat > contrib/statdaemons-compat/statdaemons/PoolWithFailoverBase.h <<'EOF'
#pragma once
// Vendored 2-argument PoolWithFailoverBase for pre-2015-07 trees (the failover pool
// base was external then). Distributed connections are never opened by the
// single-node benchmark, so this only needs to compile and expose the small surface
// ConnectionPoolWithFailover uses; get()/getMany() throw if ever called.
#include <vector>
#include <sstream>
#include <cstddef>
#include <ctime>
#include <Poco/SharedPtr.h>
#include <Poco/Logger.h>
#include <Poco/Exception.h>

template <typename TNestedPool, typename TSettings>
class PoolWithFailoverBase
{
public:
    using NestedPool = TNestedPool;
    using NestedPoolPtr = Poco::SharedPtr<TNestedPool>;
    using Entry = typename TNestedPool::Entry;

    // The element carries priority both directly (.priority, ~2015-03 era) and nested
    // (.state.priority, ~2015-06 era) so either era's ConnectionPoolWithFailover
    // compiles. get()/getMany() throw, so the value is never actually consulted.
    struct PoolState { std::size_t priority = 0; };
    struct PoolWithState { NestedPoolPtr pool; PoolState state; std::size_t priority = 0; };
    using NestedPools = std::vector<NestedPoolPtr>;

    PoolWithFailoverBase(NestedPools & nested_pools_, std::size_t max_tries_,
        time_t decrease_error_period_, Poco::Logger * log_)
        : max_tries(max_tries_), decrease_error_period(decrease_error_period_), log(log_)
    {
        nested_pools.reserve(nested_pools_.size());
        for (const auto & p : nested_pools_)
        {
            PoolWithState pws;
            pws.pool = p;
            nested_pools.push_back(pws);
        }
    }
    virtual ~PoolWithFailoverBase() {}

    Entry get(TSettings)
    {
        throw Poco::Exception("Distributed connection pool is not available in this reconstructed build");
    }
    std::vector<Entry> getMany(TSettings)
    {
        throw Poco::Exception("Distributed connection pool is not available in this reconstructed build");
    }

protected:
    virtual bool tryGet(NestedPoolPtr pool, TSettings settings, Entry & out_entry,
        std::stringstream & fail_message) = 0;

    std::vector<PoolWithState> nested_pools;
    std::size_t max_tries;
    time_t decrease_error_period;
    Poco::Logger * log;
};
EOF
fi
# Auto-map every donor header of the same basename to the old <statdaemons/X.h>
# path: the statdaemons library's contents were dispersed into DB/Common/,
# common/ and DB/Dictionaries/Embedded/ (e.g. Exception.h -> DB/Common/Exception.h,
# RegionsHierarchies.h -> Embedded/). First match wins (DB/Common preferred).
# (DB/Core is scanned last so the newer DB/Common location wins when both exist:
#  in the oldest trees Exception.h/etc. still lived under DB/Core, not DB/Common.)
for pair in "dbms/include/DB/Common:DB/Common" "libs/libcommon/include/common:common" "dbms/include/DB/Dictionaries/Embedded:DB/Dictionaries/Embedded" "dbms/include/DB/Core:DB/Core"; do
    dir="${pair%%:*}"; inc="${pair##*:}"; [ -d "$dir" ] || continue
    for h in "$dir"/*.h; do
        [ -f "$h" ] || continue; base="$(basename "$h")"
        w="contrib/statdaemons-compat/statdaemons/${base}"
        [ -e "$w" ] || printf '#pragma once\n#include <%s/%s>\n' "$inc" "$base" > "$w"
    done
done
if [ -f libs/libdaemon/include/daemon/BaseDaemon.h ]; then
    printf '#pragma once\n#include <daemon/BaseDaemon.h>\ntypedef BaseDaemon Daemon;\n' \
        > contrib/statdaemons-compat/statdaemons/daemon.h
    # Pre-2013-05 the daemon lived at <Yandex/daemon.h> (implemented by the era's own
    # libcommon/src/daemon.cpp against the never-public external Yandex/daemon.h). Map
    # that include to BaseDaemon too, and drop the obsolete daemon.cpp -- BaseDaemon
    # (libdaemon) is the daemon now, so the old implementation would only conflict.
    printf '#pragma once\n#include <daemon/BaseDaemon.h>\ntypedef BaseDaemon Daemon;\n' \
        > libs/libcommon/include/common/daemon.h
    rm -f libs/libcommon/src/daemon.cpp
    # The donor's BaseDaemon is newer and drags in evolved deps (zkutil/graphite)
    # the older tree lacks. Replace it with a thin no-op base carrying just the
    # API the early Server/TCPHandler use (Poco::Util::ServerApplication plus
    # isCancelled/writeToGraphite/getGraphiteWriter, and the Application
    # using-decl the old daemon.h exposed). Metrics/cancellation become no-ops,
    # which is fine for the benchmark.
    cat > libs/libdaemon/include/daemon/GraphiteWriter.h <<'EOF'
#pragma once
#include <string>
#include <vector>
#include <utility>
#include <ctime>
class GraphiteWriter
{
public:
    template <typename T> using KeyValuePair = std::pair<std::string, T>;
    template <typename T> using KeyValueVector = std::vector<KeyValuePair<T>>;
    template <typename T> void write(const std::string &, const T &, time_t = 0, const std::string & = "") {}
    template <typename T> void write(const KeyValueVector<T> &, time_t = 0, const std::string & = "") {}
};
EOF
    cat > libs/libdaemon/include/daemon/BaseDaemon.h <<'EOF'
#pragma once
#include <Poco/Util/ServerApplication.h>
#include <Poco/Util/Option.h>
#include <Poco/Util/OptionSet.h>
#include <daemon/GraphiteWriter.h>
#include <memory>
#include <string>
#include <ctime>
#include <thread>
#include <chrono>
using Poco::Util::Application;
class BaseDaemon : public Poco::Util::ServerApplication
{
public:
    bool isCancelled() { return is_cancelled; }
    static BaseDaemon & instance() { return dynamic_cast<BaseDaemon &>(Poco::Util::Application::instance()); }
    // The real daemon's sleep() woke early on shutdown; a plain sleep is fine here
    // (used only for retry backoff, e.g. mysqlxx connection-pool reconnects).
    void sleep(double seconds) { std::this_thread::sleep_for(std::chrono::duration<double>(seconds)); }
    template <typename T> void writeToGraphite(const std::string & key, const T & value, time_t timestamp = 0, const std::string & custom_root_path = "") { if (graphite_writer) graphite_writer->write(key, value, timestamp, custom_root_path); }
    template <typename T> void writeToGraphite(const GraphiteWriter::KeyValueVector<T> & key_vals, time_t timestamp = 0, const std::string & custom_root_path = "") { if (graphite_writer) graphite_writer->write(key_vals, timestamp, custom_root_path); }
    GraphiteWriter * getGraphiteWriter() { return graphite_writer.get(); }
protected:
    // The real daemon registered --config-file and loaded it; replicate that so
    // the server accepts the entrypoint's --config-file and reads its config.
    void defineOptions(Poco::Util::OptionSet & options) override
    {
        Poco::Util::ServerApplication::defineOptions(options);
        options.addOption(Poco::Util::Option("config-file", "C", "config file").required(false)
            .repeatable(false).argument("<file>").binding("config-file"));
    }
    void initialize(Poco::Util::Application & self) override
    {
        if (config().hasProperty("config-file"))
            loadConfiguration(config().getString("config-file"));
        Poco::Util::ServerApplication::initialize(self);
    }
    bool is_cancelled = false;
    std::unique_ptr<GraphiteWriter> graphite_writer;
};
EOF
    rm -f libs/libdaemon/src/*.cpp
    printf '// minimal daemon base (see reconstruct.sh)\n' > libs/libdaemon/src/BaseDaemon.cpp
fi
# statdaemons/Interests.h: the never-public header of interest-category bit flags that
# the pre-2014 legacy OLAP handler (dbms/src/Server/OLAPAttributesMetadata.h) masks
# against. The OLAP HTTP interface is dead code for the benchmark, so the exact bit
# values are immaterial -- distinct flags are enough to compile. Unscoped enum at global
# scope so the enumerators are visible unqualified, as the original was.
cat > contrib/statdaemons-compat/statdaemons/Interests.h <<'EOF'
#pragma once
enum Interests
{
    PHOTO = 1 << 0, MOVIE_PREMIERES = 1 << 1, TOURISM = 1 << 2, FAMILY_AND_CHILDREN = 1 << 3,
    FINANCE = 1 << 4, B2B = 1 << 5, CARS = 1 << 6, MOBILE_AND_INTERNET_COMMUNICATIONS = 1 << 7,
    BUILDING = 1 << 8, CULINARY = 1 << 9, ESTATE = 1 << 10, HEALTHY_LIFESTYLE = 1 << 11,
    LITERATURE = 1 << 12, SOFTWARE = 1 << 13
};
EOF
# CategoriesHierarchy: a Metrica embedded dictionary the donor dropped (so the
# auto-map can't forward it). The benchmark never loads category dictionaries, so a
# no-op stub with the small interface Dictionaries.h / FunctionsDictionaries.h use is
# enough (templated methods avoid depending on the era's integer typedefs). Created
# only if the auto-map didn't already forward a real one.
if [ ! -e contrib/statdaemons-compat/statdaemons/CategoriesHierarchy.h ]; then
    cat > contrib/statdaemons-compat/statdaemons/CategoriesHierarchy.h <<'EOF'
#pragma once
/// Stub for the never-vendored Metrica category hierarchy (unused by the benchmark).
class CategoriesHierarchy
{
public:
    CategoriesHierarchy() {}
    void reload() {}
    template <typename T> T toParent(T x) const { return x; }
    template <typename T> T toMostAncestor(T x) const { return x; }
    template <typename T> T toSecondLevel(T x) const { return x; }
    template <typename T> bool in(T, T) const { return false; }
};
EOF
fi

# The auto-map above only handles <statdaemons/X.h>; the pre-2015-11 trees also
# pull <statdaemons/threadpool.hpp> and <statdaemons/ext/*.hpp> (.hpp / a subdir).
# By PATCH_REF these live in-tree as <common/threadpool.hpp> and <ext/*.hpp>
# (overlaid); forward the old paths to them.
[ -f libs/libcommon/include/common/threadpool.hpp ] && \
    printf '#pragma once\n#include <common/threadpool.hpp>\n' > contrib/statdaemons-compat/statdaemons/threadpool.hpp
if [ -d libs/libcommon/include/ext ]; then
    mkdir -p contrib/statdaemons-compat/statdaemons/ext
    for h in libs/libcommon/include/ext/*.hpp; do
        [ -f "$h" ] || continue; base="$(basename "$h")"
        printf '#pragma once\n#include <ext/%s>\n' "$base" > "contrib/statdaemons-compat/statdaemons/ext/${base}"
    done
fi
# ext/memory.hpp provided ext::make_unique before C++14's std::make_unique; the old
# statdaemons ext/ had it, the donor dropped it. Vendor it if not already forwarded.
if [ ! -e contrib/statdaemons-compat/statdaemons/ext/memory.hpp ]; then
    mkdir -p contrib/statdaemons-compat/statdaemons/ext
    cat > contrib/statdaemons-compat/statdaemons/ext/memory.hpp <<'EOF'
#pragma once
#include <memory>
#include <utility>
namespace ext
{
    template <typename T, typename... Args>
    std::unique_ptr<T> make_unique(Args &&... args) { return std::unique_ptr<T>(new T(std::forward<Args>(args)...)); }
}
EOF
fi
# statdaemons/stdext.h: the pre-2015 trees get make_unique from stdext::make_unique
# (the earlier name for ext::make_unique). Vendor the same thin make_unique.
if [ ! -e contrib/statdaemons-compat/statdaemons/stdext.h ]; then
    cat > contrib/statdaemons-compat/statdaemons/stdext.h <<'EOF'
#pragma once
#include <memory>
#include <utility>
namespace stdext
{
    template <typename T, typename... Args>
    std::unique_ptr<T> make_unique(Args &&... args) { return std::unique_ptr<T>(new T(std::forward<Args>(args)...)); }
}
EOF
fi

# -- Yandex/ -> common/: the old include prefix for the common utilities that the
#    donor renamed to common/ (e.g. <Yandex/Common.h> == <common/Common.h>).
#    Expose the donor's common headers under the old Yandex/ prefix. --
if [ -d libs/libcommon/include/common ]; then
    mkdir -p contrib/yandex-compat
    ln -sfn "$(pwd)/libs/libcommon/include/common" contrib/yandex-compat/Yandex
    # Yandex/Revision.h: the tiny public revision header, external in that era. The
    # in-tree libcommon/src/Revision.cpp defines Revision::get() (reading REVISION
    # from the generated revision.h); just declare it so the include resolves.
    [ -e libs/libcommon/include/common/Revision.h ] || \
        printf '#pragma once\nnamespace Revision { unsigned get(); }\n' > libs/libcommon/include/common/Revision.h
    # Yandex/optimization.h: the external header of branch-prediction macros (likely/
    # unlikely) that pre-2013 code (e.g. libpocoext/ThreadNumber.cpp) includes. The donor
    # moved these to common/likely.h, so provide optimization.h under the common/ prefix
    # (== the Yandex/ symlink). Guarded so it's a no-op where the header already exists.
    [ -e libs/libcommon/include/common/optimization.h ] || \
        printf '#pragma once\n#if !defined(likely)\n#define likely(x)   __builtin_expect(!!(x), 1)\n#endif\n#if !defined(unlikely)\n#define unlikely(x) __builtin_expect(!!(x), 0)\n#endif\n' \
            > libs/libcommon/include/common/optimization.h
    # LOG_* macros: the 2012 / early-2013 prototypes call them as block statements with
    # no trailing ';' (e.g. TCPHandler.cpp's connect log), which the donor's
    # do{...}while(0) form rejects ("expected ';' before '}'"). Convert do{...}while(0)
    # -> a plain {...} block so the trailing ';' becomes optional. Restrict this to those
    # old snapshots (commit date < 2013-01-01): from 2013-02 on the code writes the ';'
    # AND uses LOG in unbraced if/else (e.g. libzkutil Lock.cpp), where a bare block
    # breaks the dangling-else the do/while idiom guards against.
    # %ci (not %cs) -- the 14.04 image's git predates %cs (git 2.10) and would emit the
    # literal "%cs", which sorts before the threshold and would wrongly match every build.
    CH_COMMIT_DATE=$(git show -s --format=%ci HEAD 2>/dev/null | cut -d' ' -f1 || true)
    if [ -e libs/libcommon/include/common/logger_useful.h ] \
       && printf '%s' "${CH_COMMIT_DATE}" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' \
       && [ "${CH_COMMIT_DATE}" \< "2013-01-01" ]; then
        sed -i 's/ do {/ {/g; s/} while(0)/}/g; s/} while (0)/}/g' libs/libcommon/include/common/logger_useful.h
    fi
    # Yandex/time2str.h: external time helpers the donor folded into DateLUT. The only
    # ones used by compiled (non-Server, non-test) code are the MergeTree part-naming
    # helpers Date2OrderedIdentifier / OrderedIdentifier2Date; implement them via
    # DateLUT so they stay consistent with the DateLUT the callers use.
    if [ ! -e libs/libcommon/include/common/time2str.h ]; then
        cat > libs/libcommon/include/common/time2str.h <<'EOF'
#pragma once
#include <string>
#include <ctime>
#include <cstdlib>
#include <cstdio>
#include <common/DateLUT.h>
/// Helpers from the external Yandex/time2str.h, reimplemented via DateLUT so they
/// stay consistent with the DateLUT the callers use. Date2OrderedIdentifier /
/// OrderedIdentifier2Date drive MergeTree part naming (must be correct); Time2Date /
/// Date2Str are used only by the legacy OLAP server code.
inline unsigned Date2OrderedIdentifier(time_t time)
{
    return DateLUT::instance().toNumYYYYMMDD(time);
}
inline time_t OrderedIdentifier2Date(const std::string & str)
{
    return DateLUT::instance().YYYYMMDDToDate(static_cast<unsigned>(std::strtoul(str.c_str(), nullptr, 10)));
}
inline time_t Time2Date(time_t time)
{
    return DateLUT::instance().toDate(time);
}
inline std::string Date2Str(time_t date)
{
    const auto & lut = DateLUT::instance();
    char buf[16];
    std::snprintf(buf, sizeof(buf), "%04u-%02u-%02u", lut.toYear(date), lut.toMonth(date), lut.toDayOfMonth(date));
    return std::string(buf);
}
EOF
    fi
fi

# -- double-conversion: the old code includes <src/double-conversion.h>; the
#    donor's header is double-conversion/double-conversion.h (same namespace). --
if [ -f contrib/libdouble-conversion/double-conversion/double-conversion.h ]; then
    mkdir -p contrib/dc-compat/src
    printf '#pragma once\n#include <double-conversion/double-conversion.h>\n' > contrib/dc-compat/src/double-conversion.h
fi

# -- strconvert/escape.h: another never-public Yandex string-escaping header. The
#    only compiled use is MySQLDictionarySource's escaped_for_like (MySQL external
#    dictionaries -- never exercised by the benchmark); strconvert::hash appears only
#    in the OLAP server code, which is excluded from the build. Provide equivalents
#    (escaped_for_like is identity-safe for compile-only use). --
mkdir -p contrib/strconvert-compat/strconvert
cat > contrib/strconvert-compat/strconvert/escape.h <<'EOF'
#pragma once
#include <string>
#include <cstddef>
namespace strconvert
{
    // MySQL external dictionaries are unsupported in this reconstructed build, so
    // the escaping only needs to compile (this path is never executed).
    inline std::string escaped_for_like(const std::string & s) { return s; }
    inline std::size_t hash(const std::string & s) { std::size_t h = 0; for (char c : s) h = h * 131 + static_cast<unsigned char>(c); return h; }
}
EOF
# strconvert/hash64.h: used by the legacy OLAP server code (OLAPAttributesMetadata)
# to hash attribute names. A deterministic 64-bit hash (FNV-1a) suffices; the OLAP
# protocol is not exercised by the benchmark.
cat > contrib/strconvert-compat/strconvert/hash64.h <<'EOF'
#pragma once
#include <string>
#include <cstdint>
namespace strconvert
{
    inline std::uint64_t hash64(const std::string & s)
    {
        std::uint64_t h = 14695981039346656037ULL;
        for (char c : s) { h ^= static_cast<unsigned char>(c); h *= 1099511628211ULL; }
        return h;
    }
}
EOF

# -- jsonxx.h: pre-2014-10 FileChecker (Log-table sizes.json) used the third-party
#    jsonxx JSON library, later replaced by ClickHouse's own JSON. The benchmark uses
#    MergeTree, never Log/StripeLog/TinyLog, so FileChecker is never exercised. Provide
#    a compile-only stub: parse() is a no-op (empty map), so the getters never run. --
mkdir -p contrib/jsonxx-compat
cat > contrib/jsonxx-compat/jsonxx.h <<'EOF'
#pragma once
// Compile-only stub of the third-party jsonxx (see reconstruct.sh). FileChecker is
// the only user and is never exercised by the benchmark (MergeTree, not Log tables).
#include <string>
#include <map>
#include <istream>
namespace jsonxx
{
    enum Assortment { JSON = 0, JSONx = 1 };
    class Object;
    class Value
    {
    public:
        template <typename T> T & get() { static T v; return v; }
    };
    class Object
    {
    public:
        Object() {}
        Object(const std::string &, const std::string &) {}
        template <typename T> T get(const std::string &) const { return T(); }
        void import(const std::string &, const Object &) {}
        std::string write(unsigned = JSON) const { return "{}"; }
        const std::map<std::string, Value *> & kv_map() const { return values_; }
        bool parse(std::istream &) { return true; }
        bool parse(const std::string &) { return true; }
    private:
        std::map<std::string, Value *> values_;
    };
}
EOF

# -- zookeeper/zookeeper.hh: pre-2014-07 zkutil is built on the C++ ZooKeeper client
#    org::apache::zookeeper (a Yandex-internal package, never public; 2014-07 rewrote
#    zkutil onto the C client). The benchmark uses plain MergeTree, never Replicated /
#    ZooKeeper, so provide a compile-only stub of the C++ client API that zkutil and the
#    replication code reference (enums, data::{Id,ACL,Stat}, Watch, Op::{Create,Remove,
#    SetData}, OpResult, ZooKeeper). Methods return Ok / do nothing (never executed). --
mkdir -p contrib/zkcpp-stub/zookeeper
cat > contrib/zkcpp-stub/zookeeper/zookeeper.hh <<'EOF'
#pragma once
// Compile-only stub of the never-public org::apache::zookeeper C++ client (see
// reconstruct.sh). Replication/ZooKeeper is never exercised by the benchmark.
#include <string>
#include <vector>
#include <cstdint>
#include <boost/shared_ptr.hpp>
#include <boost/ptr_container/ptr_vector.hpp>

namespace org { namespace apache { namespace zookeeper {

namespace ReturnCode
{
    enum type { Ok = 0, NoNode, NodeExists, BadVersion, NotEmpty,
                NoChildrenForEphemerals, SessionExpired, ConnectionLoss, RuntimeInconsistency, Error };
    inline std::string toString(type) { return "ReturnCode"; }
}
namespace CreateMode
{
    enum type { Persistent = 0, Ephemeral = 1, PersistentSequential = 2, EphemeralSequential = 3 };
}
namespace SessionState
{
    enum type { Connecting = 0, Connected = 1, Expired = 2, AuthFailed = 3 };
    inline std::string toString(type) { return "SessionState"; }
}
namespace WatchEvent
{
    enum type { None = 0, NodeCreated, NodeDeleted, NodeDataChanged, NodeChildrenChanged };
    inline std::string toString(type) { return "WatchEvent"; }
}
namespace Permission
{
    enum type { Read = 1, Write = 2, Create = 4, Delete = 8, Admin = 16, All = 31 };
}

namespace data
{
    struct Id
    {
        std::string scheme, id;
        std::string & getscheme() { return scheme; }
        std::string & getid() { return id; }
    };
    struct ACL
    {
        Id id_; int perms = 0;
        Id & getid() { return id_; }
        void setperms(int p) { perms = p; }
        int getperms() const { return perms; }
    };
    struct Stat
    {
        int64_t czxid = 0, mzxid = 0, pzxid = 0, ctime = 0, mtime = 0, ephemeralOwner = 0;
        int32_t version = 0, cversion = 0, aversion = 0, dataLength = 0, numChildren = 0;
        int64_t getczxid() const { return czxid; }
        int32_t getversion() const { return version; }
        int32_t getcversion() const { return cversion; }
        int32_t getnumChildren() const { return numChildren; }
    };
}

struct Watch
{
    virtual ~Watch() {}
    virtual void process(WatchEvent::type, SessionState::type, const std::string &) = 0;
};

namespace OpCode { enum type { Create, Remove, SetData, Check }; }
struct Op
{
    virtual ~Op() {}
    virtual OpCode::type getType() const { return OpCode::Check; }
    struct Create; struct Remove; struct SetData; struct Check;
};
struct Op::Create : Op
{
    Create(const std::string &, const std::string &, const std::vector<data::ACL> &, CreateMode::type) {}
    OpCode::type getType() const { return OpCode::Create; }
};
struct Op::Remove : Op
{
    Remove(const std::string &, int32_t) {}
    OpCode::type getType() const { return OpCode::Remove; }
};
struct Op::SetData : Op
{
    SetData(const std::string &, const std::string &, int32_t) {}
    OpCode::type getType() const { return OpCode::SetData; }
};
struct Op::Check : Op
{
    Check(const std::string &, int32_t) {}
    OpCode::type getType() const { return OpCode::Check; }
};

struct OpResult
{
    virtual ~OpResult() {}   // polymorphic: consumers dynamic_cast to OpResult::Create
    ReturnCode::type getReturnCode() const { return ReturnCode::Ok; }
    std::string getPath() const { return {}; }
    struct Create; struct Remove; struct SetData; struct Check;
};
struct OpResult::Create : OpResult { std::string getPathCreated() const { return {}; } };
struct OpResult::Remove : OpResult {};
struct OpResult::SetData : OpResult {};
struct OpResult::Check : OpResult {};

class ZooKeeper
{
public:
    ReturnCode::type init(const std::string &, int32_t, boost::shared_ptr<Watch>) { return ReturnCode::Ok; }
    ReturnCode::type close() { return ReturnCode::Ok; }
    ReturnCode::type create(const std::string &, const std::string &, const std::vector<data::ACL> &, CreateMode::type, std::string &) { return ReturnCode::Ok; }
    ReturnCode::type remove(const std::string &, int32_t) { return ReturnCode::Ok; }
    ReturnCode::type exists(const std::string &, boost::shared_ptr<Watch>, data::Stat &) { return ReturnCode::Ok; }
    ReturnCode::type get(const std::string &, boost::shared_ptr<Watch>, std::string &, data::Stat &) { return ReturnCode::Ok; }
    ReturnCode::type getChildren(const std::string &, boost::shared_ptr<Watch>, std::vector<std::string> &, data::Stat &) { return ReturnCode::Ok; }
    ReturnCode::type set(const std::string &, const std::string &, int32_t, data::Stat &) { return ReturnCode::Ok; }
    ReturnCode::type multi(const boost::ptr_vector<Op> &, boost::ptr_vector<OpResult> &) { return ReturnCode::Ok; }
};

}}}
EOF

# -- stats/*: the pre-2015-12 trees include several headers from an external Yandex
#    "stats" library that was never open-sourced. At the 2015-11 -> 2015-12 boundary
#    these were inlined into the repo (a coordinated refactor). We reproduce that:
#      * stats/IntHash.h   -> the templated intHash32<salt>+IntHash32 functor, which
#        2015-12 moved into DB/Common/HashTable/Hash.h. Append them to the era's
#        own Hash.h (which lacks intHash32) so they are visible everywhere Hash.h is
#        included -- notably the overlaid UniquesHashSet -- and forward the old
#        <stats/IntHash.h> path there. (Appending, not a separate compat definition,
#        avoids a double-definition when both headers land in one TU.)
#      * stats/{UniquesHashSet,ReservoirSampler,ReservoirSamplerDeterministic}.h ->
#        the algorithms, overlaid in-tree from PATCH_REF and forwarded. --
mkdir -p contrib/stats-compat/stats
# intHash32<salt>/IntHash32 and intHashCRC32 lived in the external <stats/IntHash.h>
# before ~2015-12 (2015-12 moved them into Hash.h; intHashCRC32 arrived after 2014-12).
# When Hash.h lacks a definition, INSERT it right after the includes -- not appended at
# the end -- because Hash.h itself uses intHash32<0> early (in DefaultHash64), so the
# definition must precede the first use. Guard matches the definition `intHash32(`
# (the call `intHash32<0>(` does not), so trees that already define it are untouched.
python3 - <<'PYEOF'
import os, re
p = "dbms/include/DB/Common/HashTable/Hash.h"
if os.path.exists(p):
    s = open(p, encoding="utf-8", errors="surrogateescape").read()
    add = ""
    if "intHash32(" not in s:
        add += ("template <DB::UInt64 salt>\n"
                "inline DB::UInt32 intHash32(DB::UInt64 key)\n{\n"
                "\tkey ^= salt;\n"
                "\tkey = (~key) + (key << 18);\n"
                "\tkey = key ^ ((key >> 31) | (key << 33));\n"
                "\tkey = key * 21;\n"
                "\tkey = key ^ ((key >> 11) | (key << 53));\n"
                "\tkey = key + (key << 6);\n"
                "\tkey = key ^ ((key >> 22) | (key << 42));\n"
                "\treturn key;\n}\n"
                "template <typename T, DB::UInt64 salt = 0>\n"
                "struct IntHash32 { size_t operator() (const T & key) const { return intHash32<salt>(key); } };\n")
    if "intHashCRC32(" not in s:
        add += ("inline DB::UInt64 intHashCRC32(DB::UInt64 x)\n{\n"
                "\tDB::UInt64 crc = -1ULL;\n"
                "\tasm(\"crc32q %[x], %[crc]\\n\" : [crc] \"+r\" (crc) : [x] \"rm\" (x));\n"
                "\treturn crc;\n}\n")
    if add:
        # insert after <DB/Core/Types.h> (which defines UInt32/UInt64), else after the
        # last include in the top block.
        m = re.search(r'^#include\s*<DB/Core/Types\.h>[^\n]*\n', s, re.M)
        if not m:
            incs = list(re.finditer(r'^#include[^\n]*\n', s, re.M))
            pos = incs[-1].end() if incs else 0
        else:
            pos = m.end()
        s = s[:pos] + "\n// Added by reconstruct.sh: int hashes from the external <stats/IntHash.h>.\n" + add + "\n" + s[pos:]
        open(p, "w", encoding="utf-8", errors="surrogateescape").write(s)
PYEOF
# The oldest trees (pre-2014-12) have no DB/Common/HashTable/Hash.h at all -- their
# HashMap.h pulled intHash32 straight from the external <stats/IntHash.h>, and nothing
# in-tree defines it. Two consumers need it: that external path, and the back-ported
# (PATCH_FILL) UniquesHashSet.h, which includes <DB/Common/HashTable/Hash.h> +
# <DB/Common/HashTable/HashTableAllocator.h>. So when the subdir Hash.h is absent,
# CREATE it (the int-hash helpers the external stats library provided) and forward the
# subdir HashTableAllocator.h path to this era's flat DB/Common/HashTableAllocator.h
# (the subdir split came later; the flat header already has HashTableAllocator +
# HashTableAllocatorWithStackMemory). stats/IntHash.h then forwards to this one file, so
# there is a single intHash32 definition per TU regardless of era.
if [ ! -f dbms/include/DB/Common/HashTable/Hash.h ]; then
    mkdir -p dbms/include/DB/Common/HashTable
    cat > dbms/include/DB/Common/HashTable/Hash.h <<'IHEOF'
#pragma once
// Added by reconstruct.sh: the int-hash helpers pre-2014-12 pulled from the external
// stats library (this era has no in-tree HashTable/Hash.h). intHash32/IntHash32 are
// used by HashMap.h (via <stats/IntHash.h>) and intHash32/intHashCRC32 by the
// back-ported UniquesHashSet.h.
#include <DB/Core/Types.h>

template <DB::UInt64 salt>
inline DB::UInt32 intHash32(DB::UInt64 key)
{
	key ^= salt;
	key = (~key) + (key << 18);
	key = key ^ ((key >> 31) | (key << 33));
	key = key * 21;
	key = key ^ ((key >> 11) | (key << 53));
	key = key + (key << 6);
	key = key ^ ((key >> 22) | (key << 42));
	return key;
}

// The 2012 HashMap.h calls the older two-template-arg form intHash32<T, salt>(key);
// forward it to the salt-only form. (intHash32<0>(x) still binds the one above.)
template <typename T, DB::UInt64 salt>
inline DB::UInt32 intHash32(T key) { return intHash32<salt>(static_cast<DB::UInt64>(key)); }

template <typename T, DB::UInt64 salt = 0>
struct IntHash32 { size_t operator() (const T & key) const { return intHash32<salt>(key); } };

inline DB::UInt64 intHashCRC32(DB::UInt64 x)
{
	DB::UInt64 crc = -1ULL;
	asm("crc32q %[x], %[crc]\n" : [crc] "+r" (crc) : [x] "rm" (x));
	return crc;
}
IHEOF
    # The back-ported UniquesHashSet.h also needs <DB/Common/HashTable/HashTableAllocator.h>,
    # providing a global HashTableAllocatorWithStackMemory<N>. Two eras:
    if [ ! -e dbms/include/DB/Common/HashTable/HashTableAllocator.h ]; then
        if [ -e dbms/include/DB/Common/HashTableAllocator.h ]; then
            # 2014-03/04: the flat header exists but keeps the allocators in namespace
            # DB, while the (global) back-ported UniquesHashSet refers to
            # HashTableAllocatorWithStackMemory unqualified -- later eras exposed it as a
            # global alias. Forward to the flat header and hoist both to global scope.
            {
                printf '#pragma once\n#include <DB/Common/HashTableAllocator.h>\n'
                printf 'using DB::HashTableAllocator;\nusing DB::HashTableAllocatorWithStackMemory;\n'
            } > dbms/include/DB/Common/HashTable/HashTableAllocator.h
        else
            # 2014-02 and older: no HashTableAllocator exists anywhere (uniq() used the
            # external stats library's own allocation). Provide a self-contained,
            # malloc-backed global allocator exposing exactly the surface the
            # back-ported UniquesHashSet uses (alloc/free/realloc). We skip the
            # small-object stack optimization the real one had -- it changes only
            # performance, not results, which is immaterial for uniq() correctness.
            cat > dbms/include/DB/Common/HashTable/HashTableAllocator.h <<'HAEOF'
#pragma once
// Added by reconstruct.sh: minimal malloc-backed HashTableAllocator for pre-2014-03
// trees that ship no allocator at all, matching the surface the back-ported
// UniquesHashSet.h uses. Global scope (UniquesHashSet refers to it unqualified).
#include <cstdlib>
#include <cstring>

class HashTableAllocator
{
public:
	void * alloc(size_t size) { return ::calloc(size, 1); }
	void free(void * buf, size_t) { ::free(buf); }
	void * realloc(void * buf, size_t old_size, size_t new_size)
	{
		buf = ::realloc(buf, new_size);
		if (new_size > old_size)
			memset(reinterpret_cast<char *>(buf) + old_size, 0, new_size - old_size);
		return buf;
	}
};

template <size_t N = 64>
class HashTableAllocatorWithStackMemory : public HashTableAllocator {};
HAEOF
        fi
    fi
fi
printf '#pragma once\n#include <DB/Common/HashTable/Hash.h>\n' > contrib/stats-compat/stats/IntHash.h

# The overlaid 2015-12 ReservoirSampler{,Deterministic}.h back a small sample buffer
# with DB::PODArray<T, N, AllocatorWithStackMemory<Allocator<false>, N>> -- but
# 2015-11's Allocator is a non-template class and lacks AllocatorWithStackMemory, and
# back-porting the templated allocator would ripple through every container. The
# buffer only ever needs push_back / [] / size / resize / begin / end / clear / swap,
# so retarget it to std::vector (the first PODArray template arg is the element type).
# quantile() is unused by the benchmark, so exact reservoir behaviour is immaterial.
for f in dbms/include/DB/AggregateFunctions/ReservoirSampler.h \
         dbms/include/DB/AggregateFunctions/ReservoirSamplerDeterministic.h; do
    [ -f "$f" ] || continue
    sed -i 's#include <DB/Common/PODArray.h>#include <vector>#' "$f"
    sed -i 's#using Array = DB::PODArray<\([^,]*\),[^;]*>;#using Array = std::vector<\1>;#' "$f"
done

# Forward the old <stats/...> algorithm paths to the overlaid in-tree headers.
for base in ReservoirSampler ReservoirSamplerDeterministic UniquesHashSet; do
    if [ -f "dbms/include/DB/AggregateFunctions/${base}.h" ]; then
        printf '#pragma once\n#include <DB/AggregateFunctions/%s.h>\n' "$base" \
            > "contrib/stats-compat/stats/${base}.h"
    fi
done

# -- VarInt narrow read overloads: pre-2012-07 VarInt.h declared readVarUInt only for
#    UInt64, but the back-ported UniquesHashSet reads its UInt32 size fields directly
#    (readVarUInt(UInt32&, ...)). Add the narrow *read* overloads (forwarding through a
#    UInt64) inside namespace DB when absent. Only the read side is needed: a UInt32 *write*
#    argument already widens uniquely to writeVarUInt(UInt64), whereas adding narrow write
#    overloads would make int/enum callers (Connection.cpp) ambiguous. A no-op on the donor
#    and every later era, which already declare the UInt32/UInt16 read overloads. --
python3 - <<'PYEOF'
p = 'dbms/include/DB/IO/VarInt.h'
import os
if os.path.exists(p):
    with open(p, encoding='utf-8', errors='surrogateescape') as f:
        s = f.read()
    if 'readVarUInt(UInt32' not in s:
        anchor = 'void readVarUInt(UInt64 & x, ReadBuffer & istr);'
        add = (anchor + '\n'
               '/// Narrow read overloads (reconstruct shim): forward through UInt64.\n'
               'inline void readVarUInt(UInt32 & x, ReadBuffer & istr) { UInt64 t = 0; readVarUInt(t, istr); x = static_cast<UInt32>(t); }\n'
               'inline void readVarUInt(UInt16 & x, ReadBuffer & istr) { UInt64 t = 0; readVarUInt(t, istr); x = static_cast<UInt16>(t); }\n')
        if anchor in s:
            s = s.replace(anchor, add, 1)
            with open(p, 'w', encoding='utf-8', errors='surrogateescape') as f:
                f.write(s)
PYEOF

# -- generate the re2_st (single-threaded re2) headers into a stable include dir --
mkdir -p contrib/re2_st_gen
( cd contrib/re2_st_gen && sh /src/contrib/libre2/create_st_headers.sh /src/contrib/libre2 . )


# -- MongoDB dictionary: throwing stub (legacy mongoclient driver not vendored) --
cat > dbms/include/DB/Dictionaries/MongoDBBlockInputStream.h <<'EOF'
#pragma once
// Stub: MongoDB support removed (legacy mongoclient driver not vendored).
EOF
cat > dbms/include/DB/Dictionaries/MongoDBDictionarySource.h <<'EOF'
#pragma once
#include <DB/Dictionaries/IDictionarySource.h>
#include <DB/Common/Exception.h>
#include <Poco/Util/AbstractConfiguration.h>
#include <string>
#include <vector>
namespace DB
{
struct DictionaryStructure;
class Block;
class Context;
// MongoDB dictionary support is disabled in this reconstructed build; requesting
// a mongodb dictionary source throws. Never exercised by the benchmark.
class MongoDBDictionarySource final : public IDictionarySource
{
public:
    MongoDBDictionarySource(const DictionaryStructure &, const Poco::Util::AbstractConfiguration &,
        const std::string &, Block &, Context &)
    { throw Exception("MongoDB dictionary source is not supported in this build", 0); }
    // No `override` on these: the exact IDictionarySource virtuals vary across the
    // era (e.g. loadKeys did not exist before ~2015-12). Omitting the keyword makes
    // each an implicit override where the matching virtual exists and a harmless
    // extra method where it doesn't, so the stub is concrete for every snapshot.
    BlockInputStreamPtr loadAll() { throw Exception("MongoDB not supported", 0); }
    bool supportsSelectiveLoad() const { return false; }
    BlockInputStreamPtr loadIds(const std::vector<std::uint64_t> &) { throw Exception("MongoDB not supported", 0); }
    BlockInputStreamPtr loadKeys(const ConstColumnPlainPtrs &, const std::vector<std::size_t> &) { throw Exception("MongoDB not supported", 0); }
    bool isModified() const { return false; }
    DictionarySourcePtr clone() const { throw Exception("MongoDB not supported", 0); }
    std::string toString() const { return "MongoDB(disabled)"; }
};
}
EOF

# -- member-template virt-specifiers: the early trees mark templated member
#    functions with `override`/`final` (e.g. `template <typename T> bool
#    execute(...) override` in FunctionsMiscellaneous.h). A member template can
#    never be virtual, so this is ill-formed; the era's compiler accepted it but
#    gcc-5 rejects it ("member template ... may not have virt-specifiers"). Strip
#    the trailing specifier from any method whose immediately-preceding non-blank
#    line opens a `template<...>` declaration. --
python3 - <<'PYEOF'
import os, re
# ") ... override|final" at end of a declaration line (body brace on next line)
spec = re.compile(r'\)\s*(?:const\s*)?(?:override|final)(?:\s+(?:override|final))?\s*$')
tmpl = re.compile(r'^\s*template\s*<')
for root, _dirs, files in os.walk('dbms'):
    for fn in files:
        if not fn.endswith(('.h', '.hpp', '.cpp')):
            continue
        p = os.path.join(root, fn)
        try:
            with open(p, encoding='utf-8', errors='surrogateescape') as f:
                lines = f.readlines()
        except OSError:
            continue
        changed = False
        prev_nonblank = ''
        for i, ln in enumerate(lines):
            if spec.search(ln) and tmpl.match(prev_nonblank):
                # drop just the virt-specifier keyword(s), keep the rest verbatim
                lines[i] = re.sub(r'\s*(?:override|final)(?:\s+(?:override|final))?\s*$', '\n', ln)
                changed = True
            if ln.strip():
                prev_nonblank = ln
        if changed:
            with open(p, 'w', encoding='utf-8', errors='surrogateescape') as f:
                f.writelines(lines)
PYEOF

# -- ConnectionPoolWithFailover: the external (pre-2015-11) PoolWithFailoverBase
#    exposed a 1-arg virtual getMany(settings); the back-ported base has a 2-arg
#    getMany(settings, get_all) (non-virtual). Adapt the derived client's override
#    so it compiles against the newer base. This is distributed-query plumbing the
#    single-node benchmark never exercises, so only compilation matters. --
CPF=dbms/include/DB/Client/ConnectionPoolWithFailover.h
if [ -f "$CPF" ] && grep -q 'getMany(const Settings \* settings = nullptr) override' "$CPF"; then
    sed -i 's#getMany(const Settings \* settings = nullptr) override#getMany(const Settings * settings = nullptr, bool get_all = false)#' "$CPF"
    sed -i 's#return Base::getMany(settings);#return Base::getMany(settings, get_all);#' "$CPF"
fi

# -- ErrorCodes::NO_AVAILABLE_DATA: the back-ported CompactArray/HyperLogLog throw
#    with this code, added to the enum only after 2015-08. Append it (with a free
#    number) to the era's enum when absent, so those overlaid headers compile. --
EC=dbms/include/DB/Core/ErrorCodes.h
if [ -f "$EC" ] && ! grep -q 'NO_AVAILABLE_DATA' "$EC"; then
    python3 - "$EC" <<'PYEOF'
import sys, re
p = sys.argv[1]
s = open(p, encoding='utf-8', errors='surrogateescape').read()
m = re.search(r'enum ErrorCodes\s*\{', s)
if m:
    end = s.index('};', m.end())
    nums = [int(n) for n in re.findall(r'=\s*(\d+)', s[m.end():end])]
    s = s[:end] + ('\t\tNO_AVAILABLE_DATA = %d,\n\t' % ((max(nums) + 1) if nums else 10000)) + s[end:]
    open(p, 'w', encoding='utf-8', errors='surrogateescape').write(s)
PYEOF
fi

# -- ALWAYS_INLINE macro: used by the back-ported CompactArray (which includes
#    DB/Core/Defines.h); added to Defines.h after 2014-10. Append it when absent. --
DEF=dbms/include/DB/Core/Defines.h
if [ -f "$DEF" ] && ! grep -q 'ALWAYS_INLINE' "$DEF"; then
    printf '\n#ifndef ALWAYS_INLINE\n#define ALWAYS_INLINE __attribute__((__always_inline__))\n#endif\n' >> "$DEF"
fi

# -- IPv4 listen: pre-2014-12 Server.cpp hardcodes Poco SocketAddress("[::]:<port>")
#    (the IPv6 wildcard), which fails with EAI_ADDRFAMILY on an IPv6-disabled host, so
#    the server exits on boot ("DNS error: EAI: -9"). Rewrite to 0.0.0.0 so it listens
#    on IPv4 (the benchmark connects over 127.0.0.1). 2014-12+ take the listen host
#    from config, so this is a no-op there. --
SRV=dbms/src/Server/Server.cpp
[ -f "$SRV" ] && sed -i 's#\[::\]:#0.0.0.0:#g' "$SRV"

# -- init.d / logrotate INCLUDEs: the donor Server/CMakeLists.txt INCLUDEs the cmake
#    fragments tools/init.d/CMakeLists.init and tools/logrotate/CMakeLists.logrotate.
#    Those are neither CMakeLists.txt nor .cmake, so the overlay doesn't bring them, and
#    the oldest trees don't ship them at all -- cmake then fails ("include could not
#    find load file"). They only add init.d/logrotate packaging, irrelevant to building
#    the server binary, so drop the INCLUDE lines when the fragment is absent. No-op on
#    trees that do ship the fragments. --
SRV_CML=dbms/src/Server/CMakeLists.txt
if [ -f "$SRV_CML" ]; then
    [ -f tools/init.d/CMakeLists.init ] || sed -i '/INCLUDE[[:space:]]*(.*tools\/init\.d\/CMakeLists\.init)/d' "$SRV_CML"
    [ -f tools/logrotate/CMakeLists.logrotate ] || sed -i '/INCLUDE[[:space:]]*(.*tools\/logrotate\/CMakeLists\.logrotate)/d' "$SRV_CML"
fi

# -- Poco/Ext/scopedTry.h (pre-2013-05): StorageMergeTree uses Poco::ScopedTry<FastMutex>
#    (a scoped try-lock) from this never-public libpocoext header. It was dropped later,
#    so provide it when absent: default-constructed, lock(&mutex) tries and returns
#    whether it acquired, destructor releases if held -- exactly the surface the caller
#    (clearOldParts) uses. --
SCT=libs/libpocoext/include/Poco/Ext/scopedTry.h
if [ -d libs/libpocoext/include/Poco/Ext ] && [ ! -e "$SCT" ]; then
    cat > "$SCT" <<'EOF'
#pragma once
namespace Poco
{
    template <typename M>
    class ScopedTry
    {
    public:
        ScopedTry() : m(0) {}
        ~ScopedTry() { if (m) m->unlock(); }
        bool lock(M * mutex) { if (mutex && mutex->tryLock()) { m = mutex; return true; } return false; }
    private:
        M * m;
    };
}
EOF
fi

# -- mysqlxx/PoolWithFailover.h (pre-2013-05): the back-ported Embedded dictionaries
#    (TechDataHierarchy/RegionsHierarchy) include it, but this era's mysqlxx only has
#    Pool.h (the failover pool came in 2013-05). Provide a thin wrapper over mysqlxx::Pool
#    exposing the surface those dicts use (ctor from a config key, Entry, Get()). MySQL
#    dictionaries are never loaded by the benchmark, so it only needs to compile/link. --
MPF=libs/libmysqlxx/include/mysqlxx/PoolWithFailover.h
if [ -e libs/libmysqlxx/include/mysqlxx/Pool.h ] && [ ! -e "$MPF" ]; then
    cat > "$MPF" <<'EOF'
#pragma once
#include "Pool.h"
namespace mysqlxx
{
    class PoolWithFailover
    {
    public:
        typedef Pool::Entry Entry;
        PoolWithFailover(const std::string & config_name, unsigned = 1, unsigned = 3) : pool(config_name) {}
        Entry Get() { return pool.Get(); }
    private:
        Pool pool;
    };
}
EOF
fi

# -- Poco::FileOutputStream: pre-2014-07 InterpreterAlterQuery uses it without
#    including <Poco/FileStream.h> (it came in transitively then, not with the donor
#    Poco). Add the include when the file references it but lacks the include. --
IAQ=dbms/src/Interpreters/InterpreterAlterQuery.cpp
[ -f "$IAQ" ] && grep -q 'Poco::FileOutputStream' "$IAQ" && ! grep -q 'Poco/FileStream.h' "$IAQ" \
    && sed -i '1i #include <Poco/FileStream.h>' "$IAQ"

# -- Poco::Timestamp: pre-2013 IProfilingBlockInputStream.cpp uses Poco::Timestamp::
#    TimeDiff without including <Poco/Timestamp.h> (transitive then). Add it when the
#    file references Poco::Timestamp but lacks the include. --
IPBIS=dbms/src/DataStreams/IProfilingBlockInputStream.cpp
[ -f "$IPBIS" ] && grep -q 'Poco::Timestamp' "$IPBIS" && ! grep -q 'Poco/Timestamp.h' "$IPBIS" \
    && sed -i '1i #include <Poco/Timestamp.h>' "$IPBIS"

# -- uniq on Float32/Float64 (pre-2015-09): AggregateFunctionUniq{HLL12,Combined}Data
#    typedef their HyperLogLog / CombinedCardinalityEstimator Set over the raw column
#    type T, so uniq(Float) instantiates the HLL on `float`. But OneAdder inserts the
#    *hashed* value (AggregateFunctionUniqTraits<T>::hash -> UInt64), and the
#    back-ported HLL bit-shifts its value type (can't be float). Add Float32/Float64
#    data specializations that use a UInt64 Set (exactly as the existing <String>
#    specialization does) -- the HLL is then only ever built on UInt64, which both
#    compiles and is correct (2015-09+ restructured the code the same way). --
AFU=dbms/include/DB/AggregateFunctions/AggregateFunctionUniq.h
# Pre-2014-06 used UniquesHashSet as a plain (non-template) type, both as `typedef
# UniquesHashSet Set;` and as a bare local like `UniquesHashSet tmp_set;`. The
# back-ported UniquesHashSet is a template with a default Hash, so any bare use needs
# <>. Rewrite "UniquesHashSet <identifier>;" -> "UniquesHashSet<> <identifier>;" (this
# also covers the typedef); the <stats/UniquesHashSet.h> include and the longer
# ...UniquesHashSetData identifiers are not followed by whitespace, so they are left
# alone. No-op once UniquesHashSet is always used with explicit arguments.
[ -f "$AFU" ] && sed -i -E 's#UniquesHashSet[[:space:]]+([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*;#UniquesHashSet<> \1;#g' "$AFU"
if [ -f "$AFU" ] && grep -q 'AggregateFunctionUniqHLL12Data<String>' "$AFU" \
   && ! grep -q 'AggregateFunctionUniqHLL12Data<Float32>' "$AFU"; then
    python3 - "$AFU" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8', errors='surrogateescape').read()
def add_after_string_spec(s, base, body):
    key = 'struct %s<String>' % base
    if key not in s:
        return s
    j = s.index('};', s.index(key)) + 2                 # end of the <String> specialization
    return s[:j] + body + s[j:]
hll = ''.join('\n\ntemplate <>\nstruct AggregateFunctionUniqHLL12Data<%s>\n{\n'
              '\ttypedef HyperLogLogWithSmallSetOptimization<UInt64, 16, 12> Set;\n\tSet set;\n'
              '\tstatic String getName() { return "uniqHLL12"; }\n};' % t for t in ('Float32', 'Float64'))
comb = ''.join('\n\ntemplate <>\nstruct AggregateFunctionUniqCombinedData<%s>\n{\n'
               '\tusing Key = UInt64;\n\tusing Set = CombinedCardinalityEstimator<Key, HashSet<Key, DefaultHash<Key>, HashTableGrower<4> >, 16, 16, 19>;\n\tSet set;\n'
               '\tstatic String getName() { return "uniqCombined"; }\n};' % t for t in ('Float32', 'Float64'))
s = add_after_string_spec(s, 'AggregateFunctionUniqHLL12Data', hll)
s = add_after_string_spec(s, 'AggregateFunctionUniqCombinedData', comb)
open(p, 'w', encoding='utf-8', errors='surrogateescape').write(s)
PYEOF
fi

# -- std::tr1 -> std (pre-2014-02): the oldest snapshots use the pre-C++11 TR1
#    namespace (std::tr1::unordered_set/map) and <tr1/...> include paths, which a
#    modern gcc-5 in -std=gnu++1y mode no longer provides. Rewrite both to their C++11
#    forms. Guarded by grep, so it's a no-op on trees that already use std:: directly. --
grep -rlZ 'tr1' dbms libs 2>/dev/null | while IFS= read -r -d '' f; do
    sed -i 's#<tr1/\([a-z_]*\)>#<\1>#g; s#std::tr1::#std::#g' "$f"
done

# -- StoragePtr::operator bool (pre-2013-12): the old smart-pointer wrapper's
#    `operator bool() const { return ptr; }` relied on boost::shared_ptr's implicit
#    safe-bool conversion, but trusty's boost makes operator bool explicit, so the
#    implicit conversion in the return fails. Make it explicit. Guarded on the file +
#    exact return, so it's a no-op once StoragePtr was replaced by std::shared_ptr. --
SP=dbms/include/DB/Storages/StoragePtr.h
[ -f "$SP" ] && sed -i 's#^\(\s*\)return ptr;#\1return static_cast<bool>(ptr);#' "$SP"

# -- HyperLogLog counter template arg order: pre-2015-09
#    HyperLogLogWithSmallSetOptimization instantiates the counter as
#    HyperLogLogCounter<K, Hash, DenominatorType> (old 3-arg form). The back-ported
#    (PATCH_REF) counter inserted a HashValueType 3rd parameter, so the old call puts
#    DenominatorType (float) in the HashValueType slot -> the counter bit-shifts a
#    float and won't compile. Insert the UInt32 HashValueType (the IntHash32 result
#    type), matching 2015-09+. CombinedCardinalityEstimator reaches the counter
#    through SmallSetOptimization, so this single fix covers both. The sed only
#    matches the old 3-arg form, so it's a no-op on trees that already pass 4 args. --
SSO=dbms/include/DB/Common/HyperLogLogWithSmallSetOptimization.h
[ -f "$SSO" ] && sed -i 's#HyperLogLogCounter<K, Hash, DenominatorType>#HyperLogLogCounter<K, Hash, UInt32, DenominatorType>#' "$SSO"

# -- DateLUT API migration (pre-2015-08): the monolithic calendar class DateLUT was
#    split into DateLUT (a singleton whose instance() returns `const DateLUTImpl &`)
#    and DateLUTImpl (the calendar, carrying the `Values` struct). The donor supplies
#    that split (and its DateLUT.cpp/DateLUTImpl.cpp overwrite the era's old ones), so
#    migrate the era's consumers exactly as 2015-08 did:
#      * `DateLUT & x = DateLUT::instance(...)`  ->  `const auto & x = DateLUT::instance(...)`
#        (the returned reference is now `const DateLUTImpl &`), and
#      * `DateLUT::Values`                       ->  `DateLUTImpl::Values`.
#    `DateLUT::instance().<method>()` already works (it returns a DateLUTImpl). A no-op
#    on trees already migrated (2015-08+), which have neither pattern. --
python3 - <<'PYEOF'
import os, re
# `DateLUT & x = DateLUT::instance(...)` -> `const auto & x = ...` (the reference is
# now const, so `const auto &` is required; a bare `DateLUTImpl &` would fail const).
ref = re.compile(r'(?:const\s+)?DateLUT\s*&\s*([A-Za-z_]\w*)\s*=\s*DateLUT::instance\(([^)]*)\)')
for base in ('dbms', 'libs'):
    for root, _dirs, files in os.walk(base):
        for fn in files:
            if not fn.endswith(('.h', '.hpp', '.cpp', '.inl')):
                continue
            if fn.startswith('DateLUT'):          # don't rewrite the headers that DEFINE the classes
                continue
            p = os.path.join(root, fn)
            try:
                with open(p, encoding='utf-8', errors='surrogateescape') as f:
                    s = f.read()
            except OSError:
                continue
            if 'DateLUT' not in s and 'Yandex::' not in s:
                continue
            # Pre-2014-08 named the singleton accessor DateLUTSingleton (DateLUTSingleton
            # ::instance() -> the calendar). Route it to the donor's DateLUT singleton and
            # rename the type to DateLUT, so the migration below handles it uniformly.
            # (Applied to ns, not s, so the ns != s write-back check still fires.)
            ns = s
            # Pre-2014 much of the code lived in `namespace Yandex` (libmysqlxx uses
            # Yandex::DateLUTSingleton / Yandex::DateLUT::Values / Yandex::DayNum_t /
            # Yandex::VisitID_t). The donor moved all of these to global scope, so drop
            # the Yandex:: qualifier; the methods those callers use (getValues,
            # toHourInaccurate, ...) all still exist on the donor DateLUTImpl.
            ns = ns.replace('Yandex::', '')
            # Pre-2013-05 named the bounds-checked day-number conversions safeFromDayNum
            # / safeToDayNum; the donor dropped the "safe" prefix (fromDayNum/toDayNum are
            # bounds-checked via fixDay).
            ns = ns.replace('safeFromDayNum', 'fromDayNum').replace('safeToDayNum', 'toDayNum')
            # Pre-2012-09 ToMondayImpl rounds down to Monday via date_lut.toWeek(...); the
            # donor renamed that "start of the week" method to toFirstDayOfWeek (its toWeek,
            # when it later reappeared, means the ISO week *number*). Newer eras don't call
            # `.toWeek(` at all, so this is a no-op there. (DayNum_t -> time_t converts the
            # same way toFirstDayOfMonth(DayNum_t) already relies on.)
            ns = ns.replace('.toWeek(', '.toFirstDayOfWeek(')
            if 'DateLUTSingleton' in ns:
                ns = ns.replace('DateLUTSingleton::instance', 'DateLUT::instance').replace('DateLUTSingleton', 'DateLUT')
            ns = ref.sub(r'const auto & \1 = DateLUT::instance(\2)', ns)
            ns = ns.replace('DateLUT::Values', 'DateLUTImpl::Values')
            # Any remaining reference/pointer to `DateLUT` (e.g. a `DateLUT &` function
            # parameter carrying the calendar) is really the DateLUTImpl now — and it is
            # read-only, since DateLUT::instance() returns `const DateLUTImpl &`, so make
            # the target const (a non-const ref won't bind the const instance). Do the
            # already-const forms first so we never produce `const const`. `DateLUT::`
            # (instance()/statics) and `Singleton<DateLUT>` have no ` &`/`*` and are left
            # alone.
            ns = ns.replace('const DateLUT &', 'const DateLUTImpl &').replace('DateLUT &', 'const DateLUTImpl &')
            ns = ns.replace('const DateLUT&', 'const DateLUTImpl&').replace('DateLUT&', 'const DateLUTImpl&')
            ns = ns.replace('const DateLUT *', 'const DateLUTImpl *').replace('DateLUT *', 'const DateLUTImpl *')
            ns = ns.replace('const DateLUT*', 'const DateLUTImpl*').replace('DateLUT*', 'const DateLUTImpl*')
            if ns != s:
                with open(p, 'w', encoding='utf-8', errors='surrogateescape') as f:
                    f.write(ns)
PYEOF

# -- assertChar: the back-ported Embedded dictionaries (RegionsHierarchy/RegionsNames)
#    call DB::assertChar, a ReadHelpers function added after 2015-07. Add it inline in
#    terms of the era's existing assertString (no new .cpp / error code) when absent. --
RH=dbms/include/DB/IO/ReadHelpers.h
if [ -f "$RH" ] && ! grep -q 'assertChar' "$RH"; then
    python3 - "$RH" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8', errors='surrogateescape').read()
anchor = 'void assertString(const char * s, ReadBuffer & buf);'
if anchor in s:
    i = s.index(anchor) + len(anchor)
    add = ('\n\n/// Added by reconstruct.sh: assertChar (used by the back-ported Embedded'
           '\n/// dictionaries); implemented via the era\'s existing assertString.'
           '\ninline void assertChar(char symbol, ReadBuffer & buf)'
           '\n{\n\tconst char s[2] = { symbol, 0 };\n\tassertString(s, buf);\n}')
    open(p, 'w', encoding='utf-8', errors='surrogateescape').write(s[:i] + add + s[i:])
PYEOF
fi

# -- WriteBufferFromFileDescriptor::sync (pre-2014): the back-ported (PATCH_FILL)
#    CounterInFile.h calls buf.sync() to flush the counter file, but this era's
#    WriteBufferFromFileDescriptor only has next() (sync() was added later). Add a
#    sync() that flushes the buffer -- durability/fsync is irrelevant for the ephemeral
#    benchmark, and CounterInFile itself is unused by it. Guarded on the class lacking
#    sync(), so it's a no-op once sync() landed. --
WB=dbms/include/DB/IO/WriteBufferFromFileDescriptor.h
if [ -f "$WB" ] && ! grep -q 'void sync' "$WB"; then
    python3 - "$WB" <<'PYEOF'
import sys, re
p = sys.argv[1]
s = open(p, encoding='utf-8', errors='surrogateescape').read()
m = re.search(r'class\s+WriteBufferFromFileDescriptor\b[^{]*\{', s)
if m:
    i = m.end()
    s = s[:i] + '\npublic:\n\tvoid sync() { next(); }\n' + s[i:]
    open(p, 'w', encoding='utf-8', errors='surrogateescape').write(s)
PYEOF
fi

# -- DB::toString (pre-2014): the back-ported Embedded dictionaries (RegionsHierarchy.h)
#    call DB::toString, a WriteHelpers helper added later. Append the same template the
#    donor defines (WriteBufferFromString + writeText) when this era's WriteHelpers.h
#    lacks it. This era's WriteBufferFromString.h doesn't include WriteHelpers.h, so
#    there is no circular include. No-op once toString is present. --
WH=dbms/include/DB/IO/WriteHelpers.h
if [ -f "$WH" ] && ! grep -q 'String toString' "$WH"; then
    {
        printf '\n#include <DB/IO/WriteBufferFromString.h>\n'
        printf 'namespace DB { template <typename T> inline std::string toString(const T & x) { std::string res; { WriteBufferFromString buf(res); writeText(x, buf); } return res; } }\n'
    } >> "$WH"
fi

# -- The back-ported Embedded RegionsHierarchy.h uses DB::toString but only includes
#    ReadHelpers.h, relying on WriteHelpers.h (which carries toString) arriving
#    transitively -- which it does in some eras but not others (e.g. 2013-03 fails).
#    Make it self-sufficient by including WriteHelpers.h directly. Guarded on the file
#    using toString and not already including it, so it's a no-op elsewhere. --
RH_EMB=dbms/include/DB/Dictionaries/Embedded/RegionsHierarchy.h
if [ -f "$RH_EMB" ] && grep -q 'DB::toString' "$RH_EMB" && ! grep -q 'IO/WriteHelpers.h' "$RH_EMB"; then
    sed -i '/#pragma once/a #include <DB/IO/WriteHelpers.h>' "$RH_EMB"
fi

# -- ColumnWithNameAndType -> ColumnWithTypeAndName: the struct was renamed after
#    2015-07. The back-ported SummingSorted uses the new name; add a compat alias so
#    it resolves against the era's old type. Guarded on the old header existing and
#    the new one not, so it's a no-op once the rename landed (2015-08+). --
CWN=dbms/include/DB/Core/ColumnWithNameAndType.h
if [ -f "$CWN" ] && [ ! -f dbms/include/DB/Core/ColumnWithTypeAndName.h ]; then
    printf '\nnamespace DB { using ColumnWithTypeAndName = ColumnWithNameAndType; }\n' >> "$CWN"
fi

# -- RegionsNames::SupportedLanguages -> Language: the region-name language enum was
#    renamed (SupportedLanguages::Enum / ::RU -> Language / Language::RU); the methods
#    getLanguageEnum() and getRegionName() kept their names. Rename the old references
#    (regionToName in FunctionsDictionaries) to match the donor's RegionsNames. A
#    no-op on 2015-01+, which no longer name the enum. --
grep -rlZ 'RegionsNames::SupportedLanguages' dbms 2>/dev/null | while IFS= read -r -d '' f; do
    sed -i 's#RegionsNames::SupportedLanguages::Enum#RegionsNames::Language#g; s#RegionsNames::SupportedLanguages::#RegionsNames::Language::#g' "$f"
done

# -- StringRef: the donor's libcommon common/JSON.h uses an unqualified, global
#    `StringRef` (its getRawString()/getRawName() return it). By 2014-05 StringRef
#    lived at global scope in DB/Core/StringRef.h, but the 2014-04-and-older copy
#    defines it inside `namespace DB`, so the global name the donor JSON.h expects
#    is invisible. Hoist it with a global `using DB::StringRef;` — but only when the
#    header defines StringRef solely inside namespace DB (guarded on the absence of a
#    top-level `struct StringRef`), so it's a no-op on 2014-05+ where it's already global. --
SR=dbms/include/DB/Core/StringRef.h
# Pre-2012-06 predates StringRef entirely (the file does not exist), yet the overlaid
# donor libcommon JSON.h includes <DB/Core/StringRef.h>. Create the known-good early
# (2012-06) definition -- namespace DB, backed by CityHash from contrib -- when absent;
# the hoist below then exposes it globally. A no-op once the file exists.
if [ ! -f "$SR" ]; then
    mkdir -p "$(dirname "$SR")"
    cat > "$SR" <<'EOF'
#pragma once

#include <string.h>
#include <city.h>

#include <string>


namespace DB
{
	/// Reconstruct shim: StringRef did not exist before 2012-06 (this is that copy).
	struct StringRef
	{
		const char * data;
		size_t size;

		StringRef(const char * data_, size_t size_) : data(data_), size(size_) {}
		StringRef(const unsigned char * data_, size_t size_) : data(reinterpret_cast<const char *>(data_)), size(size_) {}
		StringRef(const std::string & s) : data(s.data()), size(s.size()) {}
		StringRef() : data(NULL), size(0) {}
	};

	inline bool operator==(StringRef lhs, StringRef rhs)
	{
		return lhs.size == rhs.size && 0 == memcmp(lhs.data, rhs.data, lhs.size);
	}

	inline bool operator!=(StringRef lhs, StringRef rhs)
	{
		return !(lhs == rhs);
	}

	struct StringRefHash
	{
		inline size_t operator() (StringRef x) const
		{
			return CityHash64(x.data, x.size);
		}
	};
}
EOF
fi
if [ -f "$SR" ] && grep -q 'namespace DB' "$SR" && ! grep -qE '^struct StringRef' "$SR" \
   && ! grep -q 'using DB::StringRef' "$SR"; then
    printf '\n// Added by reconstruct.sh: expose DB::StringRef globally for the donor libcommon JSON.h\nusing DB::StringRef;\n' >> "$SR"
fi

# -- root CMakeLists: add the quicklz/re2_st include dirs and, on the C++ flags,
#    -fpermissive plus the force-included cmath shim (anchored on the donor's
#    stable libcityhash include line / -std=gnu++1y flag) --
sed -i 's#include_directories (${METRICA_SOURCE_DIR}/contrib/libcityhash/)#include_directories (${METRICA_SOURCE_DIR}/contrib/quicklz-stub/)\ninclude_directories (${METRICA_SOURCE_DIR}/contrib/re2_st_gen/)\ninclude_directories (${METRICA_SOURCE_DIR}/contrib/statdaemons-compat/)\ninclude_directories (${METRICA_SOURCE_DIR}/contrib/yandex-compat/)\ninclude_directories (${METRICA_SOURCE_DIR}/contrib/dc-compat/)\ninclude_directories (${METRICA_SOURCE_DIR}/contrib/stats-compat/)\ninclude_directories (${METRICA_SOURCE_DIR}/contrib/strconvert-compat/)\ninclude_directories (${METRICA_SOURCE_DIR}/contrib/jsonxx-compat/)\ninclude_directories (${METRICA_SOURCE_DIR}/contrib/zkcpp-stub/)\ninclude_directories (${METRICA_SOURCE_DIR}/contrib/libcityhash/)#' CMakeLists.txt
# Force-include a few standard headers: on this (trusty) toolchain they aren't
# pulled in transitively the way the newer 16.04/boost-1.58 headers were, so code
# that assumes std::accumulate (<numeric>) / std::mt19937 (<random>) /
# std::unordered_set (pre-2014-05 ITableDeclaration relied on a transitive include)
# is in scope fails to compile without them.
sed -i 's#-std=gnu++1y#-std=gnu++1y -fpermissive -D_GLIBCXX_USE_CXX11_ABI=0 -include numeric -include random -include unordered_set#' CMakeLists.txt

echo "reconstruct.sh: build system reconciled"
