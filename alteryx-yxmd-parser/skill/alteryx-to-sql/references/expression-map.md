# Alteryx expression language → SQL

Translate structurally: parse the expression, then emit. Do not regex-replace blindly.

## Syntax
| Alteryx | Spark SQL | T-SQL |
|---|---|---|
| `[Field]` | `` `Field` `` | `[Field]` |
| `"text"` or `'text'` | `'text'` (escape `'` as `''`) | same |
| `=` / `!=` / `<>` | `=` / `<>` | same |
| `AND OR NOT` (case-insens.) | same | same |
| `IF c THEN a ELSEIF c2 THEN b ELSE z ENDIF` | `CASE WHEN c THEN a WHEN c2 THEN b ELSE z END` | same |
| `IIF(c, a, b)` | `CASE WHEN c THEN a ELSE b END` / `IF(c,a,b)` | `IIF(c,a,b)` |
| `SWITCH(v, default, c1, r1, ...)` | `CASE v WHEN c1 THEN r1 ... ELSE default END` | same |
| `//` and `/* */` comments | `--` / `/* */` | same |
| `NULL()` | `NULL` | `NULL` |
| `[Row-1:X]` (Multi-Row) | `LAG(X,1) OVER (...)` | same |
| `%User.X%` | parameter | parameter |

Alteryx `=` on strings is **case-sensitive**; Spark default is case-sensitive, T-SQL depends on collation — flag if a collation is CI.

## Functions
| Alteryx | Spark SQL | T-SQL |
|---|---|---|
| `IsNull(x)` / `IsEmpty(x)` | `x IS NULL` / `(x IS NULL OR x = '')` | same |
| `ToString(x)` / `ToNumber(x)` | `CAST(x AS STRING)` / `CAST(x AS DOUBLE)` | `CAST(x AS NVARCHAR(MAX))` / `TRY_CAST(x AS FLOAT)` |
| `Abs Ceil Floor Round(x,m) Pow Sqrt Log Exp Mod(a,b)` | `ABS CEIL FLOOR ROUND(x, -log10(m))`* `POW SQRT LN EXP MOD` | `ABS CEILING FLOOR ROUND POWER SQRT LOG EXP a % b` |
| `Length(s)` | `LENGTH` | `LEN` (trims trailing spaces!) — use `DATALENGTH/2` for NVARCHAR if exact |
| `Left(s,n) Right(s,n) Substring(s,start,len)` | `LEFT RIGHT SUBSTRING(s,start+1,len)` — Alteryx start is **0-based** | same, 1-based |
| `Trim TrimLeft TrimRight` | `TRIM LTRIM RTRIM` (Alteryx can trim a char set: `TRIM(s,'x')` → `TRIM('x' FROM s)`) | `TRIM`/`LTRIM`/`RTRIM` |
| `Uppercase Lowercase TitleCase` | `UPPER LOWER INITCAP` | `UPPER LOWER` / TitleCase = MANUAL |
| `Contains(s,t)` / `StartsWith` / `EndsWith` | `s LIKE '%t%'` or `contains()` / `startswith()` / `endswith()` | `CHARINDEX(t,s)>0` / `s LIKE 't%'` / `s LIKE '%t'` |
| `FindString(s,t)` | `INSTR(s,t) - 1` (Alteryx is 0-based, -1 if absent) | `CHARINDEX(t,s) - 1` |
| `Replace(s,a,b)` | `REPLACE` | same |
| `REGEX_Match / REGEX_Replace / REGEX_CountMatches` | `RLIKE` / `regexp_replace` / `size(regexp_extract_all(...))` | MANUAL |
| `PadLeft(s,n,c)` / `PadRight` | `LPAD` / `RPAD` | `RIGHT(REPLICATE(c,n)+s,n)` |
| `GetWord(s,n)` | `split(s,' ')[n]` | `STRING_SPLIT` + ordinal (2022+) |
| `DateTimeToday()` / `DateTimeNow()` | `current_date()` / `current_timestamp()` | `CAST(GETDATE() AS DATE)` / `GETDATE()` |
| `DateTimeFormat(d, fmt)` | `date_format(d, <fmt'>)` | `FORMAT(d, <fmt'>)` |
| `DateTimeParse(s, fmt)` | `to_timestamp(s, <fmt'>)` | `TRY_CONVERT` with style, or `PARSE` |
| `DateTimeAdd(d, n, unit)` | `d + INTERVAL n unit` / `date_add`, `add_months` | `DATEADD(unit, n, d)` |
| `DateTimeDiff(a, b, unit)` | `datediff(a,b)` (days) / `months_between` / `unix_timestamp` math | `DATEDIFF(unit, b, a)` |
| `DateTimeYear/Month/Day(d)` | `year month day` | `YEAR MONTH DAY` |
| `DateTimeTrim(d, 'firstofmonth')` | `trunc(d,'MM')` | `DATEFROMPARTS(YEAR(d),MONTH(d),1)` |
| `DateTimeFirstOfMonth/LastOfMonth` | `trunc(d,'MM')` / `last_day(d)` | `DATEFROMPARTS` / `EOMONTH` |

*Alteryx `Round(x, 0.01)` rounds to a multiple; SQL `ROUND(x, 2)` rounds to decimals. Convert `m` → `-LOG10(m)` places; if `m` is not a power of 10, use `ROUND(x/m)*m`.

### Date format tokens (Alteryx → Spark / T-SQL `FORMAT`)
`%Y`→`yyyy`/`yyyy` · `%y`→`yy` · `%m`→`MM` · `%d`→`dd` · `%H`→`HH` · `%M`→`mm` · `%S`→`ss` · `%b`→`MMM` · `%B`→`MMMM` · `%a`→`EEE`/`ddd` · `%A`→`EEEE`/`dddd` · `%j`→`DDD`/MANUAL · `%U`→week MANUAL.

## Null semantics to preserve
- Alteryx `[a] = NULL` is never true; comparisons with NULL yield NULL (same as SQL). **Filter** sends NULL results to the False anchor.
- String concat `[a] + [b]` with a NULL yields NULL in Alteryx (same as SQL `+`/`||`; T-SQL `CONCAT()` treats NULL as '' — don't use it unless the Alteryx expression used `Concat()`... it doesn't exist; stick to `+`).
- Integer overflow in Alteryx wraps silently in some versions — irrelevant to SQL but worth a note when sums get large (use BIGINT/DECIMAL).
