<#
Print the steps of an Alteryx .yxmd workflow in execution order, one line per tool.
Works in Windows PowerShell 5.1 (built into Windows) and PowerShell 7. No admin, no installs.

    powershell -ExecutionPolicy Bypass -File yxmd_steps.ps1 flow.yxmd | Out-File steps.md -Encoding utf8

    N. [id] what it does   <- inputs   -> outputs   // annotation   !! flags

Order: a tool is listed once every tool feeding it is listed; ties go to the lower tool id.
#>
param([Parameter(Mandatory)][string]$Path)

$SKIP = @("BrowseV2", "Browse", "TextBox", "ToolContainer")                                # tools with no effect on data
$ORDER_DEPENDENT = @("Unique", "Sample", "MultiRowFormula", "RunningTotal", "RecordID")   # result depends on incoming row order


# ---------- helpers for reading a tool's <Configuration> ----------

function txt($el, $xpath, $a) {                  # an element's attribute if given, else its text (Alteryx uses both)
    $n = $el.SelectSingleNode($xpath)
    if (-not $n) { "" } elseif ($a -and $n.GetAttribute($a)) { $n.GetAttribute($a) } else { $n.InnerText }
}
function attr($el, $xpath, $a)              { $n = $el.SelectSingleNode($xpath); if ($n) { $n.GetAttribute($a) } else { "" } }
function vals($el, $xpath, $a = "field")    { @($el.SelectNodes($xpath) | ForEach-Object {
                                                  $v = $_.GetAttribute($a); if (-not $v) { $v = $_.GetAttribute("name") }; if (-not $v) { $v = $_.InnerText }; $v }) }
function csv($el, $xpath, $a = "field")     { (vals $el $xpath $a) -join ", " }
function oneLine($s)                        { ($s -replace "`r", "") -replace "`n", '\n' }
function mask($s)                           { $s -replace '(?i)(pwd|password)=[^;|]*', '$1=***' }    # credentials in connection strings
function opt($label, $value)                { if ($value) { " [$label$value]" } else { "" } }

function selectParts($el, $xpath = "SelectFields/SelectField") {      # used by Select and Join
    $out = @(foreach ($f in $el.SelectNodes($xpath)) {
        $name = $f.GetAttribute("field"); $keep = $f.GetAttribute("selected") -ne "False"
        if ($name -eq "*Unknown") { if ($keep) { "keep unlisted" } else { "drop unlisted" } } elseif (-not $keep) { "drop $name" } else {
            if ($f.GetAttribute("rename")) { "rename ${name}->$($f.GetAttribute('rename'))" }
            if ($f.GetAttribute("type"))   { "cast $name $($f.GetAttribute('type'))($($f.GetAttribute('size')))" }
        }
    })
    if ($el.SelectSingleNode("OrderChanged[@value='True']")) { $out = @("reordered") + $out }
    $out -join "; "
}

function joinDesc($c) {
    $sel = $c.SelectSingleNode("SelectConfiguration/Configuration"); if (-not $sel) { $sel = $c }
    if ($c.GetAttribute("joinByRecordPos") -eq "True") { $keys = "by record position" } else {
        $l = @(vals $c "JoinInfo[@connection='Left']/Field"); $r = @(vals $c "JoinInfo[@connection='Right']/Field")
        $pairs = for ($i = 0; $i -lt $l.Count; $i++) { "$($l[$i]) = $($r[$i])" }
        $keys = "on " + ($pairs -join ", ")
    }
    "Join $keys; " + (selectParts $sel)
}

function multirowName($c) {                      # CreateField_Name keeps a default even in update mode, so check the flag
    if ($c.SelectSingleNode("UpdateField[@value='True']")) { txt $c "UpdateField_Name" } else { txt $c "CreateField_Name" }
}


# ---------- one line per tool type ----------

function describe($tool, $c) {
    switch -Wildcard ($tool) {
        "DbFileInput"       { "Input " + (mask (txt $c "File")) + (opt "RecordLimit=" (attr $c "File" "RecordLimit")) }
        "DbFileOutput"      { "Output " + (mask (txt $c "File")) + (opt "" (txt $c "FormatSpecificOptions/OutputMode")) }
        "TextInput"         { $rows = foreach ($r in $c.SelectNodes("Data/r")) { @($r.SelectNodes("c") | ForEach-Object { $_.InnerText }) -join ", " }
                              "TextInput ($(csv $c 'Fields/Field' 'name')): " + ($rows -join "; ") }
        "AlteryxSelect"     { "Select: " + (selectParts $c) }
        "Filter"            { "Filter: " + (txt $c "Expression") }
        "Formula"           { "Formula: " + (@($c.SelectNodes("FormulaFields/FormulaField") | ForEach-Object {
                                  "$($_.GetAttribute('field')) = $($_.GetAttribute('expression')) [$($_.GetAttribute('type'))($($_.GetAttribute('size')))]" }) -join "; ") }
        "MultiFieldFormula" { "MultiFieldFormula $(txt $c 'Expression') on $(csv $c 'Fields/Field')" }
        "MultiRowFormula"   { "MultiRow: $(multirowName $c) = $(txt $c 'Expression') [$(txt $c 'CreateField_Type')] partition by $(csv $c 'GroupByFields/Field')" }
        "Join"              { joinDesc $c }
        "JoinMultiple"      { $mode = if ((attr $c "OutputJoinOnly" "value") -eq "True") { "inner only" } else { "full outer" }
                              "JoinMultiple ($mode) on " + (@($c.SelectNodes("JoinInfo") | ForEach-Object { "$($_.GetAttribute('connection')): $(csv $_ 'Field')" }) -join "; ") }
        "AppendFields"      { "AppendFields (cross join)" }
        "Union"             { $keep = txt $c "ByName_OutputMode"; if (-not $keep) { $keep = "All" }
                              "Union (UNION ALL) $(txt $c 'Mode'), keep $keep columns" }
        "Summarize"         { $sf = $c.SelectNodes("SummarizeFields/SummarizeField")
                              $gb = @($sf | Where-Object { $_.GetAttribute("action") -eq "GroupBy" } | ForEach-Object { $_.GetAttribute("field") }) -join ", "
                              $ag = @($sf | Where-Object { $_.GetAttribute("action") -ne "GroupBy" } | ForEach-Object {
                                  "$($_.GetAttribute('action'))($($_.GetAttribute('field'))) as $($_.GetAttribute('rename'))" }) -join ", "
                              "Summarize group by ${gb}: $ag" }
        "Sort"              { "Sort by " + (@($c.SelectNodes("SortInfo/Field") | ForEach-Object { "$($_.GetAttribute('field')) $($_.GetAttribute('order'))" }) -join ", ") }
        "Unique"            { "Unique on $(csv $c 'UniqueFields/Field') (first row per key wins)" }
        "Sample"            { "Sample $(txt $c 'Mode') $(txt $c 'N') per $(csv $c 'GroupFields/Field')" }
        "RecordID"          { $f = txt $c "FieldName"; if (-not $f) { $f = "RecordID" }; "RecordID -> $f" }
        "RunningTotal"      { "RunningTotal of $(csv $c 'RunningTotalFields/Field') per $(csv $c 'GroupByFields/Field')" }
        "CrossTab"          { "CrossTab pivot $(txt $c 'DataField' 'field') by $(txt $c 'HeaderField' 'field') ($(csv $c 'Methods/Method' 'method')) group by $(csv $c 'GroupFields/Field')" }
        "Transpose"         { "Transpose keep $(csv $c 'KeyFields/Field'), unpivot $(csv $c "DataFields/Field[not(@selected='False')]")" }
        "TextToColumns"     { "TextToColumns $(txt $c 'Field') on '$(txt $c 'Delimeters')' -> $(txt $c 'NumFields') columns" }
        "RegEx"             { "RegEx $(txt $c 'Method') $(txt $c 'Field'): $(txt $c 'RegExExpression')" + (opt "-> " (txt $c "ReplaceExpression")) }
        "GenerateRows"      { $f = txt $c "CreateField_Name"; if (-not $f) { $f = txt $c "UpdateField_Name" }
                              "GenerateRows ${f}: init $(txt $c 'Expression_Init'); while $(txt $c 'Expression_Cond'); step $(txt $c 'Expression_Loop')" }
        "Macro:*"           { $v = @($c.SelectNodes("Value") | ForEach-Object { "$($_.GetAttribute('name'))=$($_.InnerText)" }) -join ", "
                              "$tool {$v}" }
        default             { "$tool (UNKNOWN TOOL) " + ($c.OuterXml -replace '>\s+<', '><') }     # drop indentation between tags only
    }
}


# ---------- read the file ----------

function cols($n) {                              # last-run output schema; multi-output tools have one MetaInfo per anchor
    $blocks = @($n.SelectNodes("Properties/MetaInfo") | Where-Object { $_.SelectSingleNode("RecordInfo/Field") })
    @(foreach ($m in $blocks) {
        $(if ($blocks.Count -gt 1) { "$($m.GetAttribute('connection')): " }) +
        (@($m.SelectNodes("RecordInfo/Field") | ForEach-Object { "$($_.GetAttribute('name')):$($_.GetAttribute('type'))" }) -join ", ")
    }) -join "; "
}

function addLink($table, $key, $id) { if (-not $table[$key]) { $table[$key] = @() }; $table[$key] += $id }

function parse($path) {
    # returns title, params, nodes.  nodes[id] = @{ tool, cfg, note, cols, off, inputs: {anchor: [ids]}, outputs: {anchor: [ids]} }
    $xml = New-Object System.Xml.XmlDocument
    $xml.Load((Resolve-Path $path).Path)
    $root = $xml.DocumentElement
    $nodes = @{}

    function walk($parent, $off) {                                  # recurse into tool containers
        foreach ($n in $parent.SelectNodes("Node")) {
            $cfg = $n.SelectSingleNode("Properties/Configuration"); if (-not $cfg) { $cfg = $xml.CreateElement("Configuration") }
            $plugin = attr $n "GuiSettings" "Plugin"
            $macro = attr $n "EngineSettings" "Macro"                       # may be a full path
            $tool = if ($macro) { "Macro:" + (($macro -split '[\\/]')[-1] -replace '\.[^.]*$', '') } else { ($plugin -split '\.')[-1] }
            if (-not $tool) { $tool = "Unknown" }
            $nodes[[int]$n.GetAttribute("ToolID")] = @{
                tool = $tool; cfg = $cfg; off = $off; inputs = [ordered]@{}; outputs = [ordered]@{}
                note = (txt $n "Properties/Annotation/AnnotationText").Trim()
                cols = cols $n
            }
            $child = $n.SelectSingleNode("ChildNodes")
            if ($child) { walk $child ($off -or ($null -ne $cfg.SelectSingleNode("Disabled[@value='True']"))) }
        }
    }
    walk $root.SelectSingleNode("Nodes") $false

    foreach ($c in $root.SelectNodes("Connections/Connection")) {
        $o = $c.SelectSingleNode("Origin"); $d = $c.SelectSingleNode("Destination")
        $src = [int]$o.GetAttribute("ToolID"); $dst = [int]$d.GetAttribute("ToolID")
        if ($nodes.ContainsKey($src) -and $nodes.ContainsKey($dst)) {
            $anchor = $c.GetAttribute("name"); if (-not $anchor) { $anchor = $d.GetAttribute("Connection") }   # Union inputs are #1, #2 ...
            addLink $nodes[$src].outputs $o.GetAttribute("Connection") $dst
            addLink $nodes[$dst].inputs $anchor $src
        }
    }

    $title = txt $root "Properties/MetaInfo/Name"; if (-not $title) { $title = $path }
    $params = @($root.SelectNodes("Properties/Constants/Constant[Namespace='User']") | ForEach-Object { "User.$(txt $_ 'Name')=$(txt $_ 'Value')" }) -join ", "
    @{ title = $title; params = $params; nodes = $nodes }
}

function order($nodes) {
    # Kahn's algorithm: a tool is ready once every tool feeding it has been placed
    $live = @{}; foreach ($id in $nodes.Keys) { if ($SKIP -notcontains $nodes[$id].tool -and -not $nodes[$id].off) { $live[$id] = $true } }
    $placed = @(); $done = @{}
    while ($placed.Count -lt $live.Count) {
        $ready = @($live.Keys | Where-Object { -not $done[$_] } | Sort-Object | Where-Object {
            $id = $_
            -not @($nodes[$id].inputs.Values | ForEach-Object { $_ } | Where-Object { $live[$_] -and -not $done[$_] }).Count
        })
        if (-not $ready) { Write-Error "cycle detected"; exit 1 }
        $placed += $ready; foreach ($id in $ready) { $done[$id] = $true }
    }
    @{ steps = $placed; live = $live }
}


# ---------- flags the SQL writer needs ----------

function lastSort($nodes, $tid) {                # nearest Sort tool upstream, if any
    foreach ($srcs in $nodes[$tid].inputs.Values) { foreach ($s in $srcs) {
        if ($nodes[$s].tool -eq "Sort") { return $s }
        $found = lastSort $nodes $s; if ($found) { return $found }
    } }
}

function flags($nodes, $tid) {
    $n = $nodes[$tid]; $t = $n.tool; $c = $n.cfg; $out = @()
    $dep = ($ORDER_DEPENDENT -contains $t) -or
           ($t -eq "Summarize" -and @($c.SelectNodes("SummarizeFields/SummarizeField[@action='First' or @action='Last' or @action='Concat']")).Count) -or
           ($t -eq "Join" -and $c.GetAttribute("joinByRecordPos") -eq "True") -or
           ($t -eq "Union" -and (txt $c "Mode") -eq "ByPos")
    if ($dep) { $s = lastSort $nodes $tid; $out += "ORDER-DEPENDENT" + $(if ($s) { " (last sort: [$s])" } else { " (no upstream sort)" }) }
    foreach ($srcs in $n.inputs.Values) { foreach ($s in $srcs) { if ($nodes[$s].off) { $out += "input from disabled [$s]" } } }
    $out
}


# ---------- print ----------

function links($table) {                         # "anchor:ids" per anchor; Union's #1, #2 ... in numeric order
    $keys = @($table.Keys)
    if ($keys.Count -and @($keys | Where-Object { $_ -notmatch '^#\d+$' }).Count -eq 0) { $keys = @($keys | Sort-Object { [int]$_.Substring(1) }) }
    @($keys | Where-Object { $table[$_] } | ForEach-Object { "$($_):$($table[$_] -join ',')" }) -join " "
}

$p = parse $Path
$o = order $p.nodes
$nodes = $p.nodes

$i = 0
$lines = foreach ($tid in $o.steps) {
    $i++; $n = $nodes[$tid]
    $outs = [ordered]@{}; foreach ($a in $n.outputs.Keys) { $outs[$a] = @($n.outputs[$a] | Where-Object { $o.live[$_] }) }
    $f = @(flags $nodes $tid)
    $line = "$i. [$tid] " + (oneLine (describe $n.tool $n.cfg))
    if ($n.inputs.Count) { $line += "   <- " + (links $n.inputs) }
    if (links $outs)     { $line += "   -> " + (links $outs) }
    if ($n.note)         { $line += "   // " + (oneLine $n.note) }
    if ($f.Count)        { $line += "   !! " + ($f -join "; ") }
    if ($n.cols)         { $line += "`n     last-run cols: $($n.cols)" }
    $line
}

$unknown = @($lines | Where-Object { $_ -match '\(UNKNOWN TOOL\)' }).Count
"# $($p.title)`ntools: $($o.steps.Count), not fully described: $unknown" + $(if ($p.params) { "`nparams: $($p.params)" }) + "`n"
$lines -join "`n"
$off = @($nodes.Keys | Sort-Object | Where-Object { $nodes[$_].off } | ForEach-Object { "[$_] $($nodes[$_].tool)" })
if ($off) { "`nskipped (disabled container): " + ($off -join ", ") }
