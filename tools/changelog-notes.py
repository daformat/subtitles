#!/usr/bin/env python3
"""Prints one version's CHANGELOG entry, as Markdown or as an HTML fragment.

    tools/changelog-notes.py 1.5.0          # the Markdown bullets, for `gh release`
    tools/changelog-notes.py 1.5.0 --html   # an HTML fragment, for the appcast

The changelog is the single source of release notes: the GitHub release quotes
it, and Sparkle's generate_appcast picks up an HTML file named after the archive
and embeds it in the feed, so the update window shows the same words. Exits 1
with a message when the version has no entry, which is release.sh's cue that the
changelog was not written — a release with no notes is not one to ship.

Stdlib only, like the site's build.py. The HTML is deliberately the least it can
be: a heading and a list, no styling, because Sparkle's window supplies its own
and a bare fragment is what it treats as embedded notes.
"""

import html
import re
import sys
from pathlib import Path

CHANGELOG = Path(__file__).resolve().parent.parent / "CHANGELOG.md"


def entry(version: str) -> tuple[str, str]:
    """(heading, body) for the version, body being the Markdown below it."""
    text = CHANGELOG.read_text(encoding="utf-8")
    heads = list(re.finditer(r"^## (\S+)(.*)$", text, re.M))
    for i, m in enumerate(heads):
        if m.group(1) == version:
            end = heads[i + 1].start() if i + 1 < len(heads) else len(text)
            return m.group(0)[3:].strip(), text[m.end():end].strip()
    sys.exit(f"!! no CHANGELOG entry for {version} — write one before releasing")


def bullets(body: str) -> list[str]:
    """Markdown bullets, each joined back into one paragraph.

    The changelog wraps at 80 columns with two-space continuation, so a bullet
    is the `- ` line plus every indented line after it.
    """
    items: list[str] = []
    for line in body.splitlines():
        if line.startswith("- "):
            items.append(line[2:].strip())
        elif line.startswith("  ") and items:
            items[-1] += " " + line.strip()
        elif line.strip() and not items:
            items.append(line.strip())
    return items


def inline(md: str) -> str:
    """Bold, code and links; the only inline Markdown the changelog uses."""
    s = html.escape(md, quote=False)
    s = re.sub(r"`([^`]+)`", r"<code>\1</code>", s)
    s = re.sub(r"\*\*([^*]+)\*\*", r"<strong>\1</strong>", s)
    s = re.sub(r"\[([^\]]+)\]\(([^)]+)\)", r'<a href="\2">\1</a>', s)
    return s


def main() -> None:
    args = sys.argv[1:]
    want_html = "--html" in args
    args = [a for a in args if a != "--html"]
    if len(args) != 1:
        sys.exit(__doc__.strip().splitlines()[0])
    heading, body = entry(args[0])
    if want_html:
        print(f"<h2>{inline(heading)}</h2>")
        print("<ul>")
        for b in bullets(body):
            print(f"  <li>{inline(b)}</li>")
        print("</ul>")
    else:
        print(body)


if __name__ == "__main__":
    main()
