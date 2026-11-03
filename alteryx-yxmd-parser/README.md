# alteryx-yxmd-parser

Turn an Alteryx `.yxmd` workflow into a one-line-per-tool step list, then hand that to an AI skill to write the SQL.

```
python yxmd_steps.py flow.yxmd > steps.md                                                   # Python
powershell -ExecutionPolicy Bypass -File yxmd_steps.ps1 flow.yxmd | Out-File steps.md -Encoding utf8   # Windows, no Python, no admin
```

Output:

```
# Loan Tape Region Rollup
params: User.MinBalance=10000

1. [12] Input C:\Deals\loan_tape.csv   -> Output:5
     cols: LoanID:V_String, CustomerID:V_String, Balance:Double, ...
2. [5] Select: rename Balance->OutstandingBalance; cast Rate FixedDecimal(19.6); drop OriginationDate; drop unlisted   <- Input:12   -> Output:9   // Tidy columns
3. [9] Filter: [Status] = "Performing" AND [OutstandingBalance] > %User.MinBalance%   <- Input:5   -> True:22
...
```

Reading a line: step number · `[tool id]` · what it does · `<-` which tool ids feed each input anchor · `->` which output anchors go where (anchors not listed are unused) · `//` the author's annotation. Inputs get a `cols:` line when Alteryx cached the schema.

Two equivalent implementations, same output: `yxmd_steps.py` (Python 3.8+, stdlib only) and `yxmd_steps.ps1` (Windows PowerShell 5.1 or 7, nothing to install). Each is one file, ~140 lines, four sections: helpers → one case per tool type → parse/order → print. Unknown tools print their raw config instead of failing; disabled containers are skipped and listed at the end.

**Add a tool:** one entry in the `DESCRIBE` dict (`.py`) or one `switch` case (`.ps1`), keyed by the last segment of the tool's `Plugin` attribute.

**PowerShell notes.** Running a script file is normally blocked by the default execution policy; `-ExecutionPolicy Bypass` on the command line gets around that without admin rights. If your organisation locks the policy via Group Policy so that flag is ignored, paste the script's contents into a PowerShell window instead (set `$Path` first), or run `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned` once. If the `.ps1` was downloaded, `Unblock-File yxmd_steps.ps1` clears the "from the internet" mark. Use `Out-File -Encoding utf8` rather than `>` — in PowerShell 5.1 `>` writes UTF-16.

## SQL skill

`skill/alteryx-to-sql/` is an Agent-Skills-format skill (Claude Code, Codex, ChatGPT). It reads `steps.md`, emits one CTE per step in Databricks Spark SQL or Fabric T-SQL, stubs anything it can't translate, flags order-dependent steps, and appends a reconciliation query per output. `references/` holds the tool→SQL map, the Alteryx expression language map, and dialect differences.

Install: copy `skill/alteryx-to-sql/` into your skills folder (`~/.claude/skills/` for Claude Code).

## Layout

```
yxmd_steps.py            the parser (Python)
yxmd_steps.ps1           the same parser in PowerShell
examples/                two sample workflows and their steps.md
skill/alteryx-to-sql/    SKILL.md + references/
```
