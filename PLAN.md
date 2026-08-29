# pwm-deadtime — Configurable PWM Generator with Dead-Time Insertion

Verilog-2001 RTL + self-checking Verilog testbenches. Portfolio project plan.

One-line README pitch: *A counter-based PWM timer with runtime-writable frequency
and duty, glitch-free shadow registers, and a dead-time FSM that guarantees the
high and low side are never on at the same time — verified cycle-by-cycle.*

## 1. Why this project reads well

Anyone can write a counter and a comparator. What makes this a portfolio piece
is the three details that real motor-drive timers have and toy PWMs don't:

1. **Shadow (double-buffered) registers** — you can write a new duty cycle in the
   middle of a period without producing a runt pulse.
2. **Dead-time insertion** — turn-off is immediate, turn-on is delayed. The
   safety invariant `!(pwm_h && pwm_l)` must hold in *every* clock cycle,
   including reset, fault, 0% duty, 100% duty, and pulses shorter than the dead
   time.
3. **Fault shutdown** — an external trip forces both outputs low and resumes only
   at a period boundary, never mid-pulse.

Everything below is Verilog-2001 only: no SystemVerilog, no `assert`, no classes.
Checkers are written as ordinary `always` blocks and tasks.

## 2. Architecture

```
              +----------------+        +--------------+
 wr/addr/data | pwm_regs       | period |              |  pwm_raw   +----------+  pwm_h
 ------------>| shadow buffers |------->| pwm_counter  |----------->| deadtime |--------->
              |                | duty   | (up counter  |            |   FSM    |  pwm_l
              +----------------+ dt     |  + compare)  |            |          |--------->
                                        +--------------+            +----------+
                                              | update (wrap pulse)      ^ dt
                                              +--------------------------+
```

Three small modules, one wrapper. Each is independently testable — that is the
whole point of splitting it this way.

**`pwm_counter.v`** — parameter `CNT_W = 16`. **Built and verified**
(`rtl/pwm_counter.v`, `tb/tb_pwm_counter.v`).
- Free-running up-counter over `0 .. period-1`, so `f_pwm = f_clk / period`.
  At 100 MHz with `period = 5000` that's 20 kHz — a realistic inverter
  switching frequency to quote in the README.
- `pwm_raw <= (cnt < duty)`, registered, so it lags `cnt` by one clock. The
  pulse sits one cycle later in the period; its width is unaffected.
- `update` is **combinational**, high during the *last* cycle of the period, so
  a synchronous load using it as an enable lands on exactly the edge where
  `cnt` wraps to 0. Registering it would push the new config one cycle into the
  next period. It is a load enable sampled at a clock edge, never a gate drive.
  Held high while disabled, so config written to a stopped timer applies at
  once rather than waiting for a wrap that is never coming.
- Degenerate values are *defined*, not illegal — a register write can produce
  any of them and the counter must not be able to run away:
  `duty = 0` → static low; `duty >= period` → static high; `period = 0 or 1` →
  wraps every cycle; `period` reduced below the current `cnt` → wraps next
  cycle. The comparator gives 0% and 100% for free, with no runt pulse.

> **Interface contract — the thing that will bite you in Phase 4.**
> `period` and `duty` must be **register outputs that settle after the clock
> edge**, which is exactly what `pwm_regs.v` provides. They must not be driven
> combinationally from a write port. `wrap` is combinational on the live
> `period` input, so if a *larger* period arrives before the wrap edge rather
> than at it, `cnt + 1 >= period` goes false and **the wrap is cancelled** —
> the counter sails past its endpoint and the period comes out as
> `period_new - period_old`. The first version of the testbench drove these
> inputs combinationally and produced exactly that; the RTL was fine. Write
> this contract in the module header, because the failure looks like a counter
> bug and is not one.

**`pwm_regs.v`** — the double buffer. **Built and verified** (`rtl/pwm_regs.v`,
`tb/tb_pwm_regs.v`).
- Writes land in `period_next`, `duty_next`, `dt_next` at any time; the active
  `*_q` load from them only when `update` pulses. That is the entire reason a
  mid-period write is safe, and it is two lines of Verilog. Say so in the README.
- A write landing on the update edge itself reads as its *old* value on the load
  side — both are registers on the same clock — so it commits at the following
  boundary. No torn value, one period of latency.
- **`CTRL` is not shadowed.** Shadowing stops a data change from corrupting a
  pulse in flight; control that switches the output *off* must never be delayed
  by up to a period. Stop means stop.
- **Reset values are the safe end of every range, not zero**: `PERIOD` = max,
  `DUTY` = 0, `DEADTIME` = max, `en` = 0, `force_off` = 1. `CTRL` therefore does
  not read back as zero after reset — the safe state of an output-disable bit is
  asserted.
- Known gap: multi-register writes are not atomic. `PERIOD` and `DUTY` commit
  independently, so a write pair straddling a boundary can leave one period on a
  mixed config, and if that mix has `duty >= period` it is one period at 100%
  duty. The fix is a `LOAD` commit bit that arms the shadow load — exactly what
  the STM32 timer's UG bit does. Listed as a limitation, not built.

**`deadtime.v`** — parameter `DT_W = 8`, the interesting module. **Built and
verified** (`rtl/deadtime.v`, `tb/tb_deadtime.v`).

A 4-state FSM with exactly one rule: *nothing turns on except by leaving
`S_DEAD`, and `S_DEAD` always runs its counter to zero.* Normal switching,
fault release and reset release all funnel through it, so every turn-on in the
design is preceded by a full dead time by construction.

Outputs are **registered**, decoded from `next_state` rather than combinationally
from `state` — a decode of state bits can glitch while they settle, and a glitch
here is a shoot-through in the real bridge.

```
S_LO_ON : pwm_l=1, pwm_h=0
S_HI_ON : pwm_h=1, pwm_l=0
S_DEAD  : both 0, counting down
S_FAULT : both 0, shutdown

S_LO_ON : pwm_raw          -> S_DEAD, dt_cnt <= dt
S_HI_ON : !pwm_raw         -> S_DEAD, dt_cnt <= dt
S_DEAD  : dt_cnt <= 1      -> pwm_raw ? S_HI_ON : S_LO_ON
          else dt_cnt <= dt_cnt - 1
S_FAULT : !force_off       -> S_DEAD, dt_cnt <= dt
any     : force_off        -> S_FAULT          (highest priority)
reset   :                  -> S_DEAD, dt_cnt <= dt, both outputs low
```

**The design mistake worth writing up in the README.** The obvious first cut has
*two* dead-time states, `S_DT_LH` and `S_DT_HL`, each of which returns early if
the request is withdrawn mid-count. That shortcut is safe for normal switching —
the side that was already on never turned off, so there is nothing to interlock
against. But the fault-release and reset-release paths reuse the same state
*after the other side has been conducting*, and there the early return turns a
device on two cycles after its complement. Directed tests all passed; the
randomized stress found it in 20k cycles. Collapsing to one non-abortable state
removes the entire class of bug and is *simpler* than what it replaced. That
sequence — plausible design, targeted tests green, random test finds the hole,
fix makes it smaller — is the best story in this repo. Keep the VCD screenshot
of the failure.

Three consequences to state out loud in the docs:
- A requested pulse **narrower than the dead time is swallowed entirely**. Both
  outputs stay off. That is correct and safe, and it is why the achievable duty
  range shrinks as dead time grows.
- The delivered on-time is `duty - dt` clocks, not `duty`. Real inverters
  compensate for this in software; note it as a known, intentional limitation.
- `dt = 0` still inserts **one** clock of dead time. The floor is 1, not 0, on
  purpose: a safety interlock that can be configured to zero is not one.

**`pwm_top.v`** — instantiates the three. **Built and verified**
(`rtl/pwm_top.v`, `tb/tb_pwm_top.v`).
- `fault_n` async input through a **2-FF synchroniser**, resetting to
  *tripped*, so the gates are off out of reset and stay off until a healthy
  `fault_n` has propagated. Never use a raw async input as FSM logic.
- `force_off = fault | ~armed | force_off_q | ~en_q` — four independent reasons
  to blank the gates, combinational from registered sources so a trip lands on
  the very next edge.
- `armed` clears immediately on a trip and sets only on `update`, so recovery
  lands on a period boundary. Not a safety matter — `deadtime.v` serves a full
  dead time leaving `S_FAULT` regardless — it just stops the first pulse after
  recovery being an arbitrary width.
- `en = 0` blanks the outputs too: a stopped timer coasts (both off) rather
  than braking (low side on). That makes `en` and `force_off` genuinely
  different controls rather than two spellings of the same one.

Register map (byte-addressed, simple write-only strobe interface — no need for a
full AXI/APB port):

| addr | name    | bits   | meaning                    |
|------|---------|--------|----------------------------|
| 0x0  | PERIOD  | [15:0] | counter wrap value         |
| 0x4  | DUTY    | [15:0] | compare value              |
| 0x8  | DEADTIME| [7:0]  | dead-time in clock cycles  |
| 0xC  | CTRL    | [0] en, [1] force_off      |

## 3. Phases

Each phase leaves you with something that simulates and a waveform you can show.

**Phase 0 — toolchain (an evening).**
`brew install icarus-verilog gtkwave`. Write a 20-line counter + testbench,
dump a VCD, open it in GTKWave. Do not skip this — get the loop
*edit → `make sim` → look at waveform* working before writing real RTL.

**Phase 1 — PWM core. ✅ DONE.** `pwm_counter.v` with a continuous checker that
measures *every* period the DUT produces: cycles between `update` pulses ==
`period` (the off-by-one killer), high cycles per period == `min(duty, period)`,
and `cnt` in range. 30 directed checks covering 0%, 100%, `duty > period`,
`period` of 2/1/0, disable-mid-period, and period-shrunk-below-`cnt` recovery,
plus 63,000 randomly configured periods across seven seeds. Soak with
`vvp build/tb_pwm_counter.vvp +configs=3000 +seed=c0de`.

Two testbench notes worth reusing in Phase 2: the shadow register has to be
modelled as a real register (see the interface contract above), and the
measurement window must be aligned to the `update` pulse **delayed by one
cycle**, because `pwm_raw` is registered and lags `cnt`. Align to `cnt` instead
and every config-change window reads one cycle off.

**Phase 2 — runtime configuration. ✅ DONE.** `pwm_regs.v` with three continuous
checkers (config never moves except on `update`; on every `update` it equals the
last value written; `CTRL` lands the very next cycle), 29 directed checks across
10 scenarios, and 30,000 randomized register commits across four seeds.

**Phase 3 — dead-time FSM, standalone. ✅ DONE.** `deadtime.v` tested on its own,
driven by a hand-written `pwm_raw` stimulus so the nasty cases go in directly
(1-cycle request, request exactly `dt` long, `dt = 0`, back-to-back edges, fault
and reset mid-conduction). 14 directed tests plus an LFSR soak; clean over 2.4M
random cycles across six seeds. Run it with `make -C sim`, soak it with
`vvp build/tb_deadtime.vvp +cycles=400000 +seed=beef`.

**Phase 4 — integration + fault. ✅ DONE.** `pwm_top.v` with the synchroniser
and fault path. `tb_pwm_top.v` drives the design through the register port with
an asynchronous fault line and measures the gate outputs: three continuous
output checkers (high cycles, low cycles, period) on top of C1–C3, 47 directed
checks across 13 scenarios, and randomised reconfiguration with random fault
pulses. The `period increased through the real register path` test is the one
that proves the interface contract above holds in the assembled design.

**Phase 5 — README + waveforms. ✅ DONE.** `README.md` leads with the dead-time
bands, and carries the two carrier shapes, the swallowed pulse, the fault trip
and the three-phase gates. Every figure is a real SVG rendered from the VCDs by
`tools/vcd2svg.py`; `make -C sim waves` regenerates the set.

Better than the GTKWave screenshots this phase originally called for: vector
rather than raster, small enough to diff, reproducible from the simulation
rather than captured by hand, and they render inline on GitHub in both themes.
Buses render as an analog ramp instead of hex, which is what makes the
sawtooth-versus-triangle difference between the two carrier modes visible at a
glance. The one fragility: the time windows in `tools/make_waves.sh` are
hand-picked from the VCDs, so they need re-picking if the testbenches change.

The broken first FSM is kept at `docs/deadtime_v1_buggy.v` and `make -C sim bug`
reproduces the original failure, so the bug story is demonstrable rather than
retold.

**Phase 6a — center-aligned mode. ✅ DONE.** Up/down counter selected by
`CTRL[2]`, `f_pwm = f_clk / (2*period)`. This is what real three-phase drives
use: the pulse sits in the middle of the period rather than pinned to its
start, which lowers the harmonic content of the line-to-line voltage.

The detail that matters: **both turning points are held for a cycle**, so the
sequence is `0,1,..,top-1,top-1,..,1,0` and every count appears exactly twice.
Without the holds the endpoints appear once each, the high time comes out as
`2*duty-1` rather than `2*duty`, and 100% duty becomes unreachable. Holding
them makes the duty ratio identical to edge-aligned and keeps every expected
value a clean doubling.

`CTRL[2]` is **shadowed** while `CTRL[0]`/`CTRL[1]` stay immediate. That split
is a principle, not a convenience: a bit that shapes the waveform is
double-buffered, a bit that switches the output off is not. Changing mode
mid-period would emit one malformed period; delaying a stop by up to a period
is exactly the wrong trade.

`pwm_compare.v` is split out of `pwm_counter.v` here, so a multi-phase design
can share one carrier between channels.

**Phase 6b — three-phase. ✅ DONE.** `pwm3_top.v`: one carrier, three
`pwm_compare` + `deadtime` channels, six gate outputs, one fault input and one
dead-time value for the whole bridge.

One carrier for all three phases is the point, not an optimisation. It is the
LINE-TO-LINE voltage that matters, and that is the difference of two phase
voltages; give each phase its own counter and they drift, the difference picks
up beat frequencies, and the motor hears them. The 120-degree relationship is
not in the hardware at all — it is in the three duty values software writes.

Registers 0–3 are `pwm_regs` unchanged; `DUTY_B`/`DUTY_C` add two more shadow
registers on the same `update` enable, so all three duties commit on one edge.
A three-phase command is only meaningful as a set.

The last test walks the three duties around a sine table 120 degrees apart, in
center-aligned mode, checking every phase against its own commanded duty at
every step — which is what a drive's control loop actually does.

## 4. Verification — this is the deliverable

No SystemVerilog assertions available, so build the checkers as `always` blocks
in `tb/checkers.vh` and `` `include`` them. Any failure prints and calls
`$finish` with a nonzero-looking banner your Makefile greps for.

**Continuous checkers (run for the whole simulation, every test):**
- **C1 — shoot-through**: `if (pwm_h && pwm_l) FAIL`. The headline invariant.
- **C2 — dead-time**: on every rising edge of either output, check that at least
  `dt_q` clocks have elapsed since the falling edge of the other. Implement with
  a free-running cycle counter and two timestamp registers.
- **C3 — reset**: after any reset assertion, both outputs low within 1 cycle.

**Directed tests:**
| # | test | expected |
|---|------|----------|
| 1 | duty sweep 0…period, dt=5 | measured on-time == `duty - dt`, or 0 if `duty <= dt` |
| 2 | dt ∈ {0, 1, 2, 5, 20} | C2 holds; dt=0 still never overlaps |
| 3 | duty = 0 | `pwm_h` never rises, `pwm_l` steady high |
| 4 | duty = period | `pwm_h` steady high, `pwm_l` never rises |
| 5 | duty = dt - 1 (narrow pulse) | `pwm_h` never rises, no glitch on `pwm_l` |
| 6 | write duty mid-pulse | current period unchanged, next period updated |
| 7 | write period mid-pulse | no short/long runt period at the switchover |
| 8 | fault asserted mid-`pwm_h` | both low within 2 cycles |
| 9 | fault released mid-period | outputs stay off until next `update` pulse |
| 10 | pseudo-random stimulus (LFSR-driven duty/dt writes, 100k cycles) | C1–C3 hold |

Test 10 is cheap — an 8-bit LFSR in the testbench feeding random legal writes —
and it's the closest you get to constrained-random in plain Verilog. It's also
the test most likely to find a real bug in the FSM corner cases.

**Frequency check**: measure the wrap-to-wrap time and assert
`period_q == measured_cycles`. Catches off-by-one in the wrap comparison, which
is the single most common bug in this design.

## 5. Repo layout

```
pwm-deadtime/
  rtl/
    pwm_counter.v
    pwm_regs.v
    deadtime.v
    pwm_top.v
  tb/
    tb_pwm_counter.v
    tb_deadtime.v
    tb_pwm_top.v
    checkers.vh        # C1-C3, included by each tb
    tasks.vh           # measure_high_time, write_reg, expect_eq
  sim/
    Makefile           # make sim / make wave / make lint
  docs/
    timing.md          # the FSM table + a hand-drawn dead-time timing diagram
    waves/*.png
  README.md
```

Makefile targets:
```
sim:   iverilog -g2001 -Wall -o build/tb.vvp rtl/*.v tb/tb_pwm_top.v && vvp build/tb.vvp
wave:  gtkwave build/dump.vcd
lint:  iverilog -g2001 -Wall -tnull rtl/*.v      # catches width/latch warnings
```

## 6. RTL house rules (keep the code synthesizable)

- One clock, one reset. Async assert / sync deassert, or fully synchronous —
  pick one and use it everywhere.
- `always @(posedge clk)` with non-blocking `<=` for all sequential logic;
  blocking `=` only in combinational `always @(*)` blocks.
- Every `always @(*)` assigns every output on every path → no inferred latches.
  `iverilog -Wall` will tell you.
- No `#` delays, no `initial` blocks in `rtl/`. Those belong in `tb/` only.
- Size every constant (`16'd0`, not `0`) and every parameter comparison.
- Async inputs (`fault_n`) get a 2-FF synchronizer before anything else touches
  them.

## 7. Suggested order of work

1. Toolchain + VCD loop (Phase 0). Don't write RTL until a waveform opens.
2. `deadtime.v` **first**, not the counter. It's the hard part, it's independently
   testable, and getting it right early means Phase 4 is just wiring.
3. `pwm_counter.v`, then `pwm_regs.v` on top of it.
4. Integrate, add fault, run the random test overnight.
5. README with the zoomed dead-time waveform at the top.

Realistic effort: ~2 weekends for Phases 0–5 at a third-year level, most of it
in the testbench rather than the RTL. The RTL is maybe 250 lines total; the
testbench will be longer, and that ratio is itself worth mentioning in the README.

## 8. Honest limitations to list in the README

Naming what you didn't build reads as engineering maturity:
- Dead time reduces effective duty by `dt` clocks; no software compensation.
- Dead-time resolution is one clock cycle — no fine (sub-clock) delay line.
- No FPGA board bring-up; simulation only (unless you have a Basys/DE10 handy,
  in which case a blinking-LED demo at 1 Hz plus a scope shot of the real dead
  time is a very strong addition).
- Single-phase half-bridge; three-phase is the obvious extension.
- Simple write-strobe register interface, not AXI4-Lite.

## 9. Optional: synthesis numbers

`brew install yosys`, then `yosys -p "read_verilog rtl/*.v; synth -top pwm_top;
stat"` gives a cell count. Quoting "≈180 LUT-equivalent cells, no latches
inferred" in the README costs ten minutes and signals that you know RTL is meant
to become hardware. Skip the timing closure story — you don't have a real
target device and shouldn't pretend to.
