# Icarus Verilog simulation flow. Run from the repo root: `make -C sim`
#
#   make                     lint, then run all five testbenches
#   make lint                elaborate the RTL alone -- catches inferred
#                            latches, width mismatches, unconnected ports
#   make tb_deadtime         run one testbench by name
#   make soak                run every randomized test long, over four seeds
#   make wave TB=tb_deadtime open that testbench's VCD in GTKWave
#   make bug                 reproduce the shoot-through in the first version
#                            of the dead-time FSM (expected to FAIL)
#   make waves               regenerate the README figures from the VCDs
#   make clean               delete build/

IVERILOG := iverilog
VVP      := vvp
FLAGS    := -g2001 -Wall -Wno-timescale

RTL      := ../rtl/deadtime.v ../rtl/pwm_compare.v ../rtl/pwm_counter.v \
            ../rtl/pwm_regs.v ../rtl/pwm_top.v ../rtl/pwm3_top.v
BUILD    := build

TB       ?= tb_deadtime
TBS      := tb_deadtime tb_pwm_counter tb_pwm_regs tb_pwm_top tb_pwm3_top

.PHONY: all sim lint wave waves clean bug soak $(TBS)

all: $(TBS)

# run every testbench
$(TBS): lint | $(BUILD)
	@echo "=== $@ ==="
	$(IVERILOG) $(FLAGS) -o $(BUILD)/$@.vvp $(RTL) ../tb/$@.v
	$(VVP) $(BUILD)/$@.vvp | tee $(BUILD)/$@.log
	@grep -q "TEST PASSED" $(BUILD)/$@.log || (echo "$@ FAILED"; exit 1)

$(BUILD):
	mkdir -p $(BUILD)

sim: lint | $(BUILD)
	$(IVERILOG) $(FLAGS) -o $(BUILD)/$(TB).vvp $(RTL) ../tb/$(TB).v
	$(VVP) $(BUILD)/$(TB).vvp | tee $(BUILD)/$(TB).log
	@grep -q "TEST PASSED" $(BUILD)/$(TB).log || (echo "SIMULATION FAILED"; exit 1)

lint: | $(BUILD)
	$(IVERILOG) $(FLAGS) -tnull $(RTL)
	@echo "lint clean"

wave:
	gtkwave $(BUILD)/$(TB).vcd &

# Long randomized runs. The directed tests run every time too, so a soak that
# passes is a superset of `make`, not a different thing.
SEEDS := beef 1234 c0de 0001
soak: $(TBS)
	@rc=0; for s in $(SEEDS); do \
	    for t in $(TBS); do \
	        printf "%-16s seed %s  " $$t $$s; \
	        $(VVP) $(BUILD)/$$t.vvp +cycles=400000 +configs=3000 +seed=$$s \
	            > $(BUILD)/$$t.soak.log; \
	        grep -E "TEST (PASSED|FAILED)" $(BUILD)/$$t.soak.log || true; \
	        grep -q "TEST PASSED" $(BUILD)/$$t.soak.log || rc=1; \
	    done; \
	done; \
	[ $$rc -eq 0 ] || { echo "SOAK FAILED -- see $(BUILD)/*.soak.log"; exit 1; }

# Reproduce the shoot-through the randomized test found in the first version
# of the dead-time FSM. Expected to FAIL -- that is the point. See README.md.
bug: | $(BUILD)
	$(IVERILOG) $(FLAGS) -o $(BUILD)/bug.vvp \
	    ../docs/deadtime_v1_buggy.v ../tb/tb_deadtime.v
	-$(VVP) $(BUILD)/bug.vvp | tee $(BUILD)/bug.log
	@mv -f $(BUILD)/tb_deadtime.vcd $(BUILD)/bug.vcd
	@echo "--- first C2 violation ---"
	@grep -m1 "C2 dead time" $(BUILD)/bug.log \
	    || { echo "(none) -- v1 no longer shoot-throughs; the counterexample is stale"; \
	         exit 1; }

# Figures in README.md come from the VCDs, so the testbenches must have
# run first. Never hand-edit docs/waves/*.svg.
waves: $(TBS)
	../tools/make_waves.sh

clean:
	rm -rf $(BUILD)
