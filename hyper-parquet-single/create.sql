create external table hits
for 'hits.parquet'
with (format => 'parquet', binary_as_text => true, immutable => true);
