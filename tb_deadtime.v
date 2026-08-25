//============================================================================
// tb_deadtime.v -- standalone testbench for deadtime.v
//
// pwm_raw is driven by hand here rather than by the PWM counter, so the nasty
// cases (1-cycle request, request exactly dt long, dt=0, back-to-back edges,
// fault mid-pulse) can be injected directly.
//
// Timing convention: the clock is 10 ns. Monitors run at negedge with no
// delay; stimulus changes signals at negedge+1ns. So every signal the monitor
// samples is the one the DUT actually latched on the preceding posedge, with
// no race between the two.
//
// Verilog-2001. iverilog -g2001.
//============================================================================
`timescale 1ns/1ps

module tb_deadtime;

    localparam DT_W = 8;

    reg              clk = 1'b0;
    reg              rst_n;
    reg  [DT_W-1:0]  dt;
    reg              pwm_raw;
    reg              force_off;
    wire             pwm_h, pwm_l;

    always #5 clk = ~clk;

    deadtime #(.DT_W(DT_W)) dut (
        .clk       (clk),
        .rst_n     (rst_n),
        .dt        (dt),
        .pwm_raw   (pwm_raw),
        .force_off (force_off),
        .pwm_h     (pwm_h),
        .pwm_l     (pwm_l)
    );

    //------------------------------------------------------------------
    // Monitor: continuous checkers C1-C3 + measurement counters
    //------------------------------------------------------------------
    integer errors   = 0;
    integer cyc      = 0;
    integer dte      = 1;          // effective dead time = max(dt,1)
    integer h_cycles = 0, l_cycles = 0;
    integer h_rises  = 0, l_rises  = 0;
    integer t_h_fall = -1000000, t_l_fall = -1000000;
    integer dt_at_h_fall = 0, dt_at_l_fall = 0;
    reg     h_d = 1'b0, l_d = 1'b0;

    always @(negedge clk) begin
        cyc = cyc + 1;
        dte = (dt == {DT_W{1'b0}}) ? 1 : dt;

        // C1 -- the headline invariant: never both on
        if (pwm_h === 1'b1 && pwm_l === 1'b1)
            fail("C1 SHOOT-THROUGH: pwm_h and pwm_l both high");

        // C3 -- outputs low whenever reset is asserted
        if (rst_n === 1'b0 && (pwm_h !== 1'b0 || pwm_l !== 1'b0))
            fail("C3 outputs not low during reset");

        // falling edges: remember when, and the dt in force at the time
        if (h_d === 1'b1 && pwm_h === 1'b0) begin
            t_h_fall = cyc; dt_at_h_fall = dte;
        end else if (dte < dt_at_h_fall) dt_at_h_fall = dte;

        if (l_d === 1'b1 && pwm_l === 1'b0) begin
            t_l_fall = cyc; dt_at_l_fall = dte;
        end else if (dte < dt_at_l_fall) dt_at_l_fall = dte;

        // C2 -- a rise must be >= dt clocks after the OTHER output fell
        if (h_d === 1'b0 && pwm_h === 1'b1) begin
            h_rises = h_rises + 1;
            if ((cyc - t_l_fall) < dt_at_l_fall)
                fail("C2 dead time too short before pwm_h rise");
        end
        if (l_d === 1'b0 && pwm_l === 1'b1) begin
            l_rises = l_rises + 1;
            if ((cyc - t_h_fall) < dt_at_h_fall)
                fail("C2 dead time too short before pwm_l rise");
        end

        if (pwm_h === 1'b1) h_cycles = h_cycles + 1;
        if (pwm_l === 1'b1) l_cycles = l_cycles + 1;

        h_d = pwm_h;
        l_d = pwm_l;
    end

    //------------------------------------------------------------------
    // Helpers
    //------------------------------------------------------------------
    task fail(input [8*80-1:0] msg);
        begin
            errors = errors + 1;
            $display("    ** FAIL  cyc=%0d  t=%0t : %0s", cyc, $time, msg);
        end
    endtask

    task expect_eq(input [8*40-1:0] what, input integer got, input integer exp);
        begin
            if (got == exp)
                $display("       ok  %0s = %0d", what, got);
            else begin
                errors = errors + 1;
                $display("    ** FAIL  %0s = %0d, expected %0d", what, got, exp);
            end
        end
    endtask

    // advance n clock cycles; enter and leave at negedge+1ns
    task step(input integer n);
        integer i;
        begin
            for (i = 0; i < n; i = i + 1) @(negedge clk);
            #1;
        end
    endtask

    task clear_counts;
        begin
            h_cycles = 0; l_cycles = 0; h_rises = 0; l_rises = 0;
        end
    endtask

    task banner(input [8*80-1:0] name);
        begin
            $display("\n[TEST] %0s", name);
            clear_counts;
        end
    endtask

    //------------------------------------------------------------------
    // Stimulus
    //------------------------------------------------------------------
    integer i;
    integer n_rand = 20000;             // +cycles=<n> to soak for longer
    reg [15:0] lfsr = 16'hace1;         // +seed=<hex> to change the pattern

    initial begin
        if ($value$plusargs("cycles=%d", n_rand)) ;
        if ($value$plusargs("seed=%h",   lfsr))   ;
        $dumpfile("build/tb_deadtime.vcd");
        $dumpvars(0, tb_deadtime);

        rst_n = 1'b0; dt = 8'd5; pwm_raw = 1'b0; force_off = 1'b0;
        step(4);

        //--------------------------------------------------------------
        banner("reset release -- dead time first, then the low side");
        rst_n = 1'b1;
        expect_eq("pwm_h at reset", pwm_h, 0);
        expect_eq("pwm_l at reset", pwm_l, 0);
        step(4);                                    // dt=5, still counting
        expect_eq("pwm_l mid dead time", pwm_l, 0);
        step(1);
        expect_eq("pwm_l after dead time", pwm_l, 1);
        expect_eq("pwm_h after dead time", pwm_h, 0);

        //--------------------------------------------------------------
        banner("dt=5, 20-cycle request -> on-time = 20-5");
        dt = 8'd5; pwm_raw = 1'b1; step(20);
        pwm_raw = 1'b0; step(20);
        expect_eq("pwm_h cycles", h_cycles, 15);
        expect_eq("pwm_h rises",  h_rises,  1);

        //--------------------------------------------------------------
        banner("dt=5, request exactly 5 cycles -> swallowed");
        pwm_raw = 1'b1; step(5);
        pwm_raw = 1'b0; step(20);
        expect_eq("pwm_h cycles", h_cycles, 0);
        expect_eq("pwm_h rises",  h_rises,  0);

        //--------------------------------------------------------------
        banner("dt=5, request 6 cycles -> 1 cycle of on-time");
        pwm_raw = 1'b1; step(6);
        pwm_raw = 1'b0; step(20);
        expect_eq("pwm_h cycles", h_cycles, 1);

        //--------------------------------------------------------------
        banner("dt=5, 1-cycle request -> swallowed, no glitch on pwm_l");
        pwm_raw = 1'b1; step(1);
        pwm_raw = 1'b0; step(20);
        expect_eq("pwm_h cycles", h_cycles, 0);
        expect_eq("pwm_h rises",  h_rises,  0);

        //--------------------------------------------------------------
        banner("dt=0 -> floor of 1 cycle of dead time, on-time = 20-1");
        dt = 8'd0; pwm_raw = 1'b1; step(20);
        pwm_raw = 1'b0; step(20);
        expect_eq("pwm_h cycles", h_cycles, 19);

        //--------------------------------------------------------------
        banner("dt=1 -> on-time = 20-1");
        dt = 8'd1; pwm_raw = 1'b1; step(20);
        pwm_raw = 1'b0; step(20);
        expect_eq("pwm_h cycles", h_cycles, 19);

        //--------------------------------------------------------------
        banner("dt=20, 20-cycle request -> swallowed");
        dt = 8'd20; pwm_raw = 1'b1; step(20);
        pwm_raw = 1'b0; step(40);
        expect_eq("pwm_h cycles", h_cycles, 0);

        //--------------------------------------------------------------
        banner("dt=20, 30-cycle request -> on-time = 10");
        pwm_raw = 1'b1; step(30);
        pwm_raw = 1'b0; step(40);
        expect_eq("pwm_h cycles", h_cycles, 10);

        //--------------------------------------------------------------
        // Gap shorter than dt: pwm_h turns back on out of the dead-time
        // state without a full dead time. That is correct -- pwm_l never
        // turned on, so there was nothing to interlock against.
        //--------------------------------------------------------------
        banner("dt=5, gap (3) shorter than dt -> low side never turns on");
        dt = 8'd5;
        pwm_raw = 1'b1; step(20);
        pwm_raw = 1'b0; step(3);
        pwm_raw = 1'b1; step(20);
        expect_eq("pwm_l rises in gap", l_rises,  0);
        expect_eq("pwm_h rises",        h_rises,  2);
        expect_eq("pwm_h cycles",       h_cycles, 33);
        pwm_raw = 1'b0; step(20);

        //--------------------------------------------------------------
        banner("force_off asserted mid-conduction");
        dt = 8'd5; pwm_raw = 1'b1; step(20);
        expect_eq("pwm_h before fault", pwm_h, 1);
        clear_counts;
        force_off = 1'b1; step(2);
        expect_eq("pwm_h during fault",  pwm_h,    0);
        expect_eq("pwm_l during fault",  pwm_l,    0);
        expect_eq("pwm_h cycles in fault", h_cycles, 0);
        expect_eq("pwm_l cycles in fault", l_cycles, 0);
        step(20);
        expect_eq("still off after 20 cycles", h_cycles + l_cycles, 0);

        //--------------------------------------------------------------
        banner("force_off released -- dead time before resuming");
        clear_counts;
        force_off = 1'b0; step(5);      // 1 cycle to leave S_FAULT + 5 dt
        expect_eq("pwm_h still off", pwm_h, 0);
        step(1);
        expect_eq("pwm_h back on",   pwm_h, 1);
        pwm_raw = 1'b0; step(20);

        //--------------------------------------------------------------
        // Regressions for the fault/reset-release hole: the high side has
        // just been conducting, so the low side must not turn on until a
        // full dead time has elapsed, even though pwm_raw is already low.
        //--------------------------------------------------------------
        banner("regression: fault release does not shortcut the dead time");
        dt = 8'd10; force_off = 1'b0; pwm_raw = 1'b1; step(30);
        expect_eq("pwm_h conducting", pwm_h, 1);
        pwm_raw = 1'b0; force_off = 1'b1; step(1);
        expect_eq("pwm_h dropped by fault", pwm_h, 0);
        force_off = 1'b0; step(9);
        expect_eq("pwm_l still off at t+10", pwm_l, 0);
        step(2);
        expect_eq("pwm_l on after dead time", pwm_l, 1);

        banner("regression: reset release does not shortcut the dead time");
        pwm_raw = 1'b1; step(30);
        expect_eq("pwm_h conducting", pwm_h, 1);
        pwm_raw = 1'b0; rst_n = 1'b0; step(1);
        expect_eq("pwm_h dropped by reset", pwm_h, 0);
        rst_n = 1'b1; step(9);
        expect_eq("pwm_l still off at t+10", pwm_l, 0);
        step(2);
        expect_eq("pwm_l on after dead time", pwm_l, 1);

        //--------------------------------------------------------------
        // The closest thing to constrained-random in plain Verilog: an LFSR
        // driving the request, the dead-time value, and rare fault pulses.
        // No expected values -- C1/C2/C3 do all the work.
        //--------------------------------------------------------------
        $display("\n[TEST] randomized stress: %0d cycles, seed %04h (C1-C3 only)",
                 n_rand, lfsr);
        clear_counts;
        for (i = 0; i < n_rand; i = i + 1) begin
            lfsr = {lfsr[14:0], lfsr[15]^lfsr[13]^lfsr[12]^lfsr[10]};
            if (lfsr[3:0]  == 4'h0)  pwm_raw   = ~pwm_raw;
            if (lfsr[9:4]  == 6'h2a) dt        = {4'd0, lfsr[15:12]};
            force_off = (lfsr[9:4] == 6'h15);
            step(1);
        end
        $display("       ok  survived %0d random cycles", n_rand);

        //--------------------------------------------------------------
        banner("reset asserted mid-conduction");
        force_off = 1'b0; dt = 8'd5; pwm_raw = 1'b1; step(20);
        rst_n = 1'b0; step(3);
        expect_eq("pwm_h in reset", pwm_h, 0);
        expect_eq("pwm_l in reset", pwm_l, 0);
        rst_n = 1'b1; step(10);

        //--------------------------------------------------------------
        if (errors == 0)
            $display("\n==== TEST PASSED ====\n");
        else
            $display("\n==== TEST FAILED (%0d errors) ====\n", errors);
        $finish;
    end

    // watchdog
    initial begin
        #10_000_000;
        $display("\n==== TEST FAILED (timeout) ====\n");
        $finish;
    end

endmodule
