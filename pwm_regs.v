//============================================================================
// pwm_regs.v -- register file with shadow (double-buffered) config
//
// Writes land in the *_next registers at any time. The active *_q registers
// load from them only when `update` pulses, which pwm_counter asserts during
// the last cycle of a period. So a duty written in the middle of a pulse can
// never shorten the pulse that is already in flight -- the output for the
// current period is whatever was committed at its start.
//
// Register map. `addr` is byte_addr[3:2]; translating a wider bus address is
// the wrapper's job, so the decode here is exact rather than aliased.
//
//   addr  byte  name       bits                        buffered?
//   ----  ----  ---------  --------------------------  ---------
//    0    0x0   PERIOD     [CNT_W-1:0] counter wrap    shadowed
//    1    0x4   DUTY       [CNT_W-1:0] compare         shadowed
//    2    0x8   DEADTIME   [DT_W-1:0]  clocks          shadowed
//    3    0xC   CTRL       [0] en, [1] force_off       IMMEDIATE
//
// CTRL is deliberately NOT shadowed. Shadowing exists to stop a data change
// from corrupting a pulse in flight; control that switches the output OFF
// must never be delayed by up to a period. Stop means stop.
//
// Reset values are the safe end of every range, not zero:
//   PERIOD   = max  -> slowest switching
//   DUTY     = 0    -> 0% output
//   DEADTIME = max  -> most conservative interlock
//   en       = 0    -> timer stopped
//   force_off= 1    -> gates held off until software explicitly releases them
// So CTRL does not read back as 0 after reset. That is intentional: the safe
// state of an output-disable bit is asserted.
//
// Verilog-2001. Single clock, async-assert reset.
//============================================================================

module pwm_regs #(
    parameter CNT_W = 16,
    parameter DT_W  = 8
) (
    input  wire             clk,
    input  wire             rst_n,      // async assert, active low

    input  wire             wr,         // write strobe
    input  wire [1:0]       addr,       // = byte_addr[3:2]
    input  wire [CNT_W-1:0] wdata,

    input  wire             update,     // load enable from pwm_counter

    output reg  [CNT_W-1:0] period_q,   // active config -- register outputs,
    output reg  [CNT_W-1:0] duty_q,     // which is what pwm_counter's wrap
    output reg  [DT_W-1:0]  dt_q,       // logic requires (see its header)
    output reg              en_q,
    output reg              force_off_q
);

    localparam [1:0] A_PERIOD = 2'd0,
                     A_DUTY   = 2'd1,
                     A_DT     = 2'd2,
                     A_CTRL   = 2'd3;

    reg [CNT_W-1:0] period_next, duty_next;
    reg [DT_W-1:0]  dt_next;

    //------------------------------------------------------------------
    // Write port. CTRL lands directly on the outputs; everything else
    // lands in the staging registers and waits for `update`.
    //------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            period_next <= {CNT_W{1'b1}};
            duty_next   <= {CNT_W{1'b0}};
            dt_next     <= {DT_W{1'b1}};
            en_q        <= 1'b0;
            force_off_q <= 1'b1;
        end else if (wr) begin
            case (addr)
                A_PERIOD: period_next <= wdata;
                A_DUTY:   duty_next   <= wdata;
                A_DT:     dt_next     <= wdata[DT_W-1:0];
                A_CTRL:   begin
                              en_q        <= wdata[0];
                              force_off_q <= wdata[1];
                          end
            endcase
        end
    end

    //------------------------------------------------------------------
    // Shadow load. A write that lands on the update edge itself is read
    // here as its OLD value -- both sides are registers on the same clock --
    // so it commits at the following boundary. There is no torn value.
    //
    // pwm_counter holds `update` high while it is disabled, so config
    // written to a stopped timer commits on the next cycle rather than
    // waiting for a wrap that is never coming.
    //------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            period_q <= {CNT_W{1'b1}};
            duty_q   <= {CNT_W{1'b0}};
            dt_q     <= {DT_W{1'b1}};
        end else if (update) begin
            period_q <= period_next;
            duty_q   <= duty_next;
            dt_q     <= dt_next;
        end
    end

endmodule
