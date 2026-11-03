# Tool → SQL map

`cfg` = what the step line says (e.g. for Select: rename/cast/drop/unlisted; for Join: key pairs). `IN` = the CTE feeding the node's input anchor. Spark SQL shown first, T-SQL differences noted.

| Tool (IR `tool`) | SQL pattern | Notes |
|---|---|---|
| Input Data (file) | `SELECT * FROM <source table/view>` | File paths must be mapped to a table or `read_files()`/OPENROWSET by the user; put the original path in a comment. |
| Input Data (query) | Paste `cfg.query` as the CTE body | Port dialect; flag. |
| Text Input | `SELECT * FROM (VALUES (...),(...)) AS t(col1, col2)` | T-SQL: `VALUES` needs explicit casts for non-string. |
| Select | `SELECT <keep in order, with rename/cast> FROM IN` | cast types → see type map below. `drop unlisted` ⇒ explicit list only. |
| Filter | `SELECT * FROM IN WHERE (<expr>)` for `True`; `WHERE NOT (<expr>) OR (<expr>) IS NULL` for `False` | Alteryx sends NULL-evaluating rows to **False**. |
| Formula | `SELECT IN.*, <expr1> AS f1, ... FROM IN` | If a formula overwrites an existing column, project explicitly (exclude the old one). Formulas evaluate **top-to-bottom** and later ones can reference earlier ones ⇒ nest CTEs or use a subquery per dependent formula. |
| Multi-Field Formula | One expression applied per field in `cfg.fields`; `copy_output:true` ⇒ new columns named `<field>` + suffix | |
| Multi-Row Formula | `LAG/LEAD(<col>, n) OVER (PARTITION BY cfg.group_by ORDER BY <upstream sort>)` | `[Row-1:X]`→`LAG(X,1)`, `[Row+1:X]`→`LEAD(X,1)`. `null_handling:"Null"` ⇒ leave NULL; `"Empty"` ⇒ COALESCE to 0/''. Self-referencing `[Row-1:TargetField]` is a recursive running calc — use `SUM() OVER` if additive, else flag MANUAL. |
| Join (J) | `INNER JOIN` on `cfg.keys` pairs | Column collisions: Alteryx prefixes `Right_`. Apply `output_select`. |
| Join (L anchor, if linked) | `LEFT ANTI JOIN` (Spark) / `WHERE NOT EXISTS` (T-SQL) | |
| Join (R anchor, if linked) | Right anti-join | |
| Join Multiple | Chain of FULL OUTER JOINs on `keys_by_input` unless config says inner | Flag. |
| Append Fields | `CROSS JOIN` | |
| Union | `UNION ALL` by name: align columns explicitly in each SELECT | `output_mode:"Common"` ⇒ intersect column sets. Never `UNION` (dedups). |
| Summarize | `SELECT <group_by>, agg(...) AS <as> FROM IN GROUP BY <group_by>` | Action map: Sum→SUM, Count→COUNT(*), CountDistinct→COUNT(DISTINCT), CountNonNull→COUNT(col), CountNull→SUM(CASE WHEN col IS NULL THEN 1 ELSE 0 END), Min/Max/Avg→same, First/Last→`FIRST(col)`/`LAST(col)` with window flag (T-SQL: ROW_NUMBER trick), Concat→`concat_ws(sep, collect_list(col))` (T-SQL: `STRING_AGG`), StdDev→STDDEV_SAMP, Var→VAR_SAMP, Median→`percentile_approx(col,0.5)` (T-SQL: `PERCENTILE_CONT` window), Mode→flag, Product→`EXP(SUM(LN(col)))` flag. No group_by ⇒ no GROUP BY (single row). |
| Sort | Carry keys forward; emit `ORDER BY` only on the final sink SELECT, and use the keys for any downstream window `ORDER BY` | CTEs don't preserve order. |
| Unique (U) | `ROW_NUMBER() OVER (PARTITION BY cfg.keys ORDER BY <upstream sort or TODO>)` then `WHERE rn = 1` | `D` anchor ⇒ `rn > 1`. |
| Sample | First N ⇒ `rn <= N`; Last N ⇒ reverse order; 1 in N ⇒ `rn % N = 1`; Random ⇒ flag | Per-group ⇒ PARTITION BY `group_by`. |
| Record ID | `ROW_NUMBER() OVER (ORDER BY <upstream sort or TODO>) + (cfg.start - 1)` | |
| Running Total | `SUM(col) OVER (PARTITION BY group_by ORDER BY <sort> ROWS UNBOUNDED PRECEDING)` | |
| Cross Tab | `PIVOT` with enumerated header values, or `SUM(CASE WHEN header = 'v' THEN data END) AS v` | Alteryx sanitises header values into column names (non-alnum → `_`). Values must be enumerated — flag. |
| Transpose | Spark: `stack(n, 'c1', c1, 'c2', c2, ...)` → `(Name, Value)`; T-SQL: `UNPIVOT` or `CROSS APPLY (VALUES ...)` | Alteryx output columns are literally `Name` and `Value`. |
| Text To Columns | Spark: `split(col, delim)[i]` per `num_fields`, or `explode(split(...))` if `split_to_rows` | T-SQL: `STRING_SPLIT` (rows) or `PARSENAME`/`JSON_VALUE` tricks (columns). Output names `<root_name>1..n`. |
| RegEx | Match ⇒ `col RLIKE pat` / Replace ⇒ `regexp_replace` / Parse ⇒ `regexp_extract(col, pat, n)` / Tokenize ⇒ explode of `regexp_extract_all` | T-SQL has no regex ⇒ MANUAL unless pattern is a simple LIKE. |
| Find Replace | `LEFT JOIN` lookup on whole-field match; "any part" mode ⇒ `LIKE '%'||k||'%'` flag | |
| Data Cleansing (macro) | TRIM / COALESCE(col,'') / regexp_replace for punctuation / UPPER-LOWER-INITCAP per enabled option | Option names are opaque IDs; map by the standard macro's order (see below). |
| DateTime (macro) | `to_date`/`date_format` with converted pattern | `%Y-%m-%d` → `yyyy-MM-dd`. |
| Dynamic Rename / Generate Rows / Python / R / Download / Fuzzy / Spatial | Stub CTE `SELECT * FROM IN` + `-- MANUAL` comment with config | |
| Output Data | Final SELECT; if `cfg.table` set: `CREATE OR REPLACE TABLE <table> AS` (Overwrite) / `INSERT INTO` (Append) | |

## Data Cleansing macro option order (standard Cleanse.yxmc)
Values appear as `Check Box (NN)`; typical mapping — verify against the macro version in use:
- 84: Replace NULL with blank/0 · 117: Remove leading/trailing whitespace · 164: Remove tabs/line breaks · 165: Remove all whitespace · 166: Remove duplicate whitespace · 167: Remove letters · 168: Remove numbers · 169: Remove punctuation · 170: Modify case (value in a sibling drop-down) · List Box (11): fields to apply to.

## Alteryx type → SQL type
| Alteryx | Spark SQL | T-SQL |
|---|---|---|
| Bool | BOOLEAN | BIT |
| Byte/Int16/Int32 | SMALLINT/SMALLINT/INT | TINYINT/SMALLINT/INT |
| Int64 | BIGINT | BIGINT |
| FixedDecimal `p.s` | DECIMAL(p,s) | DECIMAL(p,s) |
| Float/Double | FLOAT/DOUBLE | REAL/FLOAT |
| String/WString (fixed n) | STRING (CHAR semantics lost — note padding) | CHAR(n)/NCHAR(n) |
| V_String/V_WString | STRING | VARCHAR(n)/NVARCHAR(n) |
| Date | DATE | DATE |
| Time | STRING (no TIME type) or TIMESTAMP | TIME |
| DateTime | TIMESTAMP | DATETIME2 |
| Blob/SpatialObj | BINARY / flag | VARBINARY / flag |
