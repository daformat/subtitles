#!/usr/bin/env python3
"""Generates the 0BSD edition of Subtitles from this checkout (PLAN.md §25).

    tools/edition-0bsd.py ../subtitles-0BSD

The 0BSD edition is this app without the in-app updater (§23) and without the
trial and licence key (§24). It is not ported commit by commit; it is derived
from this tree, deterministically, by three rules:

  1. Files that belong to the main edition alone do not travel. The list is
     EXCLUDED below.
  2. In the files that do, a block between a line containing [main-edition]
     and a line containing [/main-edition] is removed, marker lines included.
     Any comment syntax will do: the marker is the bracketed word, wherever
     it sits on the line.
  3. A block between [0bsd-edition] and [/0bsd-edition] is the other
     edition's text, kept commented out in this tree so it compiles here,
     and the generator uncomments it: the marker lines go, and each inner
     line loses the comment prefix the opening marker line used ("// ",
     "# "). In Markdown the block is one HTML comment, opened on the
     marker line and closed on the closing one, so the inner lines are kept
     as they are.

Everything else is copied byte for byte, so the two editions cannot drift
except at the seams, and the seams are visible in this tree as the markers.
Package.resolved is edited rather than marked — JSON has no comments — and
LICENSE is replaced by tools/edition-0bsd/LICENSE.

Only tracked files are read, from the working tree, so an uncommitted seam
can be tried before it is committed; the upstream commit and whether the tree
was clean are printed at the end for the fork's commit message. Files in the
fork that this run does not produce are removed if git tracks them there;
untracked ones (.build, build) are left alone.

Refuses to finish if a marker survives, if a marker pair is unbalanced, or if
the output still mentions the updater or the licence anywhere but PLAN.md,
which travels whole as the design record it is.
"""

import json
import os
import re
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent.parent

# Rule 1: main-edition files and directories.
EXCLUDED = [
    "app/macos/Updater.swift",
    "app/macos/UpdateWindow.swift",
    "app/macos/Dialog.swift",
    "app/macos/License.swift",
    "app/macos/LicenseStore.swift",
    "app/macos/LicenseVerifier.swift",
    "app/macos/LicenseWindow.swift",
    "app/license/",
    "app/captions/ReleaseNotes.swift",
    "Tests/LicenseCoreTests/",
    "Tests/CaptionCoreTests/ReleaseNotesTests.swift",
    "tools/changelog-notes.py",
    "tools/update-window-harness/",
    "tools/license-window-harness/",
    "tools/edition-0bsd.py",
    "tools/edition-0bsd/",
]

# Words that must not survive outside PLAN.md. A hit means a seam was missed.
BANNED = re.compile(
    r"Sparkle|LicenseCore|LicenseController|LicenseRecord|appcast|SUFeedURL|"
    r"SPARKLE_|\bUpdater\b|UpdateWindow|LicenseWindow|ReleaseNotes|--feed\b|--verify URL")
BANNED_EXEMPT = {"PLAN.md"}

OPEN_MAIN, CLOSE_MAIN = "[main-edition]", "[/main-edition]"
OPEN_0BSD, CLOSE_0BSD = "[0bsd-edition]", "[/0bsd-edition]"
MARKERS = (OPEN_MAIN, CLOSE_MAIN, OPEN_0BSD, CLOSE_0BSD)


def fail(msg):
    sys.exit(f"!! {msg}")


def tracked_files():
    out = subprocess.run(["git", "ls-files", "-z"], cwd=HERE, check=True,
                         capture_output=True).stdout
    return [p for p in out.decode().split("\0") if p]


def excluded(path):
    return any(path == e or (e.endswith("/") and path.startswith(e)) for e in EXCLUDED)


def transform(path, text):
    """Rules 2 and 3 on one file's text."""
    if not any(m in text for m in MARKERS):
        return text
    out = []
    lines = text.split("\n")
    i = 0
    while i < len(lines):
        line = lines[i]
        if OPEN_MAIN in line:
            j = i + 1
            while j < len(lines) and CLOSE_MAIN not in lines[j]:
                if OPEN_MAIN in lines[j] or OPEN_0BSD in lines[j]:
                    fail(f"{path}:{j + 1}: marker inside a [main-edition] block")
                j += 1
            if j == len(lines):
                fail(f"{path}:{i + 1}: [main-edition] never closed")
            i = j + 1
            # A block that sat between two blank lines leaves two behind;
            # one is the tree's own spacing, the other was the block's.
            if out and out[-1] == "" and i < len(lines) and lines[i] == "":
                i += 1
            continue
        if OPEN_0BSD in line:
            # The comment prefix is whatever precedes the marker on its line,
            # less the marker itself: "// ", "# ", or "<!-- " for Markdown.
            prefix = line[:line.index(OPEN_0BSD)]
            markdown = prefix.rstrip().endswith("<!--")
            j = i + 1
            while j < len(lines) and CLOSE_0BSD not in lines[j]:
                if any(m in lines[j] for m in (OPEN_MAIN, OPEN_0BSD, CLOSE_MAIN)):
                    fail(f"{path}:{j + 1}: marker inside a [0bsd-edition] block")
                inner = lines[j]
                if markdown:
                    out.append(inner)
                else:
                    stripped = inner.lstrip()
                    indent = inner[:len(inner) - len(stripped)]
                    token = prefix.strip()
                    if stripped.startswith(token + " "):
                        out.append(indent + stripped[len(token) + 1:])
                    elif stripped == token:
                        out.append(indent.rstrip())
                    else:
                        fail(f"{path}:{j + 1}: line in a [0bsd-edition] block "
                             f"does not start with the comment prefix {token!r}")
                j += 1
            if j == len(lines):
                fail(f"{path}:{i + 1}: [0bsd-edition] never closed")
            i = j + 1
            continue
        if CLOSE_MAIN in line or CLOSE_0BSD in line:
            fail(f"{path}:{i + 1}: closing marker with no opening one")
        out.append(line)
        i += 1
    return "\n".join(out)


def transform_resolved(text):
    data = json.loads(text)
    data["pins"] = [p for p in data["pins"] if p.get("identity") != "sparkle"]
    # originHash is SwiftPM's digest of the manifest's dependencies; it is
    # recomputed on the next resolve, and a stale one only triggers that.
    data.pop("originHash", None)
    return json.dumps(data, indent=2) + "\n"


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__.strip().splitlines()[0] + "\n\n    tools/edition-0bsd.py <fork-dir>")
    fork = Path(sys.argv[1]).resolve()
    if not (fork / ".git").exists():
        fail(f"{fork} is not a git checkout")

    produced = {}
    for rel in tracked_files():
        if excluded(rel):
            continue
        src = HERE / rel
        raw = src.read_bytes()
        try:
            text = raw.decode("utf-8")
        except UnicodeDecodeError:
            produced[rel] = raw
            continue
        if rel == "Package.resolved":
            text = transform_resolved(text)
        elif rel == "LICENSE":
            text = (HERE / "tools/edition-0bsd/LICENSE").read_text()
        elif rel in BANNED_EXEMPT:
            # The design record travels as it is, and it is allowed to talk
            # about the markers without being cut by them.
            pass
        else:
            text = transform(rel, text)
        if rel not in BANNED_EXEMPT:
            hit = BANNED.search(text)
            if hit:
                line = text[:hit.start()].count("\n") + 1
                fail(f"{rel}:{line}: still mentions {hit.group(0)!r} — a seam is unmarked")
        produced[rel] = text.encode("utf-8")

    # Write, keeping executable bits, and remove what the fork tracks but this
    # run did not produce.
    for rel, data in produced.items():
        dst = fork / rel
        dst.parent.mkdir(parents=True, exist_ok=True)
        if not dst.exists() or dst.read_bytes() != data:
            dst.write_bytes(data)
        os.chmod(dst, (HERE / rel).stat().st_mode & 0o7777)
    fork_tracked = subprocess.run(["git", "ls-files", "-z"], cwd=fork, check=True,
                                  capture_output=True).stdout.decode().split("\0")
    removed = 0
    for rel in fork_tracked:
        if rel and rel not in produced and (fork / rel).exists():
            (fork / rel).unlink()
            removed += 1

    head = subprocess.run(["git", "rev-parse", "--short", "HEAD"], cwd=HERE, check=True,
                          capture_output=True).stdout.decode().strip()
    dirty = subprocess.run(["git", "status", "--porcelain"], cwd=HERE, check=True,
                           capture_output=True).stdout.decode().strip() != ""
    print(f"wrote {len(produced)} files into {fork}, removed {removed}")
    print(f"generated from upstream {head}{' (with uncommitted changes)' if dirty else ''}")
    print("next, in the fork: ./build.sh && swift test, then commit")


if __name__ == "__main__":
    main()
