# pwm-deadtime

A PWM timer for a MOSFET half-bridge, in Verilog-2001. Runtime-writable
frequency and duty, glitch-free shadow registers, edge- and center-aligned
carriers, a three-phase variant, and a dead-time FSM that guarantees the high
and low side of a leg are never on at the same time.

![Dead-time insertion](docs/waves/deadtime.svg)

Turn-**off** is immediate. Turn-**on** waits `dt` clocks. The shaded bands are
that gap. It exists because the two transistors in a half-bridge sit directly
across the DC bus: if the one turning on gets there before the one turning off
has left, they short the bus through themselves, and neither survives it.

## Key features

| module | what it does | lines |
|---|---|---|
| `rtl/deadtime.v` | complementary outputs + dead-time FSM | 61 |
| `rtl/pwm_compare.v` | one channel's comparator | 16 |
| `rtl/pwm_counter.v` | carrier: edge- or center-aligned | 51 |
| `rtl/pwm_regs.v` | register file, shadow buffering | 59 |
| `rtl/pwm_top.v` | single-phase: integration, fault synchroniser | 68 |
| `rtl/pwm3_top.v` | three-phase: one carrier, three legs | 102 |

- **A dead-time interlock that cannot be bypassed**, including on the fault-release
  and reset-release paths, and with a floor of one clock even when `dt = 0`.
- **Glitch-free reconfiguration.** Period, duty, dead time and counting mode are
  double-buffered and commit on a period boundary; the output bits are not.
- **Both carrier shapes** from one counter — sawtooth for edge-aligned,
  triangle for center-aligned — with every degenerate register value defined
  rather than illegal.
- **A three-phase variant sharing a single carrier**, so the line-to-line
  voltage stays clean.
- **A fault input that resets to tripped**, through a two-flop synchroniser, so
  the gates are dark out of reset until software explicitly releases them.
- **Registered gate outputs**, decoded from the FSM's *next* state rather than
  combinationally from its current one.

357 lines of RTL. Every figure below is rendered from the waveforms the design
actually produces, not drawn by hand.

## How it works

```
              +----------------+        +--------------+     +-----------+
 wr/addr/data | pwm_regs       | period |              | raw | deadtime  | pwm_h
 ------------>| shadow buffers |------->| pwm_counter  |---->|    FSM    |------->
              |                | duty   | (the carrier)|     |           | pwm_l
              +----------------+ dt     +--------------+     +-----------+------->
                    ^                          |                   ^ dt
                    +-------- update ----------+-------------------+
```

### pwm_counter — the carrier

Two counting modes, same duty ratio, different pulse placement.

![Edge-aligned carrier](docs/waves/carrier_edge.svg)

![Center-aligned carrier](docs/waves/carrier_center.svg)

Edge-aligned is a sawtooth: `f_pwm = f_clk / period`, pulse pinned to the start
of the period. Center-aligned is a triangle: `f_pwm = f_clk / (2*period)`, pulse
sitting in the middle. Real three-phase drives use center-aligned because it
lowers the harmonic content of the line-to-line voltage.

The detail that makes center-aligned work is that **both turning points are held
for a cycle**, so the sequence is `0,1,..,top-1,top-1,..,1,0` and every count
appears exactly twice. Without the holds the endpoints appear once each, the
high time comes out as `2*duty-1` instead of `2*duty`, and 100% duty becomes
unreachable. Holding them makes every expected value a clean doubling of the
edge-aligned case.

Degenerate values are **defined, not illegal** — a register write can produce
any of them and the counter must not be able to run away:

| written | result |
|---|---|
| `duty = 0` | static low, 0%, no edges at all |
| `duty >= period` | static high, 100%, no edges at all |
| `period = 0` or `1` | period clamps to 1 |
| `period` reduced below current `cnt` | turns around next cycle, no run to 0xFFFF |

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

**Why one dead-time state and not two.** The obvious first cut has *two* —
`S_DT_LH` and `S_DT_HL`, one per direction — each returning early if the request
is withdrawn mid-count. For normal switching that shortcut is safe: the side
that was already on never turned off, so there is nothing to interlock against.
But the fault-release and reset-release paths re-enter the same state *after the
other side has been conducting*, and there an early return turns a device on
before its complement has stopped. Collapsing both into one non-abortable
`S_DEAD` removes the case entirely — and the safe version is one state
**smaller** than the clever one.

`pwm_h` and `pwm_l` are decoded from `next_state` and **registered**, never
decoded combinationally from `state`. A decode of state bits can glitch while
they settle, and a glitch here is a shoot-through in the real bridge.

Three consequences, all intentional. First, **a request narrower than the dead
time is swallowed entirely** — which is why the achievable duty range shrinks as
dead time grows:

![Swallowed pulse](docs/waves/swallowed.svg)

Second, **delivered on-time is `duty - dt` clocks, not `duty`.** Real inverters
compensate for this in software. This one does not. Third, **`dt = 0` still
inserts one clock of dead time**: the floor is 1, not 0, on purpose, because a
safety interlock that can be configured to zero is not a safety interlock.

### pwm_regs — why a shadow register

Writes land in staging registers at any time. The active registers load from
them only when `update` pulses, during the last cycle of a period. So a duty
written in the middle of a pulse can never shorten the pulse already in flight —
the output for the current period is whatever was committed at its start.

| addr | byte | name | bits | buffered? |
|---|---|---|---|---|
| 0 | 0x0 | `PERIOD` | `[15:0]` counter top | shadowed |
| 1 | 0x4 | `DUTY` / `DUTY_A` | `[15:0]` compare | shadowed |
| 2 | 0x8 | `DEADTIME` | `[7:0]` clocks | shadowed |
| 3 | 0xC | `CTRL` | `[0]` en, `[1]` force_off | **immediate** |
| | | | `[2]` center | shadowed |
| 4 | 0x10 | `DUTY_B` | `[15:0]` phase B | shadowed (3-phase) |
| 5 | 0x14 | `DUTY_C` | `[15:0]` phase C | shadowed (3-phase) |

**`CTRL` is split on a principle, not for convenience:** a bit that *shapes* the
waveform is double-buffered, a bit that switches the output *off* is not.
Changing counting mode mid-period would emit one malformed period, so `center`
waits for the boundary. Delaying a stop by up to a period is exactly the wrong
trade, so `en` and `force_off` land immediately. Stop means stop.

**Reset values are the safe end of every range, not zero:** `PERIOD` = max
(slowest switching), `DUTY` = 0 (0% output), `DEADTIME` = max (most conservative
interlock), `en` = 0, `force_off` = 1 (gates held off until software explicitly
releases them). So `CTRL` does not read back as zero after reset. That is
intentional — the safe state of an output-disable bit is asserted.

### pwm_top — the fault path

![Fault trip and recovery](docs/waves/fault.svg)

**A 2-FF synchroniser on the fault input.** `fault_n` is asynchronous. An async
signal driving FSM logic directly can be sampled mid-transition by different
flops in different states, leaving the FSM somewhere illegal. It resets to
*tripped*, so the gates are dark out of reset and stay dark until a healthy
`fault_n` has propagated. In the trace above, the trip costs two clocks through
the synchroniser and the gates go dark on the third.

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

### pwm3_top — three phases, one carrier

![Three-phase gates](docs/waves/three_phase.svg)

Six gates, three `pwm_compare` + `deadtime` channels, **one shared carrier**.
All three legs rise together and fall at different times: same carrier,
different duties.

Sharing the carrier is the point, not an optimisation. It is the *line-to-line*
voltage that matters, and that is the difference of two phase voltages. Give
each phase its own counter and they drift, the difference picks up beat
frequencies, and the motor hears them.

The 120° phase relationship is **not in the hardware** — it is in the three duty
values software writes. The carrier stays common; the modulation is what
differs. One `DEADTIME` and one fault input serve all three legs: a bridge fault
kills the bridge, and dead time is a property of the transistors rather than of
which leg they sit in.

## Known limitations

Named rather than hidden:

- **Dead time reduces effective duty by `dt` clocks.** No software compensation.
- **Dead-time resolution is one clock cycle.** No fine sub-clock delay line.
- **Multi-register writes are not atomic.** `PERIOD` and `DUTY` commit
  independently, so a write pair that straddles a period boundary can leave one
  period running a mixed config — and if that mix has `duty >= period`, that is
  one period at 100% duty. Workaround: change frequency with the timer stopped.
- **The fault is not latched.** Clearing `fault_n` re-arms automatically at the
  next period boundary. Real drives usually latch the trip so software must
  acknowledge it, which stops a chattering fault causing repeated restarts.
- **16-bit write port, not AXI4-Lite.** A bus wrapper is a separate job.
- **Simulation only.** No FPGA bring-up, no scope traces, no timing closure
  against a real device. The synchroniser is there for real silicon; simulation
  cannot produce metastability to exercise it.

## Possible improvements

Roughly in order of how much they are worth doing.

**1. A `LOAD` commit bit.** One bit in `CTRL` that arms the shadow load, so
`PERIOD` and `DUTY` commit together on the next boundary instead of
independently. This is what the STM32 timer's UG bit is for, and it closes the
worst remaining hole: a frequency change that lands across a period boundary and
produces one period at 100 % duty into a live bridge.

**2. Latch the fault.** Add a sticky trip register that software must write to
clear. A chattering current-sense comparator currently produces a restart per
period; latched, it produces one trip and stays down until someone looks at it.
Pair it with a status register so the cause is readable.

**3. Dead-time compensation.** The delivered on-time is `duty - dt`. A drive
loop can correct for that, but the correction depends on the sign of the phase
current, which the timer does not know. Bringing a current-sign input in and
adding `dt` back on the appropriate edge is the standard fix, and it is the
difference between open-loop distortion at low modulation index and a clean
sine.

**4. An AXI4-Lite or APB wrapper.** The 16-bit write port is fine for a
testbench and useless for dropping into a real SoC. The register map is already
word-addressed, so this is a bus adapter rather than a redesign.

**5. Sub-clock dead-time resolution.** At 100 MHz, one clock is 10 ns and a
typical GaN half-bridge wants dead time resolved finer than that. A carry-chain
or a DDR-output delay line would give fractional-cycle steps — at the cost of
being device-specific, which is why it is not here.

**6. Synchronous fault-to-gate path in hardware.** The trip currently costs two
synchroniser clocks before the gates go dark. For a desat or overcurrent event
that is a long time. An asynchronous combinational blank on the output
enables — with the FSM still doing the clean recovery afterwards — would cut it
to a gate delay. That is a deliberate trade of one safety property against
another, which is why it deserves a decision rather than a default.

**7. Per-leg fault inputs on the three-phase variant.** One fault kills the
bridge today, which is correct for a shoot-through or a bus fault. A per-phase
overcurrent is a different event and might justify a different response.

**8. Phase-shifted carriers as an option.** The shared carrier is right for a
motor drive. Interleaved converters want the opposite — deliberately offset
carriers — and the counter already has everything needed to offer a per-channel
phase offset.

**9. FPGA bring-up.** Everything here is simulation. Getting it onto a board
with a real half-bridge, a current probe and a scope is what would turn the
dead-time claim from a property of the source into a measurement.

`PLAN.md` has the full design notes, the phase plan, and the interface contract
between `pwm_regs` and `pwm_counter`.
