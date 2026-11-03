<#
Print the steps of an Alteryx .yxmd workflow in execution order, one line per tool.
Works in Windows PowerShell 5.1 (built into Windows) and PowerShell 7. No admin, no installs.

    powershell -ExecutionPolicy Bypass -File yxmd_steps.ps1 flow.yxmd | Out-File steps.md -Encoding utf8

    N. [id] what it does   <- inputs   -> outputs   // annotation
#>
param([Parameter(Mandatory)][string]$Path)

$SKIP = @("BrowseV2", "Browse", "TextBox", "ToolContainer")   # tools with no effect on data


# ---------- helpers for reading a tool's <Configuration> ----------

function txt($el, $xpath)                 { $n = $el.SelectSingleNode($xpath); if ($n) { $n.InnerText } else { "" } }
function vals($el, $xpath, $attr = "field") { @($el.SelectNodes($xpath) | ForEach-Object { $_.GetAttribute($attr) }) }
function csv($el, $xpath, $attr = "field")  { (vals $el $xpath $attr) -join ", " }

function selectParts($el, $xpath = "SelectFields/SelectField") {      # used by Select and Join
    $out = foreach ($f in $el.SelectNodes($xpath)) {
        $name = $f.GetAttribute("field"); $keep = $f.GetAttribute("selected") -ne "False"
        if ($name -eq "*Unknown") { if ($keep) { "keep unlisted" } else { "drop unlisted" } } elseif (-not $keep) { "drop $name" } else {
            if ($f.GetAttribute("rename")) { "rename ${name}->$($f.GetAttribute('rename'))" }
            if ($f.GetAttribute("type"))   { "cast $name $($f.GetAttribute('type'))($($f.GetAttribute('size')))" }
        }
    }
    $out -join "; "
}


# ---------- one line per tool type ----------

function describe($tool, $c) {
    switch -Wildcard ($tool) {
        "DbFileInput"     { "Input " + (txt $c "File") }
        "DbFileOutput"    { "Output " + (txt $c "File") }
        "TextInput"       { $rows = foreach ($r in $c.SelectNodes("Data/r")) { @($r.SelectNodes("c") | ForEach-Object { $_.InnerText }) -join ", " }
                            "TextInput ($(csv $c 'Fields/Field' 'name')): " + ($rows -join "; ") }
        "AlteryxSelect"   { "Select: " + (selectParts $c) }
        "Filter"          { "Filter: " + (txt $c "Expression") }
        "Formula"         { "Formula: " + (@($c.SelectNodes("FormulaFields/FormulaField") | ForEach-Object {
                                "$($_.GetAttribute('field')) = $($_.GetAttribute('expression'))" }) -join "; ") }
        "MultiRowFormula" { $name = txt $c "CreateField_Name"; if (-not $name) { $name = txt $c "UpdateField_Name" }
                            "MultiRow: $name = $(txt $c 'Expression') partition by $(csv $c 'GroupByFields/Field')" }
        "Join"            { $l = @(vals $c "JoinInfo[@connection='Left']/Field"); $r = @(vals $c "JoinInfo[@connection='Right']/Field")
                            $keys = for ($i = 0; $i -lt $l.Count; $i++) { "$($l[$i]) = $($r[$i])" }
                            "Join on $($keys -join ', '); " + (selectParts $c "SelectConfiguration/Configuration/SelectFields/SelectField") }
        "JoinMultiple"    { "JoinMultiple on " + (@($c.SelectNodes("JoinInfo") | ForEach-Object { "$($_.GetAttribute('connection')): $(csv $_ 'Field')" }) -join "; ") }
        "AppendFields"    { "AppendFields (cross join)" }
        "Union"           { $mode = txt $c "ByName_OutputMode"; if (-not $mode) { $mode = "All" }
                            "Union $(txt $c 'Mode'), keep $mode columns" }
        "Summarize"       { $sf = $c.SelectNodes("SummarizeFields/SummarizeField")
                            $gb = @($sf | Where-Object { $_.GetAttribute("action") -eq "GroupBy" } | ForEach-Object { $_.GetAttribute("field") }) -join ", "
                            $ag = @($sf | Where-Object { $_.GetAttribute("action") -ne "GroupBy" } | ForEach-Object {
                                "$($_.GetAttribute('action'))($($_.GetAttribute('field'))) as $($_.GetAttribute('rename'))" }) -join ", "
                            "Summarize group by ${gb}: $ag" }
        "Sort"            { "Sort by " + (@($c.SelectNodes("SortInfo/Field") | ForEach-Object { "$($_.GetAttribute('field')) $($_.GetAttribute('order'))" }) -join ", ") }
        "Unique"          { "Unique on $(csv $c 'UniqueFields/Field') (first row per key wins)" }
        "Sample"          { "Sample $(txt $c 'Mode') $(txt $c 'N') per $(csv $c 'GroupFields/Field')" }
        "RecordID"        { $f = txt $c "FieldName"; if (-not $f) { $f = "RecordID" }; "RecordID -> $f" }
        "RunningTotal"    { "RunningTotal of $(csv $c 'RunningTotalFields/Field') per $(csv $c 'GroupByFields/Field')" }
        "CrossTab"        { $m = @($c.SelectNodes("Methods/Method") | ForEach-Object { $_.InnerText }) -join ", "
                            "CrossTab pivot $(txt $c 'DataField') by $(txt $c 'HeaderField') ($m) group by $(csv $c 'GroupFields/Field')" }
        "Transpose"       { "Transpose keep $(csv $c 'KeyFields/Field'), unpivot $(csv $c 'DataFields/Field')" }
        "Macro:*"         { $v = @($c.SelectNodes("Value") | ForEach-Object { "$($_.GetAttribute('name'))=$($_.InnerText)" }) -join ", "
                            "$tool {$v}" }
        default           { $raw = $c.OuterXml -replace '\s+', ' '
                            "$tool (UNKNOWN TOOL) " + $raw.Substring(0, [Math]::Min(400, $raw.Length)) }
    }
}


# ---------- read the file ----------

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
            $eng = $n.SelectSingleNode("EngineSettings"); $macro = if ($eng) { $eng.GetAttribute("Macro") } else { "" }
            $plugin = $n.SelectSingleNode("GuiSettings").GetAttribute("Plugin")
            $tool = if ($macro) { "Macro:" + ($macro -replace '\.[^.]*$', '') } else { ($plugin -split '\.')[-1] }
            $nodes[[int]$n.GetAttribute("ToolID")] = @{
                tool = $tool; cfg = $cfg; off = $off; inputs = [ordered]@{}; outputs = [ordered]@{}
                note = (txt $n "Properties/Annotation/AnnotationText").Trim()
                cols = @($n.SelectNodes("Properties/MetaInfo/RecordInfo/Field") | ForEach-Object { "$($_.GetAttribute('name')):$($_.GetAttribute('type'))" }) -join ", "
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
    $live = @($nodes.Keys | Where-Object { $SKIP -notcontains $nodes[$_].tool -and -not $nodes[$_].off })
    $placed = @()
    while ($placed.Count -lt $live.Count) {
        $ready = @($live | Where-Object { $placed -notcontains $_ } | Sort-Object | Where-Object {
            $id = $_
            $waiting = @($nodes[$id].inputs.Values | ForEach-Object { $_ } | Where-Object { $live -contains $_ -and $placed -notcontains $_ })
            $waiting.Count -eq 0
        })
        if (-not $ready) { Write-Error "cycle detected"; exit 1 }
        $placed += $ready
    }
    @{ steps = $placed; live = $live }
}


# ---------- print ----------

function links($table) { @($table.Keys | Where-Object { $table[$_] } | ForEach-Object { "$($_):$($table[$_] -join ',')" }) -join " " }

$p = parse $Path
$o = order $p.nodes
$nodes = $p.nodes

"# $($p.title)" + $(if ($p.params) { "`nparams: $($p.params)" }) + "`n"
$i = 0
foreach ($tid in $o.steps) {
    $i++; $n = $nodes[$tid]
    $outs = [ordered]@{}; foreach ($a in $n.outputs.Keys) { $outs[$a] = @($n.outputs[$a] | Where-Object { $o.live -contains $_ }) }
    $line = "$i. [$tid] " + (describe $n.tool $n.cfg)
    if ($n.inputs.Count) { $line += "   <- " + (links $n.inputs) }
    if (links $outs)     { $line += "   -> " + (links $outs) }
    if ($n.note)         { $line += "   // $($n.note)" }
    if ($n.cols)         { $line += "`n     cols: $($n.cols)" }
    $line
}
$off = @($nodes.Keys | Sort-Object | Where-Object { $nodes[$_].off } | ForEach-Object { "[$_] $($nodes[$_].tool)" })
if ($off) { "`nskipped (disabled container): " + ($off -join ", ") }
