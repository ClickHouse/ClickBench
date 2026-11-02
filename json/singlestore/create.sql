CREATE TABLE bluesky
(
    data JSON
);
-- Notes:
--   - Not using data structures to speed up scans. In SingleStore, no sort keys or indexes can be created on JSON sub-columns.
--   - The only physical optimization we use is 'use_seekable_json' but that is implicitly on: https://docs.singlestore.com/db/v8.9/create-a-database/columnstore/columnstore-seekability-using-json/
--   - We _could_ run OPTIMIZE to force a merge but since we are also not doing this for other benchmarked databases, we omit that.
