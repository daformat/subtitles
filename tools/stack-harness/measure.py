#!/usr/bin/env python3
"""Prints every box's left and right edge in each capture the harness took.

    python3 tools/stack-harness/measure.py build/stack-harness/shots

A box is a band of rows with something darker than the white backdrop in
them; its edges are the first and last dark pixel on the band's middle row.
Pixels, at the display's scale. The two short boxes must print the same
edges in every file.
"""

import glob
import sys

from PIL import Image


def edges(path):
    im = Image.open(path).convert("RGB")
    w, h = im.size
    px = im.load()

    def dark(x, y):
        r, g, b = px[x, y]
        return r + g + b < 600

    rows = [y for y in range(h) if any(dark(x, y) for x in range(0, w, 2))]
    bands = []
    for y in rows:
        if bands and y - bands[-1][1] <= 2:
            bands[-1][1] = y
        else:
            bands.append([y, y])
    out = []
    for y0, y1 in bands:
        if y1 - y0 < 10:
            continue
        ym = (y0 + y1) // 2
        xs = [x for x in range(w) if dark(x, ym)]
        out.append((min(xs), max(xs)))
    return out


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__.strip().splitlines()[0])
    for path in sorted(glob.glob(f"{sys.argv[1]}/*.png")):
        print(path.split("/")[-1], edges(path))


if __name__ == "__main__":
    main()
