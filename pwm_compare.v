//============================================================================
// pwm_compare.v -- one PWM channel's comparator
//
// Split out of pwm_counter so that a multi-phase design can share one counter
// between several channels: that is the whole point of a shared carrier, and
// it is what makes the three phases of an inverter switch in step.
//
// pwm_raw is registered, so it lags cnt by one clock. The pulse sits one cycle
// later in the period; its width is unaffected, in either counting mode.
//
// Verilog-2001.
//============================================================================

module pwm_compare #(
    parameter CNT_W = 16
) (
    input  wire             clk,
    input  wire             rst_n,      // async assert, active low
    input  wire             en,
    input  wire [CNT_W-1:0] cnt,
    input  wire [CNT_W-1:0] duty,
    output reg              pwm_raw
);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)   pwm_raw <= 1'b0;
        else if (!en) pwm_raw <= 1'b0;
        else          pwm_raw <= (cnt < duty);
    end

endmodule
