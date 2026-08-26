//============================================================================
// pwm_counter.v -- counter + compare PWM core (edge-aligned)
//
// Free-running up-counter, 0 .. period-1, so
//
//     f_pwm = f_clk / period          (100 MHz / 5000 = 20 kHz)
//
// pwm_raw is high for exactly `duty` cycles of every period. It is registered,
// so it lags cnt by one clock; the pulse sits one cycle later in the period
// but its width is unaffected.
//
// Degenerate values are defined rather than illegal, because a register write
// can produce any of them and the counter must not be able to run away:
//   * duty = 0          -> pwm_raw stays low       (0%)
//   * duty >= period    -> pwm_raw stays high      (100%)
//   * period = 0 or 1   -> wraps every cycle       (period clamps to 1)
//   * period reduced below the current cnt -> wraps on the next cycle
//
// Verilog-2001. Single clock, async-assert reset.
//============================================================================

module pwm_counter #(
    parameter CNT_W = 16
) (
    input  wire             clk,
    input  wire             rst_n,      // async assert, active low
    input  wire             en,
    input  wire [CNT_W-1:0] period,     // shadow-buffered upstream
    input  wire [CNT_W-1:0] duty,
    output reg  [CNT_W-1:0] cnt,
    output wire             update,     // high during the LAST cycle of a period
    output reg              pwm_raw
);

    localparam [CNT_W-1:0] ONE = 1;

    // Widened by one bit so cnt+1 cannot alias to 0 for any value of cnt --
    // the counter must never be able to miss its own wrap condition.
    wire wrap = (({1'b0, cnt} + 1'b1) >= {1'b0, period});

    //------------------------------------------------------------------
    // update is combinational on purpose. It is high during the last cycle
    // of the period, so a synchronous load using it as an enable lands on
    // exactly the edge where cnt wraps to 0, and the new period/duty are in
    // force for the whole of the next period. Registering it would push them
    // one cycle late. It is a load enable sampled at a clock edge, never a
    // gate drive, so a combinational decode is safe here.
    //
    // Held high while disabled, so config written to a stopped timer applies
    // immediately instead of waiting for a wrap that is never coming.
    //------------------------------------------------------------------
    assign update = wrap | ~en;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cnt     <= {CNT_W{1'b0}};
            pwm_raw <= 1'b0;
        end else if (!en) begin
            cnt     <= {CNT_W{1'b0}};   // stop rearms at 0; it does not freeze
            pwm_raw <= 1'b0;            // mid-period and resume later
        end else begin
            cnt     <= wrap ? {CNT_W{1'b0}} : (cnt + ONE);
            pwm_raw <= (cnt < duty);
        end
    end

endmodule
