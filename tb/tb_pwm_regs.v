//============================================================================
// tb_pwm_regs.v -- standalone testbench for pwm_regs.v
//
// Continuous checkers, running through every test:
//   R1  *_q never changes on a cycle where update was low
//   R2  on every update, *_q equals the last value written to that register
//   R3  en_q / force_off_q track CTRL on the very next cycle -- control that
//       switches the output off is never allowed to be delayed
//
// R2 is only well defined when a write and an update do not land on the same
// edge; the random test keeps them apart and the "write during update"
// directed test covers that case explicitly with the checker off.
//
// Verilog-2001. iverilog -g2001.
//============================================================================
`timescale 1ns/1ps

module tb_pwm_regs;

    localparam CNT_W = 16;
    localparam DT_W  = 8;

    reg              clk = 1'b0;
    reg              rst_n;
    reg              wr;
    reg  [1:0]       addr;
    reg  [CNT_W-1:0] wdata;
    reg              update;
    wire [CNT_W-1:0] period_q, duty_q;
    wire [DT_W-1:0]  dt_q;
    wire             en_q, force_off_q, center_q;

    always #5 clk = ~clk;

    pwm_regs #(.CNT_W(CNT_W), .DT_W(DT_W)) dut (
        .clk (clk), .rst_n (rst_n),
        .wr (wr), .addr (addr), .wdata (wdata),
        .update (update),
        .period_q (period_q), .duty_q (duty_q), .dt_q (dt_q),
        .center_q (center_q), .en_q (en_q), .force_off_q (force_off_q)
    );

    localparam [1:0] A_PERIOD = 2'd0, A_DUTY = 2'd1, A_DT = 2'd2, A_CTRL = 2'd3;

    //------------------------------------------------------------------
    // Scoreboard: last value written to each register
    //------------------------------------------------------------------
    integer errors = 0, cyc = 0, commits = 0;
    reg [CNT_W-1:0] pn, dn;
    reg [DT_W-1:0]  dtn;
    reg             exp_en, exp_fo;
    reg [CNT_W-1:0] pq_d, dq_d;
    reg [DT_W-1:0]  dtq_d;
    reg             cn, cq_d;             // CTRL[2] is staged, not immediate
    reg             check_en = 1'b0;

    always @(negedge clk) begin
        cyc = cyc + 1;
        if (check_en) begin
            // R3
            if (en_q        !== exp_en) fail("R3 en_q not immediate");
            if (force_off_q !== exp_fo) fail("R3 force_off_q not immediate");

            if (update === 1'b1) begin
                // R2
                if (period_q !== pn)  fail("R2 period_q != last written");
                if (duty_q   !== dn)  fail("R2 duty_q != last written");
                if (dt_q     !== dtn) fail("R2 dt_q != last written");
                if (center_q !== cn)  fail("R2 center_q != last written");
                commits = commits + 1;
            end else begin
                // R1
                if (period_q !== pq_d)  fail("R1 period_q changed without update");
                if (duty_q   !== dq_d)  fail("R1 duty_q changed without update");
                if (dt_q     !== dtq_d) fail("R1 dt_q changed without update");
                if (center_q !== cq_d)  fail("R1 center_q changed without update");
            end
        end
        pq_d = period_q; dq_d = duty_q; dtq_d = dt_q; cq_d = center_q;
    end

    //------------------------------------------------------------------
    // Helpers
    //------------------------------------------------------------------
    task fail(input [8*80-1:0] msg);
        begin
            errors = errors + 1;
            if (errors <= 10) $display("    ** FAIL  cyc=%0d : %0s", cyc, msg);
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

    task wreg(input [1:0] a, input [CNT_W-1:0] d);
        begin
            wr = 1'b1; addr = a; wdata = d;
            case (a)
                A_PERIOD: pn  = d;
                A_DUTY:   dn  = d;
                A_DT:     dtn = d[DT_W-1:0];
                A_CTRL:   begin exp_en = d[0]; exp_fo = d[1]; cn = d[2]; end
            endcase
            step(1);
            wr = 1'b0;
        end
    endtask

    task pulse_update;
        begin
            update = 1'b1; step(1); update = 1'b0; step(1);
        end
    endtask

    task banner(input [8*80-1:0] name);
        begin $display("\n[TEST] %0s", name); end
    endtask

    //------------------------------------------------------------------
    // Stimulus
    //------------------------------------------------------------------
    integer i, n_rand = 4000;
    reg [15:0] lfsr = 16'h1357;

    initial begin
        if ($value$plusargs("cycles=%d", n_rand)) ;
        if ($value$plusargs("seed=%h",   lfsr))   ;

        $dumpfile("build/tb_pwm_regs.vcd");
        $dumpvars(0, tb_pwm_regs);

        rst_n = 1'b0; wr = 1'b0; addr = 2'd0; wdata = {CNT_W{1'b0}};
        update = 1'b0;
        step(4);

        //--------------------------------------------------------------
        banner("reset values are the safe end of every range");
        expect_eq("period_q",    period_q,    (1<<CNT_W)-1);
        expect_eq("duty_q",      duty_q,      0);
        expect_eq("dt_q",        dt_q,        (1<<DT_W)-1);
        expect_eq("en_q",        en_q,        0);
        expect_eq("force_off_q", force_off_q, 1);
        expect_eq("center_q",    center_q,    0);

        // seed the scoreboard with those reset values, then arm the checkers
        pn = {CNT_W{1'b1}}; dn = {CNT_W{1'b0}}; dtn = {DT_W{1'b1}}; cn = 1'b0;
        exp_en = 1'b0; exp_fo = 1'b1;
        rst_n = 1'b1; step(2);
        pq_d = period_q; dq_d = duty_q; dtq_d = dt_q; cq_d = center_q;
        check_en = 1'b1;

        //--------------------------------------------------------------
        banner("writes are staged, not applied, while update is low");
        wreg(A_PERIOD, 16'd5000);
        wreg(A_DUTY,   16'd1250);
        wreg(A_DT,     16'd12);
        step(20);                          // R1 polices this the whole time
        expect_eq("period_q still reset",  period_q, (1<<CNT_W)-1);
        expect_eq("duty_q still reset",    duty_q,   0);
        expect_eq("dt_q still reset",      dt_q,     (1<<DT_W)-1);

        //--------------------------------------------------------------
        banner("one update commits all three at once");
        pulse_update;
        expect_eq("period_q", period_q, 5000);
        expect_eq("duty_q",   duty_q,   1250);
        expect_eq("dt_q",     dt_q,     12);

        //--------------------------------------------------------------
        banner("CTRL is immediate -- no update needed to stop the timer");
        wreg(A_CTRL, 16'h0001);            // en=1, force_off=0
        expect_eq("en_q",        en_q,        1);
        expect_eq("force_off_q", force_off_q, 0);
        wreg(A_CTRL, 16'h0002);            // en=0, force_off=1
        expect_eq("en_q",        en_q,        0);
        expect_eq("force_off_q", force_off_q, 1);
        step(10);                          // R3 polices this every cycle
        wreg(A_CTRL, 16'h0003);
        expect_eq("en_q",        en_q,        1);
        expect_eq("force_off_q", force_off_q, 1);

        //--------------------------------------------------------------
        // The point of the split: one CTRL write, two different timings.
        //--------------------------------------------------------------
        banner("CTRL is split -- en/force_off now, center at the boundary");
        wreg(A_CTRL, 16'h0005);            // en=1, force_off=0, center=1
        expect_eq("en_q immediately",      en_q,     1);
        expect_eq("force_off_q immediately", force_off_q, 0);
        expect_eq("center_q still staged", center_q, 0);
        step(15);
        expect_eq("center_q still staged", center_q, 0);
        pulse_update;
        expect_eq("center_q committed",    center_q, 1);
        wreg(A_CTRL, 16'h0001);
        expect_eq("center_q staged low",   center_q, 1);
        pulse_update;
        expect_eq("center_q back to edge", center_q, 0);

        //--------------------------------------------------------------
        banner("address decode hits exactly one register");
        wreg(A_PERIOD, 16'd100); pulse_update;
        expect_eq("period_q", period_q, 100);
        expect_eq("duty_q untouched", duty_q, 1250);
        expect_eq("dt_q untouched",   dt_q,   12);
        wreg(A_DUTY, 16'd60); pulse_update;
        expect_eq("duty_q",   duty_q,   60);
        expect_eq("period_q untouched", period_q, 100);

        //--------------------------------------------------------------
        banner("wr low -- addr and wdata are ignored");
        wr = 1'b0; addr = A_PERIOD; wdata = 16'hDEAD; step(4);
        pulse_update;
        expect_eq("period_q unchanged", period_q, 100);

        //--------------------------------------------------------------
        banner("DEADTIME truncates to DT_W bits");
        wreg(A_DT, 16'h01FF); pulse_update;
        expect_eq("dt_q", dt_q, 255);
        wreg(A_DT, 16'h0105); pulse_update;
        expect_eq("dt_q", dt_q, 5);

        //--------------------------------------------------------------
        banner("only the last write before an update commits");
        wreg(A_DUTY, 16'd11);
        wreg(A_DUTY, 16'd22);
        wreg(A_DUTY, 16'd33);
        pulse_update;
        expect_eq("duty_q", duty_q, 33);

        //--------------------------------------------------------------
        // A write landing on the update edge itself reads as its OLD value
        // on the load side -- both are registers on the same clock. So it
        // commits at the FOLLOWING boundary. No torn value, just one period
        // of latency. R2 cannot express this, so it is checked by hand.
        //--------------------------------------------------------------
        banner("write coincident with update commits one boundary later");
        check_en = 1'b0;
        wr = 1'b1; addr = A_DUTY; wdata = 16'd77; update = 1'b1;
        step(1);
        wr = 1'b0; update = 1'b0; dn = 16'd77;
        step(1);
        expect_eq("duty_q still old", duty_q, 33);
        pulse_update;
        expect_eq("duty_q now new",   duty_q, 77);
        pq_d = period_q; dq_d = duty_q; dtq_d = dt_q;
        check_en = 1'b1;

        //--------------------------------------------------------------
        banner("randomized writes and updates (R1-R3 only)");
        for (i = 0; i < n_rand; i = i + 1) begin
            lfsr = {lfsr[14:0], lfsr[15]^lfsr[13]^lfsr[12]^lfsr[10]};
            // never a write and an update on the same edge -- see header
            if (lfsr[2:0] == 3'd0)
                pulse_update;
            else if (lfsr[2:0] == 3'd1)
                wreg(lfsr[9:8], {2'd0, lfsr[15:2]});
            else
                step(1);
        end
        if (commits == 0) begin
            errors = errors + 1;
            $display("    ** FAIL  commit checker never fired");
        end else
            $display("       ok  %0d commits checked, seed %04h", commits, lfsr);

        //--------------------------------------------------------------
        if (errors == 0) $display("\n==== TEST PASSED ====\n");
        else             $display("\n==== TEST FAILED (%0d errors) ====\n", errors);
        $finish;
    end

    initial begin
        #20_000_000;
        $display("\n==== TEST FAILED (timeout) ====\n");
        $finish;
    end

endmodule
