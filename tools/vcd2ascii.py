#!/usr/bin/env python3
"""Render a window of a VCD as an ASCII waveform, for pasting into README.md.

    tools/vcd2ascii.py <vcd> <scope> <sig,sig,...> <t_start> <t_end> <t_period>

Times are in the VCD's own units (1 ps here, so a 10 ns clock is 10000).
Signals are sampled mid-cycle, one character per clock. Example -- the
dead-time notch at the top of README.md:

    tools/vcd2ascii.py sim/build/tb_deadtime.vcd tb_deadtime \
        pwm_raw,pwm_h,pwm_l 15000 405000 10000
"""
import sys, re

def parse(path, want, scope_filter):
    ids, scope = {}, []
    vals, series = {}, {}
    t = 0; defs = True
    changes = []   # (time, id, val)
    with open(path) as f:
        for line in f:
            s = line.strip()
            if defs:
                if s.startswith("$scope"):
                    scope.append(s.split()[2])
                elif s.startswith("$upscope"):
                    scope.pop()
                elif s.startswith("$var"):
                    p = s.split()
                    ident, name = p[3], p[4]
                    if ".".join(scope) == scope_filter and name in want:
                        ids[ident] = name
                elif s.startswith("$enddefinitions"):
                    defs = False
                continue
            if s.startswith("#"):
                t = int(s[1:]); continue
            if s and s[0] in "01xzXZ":
                ident = s[1:]
                if ident in ids:
                    changes.append((t, ids[ident], s[0]))
    return changes

path, scope_filter = sys.argv[1], sys.argv[2]
signals = sys.argv[3].split(",")
t0, t1, period = int(sys.argv[4]), int(sys.argv[5]), int(sys.argv[6])

changes = parse(path, set(signals), scope_filter)
cur = {s: 'x' for s in signals}
rows = {s: [] for s in signals}
idx = 0
# sample at each negedge: t = period/2 + k*period  (posedge at k*period)
t = t0
while t <= t1:
    while idx < len(changes) and changes[idx][0] <= t:
        _, n, v = changes[idx]; cur[n] = v; idx += 1
    for s in signals:
        rows[s].append(cur[s])
    t += period

HI, LO = "▔", "_"
w = max(len(s) for s in signals)
n = len(rows[signals[0]])
lbl = " " * (w + 2); tick = " " * (w + 2)
k = 0
while k < n:
    if k % 5 == 0:
        t_ = str(k)
        lbl += t_ + " " * (5 - len(t_))
        tick += "|" + "-" * 4
        k += 5
    else:
        k += 1
print(lbl[:w + 2 + n])
print(tick[:w + 2 + n])
for s in signals:
    line = "".join(HI if v == '1' else (LO if v == '0' else '?') for v in rows[s])
    print(f"{s:<{w}}  {line}")
