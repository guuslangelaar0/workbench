#!/usr/bin/env bash
# workbench architecture-drift assembler.
#
# Aligns AUTHORED INTENT (the C4 docs in .claude/architecture/) against EXTRACTED
# REALITY (graphify's GRAPH_REPORT.md) and prints a structured, model-readable
# comparison. It deliberately does NOT assert "this is drift" — graphify's
# god-nodes include framework/runtime noise (wasm shims, toasts) that legitimately
# does not belong in a C4 model, so a naive absent-from-docs=drift rule would cry
# wolf. The script gathers + aligns; the /workbench:architecture command's model
# judges which mismatches are real drift. Heuristic name-matching is labeled as a
# hint, never a verdict.
#
# Dev-time tooling: python3 parses the docs + report (not on init.sh's
# python-free scaffold path, same as drift.sh / validate-plugin.sh).
#
# Usage: arch-drift.sh [project-dir]   (default: $PWD)
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
P="${1:-$PWD}"; P="${P%/}"; [ -n "$P" ] || P="/"

ARCH="$P/.claude/architecture"
if [ ! -d "$ARCH" ]; then
  echo "arch-drift: no architecture backbone at $ARCH" >&2
  echo "  (this level's 'architecture' dial may be 'none' — /workbench:level up enables it)" >&2
  exit 2
fi

# Collect graph reports: project root + one level down (multi-repo / fleet).
graphs=()
for g in "$P/graphify-out/GRAPH_REPORT.md" "$P"/*/graphify-out/GRAPH_REPORT.md "$P"/repos/*/graphify-out/GRAPH_REPORT.md; do
  [ -f "$g" ] && graphs+=("$g")
done

if [ "${#graphs[@]}" -eq 0 ]; then
  echo "workbench architecture drift — $P"
  echo ""
  echo "No extracted graph found (looked for graphify-out/GRAPH_REPORT.md at the root,"
  echo "one level down, and under repos/). The drift check is a MANUAL read against the"
  echo "authored docs until graphify is set up — enable the 'graphify' dial and run"
  echo "'graphify update .', then re-run this for an automated first pass."
  exit 0
fi

command -v python3 >/dev/null 2>&1 || { echo "arch-drift: python3 is required to align docs vs. graph but was not found on PATH." >&2; exit 3; }

python3 - "$P" "$ARCH" "${graphs[@]}" <<'PY'
import sys, os, re, glob

proj, arch = sys.argv[1], sys.argv[2]
reports = sys.argv[3:]

# ---- authored intent: declared containers + components from the C4 tables -------
# Tables look like:  | <name> | <responsibility> | ... |
# Skip the header row, the |---| separator, and template placeholder rows (<name>).
def declared(path):
    names = []
    if not os.path.exists(path):
        return names
    for line in open(path, encoding="utf-8", errors="replace"):
        s = line.strip()
        if not s.startswith("|"):
            continue
        cells = [c.strip() for c in s.strip("|").split("|")]
        if not cells:
            continue
        first = cells[0]
        low = first.lower()
        if not first or set(first) <= set("-: "):          # separator row
            continue
        if low in ("container", "component", "module", "name"):  # header row
            continue
        if first.startswith("<") and first.endswith(">"):   # unfilled placeholder
            continue
        names.append(first.strip("`* "))
    return names

containers = declared(os.path.join(arch, "containers.md"))
components = declared(os.path.join(arch, "components.md"))

# full authored text, for "does this extracted name appear anywhere in the docs?"
doc_text = ""
for md in sorted(glob.glob(os.path.join(arch, "*.md"))):
    doc_text += open(md, encoding="utf-8", errors="replace").read().lower() + "\n"
doc_nospace = re.sub(r"[^a-z0-9]", "", doc_text)   # word boundaries dropped, for multi-word names

# generic programming/English tokens that must NOT count as a name match on their own
STOP = {"get","set","the","and","for","with","from","this","that","has","new","var",
        "let","out","all","any","via","per","not","but","its","into","onto","use","run",
        "add","data","view","item","list","obj","val","str","num","len","key","def","pass"}

def tokens(s):
    return set(t for t in re.split(r"[^a-z0-9]+", s.lower()) if len(t) >= 3 and t not in STOP)

doc_tokens = set(t for t in re.split(r"[^a-z0-9]+", doc_text) if len(t) >= 3)  # unfiltered, for exact match

# A god-node is "named in the docs" only on a STRONG match: its full normalized
# identifier appears as a whole doc token, or (for distinctive names) contiguously
# in the space-stripped text. Fragment/stopword matches (get, with, data) do NOT
# count — that is what made wasm runtime shims look documented.
def named_in_docs(disp):
    ident = re.sub(r"\(.*$", "", disp)                  # request() -> request ; SyncClient stays
    norm = re.sub(r"[^a-z0-9]", "", ident.lower())      # encryptedUpload -> encryptedupload
    if len(norm) < 3:
        return False
    if norm in doc_tokens:
        return True
    if len(norm) >= 5 and norm in doc_nospace:          # catches "Sync Client" -> syncclient
        return True
    return False

# ---- extracted reality: god-nodes (+ a summary) from each graph report ----------
god = {}        # identifier-token -> (display, max_edges, source)
summary_bits = []
god_re = re.compile(r"^\s*\d+\.\s*`([^`]+)`\s*-\s*(\d+)\s*edges", re.I)
sum_re = re.compile(r"(\d+)\s*nodes.*?(\d+)\s*communities", re.I)

for rep in reports:
    rel = os.path.relpath(rep, proj)
    in_god = False
    for line in open(rep, encoding="utf-8", errors="replace"):
        if line.startswith("## "):
            in_god = line.lower().startswith("## god nodes")
            continue
        m = sum_re.search(line)
        if m and "node" in line.lower():
            summary_bits.append(f"{rel}: {m.group(1)} nodes, {m.group(2)} communities")
        if in_god:
            g = god_re.match(line)
            if g:
                disp, edges = g.group(1), int(g.group(2))
                ident = re.sub(r"\(.*$", "", disp).strip()          # request() -> request
                key = re.sub(r"[^a-z0-9]+", "", ident.lower())
                if not key:
                    continue
                prev = god.get(key)
                if prev is None or edges > prev[1]:
                    god[key] = (disp, edges, rel)

god_sorted = sorted(god.items(), key=lambda kv: -kv[1][1])

# ---- emit ----------------------------------------------------------------------
print(f"workbench architecture drift — {proj}")
print("authored: " + ", ".join(os.path.basename(p) for p in sorted(glob.glob(os.path.join(arch, '*.md')))))
if summary_bits:
    print("extracted: " + " | ".join(summary_bits))
print()

print("## Declared in your C4 docs (authored intent)")
print("  containers: " + (", ".join(containers) if containers else "(none filled in — only template placeholders)"))
print("  components: " + (", ".join(components) if components else "(none filled in — only template placeholders)"))
print()

print("## graphify's core abstractions (god-nodes) vs. your docs")
print("  named?  edges  abstraction")
documented = 0
for key, (disp, edges, src) in god_sorted:
    named = named_in_docs(disp)
    documented += 1 if named else 0
    print(f"  {'yes' if named else 'no ':4s}   {edges:5d}  {disp}")
if not god_sorted:
    print("  (no god-nodes parsed from the report)")
print()
print('  ("no" means the name is absent from your C4 docs. That can be real drift —')
print("   a core abstraction you never documented — OR runtime/framework noise (wasm")
print("   shims, UI toasts) that does not belong in a C4 model. Judge each on merit.)")
print()

# declared components whose tokens never show up among the god-nodes (heuristic)
god_tok = set()
for key, (disp, e, s) in god.items():
    god_tok |= tokens(re.sub(r"\(.*$", "", disp))
orphans = [c for c in components if not (tokens(c) & god_tok)]
print("## Declared components with no token match among god-nodes (heuristic — verify)")
if orphans:
    for o in orphans:
        print(f"  - {o}  (pure intent, not-yet-built, or just not a hub — confirm before filing)")
else:
    print("  (every declared component token-matches at least one extracted abstraction)")
print()

ng = len(god_sorted)
print(f"## Heuristic read: {documented}/{ng} god-nodes are named in your docs; "
      f"{len(orphans)} declared component(s) have no extracted token-match.")
print("Name-matching is a heuristic HINT, not a verdict. Reconcile real drift as a task;")
print("ignore runtime/framework noise. Drift is a signal — surface it, don't fake it.")
PY
