---
name: alteryx-to-sql
description: Convert an Alteryx workflow (a steps.md produced by yxmd_steps.py, or a raw .yxmd) into Databricks Spark SQL or Microsoft Fabric T-SQL, as one CTE per tool, with a reconciliation query and a review list. Use whenever the user hands over a .yxmd or a steps.md and wants SQL.
---

# Alteryx → SQL (from steps.md)

You convert a workflow that has **already been parsed** into an ordered step list. You never read raw `.yxmd` XML. If you are given a `.yxmd`, run the parser first:

```
python yxmd_steps.py <file.yxmd> > steps.md
```

`steps.md` has one line per tool, in execution order:

```
N. [id] what it does   <- anchor:feeding_ids   -> anchor:fed_ids   // author's annotation
     cols: Name:Type, ...        (only where Alteryx cached the schema, usually inputs)
```

`<-` lists which tool ids feed each input anchor (`Left:14 Right:7`, `#1:9 #2:21`). `->` lists where each output anchor goes; an anchor not listed is unused (e.g. a Filter with only `True:22` sends its False rows nowhere). A `params:` line at the top lists `User.*` constants. `(UNKNOWN TOOL)` lines carry the raw config.

## Target dialect

Ask once if not stated: **Databricks Spark SQL** or **Fabric T-SQL**. Then use `references/dialect-map.md` for every function and construct. Never mix dialects.

## Procedure

1. **Read the whole steps.md first.** Count the tools, note the `params:` line, which lines are `Input`/`TextInput` (sources) and `Output` (sinks), and which carry `(UNKNOWN TOOL)` or a `Macro:` prefix. State a coverage line to the user up front, e.g. `14 tools · 2 need review`.
2. **One CTE per step, in the listed order.** Name CTEs `t<id>_<tool>` (e.g. `t9_filter`). Every CTE's FROM references the CTE(s) of the ids after `<-`. Never reorder, merge, or skip steps on the first pass — fidelity before elegance. (A second "simplify" pass is allowed only if the user asks and only after reconciliation passes.)
3. **Translate by tool type** using `references/tool-map.md`. The step line is the only source of truth for what a tool does. Track the column set yourself as you go: each step is a diff (rename/cast/drop/add) applied to its input's columns, starting from the `cols:` line on the inputs.
4. **Expressions** (Filter, Formula, Multi-Row, Generate Rows): translate the Alteryx expression language with `references/expression-map.md`. Preserve operator precedence; wrap each translated expression in parentheses. `[Field]` → identifier quoted for the dialect (`` `Field` `` / `[Field]`). `%User.X%` / `%Question.X%` → a declared variable or a `:param` placeholder, listed in a **Parameters** header comment.
5. **Multi-output anchors.** Only emit CTEs for anchors that appear after `->`. Filter `False`, Join `Left`/`Right`, Unique `Duplicate` that are not listed are dropped. A Join `Left` anchor that *is* listed becomes a LEFT ANTI JOIN CTE (`t2_join_left`), and so on.
6. **Each `Output` step** becomes a final `SELECT … FROM t<id>` (or `CREATE OR REPLACE TABLE … AS` / `INSERT` when it targets a table). Walk the `<-` chain backwards to confirm every CTE it needs is present.
7. **Review flags.** Any step that is order-dependent, uses an ambiguous function, is a `Macro:`, or is `(UNKNOWN TOOL)` gets a `-- REVIEW [#id tool]: <note>` comment immediately above its CTE, *and* a line in a "Needs review" list at the end of your reply. Python/R/Download/Fuzzy/Spatial and `(UNKNOWN TOOL)` steps get a stub CTE that selects from its input unchanged, a `-- MANUAL [#id tool]` comment, and the step line pasted as a comment so a human can finish it.
8. **Order-dependent tools** (Unique, Sample, MultiRow, RunningTotal, RecordID, Summarize First/Last): Alteryx uses arrival order. Find the nearest upstream `Sort` step and use its keys as the window `ORDER BY`. If there is none, emit `ORDER BY /* TODO: no upstream Sort — Alteryx used file order */ 1` and flag it.
9. **Reconciliation query.** After the main SQL, emit a second block that, for each sink, computes `COUNT(*)`, `COUNT(DISTINCT <first key-like column>)`, and `SUM`/`MIN`/`MAX` of every numeric column, so the person can run it against the Alteryx output file. Name it `recon_<sinkid>`.
10. **Deliver**: (a) the coverage line, (b) the SQL as a file `<name>.<dialect>.sql`, (c) the recon SQL in the same file under a header, (d) the "Needs review" list, (e) nothing else — no restating the workflow.

## Hard rules

- Never guess a tool's behaviour from its name alone; an `(UNKNOWN TOOL)` line is stubbed, not translated.
- Never silently change join semantics. Alteryx Join `J` = INNER on the key pairs; string keys compare case-sensitively and Alteryx treats `NULL`, `''` and whitespace-only as **equal** — note this in the REVIEW comment and offer `COALESCE(TRIM(k),'')` normalisation as an option, not a default.
- Alteryx `Sum` of a column with any NULL returns NULL only when *all* are NULL; SQL does the same — fine. But Alteryx **arithmetic** (`[a] + [b]`) with a NULL operand yields NULL just like SQL; do not add COALESCE unless the Formula does.
- Division: Alteryx `/` on integers yields a double. In T-SQL, cast operands to `FLOAT`; in Spark `/` already returns double.
- `drop unlisted` on a Select or Join means **drop every column not named in that step** — emit an explicit column list, never `SELECT *`. `keep unlisted` means pass everything else through.
- Text Input rows become a `VALUES` CTE with every value cast to the type implied by downstream use (or STRING if unclear, with a REVIEW note).
- Preserve Alteryx's output column order where the step gives it (Select order, Summarize field order).
- Do not emit `SELECT *` anywhere in the final deliverable except inside stub CTEs for manual nodes.

## Output skeleton

```sql
-- Workflow: <name>   Source: <path>   Dialect: <dialect>
-- Coverage: <n> tools · <k> need review
-- Parameters: User.MinBalance (default 10000) → :min_balance

WITH
t12_input AS ( ... ),
t5_select AS ( ... ),
-- REVIEW [#9 Filter]: expression uses %User.MinBalance%
t9_filter AS ( ... ),
...
SELECT ... FROM t32_sort ORDER BY ...;   -- sink #3 region_rollup.csv

-- ===== Reconciliation =====
-- Run against the Alteryx output and compare.
SELECT COUNT(*) AS row_count, SUM(TotalBalance) AS sum_TotalBalance, ... FROM t32_sort;  -- recon_3
```
