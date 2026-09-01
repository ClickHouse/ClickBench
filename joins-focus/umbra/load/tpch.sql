-- TPCH load for Umbra. Umbra has no Parquet reader, so it loads the CSV
-- export. NULL is \N there, which is how an empty string stays distinguishable
-- from a NULL.

COPY tpch.nation FROM '{{DATA}}/csv/tpch/nation.csv' (FORMAT csv, NULL '\N');
COPY tpch.region FROM '{{DATA}}/csv/tpch/region.csv' (FORMAT csv, NULL '\N');
COPY tpch.part FROM '{{DATA}}/csv/tpch/part.csv' (FORMAT csv, NULL '\N');
COPY tpch.supplier FROM '{{DATA}}/csv/tpch/supplier.csv' (FORMAT csv, NULL '\N');
COPY tpch.partsupp FROM '{{DATA}}/csv/tpch/partsupp.csv' (FORMAT csv, NULL '\N');
COPY tpch.customer FROM '{{DATA}}/csv/tpch/customer.csv' (FORMAT csv, NULL '\N');
COPY tpch.orders FROM '{{DATA}}/csv/tpch/orders.csv' (FORMAT csv, NULL '\N');
COPY tpch.lineitem FROM '{{DATA}}/csv/tpch/lineitem.csv' (FORMAT csv, NULL '\N');
