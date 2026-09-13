#!/usr/bin/env python3
"""Re-pins the line ranges in tools/vendor-demo.sh after the site has moved.

    tools/vendor-demo-ranges.py ../subtitles-site          # print the new ranges
    tools/vendor-demo-ranges.py ../subtitles-site --write  # and rewrite the script

The vendored files under app/macos/Demo are the slices as they were last cut,
laid end to end with a blank line between: so each old slice is known exactly,
without needing the site's old files, and its first and last lines can be looked
for in the site's files as they are now. The start is the shortest run of
leading lines that occurs once; the end, the longest run of trailing lines
found after it, so a slice that grew a new tail is caught by the script's own
end guard rather than silently cut short. A slice whose tail is gone falls back
on the anchor the guard names, one line before it.

Stdlib only, like the vendor script's Python. It rewrites nothing unless asked.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "tools" / "vendor-demo.sh"
OUT = ROOT / "app" / "macos" / "Demo"

# The slices, in the order the script writes each file, and the anchor its end
# guard names. `file` is the site's; `out` the vendored file the slice is in.
SLICES = [
    ("HTML", "index.html", "demo.html", "demo-caption"),
    ("CSS_ROOT", "styles.css", "demo.css", None),
    ("CSS_DEMO", "styles.css", "demo.css", "sections"),
    ("CSS_MENU", "styles.css", "demo.css", "landing pages"),
    ("CSS_FRAME", "styles.css", "demo.css", "works with"),
    ("CSS_NOTES", "styles.css", "demo.css", "Visual Studio Code"),
    ("JS_I18N", "script.js", "demo.js", None),
    ("JS_CAPTURE", "script.js", "demo.js", "function theme"),
    ("JS_WAVE", "script.js", "demo.js", None),
    ("JS_SEARCH", "script.js", "demo.js", "function liteDemo"),
    ("JS_WRITE", "script.js", "demo.js", "function navFit"),
    ("JS", "script.js", "demo.js", "changelog"),
]


def current_ranges(script: str) -> dict:
    """{name: (first, last)} as the script has them now."""
    found = {}
    for m in re.finditer(r"^(\w+)=\$\(extract (\S+) (\d+) (\d+)\)", script, re.M):
        found[m.group(1)] = (int(m.group(3)), int(m.group(4)))
    return found


def old_slices(ranges: dict) -> dict:
    """{name: [lines]}: each slice as the vendored files hold it."""
    out = {}
    lines = {f: (OUT / f).read_text().split("\n") for f in ("demo.css", "demo.js")}
    # CSS and JS: a header line, then the slices, with one blank line between
    # them — except that the palettes run straight into the demo styles, as the
    # vendor script writes them, so no blank line is skipped before CSS_DEMO.
    for file in ("demo.css", "demo.js"):
        names = [n for n, _, o, _ in SLICES if o == file]
        at = 1
        for name in names:
            if name != names[0] and name != "CSS_DEMO":
                at += 1
            length = ranges[name][1] - ranges[name][0] + 1
            out[name] = lines[file][at:at + length]
            at += length
    # HTML: between the shell's two halves, minus the comment and the closing
    # div the script adds.
    shell = (OUT / "demo.shell.html").read_text()
    token = "<!--" + "DEMO" + "-->"
    prefix, suffix = shell.split(token)
    whole = (OUT / "demo.html").read_text()
    part = whole[len(prefix):len(whole) - len(suffix)].split("\n")
    out["HTML"] = part[1:-2]
    return out


def locate(name: str, old: list, new: list, anchor: str | None) -> tuple:
    def hits(window, start_at=0):
        n = len(window)
        return [i for i in range(start_at, len(new) - n + 1) if new[i:i + n] == window]

    start = None
    for n in (3, 5, 8, 12):
        h = hits(old[:n])
        if len(h) == 1:
            start = h[0] + 1
            break
    if start is None:
        sys.exit(f"!! {name}: its first lines are not in the site's file once — re-pin it by hand")

    end = None
    for n in (12, 8, 5, 3):
        if n > len(old):
            continue
        t = hits(old[-n:], start_at=start - 1)
        if t:
            end = t[0] + n
            break
    if end is None:
        if anchor is None:
            sys.exit(f"!! {name}: its last lines are gone and it has no anchor — re-pin it by hand")
        rx = re.compile(anchor)
        a = next((i for i in range(start, len(new)) if rx.search(new[i])), None)
        if a is None:
            sys.exit(f"!! {name}: neither its last lines nor its anchor are in the site's file")
        end = a
        while end > start and new[end - 1].strip() == "":
            end -= 1
    return start, end


def main() -> None:
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    site = Path(args[0] if args else "../subtitles-site")
    write = "--write" in sys.argv
    script = SCRIPT.read_text()
    ranges = current_ranges(script)
    olds = old_slices(ranges)
    files = {f: (site / f).read_text().split("\n") for f in ("index.html", "styles.css", "script.js")}

    changed = []
    for name, file, _, anchor in SLICES:
        start, end = locate(name, olds[name], files[file], anchor)
        was = ranges[name]
        mark = "" if (start, end) == was else "  ← moved"
        print(f"{name:11} {file:11} {was[0]:>5}-{was[1]:<5} → {start:>5}-{end:<5}{mark}")
        if (start, end) != was:
            changed.append((name, file, was, (start, end)))

    if not write or not changed:
        if not changed:
            print("nothing moved")
        return
    for name, file, (a, b), (c, d) in changed:
        # The slice, and the guard window just past it, which keeps its width.
        script = script.replace(f"{name}=$(extract {file} {a} {b})", f"{name}=$(extract {file} {c} {d})")
        def shift(m):
            lo, hi = int(m.group(1)), int(m.group(2))
            return f"$(extract {file} {lo - b + d} {hi - b + d})"
        # Every guard that looked at lines just past the old end.
        script = re.sub(rf"\$\(extract {re.escape(file)} ({b + 1}|{b}) (\d+)\)", shift, script)
    SCRIPT.write_text(script)
    print(f"rewrote {SCRIPT.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
