"""Print the steps of an Alteryx .yxmd workflow in execution order, one line per tool.

    python yxmd_steps.py flow.yxmd > steps.md

    N. [id] what it does   <- inputs   -> outputs   // annotation
"""
import sys
import xml.etree.ElementTree as ET

SKIP = {"BrowseV2", "Browse", "TextBox", "ToolContainer"}   # tools with no effect on data


# ---------- helpers for reading a tool's <Configuration> ----------

def txt(el, tag):                       return el.findtext(tag) or ""
def vals(el, path, attr="field"):       return [f.get(attr) for f in el.findall(path)]
def csv(el, path, attr="field"):        return ", ".join(vals(el, path, attr))

def select_parts(el, path="SelectFields/SelectField"):      # used by Select and Join
    out = []
    for f in el.findall(path):
        name, keep = f.get("field"), f.get("selected") != "False"
        if name == "*Unknown":      out.append(("keep" if keep else "drop") + " unlisted")
        elif not keep:              out.append(f"drop {name}")
        else:
            if f.get("rename"):     out.append(f"rename {name}->{f.get('rename')}")
            if f.get("type"):       out.append(f"cast {name} {f.get('type')}({f.get('size')})")
    return "; ".join(out)


# ---------- one line per tool type ----------

DESCRIBE = {
    "DbFileInput":     lambda c: "Input " + txt(c, "File"),
    "DbFileOutput":    lambda c: "Output " + txt(c, "File"),
    "TextInput":       lambda c: f"TextInput ({csv(c, 'Fields/Field', 'name')}): "
                                 + "; ".join(", ".join(x.text or "" for x in r) for r in c.findall("Data/r")),
    "AlteryxSelect":   lambda c: "Select: " + select_parts(c),
    "Filter":          lambda c: "Filter: " + txt(c, "Expression"),
    "Formula":         lambda c: "Formula: " + "; ".join(f"{f.get('field')} = {f.get('expression')}"
                                                         for f in c.findall("FormulaFields/FormulaField")),
    "MultiRowFormula": lambda c: f"MultiRow: {txt(c, 'CreateField_Name') or txt(c, 'UpdateField_Name')} = "
                                 f"{txt(c, 'Expression')} partition by {csv(c, 'GroupByFields/Field')}",
    "Join":            lambda c: "Join on " + ", ".join(f"{l} = {r}" for l, r in zip(
                                     vals(c, "JoinInfo[@connection='Left']/Field"),
                                     vals(c, "JoinInfo[@connection='Right']/Field")))
                                 + "; " + select_parts(c, "SelectConfiguration/Configuration/SelectFields/SelectField"),
    "JoinMultiple":    lambda c: "JoinMultiple on " + "; ".join(f"{j.get('connection')}: {csv(j, 'Field')}"
                                                                for j in c.findall("JoinInfo")),
    "AppendFields":    lambda c: "AppendFields (cross join)",
    "Union":           lambda c: f"Union {txt(c, 'Mode')}, keep {txt(c, 'ByName_OutputMode') or 'All'} columns",
    "Summarize":       lambda c: "Summarize group by "
                                 + ", ".join(f.get("field") for f in c.findall("SummarizeFields/SummarizeField") if f.get("action") == "GroupBy")
                                 + ": " + ", ".join(f"{f.get('action')}({f.get('field')}) as {f.get('rename')}"
                                                    for f in c.findall("SummarizeFields/SummarizeField") if f.get("action") != "GroupBy"),
    "Sort":            lambda c: "Sort by " + ", ".join(f"{f.get('field')} {f.get('order')}" for f in c.findall("SortInfo/Field")),
    "Unique":          lambda c: f"Unique on {csv(c, 'UniqueFields/Field')} (first row per key wins)",
    "Sample":          lambda c: f"Sample {txt(c, 'Mode')} {txt(c, 'N')} per {csv(c, 'GroupFields/Field')}",
    "RecordID":        lambda c: f"RecordID -> {txt(c, 'FieldName') or 'RecordID'}",
    "RunningTotal":    lambda c: f"RunningTotal of {csv(c, 'RunningTotalFields/Field')} per {csv(c, 'GroupByFields/Field')}",
    "CrossTab":        lambda c: f"CrossTab pivot {txt(c, 'DataField')} by {txt(c, 'HeaderField')} "
                                 f"({', '.join(m.text for m in c.findall('Methods/Method'))}) group by {csv(c, 'GroupFields/Field')}",
    "Transpose":       lambda c: f"Transpose keep {csv(c, 'KeyFields/Field')}, unpivot {csv(c, 'DataFields/Field')}",
}

def describe(tool, c):
    if tool in DESCRIBE:          return DESCRIBE[tool](c)
    if tool.startswith("Macro:"): return f"{tool} " + str({v.get("name"): v.text for v in c.findall("Value")})
    return f"{tool} (UNKNOWN TOOL) " + " ".join(ET.tostring(c, encoding="unicode").split())[:400]


# ---------- read the file ----------

def parse(path):
    """Return (title, params, nodes). nodes[id] = {tool, cfg, note, cols, off, in: {anchor: [ids]}, out: {anchor: [ids]}}"""
    root, nodes = ET.parse(path).getroot(), {}

    def walk(parent, off=False):                          # recurse into tool containers
        for n in parent.findall("Node"):
            cfg = n.find("Properties/Configuration")
            cfg = cfg if cfg is not None else ET.Element("Configuration")
            eng = n.find("EngineSettings")
            macro = eng.get("Macro") if eng is not None else None
            nodes[int(n.get("ToolID"))] = {
                "tool": "Macro:" + macro.rsplit(".", 1)[0] if macro else n.find("GuiSettings").get("Plugin", "").rsplit(".", 1)[-1],
                "cfg": cfg, "off": off, "in": {}, "out": {},
                "note": txt(n, "Properties/Annotation/AnnotationText").strip(),
                "cols": ", ".join(f"{f.get('name')}:{f.get('type')}" for f in n.findall("Properties/MetaInfo/RecordInfo/Field")),
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
    placed = []
    while len(placed) < len(live):
        ready = [i for i in sorted(live - set(placed))
                 if all(s in placed or s not in live for srcs in nodes[i]["in"].values() for s in srcs)]
        if not ready: sys.exit("cycle detected")
        placed += ready
    return placed, live


# ---------- print ----------

def main(path):
    title, params, nodes = parse(path)
    steps, live = order(nodes)
    links = lambda d: " ".join(f"{a}:{','.join(map(str, ids))}" for a, ids in d.items() if ids)

    print(f"# {title}" + (f"\nparams: {params}" if params else "") + "\n")
    for i, tid in enumerate(steps, 1):
        n = nodes[tid]
        outs = {a: [d for d in ids if d in live] for a, ids in n["out"].items()}
        line = f"{i}. [{tid}] {describe(n['tool'], n['cfg'])}"
        if n["in"]:             line += f"   <- {links(n['in'])}"
        if any(outs.values()):  line += f"   -> {links(outs)}"
        if n["note"]:           line += f"   // {n['note']}"
        if n["cols"]:           line += f"\n     cols: {n['cols']}"
        print(line)

    off = [f"[{i}] {n['tool']}" for i, n in nodes.items() if n["off"]]
    if off: print("\nskipped (disabled container):", ", ".join(off))


if __name__ == "__main__":
    main(sys.argv[1])
