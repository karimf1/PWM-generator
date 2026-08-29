//============================================================================
// tb_pwm_top.v -- integration testbench
//
// Drives the design the way software would: through the register port, with
// an asynchronous fault line, measuring the gate outputs.
//
// Continuous checkers, running through every test:
//   C1  pwm_h and pwm_l are never both high            <- the master invariant
//   C2  a rise of either is >= dt clocks after the other fell
//   C3  both low whenever reset is asserted
//   T1  pwm_h high cycles per period == expected
//   T2  pwm_l high cycles per period == expected
//   T3  cycles between update pulses == period
//
// T1/T2/T3 only run when the TB has armed them with a settled config; C1-C3
// run unconditionally, including through faults, resets and reconfiguration.
//
// Verilog-2001. iverilog -g2001.
//============================================================================
`timescale 1ns/1ps

module tb_pwm_top;

    localparam CNT_W = 16;
    localparam DT_W  = 8;

    localparam [1:0] A_PERIOD = 2'd0, A_DUTY = 2'd1, A_DT = 2'd2, A_CTRL = 2'd3;

    reg              clk = 1'b0;
    reg              rst_n;
    reg              wr;
    reg  [1:0]       addr;
    reg  [CNT_W-1:0] wdata;
    reg              fault_n;
    wire             pwm_h, pwm_l, update, fault;

    always #5 clk = ~clk;

    pwm_top #(.CNT_W(CNT_W), .DT_W(DT_W)) dut (
        .clk (clk), .rst_n (rst_n),
        .wr (wr), .addr (addr), .wdata (wdata),
        .fault_n (fault_n),
        .pwm_h (pwm_h), .pwm_l (pwm_l), .update (update), .fault (fault)
    );

    //------------------------------------------------------------------
    // Monitor
    //------------------------------------------------------------------
    integer errors = 0, cyc = 0, windows = 0;
    integer win_len = 0, win_h = 0, win_l = 0;
    integer exp_period = 1, exp_h = 0, exp_l = 0;
    // Model of the DUT's dead-time shadow register.
    //
    // dt_wr_d, not dt_wr, is what the shadow loads: a write landing on the
    // update edge is read as its OLD value by the load side, because both are
    // registers on the same clock, so it commits at the FOLLOWING boundary.
    // Modelling that one-boundary lag matters -- without it the checker
    // demands a dead time the DUT has not been told about yet, and blames the
    // RTL for a gap that was correct for the dt actually in force.
    //
    // And the commit is keyed on upd_d, not update: `update` is COMBINATIONAL
    // in pwm_counter, so the value visible at a negedge is the one registers
    // will latch at the NEXT posedge. Keying on it directly moves the model's
    // commit a full cycle ahead of the DUT's.
    //
    // dte then takes the minimum of committed and pending, so a dt write in
    // flight makes the check conservative rather than wrong.
    //
    // Finally the C2 recording uses dte_d, one cycle older still. The FSM
    // latches dt into its counter from the value in force BEFORE the edge it
    // enters S_DEAD on, and a shadow load landing on that same edge changes
    // dt_q after it. Record the post-edge value and the checker demands a
    // dead time the FSM was never given.
    integer dt_cur = 255, dt_wr = 255, dt_wr_d = 255, dte = 255, dte_d = 255;
    reg     ctrl_center = 1'b0;              // TB's copy of CTRL[2]
    integer t_h_fall = -1000000, t_l_fall = -1000000;
    integer dt_at_h_fall = 0, dt_at_l_fall = 0;
    integer nb = 0;
    integer last_len = 0, last_h = 0, last_l = 0;
    reg     h_d = 1'b0, l_d = 1'b0, upd_d = 1'b0, meas_en = 1'b0;

    always @(negedge clk) begin
        cyc = cyc + 1;

        if (rst_n === 1'b0) begin
            dt_cur = 255; dt_wr = 255; dt_wr_d = 255;
        end else if (upd_d === 1'b1) dt_cur = dt_wr_d;
        dte = (dt_wr_d < dt_wr) ? dt_wr_d : dt_wr;
        if (dt_cur < dte) dte = dt_cur;
        if (dte < 1) dte = 1;

        // C1 -- the reason this project exists
        if (pwm_h === 1'b1 && pwm_l === 1'b1)
            fail("C1 SHOOT-THROUGH: pwm_h and pwm_l both high");

        // C3
        if (rst_n === 1'b0 && (pwm_h !== 1'b0 || pwm_l !== 1'b0))
            fail("C3 outputs not low during reset");

        // C2 -- min-since-fall, so a dt write mid-gap can never false-fail
        if (h_d === 1'b1 && pwm_h === 1'b0) begin
            t_h_fall = cyc; dt_at_h_fall = dte_d;
        end else if (dte_d < dt_at_h_fall) dt_at_h_fall = dte_d;

        if (l_d === 1'b1 && pwm_l === 1'b0) begin
            t_l_fall = cyc; dt_at_l_fall = dte_d;
        end else if (dte_d < dt_at_l_fall) dt_at_l_fall = dte_d;

        if (h_d === 1'b0 && pwm_h === 1'b1)
            if ((cyc - t_l_fall) < dt_at_l_fall)
                fail("C2 dead time too short before pwm_h rise");
        if (l_d === 1'b0 && pwm_l === 1'b1)
            if ((cyc - t_h_fall) < dt_at_h_fall)
                fail("C2 dead time too short before pwm_l rise");

        h_d = pwm_h; l_d = pwm_l;

        // T1/T2/T3
        if (meas_en === 1'b1) begin
            win_len = win_len + 1;
            if (pwm_h === 1'b1) win_h = win_h + 1;
            if (pwm_l === 1'b1) win_l = win_l + 1;
            if (upd_d === 1'b1) begin
                if (nb >= 2) begin
                    if (win_len != exp_period)
                        fail_num("T3 cycles per period", win_len, exp_period);
                    if (win_h   != exp_h)
                        fail_num("T1 pwm_h cycles",      win_h,   exp_h);
                    if (win_l   != exp_l)
                        fail_num("T2 pwm_l cycles",      win_l,   exp_l);
                    windows = windows + 1;
                end
                last_len = win_len; last_h = win_h; last_l = win_l;
                nb = nb + 1; win_len = 0; win_h = 0; win_l = 0;
            end
        end else begin
            nb = 0; win_len = 0; win_h = 0; win_l = 0;
        end

        upd_d = update; dt_wr_d = dt_wr; dte_d = dte;
    end

    //------------------------------------------------------------------
    // Helpers
    //------------------------------------------------------------------
    task fail(input [8*80-1:0] msg);
        begin
            errors = errors + 1;
            if (errors <= 25) $display("    ** FAIL  cyc=%0d : %0s", cyc, msg);
        end
    endtask

    task fail_num(input [8*40-1:0] what, input integer got, input integer exp);
        begin
            errors = errors + 1;
            if (errors <= 25)
                $display("    ** FAIL  cyc=%0d  %0s = %0d, expected %0d",
                         cyc, what, got, exp);
        end
    endtask

    task expect_eq(input [8*44-1:0] what, input integer got, input integer exp);
        begin
            if (got == exp) $display("       ok  %0s = %0d", what, got);
            else begin
                errors = errors + 1;
                $display("    ** FAIL  %0s = %0d, expected %0d", what, got, exp);
            end
        end
    endtask

    task step(input integer n);
        integer i;
        begin
            for (i = 0; i < n; i = i + 1) @(negedge clk);
            #1;
        end
    endtask

    task wreg(input [1:0] a, input [CNT_W-1:0] d);
        begin
            wr = 1'b1; addr = a; wdata = d;
            if (a == A_DT)   dt_wr       = {24'd0, d[DT_W-1:0]};
            if (a == A_CTRL) ctrl_center = d[2];
            step(1);
            wr = 1'b0;
        end
    endtask

    task run_periods(input integer n);
        integer k;
        begin
            for (k = 0; k < n; k = k + 1) begin
                @(negedge clk);
                while (update !== 1'b1) @(negedge clk);
            end
            #1;
        end
    endtask

    // What the gate outputs should look like for a given config.
    //
    // w_hi/w_lo are how long pwm_raw is high/low per period. The FSM spends
    // t_eff clocks in S_DEAD on every pwm_raw edge, so normally each output
    // loses t_eff. But if one half of the request is no longer than the dead
    // time it is swallowed: that output never turns on at all, the FSM only
    // enters S_DEAD once per period, and the OTHER output loses just t_eff
    // rather than t_eff plus the swallowed half.
    task set_expect(input integer p, input integer d, input integer t);
        integer d_eff, t_eff, w_hi, w_lo, top;
        begin
            top        = (p < 1) ? 1 : p;
            d_eff      = (d > top) ? top : d;
            t_eff      = (t < 1) ? 1 : t;
            // Center-aligned visits every count twice: the period and the
            // high time both double, so the duty ratio is unchanged and the
            // dead-time arithmetic below is identical.
            exp_period = ctrl_center ? 2*top   : top;
            w_hi       = ctrl_center ? 2*d_eff : d_eff;
            w_lo       = exp_period - w_hi;

            if (w_hi == 0) begin                   // pwm_raw never rises
                exp_h = 0;              exp_l = exp_period;
            end else if (w_lo == 0) begin          // pwm_raw never falls
                exp_h = exp_period;     exp_l = 0;
            end else if (w_hi <= t_eff) begin      // high request swallowed
                exp_h = 0;              exp_l = exp_period - t_eff;
            end else if (w_lo <= t_eff) begin      // low request swallowed
                exp_h = exp_period - t_eff;
                exp_l = 0;
            end else begin                         // both sides conduct
                exp_h = w_hi - t_eff;   exp_l = w_lo - t_eff;
            end
        end
    endtask

    integer w0;
    // n must be >= 3: the window checker skips two boundaries after arming,
    // so anything less measures nothing and silently reports success.
    task run_cfg(input integer p, input integer d, input integer t,
                 input integer n);
        begin
            meas_en = 1'b0;
            wreg(A_PERIOD, p[CNT_W-1:0]);
            wreg(A_DUTY,   d[CNT_W-1:0]);
            wreg(A_DT,     t[CNT_W-1:0]);
            run_periods(3);                 // commit, and let the gates settle
            set_expect(p, d, t);
            w0 = windows;
            meas_en = 1'b1;
            run_periods(n);
            meas_en = 1'b0;
            if (windows == w0) begin
                errors = errors + 1;
                $display("    ** FAIL  measurement never fired for %0d/%0d/%0d",
                         p, d, t);
            end else
                $display("       ok  p=%0d d=%0d dt=%0d -> len %0d/%0d  h %0d/%0d  l %0d/%0d  (%0d periods)",
                         p, d, t, last_len, exp_period, last_h, exp_h,
                         last_l, exp_l, windows - w0);
        end
    endtask

    task banner(input [8*80-1:0] name);
        begin $display("\n[TEST] %0s", name); end
    endtask

    //------------------------------------------------------------------
    // Stimulus
    //------------------------------------------------------------------
    integer i, n_rand = 300;
    reg [15:0] lfsr = 16'hf0f0;

    initial begin
        if ($value$plusargs("configs=%d", n_rand)) ;
        if ($value$plusargs("seed=%h",    lfsr))   ;

        $dumpfile("build/tb_pwm_top.vcd");
        $dumpvars(0, tb_pwm_top);

        rst_n = 1'b0; wr = 1'b0; addr = 2'd0; wdata = {CNT_W{1'b0}};
        fault_n = 1'b1;
        step(4);

        //--------------------------------------------------------------
        banner("out of reset the gates are dark, and stay dark");
        expect_eq("pwm_h", pwm_h, 0);
        expect_eq("pwm_l", pwm_l, 0);
        rst_n = 1'b1; step(20);
        expect_eq("pwm_h with CTRL untouched", pwm_h, 0);
        expect_eq("pwm_l with CTRL untouched", pwm_l, 0);
        expect_eq("fault clear by now",        fault, 0);

        //--------------------------------------------------------------
        banner("enable via CTRL, then measure the gates end to end");
        wreg(A_CTRL, 16'h0001);             // en=1, force_off=0
        run_cfg(40, 20, 4, 12);             // 50% duty
        run_cfg(40, 10, 4, 12);             // 25%
        run_cfg(40, 32, 4, 12);             // 80%

        //--------------------------------------------------------------
        banner("duty extremes");
        run_cfg(40,  0, 4, 8);              // 0%   -> low side only
        run_cfg(40, 40, 4, 8);              // 100% -> high side only
        run_cfg(40, 50, 4, 8);              // >100 -> clamps
        run_cfg(40,  4, 4, 8);              // duty == dt -> swallowed
        run_cfg(40,  3, 4, 8);              // duty <  dt -> swallowed
        run_cfg(40, 39, 4, 8);              // narrowest low pulse

        //--------------------------------------------------------------
        banner("dead-time extremes");
        run_cfg(40, 20,  0, 8);             // dt=0 -> floor of 1
        run_cfg(40, 20,  1, 8);
        run_cfg(40, 20, 19, 8);             // dt just under duty
        run_cfg(40, 20, 20, 8);             // dt == duty -> swallowed

        //--------------------------------------------------------------
        // The phase-4 trap. period_q/duty_q are register outputs feeding the
        // counter's combinational wrap logic. If that contract were broken,
        // an INCREASED period would cancel the wrap and T3 would measure
        // period_new - period_old. This is the test that proves the wiring.
        //--------------------------------------------------------------
        banner("period increased through the real register path");
        run_cfg(20, 10, 3, 8);
        run_cfg(60, 30, 3, 8);              // tripled
        run_cfg(25, 12, 3, 8);              // and back down
        run_cfg(200, 50, 3, 4);             // and way up

        //--------------------------------------------------------------
        banner("realistic: 100 MHz / 5000 = 20 kHz, 25% duty, 500 ns dead time");
        run_cfg(5000, 1250, 50, 3);
        $display("       ok  f_pwm = %0d Hz, dead time = %0d ns",
                 100000000 / 5000, 50 * 10);

        //--------------------------------------------------------------
        // Same duty ratio, half the switching frequency, pulse centred in
        // the period rather than pinned to its start.
        //--------------------------------------------------------------
        banner("center-aligned mode through the register port");
        wreg(A_CTRL, 16'h0005);             // en=1, force_off=0, center=1
        run_cfg(40, 20, 4, 8);              // 50%, now 80 clocks per period
        run_cfg(40, 10, 4, 8);              // 25%
        run_cfg(40,  0, 4, 6);              // 0%
        run_cfg(40, 40, 4, 6);              // 100% -- reachable because both
        run_cfg(40, 50, 4, 6);              // turning points are held
        run_cfg(40,  2, 4, 6);              // high request swallowed
        run_cfg(40, 39, 4, 6);
        run_cfg(40, 20, 0, 6);
        run_cfg(5000, 1250, 50, 4);
        $display("       ok  f_pwm = %0d Hz center-aligned (half of edge)",
                 100000000 / (2*5000));

        banner("center-aligned: fault and force_off still behave");
        run_cfg(40, 20, 4, 4);
        fault_n = 1'b0; step(4);
        expect_eq("pwm_h after trip", pwm_h, 0);
        expect_eq("pwm_l after trip", pwm_l, 0);
        fault_n = 1'b1; run_periods(3);
        set_expect(40, 20, 4); w0 = windows; nb = 0; meas_en = 1'b1;
        run_periods(6); meas_en = 1'b0;
        if (windows > w0) $display("       ok  resumed clean in center mode");
        else begin errors = errors + 1; $display("    ** FAIL  did not resume"); end

        banner("back to edge-aligned");
        wreg(A_CTRL, 16'h0001);
        run_cfg(40, 20, 4, 8);

        //--------------------------------------------------------------
        banner("fault trips the gates, synchroniser costs 2 clocks");
        run_cfg(40, 20, 4, 4);
        wreg(A_CTRL, 16'h0001);
        run_periods(1); step(10);           // land mid-pulse
        fault_n = 1'b0;
        step(4);
        expect_eq("fault flag",         fault, 1);
        expect_eq("pwm_h after trip",   pwm_h, 0);
        expect_eq("pwm_l after trip",   pwm_l, 0);
        step(60);
        expect_eq("still dark, pwm_h",  pwm_h, 0);
        expect_eq("still dark, pwm_l",  pwm_l, 0);

        //--------------------------------------------------------------
        banner("fault released -- gates stay dark until a period boundary");
        fault_n = 1'b1;
        step(4);
        expect_eq("fault flag cleared", fault, 0);
        // released deliberately mid-period; nothing may light up early
        step(3);
        expect_eq("pwm_h still dark",   pwm_h, 0);
        run_periods(3);
        set_expect(40, 20, 4); w0 = windows; nb = 0; meas_en = 1'b1;
        run_periods(8); meas_en = 1'b0;
        if (windows > w0) $display("       ok  resumed clean, %0d periods measured",
                                   windows - w0);
        else begin errors = errors + 1; $display("    ** FAIL  did not resume"); end

        //--------------------------------------------------------------
        // Simulation cannot produce metastability; the synchroniser is there
        // for real silicon. What this shows is that the logic does not care
        // which part of the cycle the trip arrives in.
        //--------------------------------------------------------------
        banner("fault asserted off the clock edge");
        @(negedge clk); #3.7; fault_n = 1'b0;
        step(4);
        expect_eq("pwm_h after off-edge trip", pwm_h, 0);
        expect_eq("pwm_l after off-edge trip", pwm_l, 0);
        @(negedge clk); #2.4; fault_n = 1'b1;
        step(2); run_periods(3);

        //--------------------------------------------------------------
        banner("CTRL.force_off blanks the gates but keeps the counter running");
        set_expect(40, 20, 4); nb = 0; meas_en = 1'b1; run_periods(4);
        meas_en = 1'b0;
        wreg(A_CTRL, 16'h0003);             // en=1, force_off=1
        step(3);
        expect_eq("pwm_h blanked", pwm_h, 0);
        expect_eq("pwm_l blanked", pwm_l, 0);
        run_periods(2);
        expect_eq("update still pulsing (counter alive)", update, 1);
        wreg(A_CTRL, 16'h0001);
        run_periods(3);
        set_expect(40, 20, 4); w0 = windows; nb = 0; meas_en = 1'b1;
        run_periods(6); meas_en = 1'b0;
        if (windows > w0) $display("       ok  resumed in step with the period");
        else begin errors = errors + 1; $display("    ** FAIL  did not resume"); end

        //--------------------------------------------------------------
        banner("en=0 coasts (both dark), it does not brake (low side on)");
        wreg(A_CTRL, 16'h0000);             // en=0, force_off=0
        step(6);
        expect_eq("pwm_h when disabled", pwm_h, 0);
        expect_eq("pwm_l when disabled", pwm_l, 0);
        step(40);
        expect_eq("still dark, pwm_h", pwm_h, 0);
        expect_eq("still dark, pwm_l", pwm_l, 0);
        wreg(A_CTRL, 16'h0001);
        run_periods(3);

        //--------------------------------------------------------------
        banner("reset asserted mid-conduction");
        run_periods(1); step(10);
        rst_n = 1'b0; step(3);
        expect_eq("pwm_h in reset", pwm_h, 0);
        expect_eq("pwm_l in reset", pwm_l, 0);
        rst_n = 1'b1; step(6);
        expect_eq("gates dark until CTRL rewritten", pwm_h | pwm_l, 0);

        //--------------------------------------------------------------
        banner("randomized configs and fault pulses (C1-C3 only)");
        wreg(A_CTRL, 16'h0001);
        for (i = 0; i < n_rand; i = i + 1) begin
            lfsr = {lfsr[14:0], lfsr[15]^lfsr[13]^lfsr[12]^lfsr[10]};
            case (lfsr[3:2])
                2'd0: wreg(A_PERIOD, {8'd0, lfsr[13:8]} + 16'd4);
                2'd1: wreg(A_DUTY,   {10'd0, lfsr[15:10]});
                2'd2: wreg(A_DT,     {12'd0, lfsr[7:4]});
                2'd3: wreg(A_CTRL,   {13'd0, lfsr[11], lfsr[9:8]});
            endcase
            fault_n = ~(lfsr[7:5] == 3'd0);
            step({29'd0, lfsr[6:4]} + 1);
        end
        fault_n = 1'b1;
        $display("       ok  %0d random writes survived, seed %04h", n_rand, lfsr);

        //--------------------------------------------------------------
        if (errors == 0) $display("\n==== TEST PASSED ====\n");
        else             $display("\n==== TEST FAILED (%0d errors) ====\n", errors);
        $finish;
    end

    initial begin
        #200_000_000;
        $display("\n==== TEST FAILED (timeout) ====\n");
        $finish;
    end

endmodule
