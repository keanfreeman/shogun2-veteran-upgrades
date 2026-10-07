"""UI audit for Veteran Upgrades: which on-screen texts and tooltips in our panel are leftovers.

Build with VU_DEBUG=1, open the Veterans list and one unit type's tree in game, then run:
    python3 tools/vu_ui_audit.py [path/to/vu_log.txt]
The debug build logs each view once per session ("ui[list]", "ui[tree]", "ui[hud]" lines) after
the mod has set its own texts and tooltips. This report lists, per view, for components that are
actually shown (the component and all its parents visible):
  * tooltips that don't come from the mod (leftover CA / multiplayer text),
  * interactive components without a tooltip,
  * visible texts that look like multiplayer leftovers,
  * every tooltip the mod set, for a read-through.
"""
import os, re, sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
from tools_db import GAME_DATA   # noqa: E402
DEFAULT_LOG = os.path.join(os.path.dirname(GAME_DATA), "vu_log.txt")   # vu.lua writes it in the game folder
LINE = re.compile(r"^\S+ (ui\[\w+\]) ((?:\. )*)(.*?) \| children (\d+) \| visible (\S+) \| interactive (\S+)(.*)$")
# Tooltips written by vu.lua (prefixes / patterns). Anything else on a shown component is a leftover.
OURS = [r"^Clan points:", r"^Upgrades bought here apply", r"^Retrain", r"^Click again to retrain", r"^Respec ",
        r"^Reset:", r"^Confirm", r"^Cancel", r"^Close$", r"^Ability:", r"^Leadership / ", r"^Ranged / ",
        r"^Physical / ", r"^Melee / ", r"^Veteran Upgrades", r" / Clan points: \d+", r"Unit types your clan can recruit",
        r"^[^/]+ / Requires ", r"^[^/]+ \d+ / \+", r"^[^/]+ \(max\) / \+", r"This unit frightens nearby enemies",
        r"^More unit types"]
# Pure layout containers of the popup: interactive, but there is nothing to explain there.
CONTAINERS = {"dock_area", "background", "bar", "grid", "shogun_subpanel", "subpanel"}
LEFTOVER_TEXT = [r"Clan Tokens", r"token", r"\b999\b", r"Encyclop", r"Requires \d+ points in"]


def parse(path):
    views = {}
    for raw in open(path, encoding="utf-8", errors="replace"):
        m = LINE.match(raw.rstrip("\n"))
        if not m:
            continue
        view, indent, cid, _, vis, inter, rest = m.groups()
        text = re.search(r"\| text (.*?)(?: \| tooltip |$)", rest)
        tip = re.search(r"\| tooltip (.*)$", rest)
        views.setdefault(view, []).append({"depth": len(indent) // 2, "id": cid, "visible": vis == "true",
                                           "interactive": inter == "true", "text": text.group(1) if text else "",
                                           "tooltip": tip.group(1) if tip else ""})
    return views


def shown(rows):
    """Yield (path, row) for rows whose ancestors are all visible, once per path (the log can hold
    several sessions)."""
    stack, seen = [], set()
    for r in rows:
        stack = stack[:r["depth"]]
        stack.append(r)
        path = "/".join(x["id"] for x in stack)
        if all(x["visible"] for x in stack) and (path, r["tooltip"]) not in seen:
            seen.add((path, r["tooltip"]))
            yield path, r


def ours(tip):
    return any(re.search(p, tip) for p in OURS)


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_LOG
    views = parse(path)
    if not views:
        print(f"No ui[...] lines in {path}. Build with VU_DEBUG=1, open the Veterans list and a tree in game, then rerun.")
        return 1
    problems = 0
    for view in sorted(views):
        rows = list(shown(views[view]))
        leftover = [(p, r) for p, r in rows if r["tooltip"] and not ours(r["tooltip"])]
        bare = [(p, r) for p, r in rows if r["interactive"] and not r["tooltip"] and r["id"] not in CONTAINERS]
        texts = [(p, r) for p, r in rows if r["text"] and any(re.search(x, r["text"], re.I) for x in LEFTOVER_TEXT)]
        mine = sorted({r["tooltip"] for _, r in rows if r["tooltip"] and ours(r["tooltip"])})
        print(f"\n=== {view}: {len(rows)} components shown ===")
        print(f"\n-- Tooltips not set by the mod ({len(leftover)}):")
        for p, r in leftover:
            print(f"   {p}\n      {r['tooltip'][:160]}")
        print(f"\n-- Interactive without a tooltip ({len(bare)}):")
        for p, r in bare:
            print(f"   {p}" + (f"   [text: {r['text'][:60]}]" if r["text"] else ""))
        print(f"\n-- Visible texts that look like multiplayer leftovers ({len(texts)}):")
        for p, r in texts:
            print(f"   {p}: {r['text'][:80]}")
        print(f"\n-- Tooltips set by the mod ({len(mine)}), for review:")
        for t in mine:
            print(f"   {t[:160]}")
        problems += len(leftover) + len(bare) + len(texts)
    print(f"\n{problems} possible problems across {len(views)} views.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
