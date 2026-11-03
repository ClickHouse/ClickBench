DROP TABLE IF EXISTS bluesky;

CREATE TABLE bluesky (
    data OBJECT(DYNAMIC) AS (
        "commit" OBJECT(DYNAMIC) AS (
            "record" OBJECT(IGNORED)
        )
    )
);
