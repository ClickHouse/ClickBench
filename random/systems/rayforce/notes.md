The translation is sent to the server as one Rayfall expression, evaluated as
`(timeit (set rf-result <translation>))`, and the result is printed with `show`.
The query must evaluate to a single table with the output columns in order.
Use `(do ...)` with `let` or `set` bindings for intermediate tables: CTEs,
derived tables and subqueries become bindings, joins become the join functions
of the documentation. A correlated subquery can often be rewritten as a join with
an aggregated table. Give null only when no rewrite keeps the result.
