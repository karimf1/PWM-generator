//============================================================================
// deadtime_v1_buggy.v -- THE BROKEN FIRST VERSION. DO NOT USE.
//
// Kept so the failure in README.md is reproducible rather than illustrated.
// This is the two-dead-time-state FSM with the early-return shortcut. It
// passes every directed test in tb/tb_deadtime.v and fails C2 in the
// randomized stress, because the fault-release and reset-release paths reuse
// S_DT_LH after the HIGH side has been conducting, and the early return then
// turns the low side on a couple of cycles after the high side stopped.
//
// Reproduce:  make -C sim bug
//
// The fix is rtl/deadtime.v: one non-abortable S_DEAD state instead of two
// abortable ones.
//============================================================================

module deadtime #(
    parameter DT_W = 8
) (
    input  wire            clk,
    input  wire            rst_n,
    input  wire [DT_W-1:0] dt,
    input  wire            pwm_raw,
    input  wire            force_off,
    output reg             pwm_h,
    output reg             pwm_l
);

    localparam [2:0] S_LO_ON = 3'd0,
                     S_DT_LH = 3'd1,
                     S_HI_ON = 3'd2,
                     S_DT_HL = 3'd3,
                     S_FAULT = 3'd4;

    localparam [DT_W-1:0] DT_ONE = 1;

    reg [2:0]      state, next_state;
    reg [DT_W-1:0] dt_cnt, next_cnt;

    always @(*) begin
        next_state = state;
        next_cnt   = dt_cnt;

        case (state)
            S_LO_ON: begin
                if (pwm_raw) begin
                    next_state = S_DT_LH;
                    next_cnt   = dt;
                end
            end

            // BUG: the early return is safe when this state was entered from
            // S_LO_ON, because the low side never turned off. It is NOT safe
            // when it was entered from S_FAULT or reset after the HIGH side
            // was conducting -- then it turns the low side on with no dead
            // time against a device that has only just stopped conducting.
            S_DT_LH: begin
                if (!pwm_raw)               next_state = S_LO_ON;
                else if (dt_cnt <= DT_ONE)  next_state = S_HI_ON;
                else                        next_cnt   = dt_cnt - DT_ONE;
            end

            S_HI_ON: begin
                if (!pwm_raw) begin
                    next_state = S_DT_HL;
                    next_cnt   = dt;
                end
            end

            S_DT_HL: begin
                if (pwm_raw)                next_state = S_HI_ON;
                else if (dt_cnt <= DT_ONE)  next_state = S_LO_ON;
                else                        next_cnt   = dt_cnt - DT_ONE;
            end

            S_FAULT: begin
                if (!force_off) begin
                    next_state = S_DT_LH;   // <-- straight into the shortcut
                    next_cnt   = dt;
                end
            end

            default: next_state = S_FAULT;
        endcase

        if (force_off) next_state = S_FAULT;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state  <= S_DT_LH;              // <-- and so does reset
            dt_cnt <= dt;
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
