CREATE TABLE bluesky (file Uint32 NOT NULL, line Uint32 NOT NULL, data JsonDocument, PRIMARY KEY (file, line)) PARTITION BY HASH(file, line) WITH (STORE = COLUMN);
