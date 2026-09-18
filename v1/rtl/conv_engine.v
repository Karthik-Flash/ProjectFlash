// conv_engine.v -- Project FLASH V1, shared 3x3 stride-2 int8 conv engine.
//
// Computes, for ONE CONV3X3 layer described by `layer_word` (see layer_table.vh):
//   acc[o,y,x] = bias[o] + sum_{c,i,j} signed_w[o,c,i,j] * unsigned_xpad[c,stride*y-pad+i,stride*x-pad+j]
//   out[o,y,x] = clip(acc >>> shift, 0, 255)
// xpad is the input feature map with `pad` zeros on every border; the RTL never skips a
// read/multiply for a padded position, it gates the fetched activation operand to 0 instead
// (matches the golden model's zero-padded array exactly).
//
// Weights are signed 8-bit, activations are unsigned 8-bit (widened to a 9-bit signed operand
// with an implicit zero sign bit before the multiply). Each product is signed 9x8 -> 17-bit
// signed, accumulated in a 22-bit signed accumulator (the widest guaranteed conv bound across
// conv1..conv5, see docs/V1_audit_v1_1.md "Numbers the RTL author needs").
//
// Pipeline (non-negotiable per the handoff doc -- v0's single combinational mux+DSP+adder was
// the critical path, V1 has more channels so it would be worse here):
//   [operand mux] -> REG -> [multiply] -> REG -> [accumulate]
// A small tag pipeline (valid/is_first/is_last/out_idx/is_pad) rides alongside the data so that
// when a product finally reaches the accumulate stage, the engine still knows which (o,y,x)
// group it belongs to and whether to start the sum from bias or continue it.
//
// One MAC is issued per cycle with no stalls; the run length is exactly
// out_c*out_h*out_w*in_c*9 cycles (matches the "MACs per image" figure in the audit) plus a
// fixed drain tail while the last few MACs finish flowing through the pipeline.
`include "layer_table.vh"

module conv_engine (
    input  wire                  clk,
    input  wire                  rst,
    input  wire                  start,
    input  wire [`LT_WORD_W-1:0] layer_word,   // packed descriptor for THIS layer
    output reg                   done,

    // weight ROM (external -- do not instantiate in this module)
    // LATENCY: w_rd_addr -> w_rd_data is 2 cycles (address reg + BRAM output reg)
    output wire [19:0]           w_rd_addr,
    input  wire signed [7:0]     w_rd_data,

    // bias ROM
    // LATENCY: b_rd_addr -> b_rd_data is 2 cycles (address reg + BRAM output reg)
    output wire [9:0]            b_rd_addr,
    input  wire signed [31:0]    b_rd_data,

    // input feature map (external BRAM, uint8, channel-major: idx = c*in_h*in_w + y*in_w + x)
    // LATENCY: fm_rd_addr -> fm_rd_data is 2 cycles (address reg + BRAM output reg)
    output wire [17:0]           fm_rd_addr,
    input  wire [7:0]            fm_rd_data,

    // output feature map (external BRAM, uint8, channel-major: idx = o*out_h*out_w + y*out_w + x)
    output reg  [17:0]           fm_wr_addr,
    output reg  [7:0]            fm_wr_data,
    output reg                   fm_wr_en,

    // debug only -- not part of the required interface. Lets the testbench check every raw
    // accumulator the engine produces, not just the shifted/clamped uint8 output. Pulses for
    // exactly one cycle per (o,y,x) group, in step with fm_wr_en, same out_idx as fm_wr_addr.
    output reg                   dbg_acc_valid,
    output reg  signed [21:0]    dbg_acc_value,
    output reg  [17:0]           dbg_acc_idx
);

    // ------------------------------------------------------------------
    // Layer parameters, latched from layer_word when a run starts. Using
    // the LT_* field macros from layer_table.vh -- no hardcoded bit positions.
    // ------------------------------------------------------------------
    reg  [11:0] in_c_r, out_c_r, in_h_r, in_w_r, out_h_r, out_w_r;
    reg  [5:0]  shift_r;
    reg  [19:0] w_base_r;
    reg  [9:0]  b_base_r;
    reg  [3:0]  stride_r, pad_r;

    // ------------------------------------------------------------------
    // FSM + loop-nest counters. Loop order (innermost -> outermost):
    //   j (0..2), i (0..2), c (0..in_c-1), x (0..out_w-1), y (0..out_h-1), o (0..out_c-1)
    // One MAC's operand addresses are generated per cycle while state==S_RUN.
    // ------------------------------------------------------------------
    localparam S_IDLE  = 2'd0,
               S_RUN   = 2'd1,
               S_DRAIN = 2'd2,
               S_DONE  = 2'd3;
    reg [1:0] state;

    reg [11:0] o, y, x, c;
    reg [1:0]  i, j;

    // Pipeline depth from "address issued" to "accumulate stage" is 4 cycles:
    // 2 cycles of memory latency + 1 operand register + 1 product register.
    // Drain for a generous margin beyond that so `done`/the final write can
    // never race the pipeline's tail -- exactness matters far more here than
    // shaving a few cycles off an already-large per-image cycle count.
    localparam PIPE_DEPTH   = 4;
    localparam DRAIN_CYCLES = 8;
    reg [3:0] drain_cnt;

    wire accept_start = (state == S_IDLE || state == S_DONE) && start;

    always @(posedge clk) begin
        if (rst) begin
            state     <= S_IDLE;
            done      <= 1'b0;
            o <= 12'd0; y <= 12'd0; x <= 12'd0; c <= 12'd0; i <= 2'd0; j <= 2'd0;
            drain_cnt <= 4'd0;
        end else if (accept_start) begin
            in_c_r   <= layer_word[`LT_IN_C_MSB   : `LT_IN_C_LSB];
            out_c_r  <= layer_word[`LT_OUT_C_MSB  : `LT_OUT_C_LSB];
            in_h_r   <= layer_word[`LT_IN_H_MSB   : `LT_IN_H_LSB];
            in_w_r   <= layer_word[`LT_IN_W_MSB   : `LT_IN_W_LSB];
            out_h_r  <= layer_word[`LT_OUT_H_MSB  : `LT_OUT_H_LSB];
            out_w_r  <= layer_word[`LT_OUT_W_MSB  : `LT_OUT_W_LSB];
            shift_r  <= layer_word[`LT_SHIFT_MSB  : `LT_SHIFT_LSB];
            w_base_r <= layer_word[`LT_W_BASE_MSB : `LT_W_BASE_LSB];
            b_base_r <= layer_word[`LT_B_BASE_MSB : `LT_B_BASE_LSB];
            stride_r <= layer_word[`LT_STRIDE_MSB : `LT_STRIDE_LSB];
            pad_r    <= layer_word[`LT_PAD_MSB    : `LT_PAD_LSB];
            o <= 12'd0; y <= 12'd0; x <= 12'd0; c <= 12'd0; i <= 2'd0; j <= 2'd0;
            drain_cnt <= 4'd0;
            done  <= 1'b0;
            state <= S_RUN;
        end else begin
            case (state)
                S_IDLE: ; // wait for start
                S_RUN: begin
                    // innermost-to-outermost carry chain: j, i, c, x, y, o
                    if (j == 2'd2) begin
                        j <= 2'd0;
                        if (i == 2'd2) begin
                            i <= 2'd0;
                            if (c == in_c_r - 12'd1) begin
                                c <= 12'd0;
                                if (x == out_w_r - 12'd1) begin
                                    x <= 12'd0;
                                    if (y == out_h_r - 12'd1) begin
                                        y <= 12'd0;
                                        if (o == out_c_r - 12'd1) begin
                                            // last MAC of the layer issued this cycle
                                            state     <= S_DRAIN;
                                            drain_cnt <= 4'd0;
                                        end else begin
                                            o <= o + 12'd1;
                                        end
                                    end else begin
                                        y <= y + 12'd1;
                                    end
                                end else begin
                                    x <= x + 12'd1;
                                end
                            end else begin
                                c <= c + 12'd1;
                            end
                        end else begin
                            i <= i + 2'd1;
                        end
                    end else begin
                        j <= j + 2'd1;
                    end
                end
                S_DRAIN: begin
                    if (drain_cnt == DRAIN_CYCLES - 1) begin
                        state <= S_DONE;
                    end else begin
                        drain_cnt <= drain_cnt + 4'd1;
                    end
                end
                S_DONE: begin
                    done <= 1'b1; // held until the next accepted start
                end
            endcase
        end
    end

    // ------------------------------------------------------------------
    // Stage 0 (combinational, same cycle as the counters above): operand
    // addresses and this MAC's control tag.
    // ------------------------------------------------------------------
    wire mac_active = (state == S_RUN);

    // Zero-padding check. Computed with generous signed width so the
    // subtraction (stride*y - pad + i) can go negative without any
    // Verilog signed/unsigned expression-context surprises.
    reg signed [19:0] iy_i, ix_i;
    always @(*) begin
        iy_i = (stride_r * y) + i - pad_r;
        ix_i = (stride_r * x) + j - pad_r;
    end
    wire signed [19:0] in_h_s = $signed({8'd0, in_h_r});
    wire signed [19:0] in_w_s = $signed({8'd0, in_w_r});
    wire tag0_is_pad = (iy_i < 0) || (iy_i >= in_h_s) || (ix_i < 0) || (ix_i >= in_w_s);

    assign w_rd_addr  = w_base_r + (o * in_c_r * 12'd9) + (c * 12'd9) + (i * 2'd3) + {10'd0, j};
    assign fm_rd_addr = tag0_is_pad ? 18'd0
                                     : (c * in_h_r * in_w_r) + (iy_i[17:0] * in_w_r) + ix_i[17:0];
    assign b_rd_addr  = b_base_r + o[9:0];

    wire        tag0_is_first = (c == 12'd0) && (i == 2'd0) && (j == 2'd0);
    wire        tag0_is_last  = (c == in_c_r - 12'd1) && (i == 2'd2) && (j == 2'd2);
    wire [17:0] tag0_out_idx  = (o * out_h_r * out_w_r) + (y * out_w_r) + x[11:0];

    // ------------------------------------------------------------------
    // Tag pipeline: mirrors the 4-cycle path from address-issue to the
    // accumulate stage (2 cycles memory latency + operand reg + product
    // reg) so the right (o,y,x) bookkeeping is available exactly when
    // each MAC's product comes back.
    //   tag[1] : valid the cycle after issue        (memory latency, cycle 1 of 2)
    //   tag[2] : aligns with w_rd_data/fm_rd_data    (memory latency, cycle 2 of 2) -- operand mux reads this
    //   tag[3] : aligns with the registered operands -- multiply reads this
    //   tag[4] : aligns with product_reg             -- accumulate/writeback reads this
    // ------------------------------------------------------------------
    reg        tag_valid   [1:4];
    reg        tag_is_first[1:4];
    reg        tag_is_last [1:4];
    reg        tag_is_pad  [1:4];
    reg [17:0] tag_out_idx [1:4];

    integer k;
    always @(posedge clk) begin
        if (rst) begin
            for (k = 1; k <= 4; k = k + 1) tag_valid[k] <= 1'b0;
        end else begin
            tag_valid[1]    <= mac_active;
            tag_is_first[1] <= tag0_is_first;
            tag_is_last[1]  <= tag0_is_last;
            tag_is_pad[1]   <= tag0_is_pad;
            tag_out_idx[1]  <= tag0_out_idx;

            tag_valid[2]    <= tag_valid[1];
            tag_is_first[2] <= tag_is_first[1];
            tag_is_last[2]  <= tag_is_last[1];
            tag_is_pad[2]   <= tag_is_pad[1];
            tag_out_idx[2]  <= tag_out_idx[1];

            tag_valid[3]    <= tag_valid[2];
            tag_is_first[3] <= tag_is_first[2];
            tag_is_last[3]  <= tag_is_last[2];
            tag_is_pad[3]   <= tag_is_pad[2];
            tag_out_idx[3]  <= tag_out_idx[2];

            tag_valid[4]    <= tag_valid[3];
            tag_is_first[4] <= tag_is_first[3];
            tag_is_last[4]  <= tag_is_last[3];
            tag_is_pad[4]   <= tag_is_pad[3];
            tag_out_idx[4]  <= tag_out_idx[3];
        end
    end

    // ------------------------------------------------------------------
    // Operand mux (combinational, using tag[2] -- the cycle w_rd_data/
    // fm_rd_data become valid for THIS mac) -> REGISTER -> multiplier.
    // Padded positions are never skipped: the fetched activation is
    // simply gated to 0, exactly like the golden model's zero border.
    // ------------------------------------------------------------------
    wire signed [8:0] act_operand_mux = tag_is_pad[2] ? 9'sd0 : {1'b0, fm_rd_data};

    reg signed [7:0] w_operand_reg;
    reg signed [8:0] act_operand_reg;
    always @(posedge clk) begin
        w_operand_reg   <= w_rd_data;      // register between operand mux and multiplier
        act_operand_reg <= act_operand_mux; // register between operand mux and multiplier
    end

    // ------------------------------------------------------------------
    // Multiply (combinational, 8-bit signed x 9-bit signed -> 17-bit
    // signed) -> REGISTER -> accumulator.
    // ------------------------------------------------------------------
    wire signed [16:0] product_mux = w_operand_reg * act_operand_reg;

    reg signed [16:0] product_reg;
    always @(posedge clk) begin
        product_reg <= product_mux; // register between multiplier and accumulator
    end

    // ------------------------------------------------------------------
    // Bias delay: bias doesn't go through the multiplier, but it needs to
    // reach the accumulate stage on the SAME cycle as product_reg (tag[4]).
    // b_rd_data is valid 2 cycles after b_rd_addr changes, same as every
    // other read port; two more plain pipeline registers here keep it in
    // lock-step with the operand-reg/product-reg path so both land on the
    // accumulate stage together, whichever group is currently in flight.
    // ------------------------------------------------------------------
    reg signed [31:0] bias_stage1, bias_stage2;
    always @(posedge clk) begin
        bias_stage1 <= b_rd_data;
        bias_stage2 <= bias_stage1;
    end
    wire signed [21:0] bias_aligned = bias_stage2[21:0];

    // ------------------------------------------------------------------
    // Accumulate (tag[4]): acc = (is_first ? bias : running acc) + product.
    // Width note: the 22-bit accumulator width is the "guaranteed" bound
    // from the audit, which already includes the bias term in its
    // derivation, so taking the low 22 bits of the 32-bit-stored bias is
    // safe (confirmed bias range needs <=16 bits, see docs/V1_audit_v1_1.md).
    // ------------------------------------------------------------------
    reg signed [21:0] acc_reg;
    wire signed [21:0] product_sext  = {{5{product_reg[16]}}, product_reg};
    wire signed [21:0] acc_add_base  = tag_is_first[4] ? bias_aligned : acc_reg;
    wire signed [21:0] acc_comb      = acc_add_base + product_sext;

    always @(posedge clk) begin
        if (tag_valid[4]) acc_reg <= acc_comb;
    end

    // ------------------------------------------------------------------
    // Shift + clamp, only meaningful when tag[4] is the last MAC of a
    // group. `>>>` is an arithmetic (sign-preserving, floor-towards
    // -infinity) shift, matching the golden model's `acc >> shift` on a
    // Python int exactly.
    // ------------------------------------------------------------------
    wire signed [21:0] shifted = acc_comb >>> shift_r;
    wire [7:0] clamped = (shifted < 0)   ? 8'd0
                        : (shifted > 22'sd255) ? 8'd255
                        : shifted[7:0];

    always @(posedge clk) begin
        if (rst) begin
            fm_wr_en      <= 1'b0;
            dbg_acc_valid <= 1'b0;
        end else begin
            fm_wr_en      <= tag_valid[4] && tag_is_last[4];
            fm_wr_addr    <= tag_out_idx[4];
            fm_wr_data    <= clamped;

            dbg_acc_valid <= tag_valid[4] && tag_is_last[4];
            dbg_acc_value <= acc_comb;
            dbg_acc_idx   <= tag_out_idx[4];
        end
    end

endmodule
