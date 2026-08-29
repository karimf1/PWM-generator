#!/usr/bin/env python3
"""Render a window of a VCD as an SVG waveform, for embedding in README.md.

    tools/vcd2svg.py <vcd> <scope> <sig[,sig...]> <t0> <t1> <tick> <out.svg>
                     [--title TEXT] [--shade A,B] [--label OLD=NEW,...]

Times are in the VCD's own units (1 ps here, so a 10 ns clock is 10000).
Signals are sampled once per tick, one column per clock.

  * 1-bit signals render as a digital waveform. A single bit of a bus can be
    picked out as name[k], which is how the three-phase gate vectors are drawn
    as six separate rows.
  * Wider signals render as an analog ramp, scaled to the window. A counter is
    far more legible as a shape than as a column of hex: edge-aligned is a
    sawtooth, center-aligned is a triangle, and that is the whole difference.

--shade takes two 1-bit signal names and shades every cycle where both are low.
For a half-bridge that is exactly the dead time, so the figure annotates itself
instead of relying on hand-placed arrows.

Colours are mid-tone and the background is transparent, so the result is
readable on GitHub in both light and dark themes.
"""
import sys

FG      = "#64748b"   # labels, ruler
GRID    = "#cbd5e1"
WAVE    = "#2563eb"   # digital
ANALOG  = "#7c3aed"   # buses
SHADE   = "#f59e0b"

COL, ROW, WAVE_H, GUT, TOP = 11, 34, 19, 96, 44


def parse(path, scope, want):
    """-> {name: [(time, value)]}, plus each signal's declared width."""
    ids, width, cur_scope, defs = {}, {}, [], True
    changes, t = [], 0
    with open(path) as f:
        for line in f:
            s = line.strip()
            if defs:
                if s.startswith("$scope"):
                    cur_scope.append(s.split()[2])
                elif s.startswith("$upscope"):
                    cur_scope.pop()
                elif s.startswith("$var"):
                    p = s.split()
                    if ".".join(cur_scope) == scope and p[4] in want:
                        ids[p[3]] = p[4]
                        width[p[4]] = int(p[2])
                elif s.startswith("$enddefinitions"):
                    defs = False
                continue
            if s.startswith("#"):
                t = int(s[1:])
            elif s[:1] in ("0", "1", "x", "z", "X", "Z"):
                if s[1:] in ids:
                    changes.append((t, ids[s[1:]], s[0]))
            elif s[:1] in ("b", "B"):
                v, i = s.split()
                if i in ids:
                    changes.append((t, ids[i], v[1:]))
    return changes, width


def sample(changes, names, t0, t1, tick):
    cur = {n: None for n in names}
    rows = {n: [] for n in names}
    idx, t = 0, t0
    while t <= t1:
        while idx < len(changes) and changes[idx][0] <= t:
            _, n, v = changes[idx]
            cur[n] = v
            idx += 1
        for n in names:
            rows[n].append(cur[n])
        t += tick
    return rows


def to_int(v):
    if v is None:
        return None
    try:
        return int(v, 2)
    except ValueError:
        return None


BIT = {}          # requested "name[k]" -> (name, k)


def split_bit(spec):
    if spec.endswith("]") and "[" in spec:
        base, idx = spec[:-1].split("[", 1)
        return base, int(idx)
    return spec, None


def pick(v, bit, w):
    """One bit out of a VCD binary value, honouring its left-extension rule."""
    if v is None or bit is None:
        return v
    v = v.rjust(w, "0" if v[0] in "01" else v[0])
    return v[w - 1 - bit]


def main():
    a = sys.argv[1:]
    opts = {}
    while len(a) > 7:
        if a[-2] in ("--title", "--shade", "--label"):
            opts[a[-2][2:]] = a[-1]
            a = a[:-2]
        else:
            break
    vcd, scope, specs, t0, t1, tick, out = a[0], a[1], a[2].split(","), \
        int(a[3]), int(a[4]), int(a[5]), a[6]

    bases = []
    for sp in specs:
        b, k = split_bit(sp)
        BIT[sp] = (b, k)
        if b not in bases:
            bases.append(b)

    changes, width = parse(vcd, scope, set(bases))
    missing = [b for b in bases if b not in width]
    if missing:
        sys.exit("not found in scope %s: %s" % (scope, ", ".join(missing)))
    raw = sample(changes, bases, t0, t1, tick)

    rows, wide = {}, {}
    for sp in specs:
        b, k = BIT[sp]
        if k is None:
            rows[sp] = raw[b]
            wide[sp] = width[b]
        else:
            rows[sp] = [pick(v, k, width[b]) for v in raw[b]]
            wide[sp] = 1
    sigs, width = specs, wide
    n = len(rows[sigs[0]])

    relabel = dict(kv.split("=", 1) for kv in opts["label"].split(",")) \
        if "label" in opts else {}

    W = GUT + n * COL + 16
    H = TOP + len(sigs) * ROW + 12
    o = ['<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" '
         'viewBox="0 0 %d %d" font-family="ui-monospace,SFMono-Regular,'
         'Menlo,monospace" font-size="11">' % (W, H, W, H)]

    if "title" in opts:
        o.append('<text x="4" y="14" fill="%s" font-size="12" '
                 'font-weight="600">%s</text>' % (FG, opts["title"]))

    # dead-time shading: every column where both named signals are low
    if "shade" in opts:
        p, q = opts["shade"].split(",")
        for i in range(n):
            if rows[p][i] == "0" and rows[q][i] == "0":
                o.append('<rect x="%d" y="%d" width="%d" height="%d" '
                         'fill="%s" opacity="0.16"/>'
                         % (GUT + i * COL, TOP - 8, COL,
                            len(sigs) * ROW + 4, SHADE))

    # cycle ruler
    for i in range(0, n, 5):
        x = GUT + i * COL
        o.append('<line x1="%d" y1="%d" x2="%d" y2="%d" stroke="%s" '
                 'stroke-width="0.5" opacity="0.5"/>'
                 % (x, TOP - 8, x, TOP + len(sigs) * ROW - 6, GRID))
        o.append('<text x="%d" y="%d" fill="%s" font-size="9">%d</text>'
                 % (x + 2, TOP - 12, FG, i))

    for r, name in enumerate(sigs):
        top = TOP + r * ROW
        yhi, ylo = top + (ROW - WAVE_H) / 2, top + (ROW - WAVE_H) / 2 + WAVE_H
        o.append('<text x="%d" y="%.0f" fill="%s" text-anchor="end">%s</text>'
                 % (GUT - 10, ylo - 4, FG, relabel.get(name, name)))

        vals = rows[name]
        if width[name] == 1:
            pts, prev = [], None
            for i, v in enumerate(vals):
                y = yhi if v == "1" else ylo
                x = GUT + i * COL
                if prev is not None and y != prev:
                    pts.append("%d,%.1f" % (x, prev))
                pts.append("%d,%.1f" % (x, y))
                prev = y
            pts.append("%d,%.1f" % (GUT + n * COL, prev))
            o.append('<polyline points="%s" fill="none" stroke="%s" '
                     'stroke-width="1.8" stroke-linejoin="round"/>'
                     % (" ".join(pts), WAVE))
        else:
            nums = [to_int(v) for v in vals]
            good = [v for v in nums if v is not None] or [0]
            lo, hi = min(good), max(good)
            span = (hi - lo) or 1
            pts = []
            for i, v in enumerate(nums):
                if v is None:
                    continue
                y = ylo - (v - lo) * WAVE_H / span
                pts.append("%d,%.1f" % (GUT + i * COL, y))
            o.append('<polyline points="%s" fill="none" stroke="%s" '
                     'stroke-width="1.6" stroke-linejoin="round"/>'
                     % (" ".join(pts), ANALOG))
            o.append('<text x="%d" y="%.0f" fill="%s" font-size="9" '
                     'opacity="0.75">%d</text>' % (GUT + 3, yhi - 2, FG, hi))

    o.append("</svg>")
    with open(out, "w") as f:
        f.write("\n".join(o))
    print("%s  (%d signals, %d cycles)" % (out, len(sigs), n))


if __name__ == "__main__":
    main()
