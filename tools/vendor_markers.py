#!/usr/bin/env python3
"""The site's vendor:skip markers, for tools/vendor-demo.sh and its ranges tool.

    python3 tools/vendor_markers.py < slice > slice-without-the-site-only-parts

The site marks what only the site wants — the demos' voice, the analytics
events, the hints over the demo — with a pair of whole-line comments, in its
script, its styles and its markup alike:

    // vendor:skip-start audio          ...          // vendor:skip-end audio
    /* vendor:skip-start hints */       ...          /* vendor:skip-end hints */
    <!-- vendor:skip-start hints -->    ...          <!-- vendor:skip-end hints -->

Each pair, markers included, becomes one line saying what was cut and how
long it was, in the same comment syntax and at the same indent:

    // vendor:skipped audio, 207 lines

so the vendored files say where the site had more, and the ranges tool can
tell how many of the site's lines each slice of them stood for. Pairs may nest
(the voice counts itself inside the audio); the outermost pair is what is cut.
A marker without its partner in the text given is an error: it means a slice's
range ends inside a marked stretch, which would cut the site's code in half.

Stdlib only.
"""

from __future__ import annotations

import re
import sys

MARKER = re.compile(r"^(\s*)(//|/\*|<!--) vendor:skip-(start|end) (\w+)(?: \*/| -->)?\s*$")
SKIPPED = re.compile(r"^\s*(?://|/\*|<!--) vendor:skipped (\w+), (\d+) lines?(?: \*/| -->)?\s*$")
CLOSE = {"//": "", "/*": " */", "<!--": " -->"}


def placeholder(indent: str, opener: str, name: str, n: int) -> str:
    return f"{indent}{opener} vendor:skipped {name}, {n} lines{CLOSE[opener]}"


def view(lines: list[str], keep_placeholders: bool = True) -> tuple[list[str], list[tuple[int, int]]]:
    """The lines with each marked stretch cut, and for every line kept, the
    first and last line numbers (1-based) it stands for in `lines`. With
    `keep_placeholders` the stretch leaves its placeholder line; without, it
    leaves nothing."""
    out: list[str] = []
    where: list[tuple[int, int]] = []
    stack: list[tuple[str, int, str, str]] = []  # name, first line, indent, opener
    for i, line in enumerate(lines, 1):
        m = MARKER.match(line)
        if m:
            indent, opener, kind, name = m.groups()
            if kind == "start":
                stack.append((name, i, indent, opener))
                continue
            if not stack or stack[-1][0] != name:
                raise ValueError(f"line {i}: vendor:skip-end {name} with no start to close")
            name, first, indent, opener = stack.pop()
            if not stack and keep_placeholders:
                out.append(placeholder(indent, opener, name, i - first + 1))
                where.append((first, i))
            continue
        if stack:
            continue
        out.append(line)
        where.append((i, i))
    if stack:
        name, first, _, _ = stack[-1]
        raise ValueError(f"line {first}: vendor:skip-start {name} is never closed")
    return out, where


def span(line: str) -> int:
    """How many of the site's lines one vendored line stands for."""
    m = SKIPPED.match(line)
    return int(m.group(2)) if m else 1


def main() -> None:
    text = sys.stdin.read()
    trailing = text.endswith("\n")
    lines = text.split("\n")
    if trailing:
        lines.pop()
    try:
        out, _ = view(lines)
    except ValueError as e:
        sys.exit(f"!! a slice cuts a vendor:skip pair in half, {e}")
    sys.stdout.write("\n".join(out) + ("\n" if trailing else ""))


if __name__ == "__main__":
    main()
