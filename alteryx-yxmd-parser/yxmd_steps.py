"""Print the steps of an Alteryx .yxmd workflow in execution order, one line per tool.

    python yxmd_steps.py flow.yxmd > steps.md

    N. [id] what it does   <- inputs   -> outputs   // annotation   !! flags

Order: a tool is listed once every tool feeding it is listed; ties go to the lower tool id.
"""
import re
import sys
import xml.etree.ElementTree as ET

SKIP = {"BrowseV2", "Browse", "TextBox", "ToolContainer"}                            # tools with no effect on data
ORDER_DEPENDENT = {"Unique", "Sample", "MultiRowFormula", "RunningTotal", "RecordID"}   # result depends on incoming row order


# ---------- helpers for reading a tool's <Configuration> ----------

def txt(el, path, attr=None):                   # an element's attribute if given, else its text (Alteryx uses both)
    n = el.find(path)
    return "" if n is None else ((attr and n.get(attr)) or n.text or "")

def attr(el, path, a):                          # one attribute, "" if absent
    n = el.find(path)
    return "" if n is None else (n.get(a) or "")

def vals(el, path, a="field"):          return [f.get(a) or f.get("name") or f.text or "" for f in el.findall(path)]
def csv(el, path, a="field"):           return ", ".join(vals(el, path, a))
def one_line(s):                        return s.replace("\r", "").replace("\n", "\\n")
def mask(s):                            return re.sub(r"(pwd|password)=[^;|]*", r"\1=***", s, flags=re.I)   # credentials in connection strings
def opt(label, value):                  return f" [{label}{value}]" if value else ""

def select_parts(el, path="SelectFields/SelectField"):      # used by Select and Join
    out = ["reordered"] if el.find("OrderChanged[@value='True']") is not None else []
    for f in el.findall(path):
        name, keep = f.get("field"), f.get("selected") != "False"
        if name == "*Unknown":      out.append(("keep" if keep else "drop") + " unlisted")
        elif not keep:              out.append(f"drop {name}")
        else:
            if f.get("rename"):     out.append(f"rename {name}->{f.get('rename')}")
            if f.get("type"):       out.append(f"cast {name} {f.get('type')}({f.get('size')})")
    return "; ".join(out)

def join_desc(c):
    sel = c.find("SelectConfiguration/Configuration")
    keys = ("by record position" if c.get("joinByRecordPos") == "True" else "on " + ", ".join(
            f"{l} = {r}" for l, r in zip(vals(c, "JoinInfo[@connection='Left']/Field"), vals(c, "JoinInfo[@connection='Right']/Field"))))
    return f"Join {keys}; " + select_parts(sel if sel is not None else c)

def multirow_name(c):                           # CreateField_Name keeps a default even in update mode, so check the flag
    update = c.find("UpdateField[@value='True']") is not None
    return txt(c, "UpdateField_Name" if update else "CreateField_Name")


# ---------- one line per tool type ----------

DESCRIBE = {
    "DbFileInput":       lambda c: "Input " + mask(txt(c, "File")) + opt("RecordLimit=", attr(c, "File", "RecordLimit")),
    "DbFileOutput":      lambda c: "Output " + mask(txt(c, "File")) + opt("", txt(c, "FormatSpecificOptions/OutputMode")),
    "TextInput":         lambda c: f"TextInput ({csv(c, 'Fields/Field', 'name')}): "
                                   + "; ".join(", ".join(x.text or "" for x in r) for r in c.findall("Data/r")),
    "AlteryxSelect":     lambda c: "Select: " + select_parts(c),
    "Filter":            lambda c: "Filter: " + txt(c, "Expression"),
    "Formula":           lambda c: "Formula: " + "; ".join(f"{f.get('field')} = {f.get('expression')} [{f.get('type')}({f.get('size', '')})]"
                                                           for f in c.findall("FormulaFields/FormulaField")),
    "MultiFieldFormula": lambda c: f"MultiFieldFormula {txt(c, 'Expression')} on {csv(c, 'Fields/Field')}",
    "MultiRowFormula":   lambda c: f"MultiRow: {multirow_name(c)} = {txt(c, 'Expression')} [{txt(c, 'CreateField_Type')}] "
                                   f"partition by {csv(c, 'GroupByFields/Field')}",
    "Join":              join_desc,
    "JoinMultiple":      lambda c: f"JoinMultiple ({'inner only' if attr(c, 'OutputJoinOnly', 'value') == 'True' else 'full outer'}) on "
                                   + "; ".join(f"{j.get('connection')}: {csv(j, 'Field')}" for j in c.findall("JoinInfo")),
    "AppendFields":      lambda c: "AppendFields (cross join)",
    "Union":             lambda c: f"Union (UNION ALL) {txt(c, 'Mode')}, keep {txt(c, 'ByName_OutputMode') or 'All'} columns",
    "Summarize":         lambda c: "Summarize group by "
                                   + ", ".join(f.get("field") for f in c.findall("SummarizeFields/SummarizeField") if f.get("action") == "GroupBy")
                                   + ": " + ", ".join(f"{f.get('action')}({f.get('field')}) as {f.get('rename')}"
                                                      for f in c.findall("SummarizeFields/SummarizeField") if f.get("action") != "GroupBy"),
    "Sort":              lambda c: "Sort by " + ", ".join(f"{f.get('field')} {f.get('order')}" for f in c.findall("SortInfo/Field")),
    "Unique":            lambda c: f"Unique on {csv(c, 'UniqueFields/Field')} (first row per key wins)",
    "Sample":            lambda c: f"Sample {txt(c, 'Mode')} {txt(c, 'N')} per {csv(c, 'GroupFields/Field')}",
    "RecordID":          lambda c: f"RecordID -> {txt(c, 'FieldName') or 'RecordID'}",
    "RunningTotal":      lambda c: f"RunningTotal of {csv(c, 'RunningTotalFields/Field')} per {csv(c, 'GroupByFields/Field')}",
    "CrossTab":          lambda c: f"CrossTab pivot {txt(c, 'DataField', 'field')} by {txt(c, 'HeaderField', 'field')} "
                                   f"({csv(c, 'Methods/Method', 'method')}) group by {csv(c, 'GroupFields/Field')}",
    "Transpose":         lambda c: f"Transpose keep {csv(c, 'KeyFields/Field')}, unpivot "
                                   + ", ".join(f.get("field") for f in c.findall("DataFields/Field") if f.get("selected") != "False"),
    "TextToColumns":     lambda c: f"TextToColumns {txt(c, 'Field')} on '{txt(c, 'Delimeters')}' -> {txt(c, 'NumFields')} columns",
    "RegEx":             lambda c: f"RegEx {txt(c, 'Method')} {txt(c, 'Field')}: {txt(c, 'RegExExpression')}" + opt("-> ", txt(c, "ReplaceExpression")),
    "GenerateRows":      lambda c: f"GenerateRows {txt(c, 'CreateField_Name') or txt(c, 'UpdateField_Name')}: init {txt(c, 'Expression_Init')}; "
                                   f"while {txt(c, 'Expression_Cond')}; step {txt(c, 'Expression_Loop')}",
}

def describe(tool, c):
    if tool in DESCRIBE:          return DESCRIBE[tool](c)
    if tool.startswith("Macro:"): return f"{tool} " + str({v.get("name"): v.text for v in c.findall("Value")})
    raw = re.sub(r">\s+<", "><", ET.tostring(c, encoding="unicode"))     # drop indentation between tags only
    return f"{tool} (UNKNOWN TOOL) {raw}"


# ---------- read the file ----------

def cols(n):                                    # last-run output schema; multi-output tools have one MetaInfo per anchor
    blocks = [m for m in n.findall("Properties/MetaInfo") if m.find("RecordInfo/Field") is not None]
    return "; ".join((f"{m.get('connection')}: " if len(blocks) > 1 else "")
                     + ", ".join(f"{f.get('name')}:{f.get('type')}" for f in m.findall("RecordInfo/Field")) for m in blocks)

def parse(path):
    """Return (title, params, nodes). nodes[id] = {tool, cfg, note, cols, off, in: {anchor: [ids]}, out: {anchor: [ids]}}"""
    root, nodes = ET.parse(path).getroot(), {}

    def walk(parent, off=False):                          # recurse into tool containers
        for n in parent.findall("Node"):
            cfg = n.find("Properties/Configuration")
            cfg = cfg if cfg is not None else ET.Element("Configuration")
            gui, eng = n.find("GuiSettings"), n.find("EngineSettings")
            plugin = gui.get("Plugin", "") if gui is not None else ""
            macro = eng.get("Macro") if eng is not None else None            # may be a full path
            nodes[int(n.get("ToolID"))] = {
                "tool": "Macro:" + macro.replace("\\", "/").rsplit("/", 1)[-1].rsplit(".", 1)[0] if macro
                        else plugin.rsplit(".", 1)[-1] or "Unknown",
                "cfg": cfg, "off": off, "in": {}, "out": {},
                "note": txt(n, "Properties/Annotation/AnnotationText").strip(),
                "cols": cols(n),
            }
            if n.find("ChildNodes") is not None:
                walk(n.find("ChildNodes"), off or cfg.find("Disabled[@value='True']") is not None)
    walk(root.find("Nodes"))

    for c in root.findall("Connections/Connection"):
        o, d = c.find("Origin"), c.find("Destination")
        src, dst = int(o.get("ToolID")), int(d.get("ToolID"))
        if src in nodes and dst in nodes:
            nodes[src]["out"].setdefault(o.get("Connection"), []).append(dst)
            nodes[dst]["in"].setdefault(c.get("name") or d.get("Connection"), []).append(src)   # Union inputs are #1, #2 ...

    params = ", ".join(f"User.{txt(c, 'Name')}={txt(c, 'Value')}"
                       for c in root.findall("Properties/Constants/Constant") if txt(c, "Namespace") == "User")
    return txt(root, "Properties/MetaInfo/Name") or path, params, nodes


def order(nodes):
    """Kahn's algorithm: a tool is ready once every tool feeding it has been placed."""
    live = {i for i, n in nodes.items() if n["tool"] not in SKIP and not n["off"]}
    placed, done = [], set()
    while len(placed) < len(live):
        ready = [i for i in sorted(live - done)
                 if all(s in done or s not in live for srcs in nodes[i]["in"].values() for s in srcs)]
        if not ready: sys.exit("cycle detected")
        placed += ready; done |= set(ready)
    return placed, live


# ---------- flags the SQL writer needs ----------

def last_sort(nodes, tid):                      # nearest Sort tool upstream, if any
    for srcs in nodes[tid]["in"].values():
        for s in srcs:
            if nodes[s]["tool"] == "Sort": return s
            found = last_sort(nodes, s)
            if found: return found

def flags(nodes, tid):
    n, out = nodes[tid], []
    t, c = n["tool"], n["cfg"]
    dep = (t in ORDER_DEPENDENT
           or (t == "Summarize" and any(f.get("action") in ("First", "Last", "Concat") for f in c.findall("SummarizeFields/SummarizeField")))
           or (t == "Join" and c.get("joinByRecordPos") == "True")
           or (t == "Union" and txt(c, "Mode") == "ByPos"))
    if dep:
        s = last_sort(nodes, tid)
        out.append("ORDER-DEPENDENT" + (f" (last sort: [{s}])" if s else " (no upstream sort)"))
    out += [f"input from disabled [{s}]" for srcs in n["in"].values() for s in srcs if nodes[s]["off"]]
    return out


# ---------- print ----------

def links(d):                                   # "anchor:ids" per anchor; Union's #1, #2 ... in numeric order
    items = sorted(d.items(), key=lambda kv: int(kv[0][1:])) if all(k[:1] == "#" and k[1:].isdigit() for k in d) else d.items()
    return " ".join(f"{a}:{','.join(map(str, ids))}" for a, ids in items if ids)

def main(path):
    title, params, nodes = parse(path)
    steps, live = order(nodes)

    lines = []
    for i, tid in enumerate(steps, 1):
        n = nodes[tid]
        outs = {a: [d for d in ids if d in live] for a, ids in n["out"].items()}
        line = f"{i}. [{tid}] {one_line(describe(n['tool'], n['cfg']))}"
        if n["in"]:             line += f"   <- {links(n['in'])}"
        if any(outs.values()):  line += f"   -> {links(outs)}"
        if n["note"]:           line += f"   // {one_line(n['note'])}"
        if flags(nodes, tid):   line += f"   !! {'; '.join(flags(nodes, tid))}"
        if n["cols"]:           line += f"\n     last-run cols: {n['cols']}"
        lines.append(line)

    unknown = sum("(UNKNOWN TOOL)" in l for l in lines)
    print(f"# {title}\ntools: {len(steps)}, not fully described: {unknown}" + (f"\nparams: {params}" if params else "") + "\n")
    print("\n".join(lines))
    off = [f"[{i}] {n['tool']}" for i, n in sorted(nodes.items()) if n["off"]]
    if off: print("\nskipped (disabled container):", ", ".join(off))


if __name__ == "__main__":
    main(sys.argv[1])
