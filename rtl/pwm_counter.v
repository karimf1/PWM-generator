//============================================================================
// pwm_counter.v -- PWM carrier: counter, plus channel A's comparator
//
// Two counting modes, selected by `center`:
//
//   EDGE-ALIGNED (center = 0)
//     0, 1, ... period-1, 0, ...                  f_pwm = f_clk / period
//     One period is `period` clocks. update fires on the last one.
//
//   CENTER-ALIGNED (center = 1)
//     0, 1, ... top-1, top-1, ... 1, 0, 0, 1, ... f_pwm = f_clk / (2*period)
//     Up to the top, hold a cycle, back down, hold a cycle. Holding both
//     turning points is what makes every count appear EXACTLY TWICE, so one
//     period is 2*period clocks and the high time is 2*duty -- the duty ratio
//     comes out identical to edge-aligned. Without the holds the endpoints
//     appear once each and the high time is 2*duty-1, which makes 100% duty
//     unreachable. update fires at the bottom of the ramp.
//
//   Center-aligned is what real three-phase drives use: the pulse is centred
//   in the period rather than pinned to its start, which lowers the harmonic
//   content of the line-to-line voltage.
//
// Degenerate values are defined rather than illegal, because a register write
// can produce any of them and the counter must not be able to run away:
//   * duty = 0          -> pwm_raw stays low       (0%)
//   * duty >= period    -> pwm_raw stays high      (100%)
//   * period = 0 or 1   -> period clamps to 1
//   * period reduced below the current cnt -> turns around on the next cycle
//
// INTERFACE CONTRACT: `period` and `duty` must be REGISTER OUTPUTS that settle
// after the clock edge -- which is what pwm_regs.v provides. `at_top` is
// combinational on the live period input, so if a larger period arrives before
// the wrap edge rather than at it, at_top goes false and THE WRAP IS CANCELLED:
// the counter sails past its endpoint and the period comes out as
// period_new - period_old. Never drive these from a write port directly.
//
// Verilog-2001. Single clock, async-assert reset.
//============================================================================

module pwm_counter #(
    parameter CNT_W = 16
) (
    input  wire             clk,
    input  wire             rst_n,      // async assert, active low
    input  wire             en,
    input  wire             center,     // 0 = edge-aligned, 1 = center-aligned
    input  wire [CNT_W-1:0] period,     // shadow-buffered upstream
    input  wire [CNT_W-1:0] duty,
    output reg  [CNT_W-1:0] cnt,
    output wire             up,         // counting direction, center mode
    output wire             update,     // last cycle of a period
    output wire             pwm_raw
);

    localparam [CNT_W-1:0] ZERO = 0;
    localparam [CNT_W-1:0] ONE  = 1;

    // A zero period would make top-1 underflow to all-ones and the counter
    // would run the full range, so it clamps to 1.
    wire [CNT_W-1:0] top = (period == ZERO) ? ONE : period;

    // `>=` rather than `==`: if period is reduced below the current cnt the
    // counter must still recognise its endpoint and turn around.
    wire at_top    = (cnt >= (top - ONE));
    wire at_bottom = (cnt == ZERO);

    reg up_q;
    assign up = up_q;

    //------------------------------------------------------------------
    // update is combinational on purpose. It marks the last cycle of the
    // period, so a synchronous load using it as an enable lands on exactly
    // the edge where the next period begins. Registering it would push the
    // new config one cycle late. It is a load enable sampled at a clock edge,
    // never a gate drive.
    //
    // Held high while disabled, so config written to a stopped timer commits
    // at once rather than waiting for a wrap that is never coming.
    //------------------------------------------------------------------
    assign update = (center ? (~up_q & at_bottom) : at_top) | ~en;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cnt  <= ZERO;
            up_q <= 1'b1;
        end else if (!en) begin
            cnt  <= ZERO;               // stop rearms at the bottom of the
            up_q <= 1'b1;               // ramp; it does not freeze mid-period
        end else if (center) begin
            if (up_q) begin
                if (at_top)    up_q <= 1'b0;        // hold cnt, turn around
                else           cnt  <= cnt + ONE;
            end else begin
                if (at_bottom) up_q <= 1'b1;        // hold cnt, turn around
                else           cnt  <= cnt - ONE;
            end
        end else begin
            cnt  <= at_top ? ZERO : (cnt + ONE);
            up_q <= 1'b1;
        end
    end

    pwm_compare #(.CNT_W(CNT_W)) u_cmp (
        .clk     (clk),
        .rst_n   (rst_n),
        .en      (en),
        .cnt     (cnt),
        .duty    (duty),
        .pwm_raw (pwm_raw)
    );

endmodule
