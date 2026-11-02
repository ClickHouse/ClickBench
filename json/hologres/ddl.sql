set hg_experimental_enable_nullable_clustering_key = true;
CREATE TABLE bluesky (
    data JSONB NOT NULL,
    distribution_key TEXT GENERATED ALWAYS AS (
        CASE
            WHEN data ->> 'did' IS NULL THEN '[NULL]'
            ELSE data ->> 'did'
        END
    ) STORED,
    sort_key TEXT GENERATED ALWAYS AS (
        -- col1: kind
        CASE 
            WHEN data ->> 'kind' IS NULL THEN '[NULL]'
            ELSE '[VAL]' || (data ->> 'kind')
        END || '|__COL1__|' ||

        -- col2: operation
        CASE 
            WHEN data -> 'commit' ->> 'operation' IS NULL THEN '[NULL]'
            ELSE '[VAL]' || (data -> 'commit' ->> 'operation')
        END || '|__COL2__|' ||

        -- col3: collection
        CASE 
            WHEN data -> 'commit' ->> 'collection' IS NULL THEN '[NULL]'
            ELSE '[VAL]' || (data -> 'commit' ->> 'collection')
        END || '|__COL3__|' ||

        -- col4: did
        CASE 
            WHEN data ->> 'did' IS NULL THEN '[NULL]'
            ELSE '[VAL]' || (data ->> 'did')
        END
    ) STORED
) WITH (clustering_key='sort_key', distribution_key='distribution_key');

ALTER TABLE bluesky ALTER COLUMN data SET (enable_columnar_type = ON);
CALL set_table_property('bluesky', 'dictionary_encoding_columns', 'data:auto');
CALL set_table_property('bluesky', 'bitmap_columns', 'data:auto');
