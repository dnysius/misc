# Dialect quick-reference: Databricks Spark SQL vs Fabric T-SQL

| Concern | Databricks Spark SQL | Fabric T-SQL (Warehouse / SQL endpoint) |
|---|---|---|
| Identifier quoting | `` `col name` `` | `[col name]` |
| String literal | `'x'` | `'x'` (`N'x'` for Unicode if NVARCHAR) |
| Concatenate | `\|\|` or `concat()` | `+` (NULL-propagating) / `CONCAT()` (NULL→'') |
| CTE | `WITH a AS (...), b AS (...)` | same; CTE must be the first statement — prefix `;` if preceded by anything |
| Integer division | `/` returns DOUBLE; `DIV` for integer | `/` on INT is integer division — cast to FLOAT/DECIMAL |
| Boolean type | `BOOLEAN`, `TRUE/FALSE` literals | `BIT`, `1/0`; no boolean expressions in SELECT list — use `CASE WHEN ... THEN 1 ELSE 0 END` |
| Top-N | `LIMIT n` | `TOP (n)` / `OFFSET ... FETCH` |
| Anti-join | `LEFT ANTI JOIN` | `WHERE NOT EXISTS (...)` |
| Pivot | `PIVOT (SUM(v) FOR k IN ('a','b'))` or CASE | `PIVOT (SUM(v) FOR k IN ([a],[b]))` |
| Unpivot | `stack()` or `UNPIVOT` (DBR 12.2+) | `UNPIVOT` / `CROSS APPLY (VALUES ...)` |
| Regex | `RLIKE`, `regexp_replace`, `regexp_extract` | none natively — MANUAL |
| First/last in group | `FIRST(col) / LAST(col)` (non-deterministic without ORDER BY — prefer ROW_NUMBER) | ROW_NUMBER pattern |
| String agg | `concat_ws(',', collect_list(col))` | `STRING_AGG(col, ',')` |
| Median | `percentile_approx(col, 0.5)` / `median()` | `PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY col) OVER (PARTITION BY ...)` |
| Date arithmetic | `date_add(d, n)`, `add_months`, `d + INTERVAL 1 DAY` | `DATEADD(day, n, d)` |
| Date diff | `datediff(end, start)` | `DATEDIFF(day, start, end)` — argument order reversed |
| Format date | `date_format(d, 'yyyy-MM')` | `FORMAT(d, 'yyyy-MM')` |
| Safe cast | `try_cast(x AS INT)` | `TRY_CAST(x AS INT)` |
| Current date | `current_date()` | `CAST(GETDATE() AS DATE)` / `SYSDATETIME()` |
| Null-safe equality | `<=>` | `IS NOT DISTINCT FROM` (2022+) or `(a = b OR (a IS NULL AND b IS NULL))` |
| Create from query | `CREATE OR REPLACE TABLE t AS SELECT ...` | `CREATE TABLE t AS SELECT ...` (CTAS) — no `OR REPLACE`; `DROP TABLE IF EXISTS` first |
| Insert | `INSERT INTO t SELECT ...` | same |
| Parameters | `:name` (notebook widgets) or `${name}` | `DECLARE @name TYPE = ...;` |
| Temp view | `CREATE OR REPLACE TEMP VIEW v AS ...` | `#temp` tables or CTE only |
| Case sensitivity | identifiers case-insensitive, data case-sensitive | identifiers case-insensitive; data depends on collation (Fabric default is CI) |
| Comments | `-- ` and `/* */` | same |

## Emission conventions
- Spark: one `WITH ... SELECT` statement per sink; if several sinks share CTEs, emit the shared CTEs as `CREATE OR REPLACE TEMP VIEW` first, then one statement per sink.
- T-SQL: same, using `#temp` tables for shared stages when there are multiple sinks (a CTE can't be reused across statements).
- Always end statements with `;`.
