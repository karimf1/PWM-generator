//============================================================================
// tb_pwm_counter.v -- standalone testbench for pwm_counter.v
//
// The continuous checker measures every PWM period the DUT produces:
//   P1  cycles between update pulses  == period      (the off-by-one killer)
//   P2  pwm_raw high cycles / period  == min(duty, period)
//   P3  cnt stays inside 0 .. period-1
//
// Two modelling details that make the expected values exact rather than
// approximate:
//
// 1. period/duty are driven from a SHADOW REGISTER here, loaded on update,
//    which is what pwm_regs.v will be in hardware. Driving them
//    combinationally instead changes them one cycle before the wrap edge,
//    and the counter then evaluates wrap against the new period on the very
//    edge it was supposed to wrap -- an increase cancels the wrap entirely.
//    pwm_counter depends on its period/duty inputs being register outputs
//    that settle after the clock edge, not before it.
//
// 2. The window boundary is the update pulse DELAYED BY ONE CYCLE, because
//    pwm_raw is registered and so lags cnt by one. Aligning the window to
//    pwm_raw instead of to cnt means every window sees exactly one duty
//    value and the transition window needs no special case.
//
// Verilog-2001. iverilog -g2001.
//============================================================================
`timescale 1ns/1ps

module tb_pwm_counter;

    localparam CNT_W = 16;

    reg              clk = 1'b0;
    reg              rst_n;
    reg              en;
    reg  [CNT_W-1:0] period, duty;              // the shadow registers
    reg  [CNT_W-1:0] period_next, duty_next;    // written at any time
    reg              shadow_en = 1'b1;
    wire [CNT_W-1:0] cnt;
    wire             update, pwm_raw;

    always #5 clk = ~clk;

    // stand-in for pwm_regs.v
    always @(posedge clk) begin
        if (update && shadow_en) begin
            period <= period_next;
            duty   <= duty_next;
        end
    end

    pwm_counter #(.CNT_W(CNT_W)) dut (
        .clk (clk), .rst_n (rst_n), .en (en),
        .period (period), .duty (duty),
        .cnt (cnt), .update (update), .pwm_raw (pwm_raw)
    );

    //------------------------------------------------------------------
    // Monitor
    //------------------------------------------------------------------
    integer errors = 0, cyc = 0, windows = 0;
    integer win_len = 0, win_high = 0;
    integer exp_period = 1, exp_duty = 0;
    integer raw_rises = 0, raw_falls = 0;
    // update is held high while the timer is disabled, so the first boundary
    // after en rises lands one cycle out of phase. Skip two boundaries after
    // any enable gap; steady-state windows are all checked.
    integer nb = 0;
    reg     check_en = 1'b1, raw_d = 1'b0, upd_d = 1'b0;

    always @(negedge clk) begin
        cyc = cyc + 1;

        if (raw_d === 1'b0 && pwm_raw === 1'b1) raw_rises = raw_rises + 1;
        if (raw_d === 1'b1 && pwm_raw === 1'b0) raw_falls = raw_falls + 1;
        raw_d = pwm_raw;

        if (en === 1'b1 && check_en === 1'b1) begin
            if (cnt >= exp_period)
                fail_num("P3 cnt out of range", cnt, exp_period - 1);

            win_len = win_len + 1;
            if (pwm_raw === 1'b1) win_high = win_high + 1;

            if (upd_d === 1'b1) begin
                if (nb >= 2) begin
                    if (win_len  != exp_period)
                        fail_num("P1 cycles per period", win_len,  exp_period);
                    if (win_high != exp_duty)
                        fail_num("P2 high cycles",       win_high, exp_duty);
                    windows = windows + 1;
                end
                nb = nb + 1; win_len = 0; win_high = 0;
                // latch the config governing the window that starts now; the
                // shadow register has already taken its new value by here
                exp_period = (period < 16'd1) ? 1 : period;
                exp_duty   = (duty >= exp_period) ? exp_period : duty;
            end
        end else begin
            nb = 0; win_len = 0; win_high = 0;
        end

        upd_d = update;
    end

    //------------------------------------------------------------------
    // Helpers
    //------------------------------------------------------------------
    task fail_num(input [8*40-1:0] what, input integer got, input integer exp);
        begin
            errors = errors + 1;
            if (errors <= 10)
                $display("    ** FAIL  cyc=%0d  %0s = %0d, expected %0d",
                         cyc, what, got, exp);
        end
    endtask

    task expect_eq(input [8*40-1:0] what, input integer got, input integer exp);
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

    // Config may be written at ANY time -- the shadow register decides when
    // it takes effect. That is the whole point of the interface.
    task cfg(input [CNT_W-1:0] p, input [CNT_W-1:0] d);
        begin
            period_next = p;
            duty_next   = d;
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

    integer w0;
    task expect_checked;
        begin
            if (windows == w0) begin
                errors = errors + 1;
                $display("    ** FAIL  window checker never fired");
            end else
                $display("       ok  %0d periods measured", windows - w0);
        end
    endtask

    task banner(input [8*80-1:0] name);
        begin
            $display("\n[TEST] %0s", name);
            w0 = windows; raw_rises = 0; raw_falls = 0;
        end
    endtask

    //------------------------------------------------------------------
    // Stimulus
    //------------------------------------------------------------------
    integer i, n_rand = 200;
    reg [15:0] lfsr = 16'hbeef;

    initial begin
        if ($value$plusargs("configs=%d", n_rand)) ;
        if ($value$plusargs("seed=%h",    lfsr))   ;

        $dumpfile("build/tb_pwm_counter.vcd");
        $dumpvars(0, tb_pwm_counter);

        rst_n = 1'b0; en = 1'b0;
        period = 16'd10; duty = 16'd4; cfg(16'd10, 16'd4);
        exp_period = 10; exp_duty = 4;
        step(4);

        //--------------------------------------------------------------
        banner("held in reset / disabled");
        expect_eq("cnt",     cnt,     0);
        expect_eq("pwm_raw", pwm_raw, 0);
        rst_n = 1'b1; step(6);
        expect_eq("cnt while disabled",     cnt,     0);
        expect_eq("pwm_raw while disabled", pwm_raw, 0);
        expect_eq("update while disabled",  update,  1);

        //--------------------------------------------------------------
        banner("period=10 duty=4, 20 periods");
        en = 1'b1; run_periods(20);
        expect_checked;

        //--------------------------------------------------------------
        banner("duty = 0 -> static low, no edges at all");
        cfg(16'd10, 16'd0); run_periods(2);
        raw_rises = 0;
        run_periods(10);
        expect_checked;
        expect_eq("pwm_raw rises", raw_rises, 0);
        expect_eq("pwm_raw level", pwm_raw,   0);

        //--------------------------------------------------------------
        banner("duty = period -> static high, no edges at all");
        cfg(16'd10, 16'd10); run_periods(2);
        raw_falls = 0;
        run_periods(10);
        expect_checked;
        expect_eq("pwm_raw falls", raw_falls, 0);
        expect_eq("pwm_raw level", pwm_raw,   1);

        //--------------------------------------------------------------
        banner("duty > period -> clamps to 100%, still no edges");
        cfg(16'd10, 16'd15); run_periods(2);
        raw_falls = 0;
        run_periods(10);
        expect_checked;
        expect_eq("pwm_raw falls", raw_falls, 0);

        //--------------------------------------------------------------
        banner("duty = 1 and duty = period-1 (narrowest pulses)");
        cfg(16'd10, 16'd1); run_periods(8);
        cfg(16'd10, 16'd9); run_periods(8);
        expect_checked;

        //--------------------------------------------------------------
        banner("degenerate periods: 2, 1, 0");
        cfg(16'd2, 16'd1); run_periods(8);
        cfg(16'd1, 16'd1); run_periods(8);
        cfg(16'd0, 16'd0); run_periods(8);
        expect_checked;

        //--------------------------------------------------------------
        banner("realistic: 100 MHz / 5000 = 20 kHz at 25% duty");
        cfg(16'd5000, 16'd1250); run_periods(4);
        expect_checked;
        $display("       ok  f_pwm = %0d Hz, duty = %0d %%",
                 100000000 / 5000, (1250 * 100) / 5000);

        //--------------------------------------------------------------
        // Every window is checked against the config latched at its start,
        // so these writes landing mid-period prove the current period is
        // unaffected and the change appears on the next one.
        //--------------------------------------------------------------
        banner("writes land mid-period, take effect at the boundary");
        cfg(16'd40, 16'd10); run_periods(2);
        step(17);  cfg(16'd40, 16'd30);   // mid-pulse
        run_periods(3);
        step(33);  cfg(16'd60, 16'd5);    // late in the period
        run_periods(3);
        step(1);   cfg(16'd25, 16'd24);   // right after a wrap
        run_periods(3);
        expect_checked;

        //--------------------------------------------------------------
        banner("disable mid-period -> stops and rearms at 0");
        cfg(16'd100, 16'd50); run_periods(2); step(37);
        en = 1'b0; step(2);
        expect_eq("cnt after disable",     cnt,     0);
        expect_eq("pwm_raw after disable", pwm_raw, 0);
        step(20);
        expect_eq("cnt stays parked", cnt, 0);
        en = 1'b1; run_periods(3);

        //--------------------------------------------------------------
        // Bypass the shadow register and write period directly while the
        // counter is already past the new value. pwm_regs.v exists to stop
        // this, but the counter must recover instead of running to 0xFFFF.
        //--------------------------------------------------------------
        banner("period shrunk below cnt mid-period -> wraps next cycle");
        cfg(16'd1000, 16'd500); run_periods(2);
        check_en = 1'b0; shadow_en = 1'b0;
        step(400);
        period = 16'd50;
        step(2);
        if (cnt < 16'd50) $display("       ok  cnt back in range = %0d", cnt);
        else begin
            errors = errors + 1;
            $display("    ** FAIL  cnt did not recover = %0d", cnt);
        end
        shadow_en = 1'b1; check_en = 1'b1;
        cfg(16'd50, 16'd25); run_periods(5);
        expect_checked;

        //--------------------------------------------------------------
        banner("randomized configs at random times (P1-P3 only)");
        for (i = 0; i < n_rand; i = i + 1) begin
            lfsr = {lfsr[14:0], lfsr[15]^lfsr[13]^lfsr[12]^lfsr[10]};
            cfg({10'd0, lfsr[5:0]} + 16'd2,      // period 2 .. 65
                {10'd0, lfsr[13:8]});            // duty   0 .. 63
            step({28'd0, lfsr[3:0]});            // write at an arbitrary phase
            run_periods(3);
        end
        expect_checked;
        $display("       ok  %0d random configs, seed %04h", n_rand, lfsr);

        //--------------------------------------------------------------
        if (errors == 0) $display("\n==== TEST PASSED ====\n");
        else             $display("\n==== TEST FAILED (%0d errors) ====\n", errors);
        $finish;
    end

    initial begin
        #50_000_000;
        $display("\n==== TEST FAILED (timeout) ====\n");
        $finish;
    end

endmodule
