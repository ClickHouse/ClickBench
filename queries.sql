SELECT disk_name, formatReadableSize(sum(data_compressed_bytes) AS size) AS compressed, formatReadableSize(sum(data_uncompressed_bytes) AS usize) AS uncompressed, round(usize / size, 2) AS compr_rate, sum(rows) AS rows, count() AS part_count FROM system.parts WHERE (active = 1) AND (`table` = \'amazon_reviews\') GROUP BY disk_name ORDER BY size DESC
SELECT product_title, review_headline FROM amazon.amazon_reviews ORDER BY helpful_votes DESC LIMIT 10
SELECT any(product_title), count() FROM amazon.amazon_reviews GROUP BY product_id ORDER BY 2 DESC LIMIT 10
