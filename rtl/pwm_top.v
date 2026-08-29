//============================================================================
// pwm_top.v -- PWM timer with dead-time insertion, assembled
//
//   pwm_regs ---> pwm_counter ---> deadtime ---> pwm_h / pwm_l
//        ^             |
//        +--- update --+
//
// What this level adds over the three sub-modules:
//
//   1. A 2-FF synchroniser on the asynchronous fault input. An async signal
//      driving FSM logic directly can be sampled mid-transition by different
//      flops in different states, and the FSM ends up somewhere illegal.
//      fault_sync resets to "tripped", so the outputs are off out of reset
//      and stay off until a healthy fault_n has propagated.
//
//   2. Resume-at-a-boundary. A trip forces the gates off in the same cycle,
//      but recovery waits for the next `update`. Restarting mid-period is not
//      a shoot-through risk -- deadtime.v serves a full dead time on the way
//      out of S_FAULT whatever happens -- it just produces a first pulse of
//      arbitrary width. Waiting for the boundary makes the first pulse after
//      recovery a correct one.
//
//   3. A disabled timer drives nothing. en=0 forces both gates off (coast),
//      rather than parking the low side on (brake). Braking a motor is a
//      deliberate act, not what "stopped" should mean.
//
// So en and force_off are genuinely different controls: en=0 stops the
// counter and the outputs; force_off=1 leaves the counter running and blanks
// the outputs, so clearing it resumes in step with the period.
//
// THE WIRING THAT MATTERS: period_q/duty_q are pwm_regs REGISTER OUTPUTS
// feeding pwm_counter's combinational wrap logic. They settle after the clock
// edge, so the counter still sees the old period on the edge it wraps. Drive
// those inputs from anything combinational and an increased period cancels
// the wrap -- see the contract in pwm_counter.v's header.
//
// Verilog-2001. Single clock, async-assert reset.
//============================================================================

module pwm_top #(
    parameter CNT_W = 16,
    parameter DT_W  = 8
) (
    input  wire             clk,
    input  wire             rst_n,      // async assert, active low

    input  wire             wr,         // register write strobe
    input  wire [1:0]       addr,       // = byte_addr[3:2]
    input  wire [CNT_W-1:0] wdata,

    input  wire             fault_n,    // ASYNCHRONOUS trip input, 0 = tripped

    output wire             pwm_h,      // high-side gate
    output wire             pwm_l,      // low-side gate
    output wire             update,     // last cycle of each period
    output wire             fault       // synchronised trip, active high
);

    //------------------------------------------------------------------
    // Fault synchroniser. Resets to 00 -- i.e. reads as tripped -- so the
    // gates are held off for the first two clocks after reset regardless of
    // what fault_n is doing.
    //------------------------------------------------------------------
    reg [1:0] fault_sync;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) fault_sync <= 2'b00;
        else        fault_sync <= {fault_sync[0], fault_n};
    end

    assign fault = ~fault_sync[1];

    //------------------------------------------------------------------
    // Re-arm only on a period boundary. Dropping out is immediate.
    //------------------------------------------------------------------
    reg armed;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)          armed <= 1'b0;
        else if (fault)      armed <= 1'b0;
        else if (update)     armed <= 1'b1;
    end

    //------------------------------------------------------------------
    // Sub-modules
    //------------------------------------------------------------------
    wire [CNT_W-1:0] period_q, duty_q;
    wire [DT_W-1:0]  dt_q;
    wire             en_q, force_off_q, center_q;
    wire             pwm_raw;

    // Four independent reasons to blank the gates. `fault` is combinational
    // from a registered synchroniser output, so a trip lands on the very next
    // edge with nothing in the way.
    wire force_off = fault | ~armed | force_off_q | ~en_q;

    pwm_regs #(.CNT_W(CNT_W), .DT_W(DT_W)) u_regs (
        .clk         (clk),
        .rst_n       (rst_n),
        .wr          (wr),
        .addr        (addr),
        .wdata       (wdata),
        .update      (update),
        .period_q    (period_q),
        .duty_q      (duty_q),
        .dt_q        (dt_q),
        .center_q    (center_q),
        .en_q        (en_q),
        .force_off_q (force_off_q)
    );

    pwm_counter #(.CNT_W(CNT_W)) u_counter (
        .clk     (clk),
        .rst_n   (rst_n),
        .en      (en_q),
        .center  (center_q),
        .period  (period_q),
        .duty    (duty_q),
        .cnt     (),
        .up      (),
        .update  (update),
        .pwm_raw (pwm_raw)
    );

    deadtime #(.DT_W(DT_W)) u_deadtime (
        .clk       (clk),
        .rst_n     (rst_n),
        .dt        (dt_q),
        .pwm_raw   (pwm_raw),
        .force_off (force_off),
        .pwm_h     (pwm_h),
        .pwm_l     (pwm_l)
    );

endmodule
