//============================================================================
// deadtime.v -- complementary output generator with dead-time insertion
//
// Takes one requested switching signal (pwm_raw) and produces the two
// half-bridge gate signals. Turn-OFF is immediate; turn-ON is delayed by
// `dt` clock cycles. The high and low side are never asserted together.
//
// The FSM has exactly one rule: NOTHING turns on except by leaving S_DEAD,
// and S_DEAD always runs its counter to zero. Normal switching, fault
// release and reset release all funnel through it, so every turn-on in the
// design is preceded by a full dead time by construction.
//
// (An earlier version had separate low->high and high->low dead-time states
// that returned early if the request was withdrawn mid-count. That is safe
// for normal switching -- the side that was on never turned off -- but the
// fault-release and reset-release paths reused the same state after the
// OTHER side had been conducting, and the early return turned a device on
// 2 cycles after its complement. Randomized stress caught it; the single
// non-abortable state removes the whole class of bug.)
//
// Behaviour worth knowing before you use it:
//   * Delivered on-time is (requested_on_time - dt) clocks. A request
//     shorter than dt is swallowed entirely -- neither output turns on.
//   * dt = 0 still inserts one clock of dead time. The minimum is 1, not 0,
//     on purpose: a configurable-to-zero safety interlock is not one.
//   * force_off must already be synchronous to clk (see pwm_top.v).
//
// Verilog-2001. Single clock, async-assert reset, registered outputs.
//============================================================================

module deadtime #(
    parameter DT_W = 8                  // width of the dead-time value
) (
    input  wire            clk,
    input  wire            rst_n,       // async assert, active low
    input  wire [DT_W-1:0] dt,          // dead time in clk cycles
    input  wire            pwm_raw,     // requested high-side state
    input  wire            force_off,   // sync fault/shutdown: both outputs low
    output reg             pwm_h,       // high-side gate
    output reg             pwm_l        // low-side gate
);

    localparam [1:0] S_LO_ON = 2'd0,    // low side conducting
                     S_HI_ON = 2'd1,    // high side conducting
                     S_DEAD  = 2'd2,    // both off, counting down
                     S_FAULT = 2'd3;    // shutdown, both off

    localparam [DT_W-1:0] DT_ONE = 1;

    reg [1:0]      state, next_state;
    reg [DT_W-1:0] dt_cnt, next_cnt;

    //------------------------------------------------------------------
    // Next-state logic
    //------------------------------------------------------------------
    always @(*) begin
        next_state = state;
        next_cnt   = dt_cnt;

        case (state)
            S_LO_ON: begin
                if (pwm_raw) begin
                    next_state = S_DEAD;
                    next_cnt   = dt;        // dt is latched here, so a write
                end                         // mid-count cannot stretch or
            end                             // shorten the gap in progress

            S_HI_ON: begin
                if (!pwm_raw) begin
                    next_state = S_DEAD;
                    next_cnt   = dt;
                end
            end

            // Runs to zero unconditionally, then turns on whichever side is
            // being asked for at that moment. A request that appears and
            // disappears inside the window is simply not reproduced -- that
            // is what "pulses narrower than the dead time are swallowed"
            // means, and it is the intended behaviour.
            S_DEAD: begin
                if (dt_cnt <= DT_ONE) next_state = pwm_raw ? S_HI_ON : S_LO_ON;
                else                  next_cnt   = dt_cnt - DT_ONE;
            end

            S_FAULT: begin
                if (!force_off) begin
                    next_state = S_DEAD;
                    next_cnt   = dt;
                end
            end
        endcase

        if (force_off) next_state = S_FAULT;    // highest priority
    end

    //------------------------------------------------------------------
    // State + output registers
    //
    // pwm_h/pwm_l are decoded from next_state and registered, never decoded
    // combinationally from state. A decode of state bits can glitch while
    // the bits settle, and a glitch here is a shoot-through in the bridge.
    //------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state  <= S_DEAD;               // both off, and whatever comes
            dt_cnt <= dt;                   // next still costs a full dt
            pwm_h  <= 1'b0;
            pwm_l  <= 1'b0;
        end else begin
            state  <= next_state;
            dt_cnt <= next_cnt;
            pwm_h  <= (next_state == S_HI_ON);
            pwm_l  <= (next_state == S_LO_ON);
        end
    end

endmodule
