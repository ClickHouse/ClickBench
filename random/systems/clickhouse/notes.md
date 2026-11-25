The queries are run in ClickHouse with the settings of the standard semantics
(join_use_nulls, aggregate_functions_null_for_empty, group_by_use_nulls, DISTINCT
by default for UNION, INTERSECT and EXCEPT). Where ClickHouse still differs from
the standard, the translation must give the standard result:

- String functions work on bytes and ASCII letters in ClickHouse, on characters
  in the standard, and the data has non-ASCII text: LENGTH and CHAR_LENGTH become
  lengthUTF8, LOWER becomes lowerUTF8, UPPER becomes upperUTF8, SUBSTRING(s, a, b)
  becomes substringUTF8(s, a, b), POSITION(a IN b) becomes positionUTF8(b, a).
- In a correlated subquery, a column qualified with the name of a CTE that the
  outer query reads without an alias resolves to the CTE itself, not to the
  outer row (https://github.com/ClickHouse/ClickHouse/issues/131320): give every
  outer reference to a CTE an alias (FROM g AS g_outer) and qualify the
  correlated columns with it.
- A correlated scalar subquery with COUNT over no rows gives NULL instead of 0
  (https://github.com/ClickHouse/ClickHouse/issues/111615): wrap it,
  COALESCE((SELECT COUNT(*) ...), 0). The same for COUNT(DISTINCT ...).
- Keep everything else as it is: the same columns with the same names, the same
  rows in the same order. Don't add LIMIT, SETTINGS or FORMAT.
