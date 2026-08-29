//============================================================================
// tb_pwm3_top.v -- three-phase integration testbench
//
// Continuous checkers, per phase, running through every test:
//   C1  pwm_h[i] and pwm_l[i] are never both high
//   C2  a rise of either is >= dt clocks after the other fell
//   C3  all six gates low whenever reset is asserted
//   T1  pwm_h[i] high cycles per period == expected from THAT phase's duty
//   T2  pwm_l[i] high cycles per period == expected
//   T3  cycles between update pulses == period (one carrier, so one answer)
//
// The last test drives the three duties from a sine table with 120-degree
// offsets, which is what a real drive's control loop does, and checks every
// phase against its own commanded duty at every step.
//
// Verilog-2001. iverilog -g2001.
//============================================================================
`timescale 1ns/1ps

module tb_pwm3_top;

    localparam CNT_W = 16;
    localparam DT_W  = 8;

    localparam [2:0] A_PERIOD = 3'd0, A_DUTY_A = 3'd1, A_DT   = 3'd2,
                     A_CTRL   = 3'd3, A_DUTY_B = 3'd4, A_DUTY_C = 3'd5;

    reg              clk = 1'b0;
    reg              rst_n;
    reg              wr;
    reg  [2:0]       addr;
    reg  [CNT_W-1:0] wdata;
    reg              fault_n;
    wire [2:0]       pwm_h, pwm_l;
    wire             update, fault;

    always #5 clk = ~clk;

    pwm3_top #(.CNT_W(CNT_W), .DT_W(DT_W)) dut (
        .clk (clk), .rst_n (rst_n),
        .wr (wr), .addr (addr), .wdata (wdata),
        .fault_n (fault_n),
        .pwm_h (pwm_h), .pwm_l (pwm_l), .update (update), .fault (fault)
    );

    //------------------------------------------------------------------
    // Monitor
    //------------------------------------------------------------------
    integer errors = 0, cyc = 0, windows = 0, j;
    integer win_len = 0, exp_period = 1, nb = 0;
    integer win_h [0:2], win_l [0:2], exp_h [0:2], exp_l [0:2];
    integer t_h_fall [0:2], t_l_fall [0:2], dt_at_h [0:2], dt_at_l [0:2];
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
    reg [2:0] h_d = 3'b000, l_d = 3'b000;
    reg       upd_d = 1'b0, meas_en = 1'b0, ctrl_center = 1'b0;

    initial begin
        for (j = 0; j < 3; j = j + 1) begin
            win_h[j] = 0; win_l[j] = 0; exp_h[j] = 0; exp_l[j] = 0;
            t_h_fall[j] = -1000000; t_l_fall[j] = -1000000;
            dt_at_h[j] = 0; dt_at_l[j] = 0;
        end
    end

    always @(negedge clk) begin
        cyc = cyc + 1;

        if (rst_n === 1'b0) begin
            dt_cur = 255; dt_wr = 255; dt_wr_d = 255;
        end else if (upd_d === 1'b1) dt_cur = dt_wr_d;
        dte = (dt_wr_d < dt_wr) ? dt_wr_d : dt_wr;
        if (dt_cur < dte) dte = dt_cur;
        if (dte < 1) dte = 1;

        for (j = 0; j < 3; j = j + 1) begin
            // C1 -- the reason this project exists, once per leg
            if (pwm_h[j] === 1'b1 && pwm_l[j] === 1'b1)
                fail_ph("C1 SHOOT-THROUGH", j);

            // C3
            if (rst_n === 1'b0 && (pwm_h[j] !== 1'b0 || pwm_l[j] !== 1'b0))
                fail_ph("C3 gate not low during reset", j);

            // C2, min-since-fall so a dt write in flight cannot false-fail
            if (h_d[j] === 1'b1 && pwm_h[j] === 1'b0) begin
                t_h_fall[j] = cyc; dt_at_h[j] = dte_d;
            end else if (dte_d < dt_at_h[j]) dt_at_h[j] = dte_d;

            if (l_d[j] === 1'b1 && pwm_l[j] === 1'b0) begin
                t_l_fall[j] = cyc; dt_at_l[j] = dte_d;
            end else if (dte_d < dt_at_l[j]) dt_at_l[j] = dte_d;

            if (h_d[j] === 1'b0 && pwm_h[j] === 1'b1)
                if ((cyc - t_l_fall[j]) < dt_at_l[j])
                    fail_ph("C2 dead time short before pwm_h rise", j);
            if (l_d[j] === 1'b0 && pwm_l[j] === 1'b1)
                if ((cyc - t_h_fall[j]) < dt_at_h[j])
                    fail_ph("C2 dead time short before pwm_l rise", j);
        end

        h_d = pwm_h; l_d = pwm_l;

        if (meas_en === 1'b1) begin
            win_len = win_len + 1;
            for (j = 0; j < 3; j = j + 1) begin
                if (pwm_h[j] === 1'b1) win_h[j] = win_h[j] + 1;
                if (pwm_l[j] === 1'b1) win_l[j] = win_l[j] + 1;
            end
            if (upd_d === 1'b1) begin
                if (nb >= 2) begin
                    if (win_len != exp_period)
                        fail_num("T3 cycles per period", 0, win_len, exp_period);
                    for (j = 0; j < 3; j = j + 1) begin
                        if (win_h[j] != exp_h[j])
                            fail_num("T1 pwm_h cycles", j, win_h[j], exp_h[j]);
                        if (win_l[j] != exp_l[j])
                            fail_num("T2 pwm_l cycles", j, win_l[j], exp_l[j]);
                    end
                    windows = windows + 1;
                end
                nb = nb + 1; win_len = 0;
                for (j = 0; j < 3; j = j + 1) begin win_h[j]=0; win_l[j]=0; end
            end
        end else begin
            nb = 0; win_len = 0;
            for (j = 0; j < 3; j = j + 1) begin win_h[j]=0; win_l[j]=0; end
        end

        upd_d = update; dt_wr_d = dt_wr; dte_d = dte;
    end

    //------------------------------------------------------------------
    // Helpers
    //------------------------------------------------------------------
    task fail_ph(input [8*60-1:0] msg, input integer ph);
        begin
            errors = errors + 1;
            if (errors <= 20)
                $display("    ** FAIL  cyc=%0d  phase %0s : %0s",
                         cyc, ph == 0 ? "A" : (ph == 1 ? "B" : "C"), msg);
        end
    endtask

    task fail_num(input [8*32-1:0] what, input integer ph,
                  input integer got, input integer exp);
        begin
            errors = errors + 1;
            if (errors <= 20)
                $display("    ** FAIL  cyc=%0d  phase %0s  %0s = %0d, expected %0d",
                         cyc, ph == 0 ? "A" : (ph == 1 ? "B" : "C"),
                         what, got, exp);
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

    task wreg(input [2:0] a, input [CNT_W-1:0] d);
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

    // Same case analysis as the single-phase testbench, applied per phase.
    task expect_phase(input integer ph, input integer p, input integer d,
                      input integer t);
        integer d_eff, t_eff, w_hi, w_lo, top;
        begin
            top   = (p < 1) ? 1 : p;
            d_eff = (d > top) ? top : d;
            t_eff = (t < 1) ? 1 : t;
            exp_period = ctrl_center ? 2*top   : top;
            w_hi       = ctrl_center ? 2*d_eff : d_eff;
            w_lo       = exp_period - w_hi;

            if (w_hi == 0) begin
                exp_h[ph] = 0;              exp_l[ph] = exp_period;
            end else if (w_lo == 0) begin
                exp_h[ph] = exp_period;     exp_l[ph] = 0;
            end else if (w_hi <= t_eff) begin
                exp_h[ph] = 0;              exp_l[ph] = exp_period - t_eff;
            end else if (w_lo <= t_eff) begin
                exp_h[ph] = exp_period - t_eff; exp_l[ph] = 0;
            end else begin
                exp_h[ph] = w_hi - t_eff;   exp_l[ph] = w_lo - t_eff;
            end
        end
    endtask

    integer w0;
    // n must be >= 3: the window checker skips two boundaries after arming.
    task run3(input integer p, input integer da, input integer db,
              input integer dc, input integer t, input integer n);
        begin
            meas_en = 1'b0;
            wreg(A_PERIOD, p[CNT_W-1:0]);
            wreg(A_DUTY_A, da[CNT_W-1:0]);
            wreg(A_DUTY_B, db[CNT_W-1:0]);
            wreg(A_DUTY_C, dc[CNT_W-1:0]);
            wreg(A_DT,     t[CNT_W-1:0]);
            run_periods(3);
            expect_phase(0, p, da, t);
            expect_phase(1, p, db, t);
            expect_phase(2, p, dc, t);
            w0 = windows; meas_en = 1'b1;
            run_periods(n);
            meas_en = 1'b0;
            if (windows == w0) begin
                errors = errors + 1;
                $display("    ** FAIL  measurement never fired");
            end else
                $display("       ok  p=%0d  A=%0d/%0d  B=%0d/%0d  C=%0d/%0d  (%0d periods)",
                         p, da, exp_h[0], db, exp_h[1], dc, exp_h[2],
                         windows - w0);
        end
    endtask

    task banner(input [8*80-1:0] name);
        begin $display("\n[TEST] %0s", name); end
    endtask

    //------------------------------------------------------------------
    // Stimulus
    //------------------------------------------------------------------
    integer i, k, n_rand = 200;
    reg [15:0] lfsr = 16'h2468;
    // one electrical cycle of a sine, 12 steps, for period = 100
    reg [CNT_W-1:0] sine [0:11];

    initial begin
        sine[0]=50; sine[1]=70; sine[2]=85; sine[3]=90;
        sine[4]=85; sine[5]=70; sine[6]=50; sine[7]=30;
        sine[8]=15; sine[9]=10; sine[10]=15; sine[11]=30;
    end

    initial begin
        if ($value$plusargs("configs=%d", n_rand)) ;
        if ($value$plusargs("seed=%h",    lfsr))   ;

        $dumpfile("build/tb_pwm3_top.vcd");
        $dumpvars(0, tb_pwm3_top);

        rst_n = 1'b0; wr = 1'b0; addr = 3'd0; wdata = {CNT_W{1'b0}};
        fault_n = 1'b1;
        step(4);

        //--------------------------------------------------------------
        banner("out of reset all six gates are dark");
        expect_eq("pwm_h", pwm_h, 0);
        expect_eq("pwm_l", pwm_l, 0);
        rst_n = 1'b1; step(20);
        expect_eq("pwm_h with CTRL untouched", pwm_h, 0);
        expect_eq("pwm_l with CTRL untouched", pwm_l, 0);

        //--------------------------------------------------------------
        banner("three independent duties on one shared carrier");
        wreg(A_CTRL, 16'h0001);
        run3(60, 30, 20, 10, 4, 8);
        run3(60, 45, 30, 15, 4, 8);
        run3(60, 10, 50, 25, 6, 8);

        //--------------------------------------------------------------
        banner("extremes on all three legs at once");
        run3(60,  0, 30, 60, 4, 6);        // 0%, 50%, 100% simultaneously
        run3(60, 60,  0,  3, 4, 6);        // 100%, 0%, swallowed
        run3(60, 59,  1, 30, 4, 6);        // narrowest low, narrowest high

        //--------------------------------------------------------------
        banner("center-aligned three-phase");
        wreg(A_CTRL, 16'h0005);
        run3(60, 30, 20, 10, 4, 6);
        run3(60,  0, 60, 30, 4, 6);
        run3(50, 25, 12, 40, 8, 6);
        wreg(A_CTRL, 16'h0001);
        run3(60, 30, 20, 10, 4, 6);

        //--------------------------------------------------------------
        banner("one fault kills the whole bridge");
        run3(60, 30, 20, 10, 4, 4);
        run_periods(1); step(15);
        fault_n = 1'b0; step(4);
        expect_eq("fault flag",        fault, 1);
        expect_eq("all high sides off", pwm_h, 0);
        expect_eq("all low sides off",  pwm_l, 0);
        step(150);
        expect_eq("still dark, pwm_h", pwm_h, 0);
        expect_eq("still dark, pwm_l", pwm_l, 0);
        fault_n = 1'b1; run_periods(3);
        expect_phase(0, 60, 30, 4); expect_phase(1, 60, 20, 4);
        expect_phase(2, 60, 10, 4);
        w0 = windows; nb = 0; meas_en = 1'b1; run_periods(6); meas_en = 1'b0;
        if (windows > w0) $display("       ok  all three legs resumed together");
        else begin errors = errors + 1; $display("    ** FAIL  did not resume"); end

        //--------------------------------------------------------------
        // What a drive's control loop actually does: hold the carrier fixed
        // and walk the three duties around a sine, 120 degrees apart. Every
        // phase is checked against its own commanded duty at every step.
        //--------------------------------------------------------------
        banner("sine modulation, 120 degrees apart, two electrical cycles");
        wreg(A_CTRL, 16'h0005);             // center-aligned, as a real drive
        for (k = 0; k < 24; k = k + 1) begin
            run3(100, sine[k % 12], sine[(k + 4) % 12], sine[(k + 8) % 12],
                 6, 4);
        end
        $display("       ok  24 modulation steps, every phase tracked its duty");

        //--------------------------------------------------------------
        banner("randomized duties, dead times, modes and faults");
        wreg(A_CTRL, 16'h0001);
        for (i = 0; i < n_rand; i = i + 1) begin
            lfsr = {lfsr[14:0], lfsr[15]^lfsr[13]^lfsr[12]^lfsr[10]};
            case (lfsr[2:0])
                3'd0: wreg(A_PERIOD, {9'd0, lfsr[13:7]} + 16'd4);
                3'd1: wreg(A_DUTY_A, {10'd0, lfsr[15:10]});
                3'd2: wreg(A_DUTY_B, {10'd0, lfsr[14:9]});
                3'd3: wreg(A_DUTY_C, {10'd0, lfsr[13:8]});
                3'd4: wreg(A_DT,     {12'd0, lfsr[7:4]});
                3'd5: wreg(A_CTRL,   {13'd0, lfsr[11], lfsr[9:8]});
                default: step(1);
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
        #300_000_000;
        $display("\n==== TEST FAILED (timeout) ====\n");
        $finish;
    end

endmodule
