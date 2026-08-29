#!/bin/sh
# Regenerate every figure in README.md from the VCDs the testbenches produce.
#
#   make -C sim && tools/make_waves.sh
#
# The time windows below are hand-picked from those VCDs, so they shift if the
# testbenches change. If a figure comes out empty or flat, re-pick its window:
# dump the signal you care about out of the VCD, find the interesting span, and
# note that times here are in ps with a 10 ns clock (one cycle = 10000).
set -e
cd "$(dirname "$0")/.."
V="python3 tools/vcd2svg.py"
B=sim/build
O=docs/waves
mkdir -p $O

# steady half-bridge switching: period 40, duty 20, dt 4
$V $B/tb_pwm_top.vcd tb_pwm_top.dut pwm_raw,pwm_h,pwm_l 655975000 656855000 10000 \
   $O/deadtime.svg --shade pwm_h,pwm_l \
   --title "Half-bridge gates, period 40 / duty 20 / dt 4 (shaded: both gates off)"

# a request no longer than the dead time
$V $B/tb_deadtime.vcd tb_deadtime pwm_raw,pwm_h,pwm_l 475000 705000 10000 \
   $O/swallowed.svg --shade pwm_h,pwm_l \
   --title "Request of 5 clocks with dt = 5: swallowed, neither gate turns on"

# the two carrier shapes, same duty ratio
$V $B/tb_pwm_counter.vcd tb_pwm_counter cnt,update,pwm_raw 155000 545000 10000 \
   $O/carrier_edge.svg \
   --title "Edge-aligned: sawtooth carrier, period 10 = 10 clocks, duty 4"
$V $B/tb_pwm_counter.vcd tb_pwm_counter cnt,update,pwm_raw 245455000 245895000 10000 \
   $O/carrier_center.svg \
   --title "Center-aligned: triangle carrier, period 10 = 20 clocks, duty 4"

# trip and recovery
$V $B/tb_pwm_top.vcd tb_pwm_top fault_n,fault,update,pwm_h,pwm_l \
   1823891000 1824841000 10000 $O/fault.svg --shade pwm_h,pwm_l \
   --title "Fault trip: gates dark on the third clock, resume only at a period boundary"

# three phases sharing one carrier
$V $B/tb_pwm3_top.vcd tb_pwm3_top \
   'pwm_h[0],pwm_l[0],pwm_h[1],pwm_l[1],pwm_h[2],pwm_l[2]' \
   655595000 656295000 10000 $O/three_phase.svg \
   --title "Three phases on one carrier: duties 30 / 20 / 10 of 60, dt = 4" \
   --label 'pwm_h[0]=A high,pwm_l[0]=A low,pwm_h[1]=B high,pwm_l[1]=B low,pwm_h[2]=C high,pwm_l[2]=C low'
