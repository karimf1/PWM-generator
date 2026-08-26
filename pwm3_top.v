//============================================================================
// pwm3_top.v -- three-phase PWM modulator with dead-time insertion
//
//                          +--> pwm_compare --> deadtime --> pwm_h[0]/pwm_l[0]
//   pwm_regs --> pwm_counter --> pwm_compare --> deadtime --> pwm_h[1]/pwm_l[1]
//        ^            |     +--> pwm_compare --> deadtime --> pwm_h[2]/pwm_l[2]
//        +-- update --+
//
// ONE carrier drives all three phases. That is the point: the three
// half-bridges of an inverter must switch in step, because it is the
// LINE-TO-LINE voltage that matters and it is the difference of two phase
// voltages. Give each phase its own counter and the phases drift, the
// difference picks up beat frequencies, and the motor hears them.
//
// The 120-degree phase relationship is NOT in the hardware -- it is in the
// three duty values software writes. The carrier stays common; the modulation
// is what differs. Pair this with center-aligned mode (CTRL[2]) and you have
// the modulator a real three-phase drive uses.
//
// One DEADTIME and one fault input serve all three phases: a bridge fault
// kills the whole bridge, and the dead time is a property of the transistors,
// not of which leg they are in.
//
// Register map. `addr` is byte_addr[4:2].
//
//   addr  byte  name       bits                        buffered?
//   ----  ----  ---------  --------------------------  ---------
//    0    0x0   PERIOD     [CNT_W-1:0] counter wrap    shadowed
//    1    0x4   DUTY_A     [CNT_W-1:0] phase A         shadowed
//    2    0x8   DEADTIME   [DT_W-1:0]  clocks          shadowed
//    3    0xC   CTRL       [0] en, [1] force_off       IMMEDIATE
//                          [2] center                  shadowed
//    4    0x10  DUTY_B     [CNT_W-1:0] phase B         shadowed
//    5    0x14  DUTY_C     [CNT_W-1:0] phase C         shadowed
//
// Addresses 0-3 are pwm_regs unchanged, so the single-phase register block is
// reused rather than reimplemented. B and C add two more shadow registers here
// on the same `update` enable, so all three duties commit on the same edge --
// which matters, because a three-phase command is only meaningful as a set.
//
// Verilog-2001. Single clock, async-assert reset.
//============================================================================

module pwm3_top #(
    parameter CNT_W = 16,
    parameter DT_W  = 8
) (
    input  wire             clk,
    input  wire             rst_n,      // async assert, active low

    input  wire             wr,         // register write strobe
    input  wire [2:0]       addr,       // = byte_addr[4:2]
    input  wire [CNT_W-1:0] wdata,

    input  wire             fault_n,    // ASYNCHRONOUS trip input, 0 = tripped

    output wire [2:0]       pwm_h,      // high-side gates, phase A/B/C
    output wire [2:0]       pwm_l,      // low-side gates
    output wire             update,     // last cycle of each period
    output wire             fault       // synchronised trip, active high
);

    //------------------------------------------------------------------
    // Fault synchroniser and re-arm, identical to pwm_top.v
    //------------------------------------------------------------------
    reg [1:0] fault_sync;
    reg       armed;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) fault_sync <= 2'b00;    // reads as tripped out of reset
        else        fault_sync <= {fault_sync[0], fault_n};
    end

    assign fault = ~fault_sync[1];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)      armed <= 1'b0;
        else if (fault)  armed <= 1'b0;     // drop out immediately
        else if (update) armed <= 1'b1;     // re-arm only on a boundary
    end

    //------------------------------------------------------------------
    // Registers: 0-3 from pwm_regs, 4-5 added here
    //------------------------------------------------------------------
    wire [CNT_W-1:0] period_q, duty_a_q;
    wire [DT_W-1:0]  dt_q;
    wire             en_q, force_off_q, center_q;

    wire force_off = fault | ~armed | force_off_q | ~en_q;

    pwm_regs #(.CNT_W(CNT_W), .DT_W(DT_W)) u_regs (
        .clk         (clk),
        .rst_n       (rst_n),
        .wr          (wr & ~addr[2]),       // addresses 0-3 only
        .addr        (addr[1:0]),
        .wdata       (wdata),
        .update      (update),
        .period_q    (period_q),
        .duty_q      (duty_a_q),
        .dt_q        (dt_q),
        .center_q    (center_q),
        .en_q        (en_q),
        .force_off_q (force_off_q)
    );

    // Same staging discipline as pwm_regs: written any time, committed on
    // `update`, so all three phases change together at a period boundary.
    reg [CNT_W-1:0] duty_b_next, duty_c_next, duty_b_q, duty_c_q;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            duty_b_next <= {CNT_W{1'b0}};
            duty_c_next <= {CNT_W{1'b0}};
        end else if (wr && addr[2]) begin
            if (addr[0]) duty_c_next <= wdata;   // addr 5
            else         duty_b_next <= wdata;   // addr 4
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            duty_b_q <= {CNT_W{1'b0}};
            duty_c_q <= {CNT_W{1'b0}};
        end else if (update) begin
            duty_b_q <= duty_b_next;
            duty_c_q <= duty_c_next;
        end
    end

    //------------------------------------------------------------------
    // One carrier, three channels
    //------------------------------------------------------------------
    wire [CNT_W-1:0] cnt;
    wire             raw_a, raw_b, raw_c;
    wire [2:0]       raw = {raw_c, raw_b, raw_a};

    // Phase A rides the comparator built into pwm_counter; B and C add one
    // each. Three identical pwm_compare instances would leave the counter's
    // own comparator driving nothing.
    pwm_counter #(.CNT_W(CNT_W)) u_carrier (
        .clk     (clk),
        .rst_n   (rst_n),
        .en      (en_q),
        .center  (center_q),
        .period  (period_q),
        .duty    (duty_a_q),
        .cnt     (cnt),
        .up      (),
        .update  (update),
        .pwm_raw (raw_a)
    );

    pwm_compare #(.CNT_W(CNT_W)) u_cmp_b (
        .clk (clk), .rst_n (rst_n), .en (en_q),
        .cnt (cnt), .duty (duty_b_q), .pwm_raw (raw_b)
    );

    pwm_compare #(.CNT_W(CNT_W)) u_cmp_c (
        .clk (clk), .rst_n (rst_n), .en (en_q),
        .cnt (cnt), .duty (duty_c_q), .pwm_raw (raw_c)
    );

    genvar g;
    generate
        for (g = 0; g < 3; g = g + 1) begin : phase
            deadtime #(.DT_W(DT_W)) u_dt (
                .clk       (clk),
                .rst_n     (rst_n),
                .dt        (dt_q),
                .pwm_raw   (raw[g]),
                .force_off (force_off),
                .pwm_h     (pwm_h[g]),
                .pwm_l     (pwm_l[g])
            );
        end
    endgenerate

endmodule
