// Bulk loader for ClickBench: reads hits.tsv (ClickHouse TabSeparated format)
// and inserts it into the `hits` table with the Firebird 4+ batch API.
//
// Firebird has no COPY-like statement, and its external tables only support
// fixed-width records, which does not work for a table with long strings.
// A client-side loop of single-row INSERTs gets only a few hundred rows per
// second, so this loader packs rows into IBatch messages of the table's
// native column types. The input is split into byte ranges, one per thread,
// each with its own attachment, transaction and batch.
//
// Usage: loader <database> <hits.tsv> <threads>

#include <firebird/Interface.h>

#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <thread>
#include <vector>

#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

using namespace Firebird;

static IMaster * master = fb_get_master_interface();

static const unsigned ROWS_PER_BATCH = 1000;
static const unsigned BATCHES_PER_COMMIT = 200;

static std::atomic<unsigned long long> total_rows{0};

struct Column
{
    unsigned type;
    unsigned length;
    unsigned offset;
    unsigned null_offset;
};

[[noreturn]] static void fail(const std::string & msg)
{
    fprintf(stderr, "%s\n", msg.c_str());
    fflush(stderr);
    /// Not `exit`: it would shut down the embedded engine under the other threads.
    _exit(1);
}

static long long parseInt(const char * begin, const char * end)
{
    bool neg = false;
    if (begin < end && *begin == '-')
    {
        neg = true;
        ++begin;
    }
    if (begin == end)
        fail("empty number");
    unsigned long long res = 0;
    for (const char * p = begin; p < end; ++p)
    {
        if (*p < '0' || *p > '9')
            fail("bad number: " + std::string(begin, end));
        res = res * 10 + (*p - '0');
    }
    return neg ? -static_cast<long long>(res) : static_cast<long long>(res);
}

static unsigned digits(const char * p, int n)
{
    unsigned res = 0;
    for (int i = 0; i < n; ++i)
        res = res * 10 + (p[i] - '0');
    return res;
}

/// Decodes the escape sequences of the TabSeparated format into `out`, returns the length.
static unsigned unescape(const char * begin, const char * end, char * out, unsigned max_length)
{
    unsigned n = 0;
    for (const char * p = begin; p < end; ++p)
    {
        char c = *p;
        if (c == '\\' && p + 1 < end)
        {
            ++p;
            switch (*p)
            {
                case 'n': c = '\n'; break;
                case 't': c = '\t'; break;
                case 'r': c = '\r'; break;
                case 'b': c = '\b'; break;
                case 'f': c = '\f'; break;
                case '0': c = '\0'; break;
                default: c = *p; break;
            }
        }
        if (n == max_length)
            fail("string is longer than the declared column length " + std::to_string(max_length));
        out[n++] = c;
    }
    return n;
}

static void loadRange(const char * db, const char * begin, const char * end)
{
    ThrowStatusWrapper status(master->getStatus());
    IUtil * util = master->getUtilInterface();
    try
    {
        IProvider * prov = master->getDispatcher();
        /// In embedded mode, the user defaults to the OS user, which has no rights on the table.
        IXpbBuilder * dpb = util->getXpbBuilder(&status, IXpbBuilder::DPB, nullptr, 0);
        dpb->insertString(&status, isc_dpb_user_name, "SYSDBA");
        IAttachment * att = prov->attachDatabase(&status, db, dpb->getBufferLength(&status), dpb->getBuffer(&status));
        dpb->dispose();

        IXpbBuilder * tpb = util->getXpbBuilder(&status, IXpbBuilder::TPB, nullptr, 0);
        tpb->insertTag(&status, isc_tpb_write);
        tpb->insertTag(&status, isc_tpb_concurrency);
        tpb->insertTag(&status, isc_tpb_wait);
        /// Without it, the transaction keeps an undo log of every inserted record in memory.
        tpb->insertTag(&status, isc_tpb_no_auto_undo);

        auto start = [&] { return att->startTransaction(&status, tpb->getBufferLength(&status), tpb->getBuffer(&status)); };
        ITransaction * tra = start();

        IStatement * stmt = att->prepare(&status, tra, 0, "SELECT * FROM hits", 3, 0);
        IMessageMetadata * out_meta = stmt->getOutputMetadata(&status);
        unsigned num_columns = out_meta->getCount(&status);
        std::string sql = "INSERT INTO hits VALUES (?";
        for (unsigned i = 1; i < num_columns; ++i)
            sql += ", ?";
        sql += ")";
        stmt->free(&status);
        out_meta->release();

        IXpbBuilder * bpb = util->getXpbBuilder(&status, IXpbBuilder::BATCH, nullptr, 0);
        bpb->insertInt(&status, IBatch::TAG_BUFFER_BYTES_SIZE, 256 * 1024 * 1024);
        IBatch * batch = att->createBatch(&status, tra, 0, sql.c_str(), 3, nullptr,
            bpb->getBufferLength(&status), bpb->getBuffer(&status));

        IMessageMetadata * meta = batch->getMetadata(&status);
        std::vector<Column> columns(num_columns);
        for (unsigned i = 0; i < num_columns; ++i)
            columns[i] = {meta->getType(&status, i), meta->getLength(&status, i), meta->getOffset(&status, i), meta->getNullOffset(&status, i)};

        unsigned alignment = meta->getAlignment(&status);
        unsigned msg_length = meta->getAlignedLength(&status);
        std::vector<unsigned char> storage(static_cast<size_t>(msg_length) * ROWS_PER_BATCH + alignment);
        unsigned char * buf = storage.data() + (alignment - reinterpret_cast<uintptr_t>(storage.data()) % alignment) % alignment;

        unsigned rows_in_buf = 0;
        unsigned batches = 0;

        auto flush = [&]
        {
            if (rows_in_buf == 0)
                return;
            batch->add(&status, rows_in_buf, buf);
            IBatchCompletionState * cs = batch->execute(&status, tra);
            unsigned pos = cs->findError(&status, 0);
            if (pos != IBatchCompletionState::NO_MORE_ERRORS)
            {
                IStatus * err = master->getStatus();
                cs->getStatus(&status, err, pos);
                char text[1024];
                util->formatStatus(text, sizeof(text), err);
                fail(std::string("batch error: ") + text);
            }
            cs->dispose();
            total_rows += rows_in_buf;
            rows_in_buf = 0;
            if (++batches % BATCHES_PER_COMMIT == 0)
            {
                tra->commit(&status);
                tra = start();
            }
        };

        const char * line = begin;
        while (line < end)
        {
            const char * eol = static_cast<const char *>(memchr(line, '\n', end - line));
            if (!eol)
                eol = end;

            unsigned char * msg = buf + static_cast<size_t>(rows_in_buf) * msg_length;
            const char * field = line;
            for (unsigned i = 0; i < num_columns; ++i)
            {
                const char * field_end = static_cast<const char *>(memchr(field, '\t', eol - field));
                if (i + 1 == num_columns)
                {
                    if (field_end)
                        fail("too many fields in a row");
                    field_end = eol;
                }
                else if (!field_end)
                    fail("too few fields in a row");

                const Column & col = columns[i];
                unsigned char * dst = msg + col.offset;
                *reinterpret_cast<short *>(msg + col.null_offset) = 0;
                switch (col.type)
                {
                    case SQL_SHORT:
                        *reinterpret_cast<ISC_SHORT *>(dst) = static_cast<ISC_SHORT>(parseInt(field, field_end));
                        break;
                    case SQL_LONG:
                        *reinterpret_cast<ISC_LONG *>(dst) = static_cast<ISC_LONG>(parseInt(field, field_end));
                        break;
                    case SQL_INT64:
                        *reinterpret_cast<ISC_INT64 *>(dst) = parseInt(field, field_end);
                        break;
                    case SQL_TYPE_DATE:
                        if (field_end - field != 10)
                            fail("bad date: " + std::string(field, field_end));
                        *reinterpret_cast<ISC_DATE *>(dst) = util->encodeDate(digits(field, 4), digits(field + 5, 2), digits(field + 8, 2));
                        break;
                    case SQL_TIMESTAMP:
                    {
                        if (field_end - field != 19)
                            fail("bad timestamp: " + std::string(field, field_end));
                        auto * ts = reinterpret_cast<ISC_TIMESTAMP *>(dst);
                        ts->timestamp_date = util->encodeDate(digits(field, 4), digits(field + 5, 2), digits(field + 8, 2));
                        ts->timestamp_time = util->encodeTime(digits(field + 11, 2), digits(field + 14, 2), digits(field + 17, 2), 0);
                        break;
                    }
                    case SQL_VARYING:
                    {
                        unsigned n = unescape(field, field_end, reinterpret_cast<char *>(dst + 2), col.length);
                        *reinterpret_cast<unsigned short *>(dst) = static_cast<unsigned short>(n);
                        break;
                    }
                    case SQL_TEXT:
                    {
                        unsigned n = unescape(field, field_end, reinterpret_cast<char *>(dst), col.length);
                        memset(dst + n, ' ', col.length - n);
                        break;
                    }
                    default:
                        fail("unsupported column type " + std::to_string(col.type));
                }
                field = field_end + 1;
            }

            if (++rows_in_buf == ROWS_PER_BATCH)
                flush();
            line = eol + 1;
        }
        flush();

        tra->commit(&status);
        batch->close(&status);
        meta->release();
        bpb->dispose();
        tpb->dispose();
        att->detach(&status);
    }
    catch (const FbException & e)
    {
        char text[1024];
        util->formatStatus(text, sizeof(text), e.getStatus());
        fail(std::string("Firebird error: ") + text);
    }
}

int main(int argc, char ** argv)
{
    if (argc != 4)
        fail("Usage: loader <database> <hits.tsv> <threads>");

    const char * db = argv[1];
    int fd = open(argv[2], O_RDONLY);
    if (fd < 0)
        fail(std::string("cannot open ") + argv[2]);
    struct stat st;
    fstat(fd, &st);
    size_t size = st.st_size;
    const char * data = static_cast<const char *>(mmap(nullptr, size, PROT_READ, MAP_PRIVATE, fd, 0));
    if (data == MAP_FAILED)
        fail("mmap failed");
    madvise(const_cast<char *>(data), size, MADV_SEQUENTIAL);

    unsigned threads = std::max(1, atoi(argv[3]));
    std::vector<const char *> bounds{data};
    for (unsigned i = 1; i < threads; ++i)
    {
        const char * p = data + size / threads * i;
        if (p < bounds.back())
            p = bounds.back();
        const char * nl = static_cast<const char *>(memchr(p, '\n', data + size - p));
        bounds.push_back(nl ? nl + 1 : data + size);
    }
    bounds.push_back(data + size);

    std::vector<std::thread> workers;
    for (unsigned i = 0; i < threads; ++i)
        workers.emplace_back(loadRange, db, bounds[i], bounds[i + 1]);

    std::thread progress([&]
    {
        while (true)
        {
            for (int i = 0; i < 60; ++i)
            {
                sleep(1);
                if (total_rows.load() == ~0ULL)
                    return;
            }
            fprintf(stderr, "loaded %llu rows\n", total_rows.load());
        }
    });

    for (auto & w : workers)
        w.join();
    unsigned long long n = total_rows.exchange(~0ULL);
    progress.join();
    printf("Loaded %llu rows\n", n);
    return 0;
}
