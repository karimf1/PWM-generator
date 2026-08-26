# pwm-deadtime

A counter-based PWM timer with runtime-writable frequency and duty, glitch-free
shadow registers, and a dead-time FSM that guarantees the high and low side of a
half-bridge are never on at the same time — verified cycle-by-cycle.

Verilog-2001, simulated with Icarus Verilog. No SystemVerilog, no vendor IP.

```
         0    5    10   15   20   25   30   35
         |----|----|----|----|----|----|----|----
pwm_raw  ________▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔____________
pwm_h    _____________▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔____________
pwm_l    _______▔_________________________▔▔▔▔▔▔▔
                ^    ^                ^   ^
                |    |                |   |
                |    |                |   low side on, 5 clocks later
                |    |                high side off the instant the request drops
                |    turn-on delayed by dt = 5 clocks
                reset dead time ends, low side takes over
```

Turn-**off** is immediate. Turn-**on** waits `dt` clocks. That asymmetry is the
whole point: it is what stops both transistors in a half-bridge conducting at
once and shorting the DC bus through them.

Every waveform in this README is rendered from the VCD the testbenches actually
produce, not drawn by hand — `tools/vcd2ascii.py` does the rendering, so any of
them can be regenerated:

```bash
tools/vcd2ascii.py sim/build/tb_deadtime.vcd tb_deadtime pwm_raw,pwm_h,pwm_l 15000 405000 10000
```

## Status

| module | what it does | state |
|---|---|---|
| `rtl/deadtime.v` | complementary outputs + dead-time FSM | ✅ built, verified |
| `rtl/pwm_counter.v` | counter + compare, `update` pulse | ✅ built, verified |
| `rtl/pwm_regs.v` | register file, shadow buffering | ✅ built, verified |
| `rtl/pwm_top.v` | integration, fault synchronizer | ✅ built, verified |

Four modules, 207 lines of RTL. The testbenches are 1324 lines. That ratio is
not an accident — see [Verification](#verification).

## Quickstart

```bash
brew install icarus-verilog gtkwave
```

```bash
make -C sim
```

That lints the RTL and runs all three testbenches. Each prints `TEST PASSED` or
exits nonzero. To look at a waveform:

```bash
make -C sim wave TB=tb_deadtime
```

To run every randomized test long, over four seeds:

```bash
make -C sim soak
```

## How it works

```
              +----------------+        +--------------+
 wr/addr/data | pwm_regs       | period |              | pwm_raw  +----------+ pwm_h
 ------------>| shadow buffers |------->| pwm_counter  |--------->| deadtime |------->
              |                | duty   | (up counter  |          |   FSM    | pwm_l
              +----------------+ dt     |  + compare)  |          |          |------->
                    ^                   +--------------+          +----------+
                    |  update (load enable)     |                      ^ dt
                    +---------------------------+----------------------+
```

### pwm_counter — frequency and duty

A free-running up-counter over `0 .. period-1`, so `f_pwm = f_clk / period`. At
100 MHz with `period = 5000` that is 20 kHz, a realistic inverter switching
frequency. `pwm_raw` is high for exactly `duty` cycles of every period.

```
         0    5    10   15   20   25   30
         |----|----|----|----|----|----|----
update   ___▔_________▔_________▔_________▔_
pwm_raw  _____▔▔▔▔______▔▔▔▔______▔▔▔▔______
```
*period = 10, duty = 4. `update` marks the last cycle of each period.*

Degenerate values are **defined, not illegal** — a register write can produce
any of them and the counter must not be able to run away:

| written | result |
|---|---|
| `duty = 0` | static low, 0%, no edges at all |
| `duty >= period` | static high, 100%, no edges at all |
| `period = 0` or `1` | wraps every cycle |
| `period` reduced below current `cnt` | wraps on the next cycle, no run to 0xFFFF |

### deadtime — the safety interlock

A 4-state FSM with exactly one rule: **nothing turns on except by leaving
`S_DEAD`, and `S_DEAD` always runs its counter to zero.** Normal switching,
fault release and reset release all funnel through it, so every turn-on in the
design is preceded by a full dead time by construction.

```
S_LO_ON : pwm_raw          -> S_DEAD, dt_cnt <= dt
S_HI_ON : !pwm_raw         -> S_DEAD, dt_cnt <= dt
S_DEAD  : dt_cnt <= 1      -> pwm_raw ? S_HI_ON : S_LO_ON
          else                dt_cnt <= dt_cnt - 1
S_FAULT : !force_off       -> S_DEAD, dt_cnt <= dt
any     : force_off        -> S_FAULT          (highest priority)
reset   :                  -> S_DEAD, both outputs low
```

`pwm_h` and `pwm_l` are decoded from `next_state` and **registered**, never
decoded combinationally from `state`. A decode of state bits can glitch while
they settle, and a glitch here is a shoot-through in the real bridge.

Three consequences, all intentional:

**A request narrower than the dead time is swallowed entirely.** Neither output
turns on. This is why the achievable duty range shrinks as dead time grows.

```
         0    5    10   15   20
         |----|----|----|----|---
pwm_raw  __▔▔▔▔▔_________________
pwm_h    ________________________   <- never rises
pwm_l    ▔▔_____▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔
```
*A 5-clock request with dt = 5. The low side steps aside, nothing takes over,
the low side comes back.*

**Delivered on-time is `duty - dt` clocks, not `duty`.** Real inverters
compensate for this in software. This one does not.

**`dt = 0` still inserts one clock of dead time.** The floor is 1, not 0, on
purpose: a safety interlock that can be configured to zero is not a safety
interlock.

### pwm_regs — why a shadow register

Writes land in staging registers at any time. The active registers load from
them only when `update` pulses, during the last cycle of a period. So a duty
written in the middle of a pulse can never shorten the pulse already in flight —
the output for the current period is whatever was committed at its start.

`addr` is `byte_addr[3:2]`; translating a wider bus address is a wrapper's job,
so the decode here is exact rather than aliased.

| addr | byte | name | bits | buffered? |
|---|---|---|---|---|
| 0 | 0x0 | `PERIOD` | `[15:0]` counter wrap | shadowed |
| 1 | 0x4 | `DUTY` | `[15:0]` compare | shadowed |
| 2 | 0x8 | `DEADTIME` | `[7:0]` clocks | shadowed |
| 3 | 0xC | `CTRL` | `[0]` en, `[1]` force_off | **immediate** |

**`CTRL` is deliberately not shadowed.** Shadowing exists to stop a data change
from corrupting a pulse in flight. Control that switches the output *off* must
never be delayed by up to a period. Stop means stop.

**Reset values are the safe end of every range, not zero:** `PERIOD` = max
(slowest switching), `DUTY` = 0 (0% output), `DEADTIME` = max (most conservative
interlock), `en` = 0, `force_off` = 1 (gates held off until software explicitly
releases them). So `CTRL` does not read back as zero after reset. That is
intentional — the safe state of an output-disable bit is asserted.

### pwm_top — the fault path

Three things live at this level.

**A 2-FF synchroniser on the fault input.** `fault_n` is asynchronous. An async
signal driving FSM logic directly can be sampled mid-transition by different
flops in different states, leaving the FSM somewhere illegal. The synchroniser
resets to *tripped*, so the gates are off out of reset and stay off until a
healthy `fault_n` has propagated.

**Recovery waits for a period boundary.** A trip blanks the gates immediately;
re-arming happens only on the next `update`. Restarting mid-period is not a
shoot-through risk — `deadtime.v` serves a full dead time leaving `S_FAULT`
whatever happens — it would just produce a first pulse of arbitrary width.

**A disabled timer drives nothing.** `en = 0` forces both gates off (coast)
rather than parking the low side on (brake). Braking a motor is a deliberate
act, not what "stopped" should mean. So `en` and `force_off` are genuinely
different controls: `en = 0` stops the counter *and* the outputs, while
`force_off = 1` leaves the counter running and blanks the outputs, so clearing
it resumes in step with the period.

```
         0    5    10   15   20   25 ...  75   80   85   90
         |----|----|----|----|----|--     |----|----|----|--
fault_n  ▔▔▔▔▔▔▔▔▔▔▔▔▔________________ ... ______▔▔▔▔▔▔▔▔▔▔▔
update   __▔__________________________ ... ___▔______________
pwm_h    _________▔▔▔▔▔▔______________ ... _______________▔▔▔
pwm_l    ▔▔▔▔▔________________________ ... __________________
              ^        ^                       ^         ^
              |        |                       |         |
              |        gates dark 2 clocks     |         dead time, then back
              |        later -- synchroniser   |
              pwm_h conducting                 re-arm waits for this update
```

*period = 40, duty = 20, dt = 4. Trimmed from the middle; the gates stay dark
for the whole fault.*

## Verification

207 lines of RTL, 1324 lines of testbench. Plain Verilog has no `assert`, no
constrained-random and no classes, so the checkers are ordinary `always` blocks
that run continuously through every test, and the randomization is an LFSR.

**Continuous checkers** — these run for the whole simulation, in every test:

| | check |
|---|---|
| C1 | `pwm_h` and `pwm_l` are never both high. The headline invariant. |
| C2 | a rise of either output is ≥ `dt` clocks after the *other* one fell |
| C3 | both outputs low whenever reset is asserted |
| P1 | cycles between `update` pulses == `period` — the off-by-one killer |
| P2 | `pwm_raw` high cycles per period == `min(duty, period)` |
| P3 | `cnt` stays inside `0 .. period-1` |
| R1 | active config never changes on a cycle where `update` was low |
| R2 | on every `update`, active config == last value written |
| R3 | `en` / `force_off` track `CTRL` on the very next cycle |
| T1 | `pwm_h` high cycles per period == expected, measured at the gate |
| T2 | `pwm_l` high cycles per period == expected, measured at the gate |
| T3 | cycles between `update` pulses == `period`, end to end |

**Directed scenarios**: 140 checks across 51 scenarios — 38/16 for the dead-time
FSM, 26/12 for the counter, 29/10 for the registers, 47/13 for the integrated
design. Covering 0%, 100%, `duty > period`, `period` of 2/1/0, requests exactly
`dt` long, 1-cycle requests, `dt = 0`, `dt` larger than the duty, back-to-back
edges, disable mid-period, `force_off` mid-pulse, fault mid-conduction, fault
asserted off the clock edge, and reset mid-conduction.

The integration testbench drives the design the way software would — through
the register port, with an asynchronous fault line — and measures the gate
outputs, not internal signals. Its `period increased through the real register
path` test is the one that proves the `pwm_regs` → `pwm_counter` contract
actually holds in the assembled design: if it were broken, T3 would measure
`period_new - period_old` instead of `period_new`.

**Randomized soak**: `make -C sim soak` runs every randomized test long over
four seeds — 2.4M dead-time cycles, 63,000 configured PWM periods, 30,000
register commits, and randomized reconfiguration with random fault pulses at
the top level. All clean.

Every measurement is exact, not approximate. The window checkers latch the
config in force at the start of each window and compare against that, so a
config change lands in the right window with no fuzz and no skipped periods.

## The bug the random test found

Worth reading if you are going to build one of these.

The obvious first cut of the dead-time FSM has *two* dead-time states,
`S_DT_LH` and `S_DT_HL`, each of which returns early if the request is withdrawn
mid-count. That shortcut looks safe, and for normal switching it is — the side
that was already on never turned off, so there is nothing to interlock against.

All 14 directed tests passed.

The randomized stress failed in 495 cycles:

```
** FAIL  cyc=495  t=4950000 : C2 dead time too short before pwm_l rise
```

The fault-release and reset-release paths reuse the same dead-time state *after
the other side has been conducting*, and there the early return turns a device
on before its complement has stopped. This is the actual VCD, `dt = 10`:

```
           0    5    10   15
           |----|----|----|-
force_off  ____▔____________     <- one-cycle software trip
pwm_raw    ▔▔▔▔____________▔
pwm_h      ▔▔▔▔_____________     <- high side stops conducting here
pwm_l      ______▔▔▔▔▔▔▔▔▔▔_     <- low side on 2 clocks later, not 10
```

The broken version is kept at `docs/deadtime_v1_buggy.v` so this is
reproducible rather than retold:

```bash
make -C sim bug
```

The fix collapses both dead-time states into one non-abortable `S_DEAD`, so
normal switching, fault release and reset release all take the same path. It is
one state *smaller* than the version it replaced. Directed regressions for both
paths are now in the testbench.

Two things this is worth remembering for:

1. Directed tests check the cases you thought of. The bug lived in a case that
   only exists when two features interact — a fault arriving while the high side
   happens to be conducting — and no reasonable directed test list contains it.
   The LFSR found it in 577 cycles.
2. The correct design was simpler than the incorrect one. The early-return
   shortcut was an optimization protecting a case that did not need protecting.

## Known limitations

Named rather than hidden:

- **Dead time reduces effective duty by `dt` clocks.** No software compensation.
- **Dead-time resolution is one clock cycle.** No fine sub-clock delay line.
- **Multi-register writes are not atomic.** `PERIOD` and `DUTY` commit
  independently, so a write pair that straddles a period boundary can leave one
  period running a mixed config — and if that mix has `duty >= period`, that is
  one period at 100% duty. Workaround: change frequency with the timer stopped.
  Fix: a `LOAD` commit bit that arms the shadow load, which is what the STM32
  timer's UG bit is for. Not built.
- **16-bit write port, not AXI4-Lite.** A bus wrapper is a separate job.
- **Simulation only.** No FPGA bring-up, no scope traces, no timing closure
  against a real device. Simulation cannot produce metastability either — the
  synchroniser is there for real silicon, and the testbench only proves the
  logic does not care which part of the cycle a trip arrives in.
- **The fault is not latched.** Clearing `fault_n` re-arms automatically at the
  next period boundary. Real drives usually latch the trip so software must
  acknowledge it, which stops a chattering fault producing repeated restarts.
- **Single-phase half-bridge, edge-aligned.** Three-phase is three instances
  sharing one counter; center-aligned needs an up/down counter. Neither is built.

## Repo layout

```
pwm-deadtime/
  rtl/    deadtime.v  pwm_counter.v  pwm_regs.v  pwm_top.v
  tb/     tb_deadtime.v  tb_pwm_counter.v  tb_pwm_regs.v  tb_pwm_top.v
  sim/    Makefile                      # make / make bug / make wave
  tools/  vcd2ascii.py                  # renders the README waveforms
  docs/   deadtime_v1_buggy.v           # the broken first FSM, kept on purpose
  PLAN.md
```

`PLAN.md` has the full design notes, the phase plan, and the interface contract
between `pwm_regs` and `pwm_counter`.
