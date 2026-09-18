// fc_unit.v -- Project FLASH V1, final 64 -> 2 fully-connected layer.
//
//   logit[n] = bias[b_base + n] + sum_{c=0..63} w[w_base + n*64 + c] * gap[c]
//
// int32 accumulator, no shift, no clamp -- exactly what the golden model's
// FC branch does (`a @ W.T + B`). The two neurons are run sequentially, one
// MAC per cycle (128 MACs total), using the same pipeline discipline as
// conv_engine.v:  [operand mux] -> REG -> [multiply] -> REG -> [accumulate].
//
// Activation signedness: gap values are uint8 (0..255) like every other
// activation in this design, so each 8-bit slice is zero-extended into a
// 9-bit signed operand before the multiply -- NOT sign-extended. Reading a
// gap of e.g. 200 as a signed int8 would make it -56 and silently wreck the
// logits; conv_engine.v treats its activations the same way.
//
// PORT NOTE: the brief's port sketch omits the weight/bias ROM ports, but
// its own implementation note ("reads weight ROM at w_base + n*64 + c,
// reads bias ROM at b_base + n") requires them, so they are added here with
// the same external-ROM convention and 2-cycle latency as conv_engine.v.
// gap_in[0:63] is flattened to gap_in_flat (channel k at bits [8k+7:8k]) --
// this iverilog parses neither unpacked-array ports nor 2D arrays.
`include "layer_table.vh"

module fc_unit (
    input  wire                  clk,
    input  wire                  rst,
    input  wire                  start,
    input  wire [`LT_WORD_W-1:0] layer_word,

    input  wire [511:0]          gap_in_flat, // 64 channels x 8 bits (uint8), channel k at [8k+7:8k]

    // weight ROM (external)
    // LATENCY: w_rd_addr -> w_rd_data is 2 cycles (address reg + BRAM output reg)
    output wire [19:0]           w_rd_addr,
    input  wire signed [7:0]     w_rd_data,

    // bias ROM (external)
    // LATENCY: b_rd_addr -> b_rd_data is 2 cycles (address reg + BRAM output reg)
    output wire [9:0]            b_rd_addr,
    input  wire signed [31:0]    b_rd_data,

    output reg  signed [31:0]    logit0,
    output reg  signed [31:0]    logit1,
    output reg                   done
);

    reg [11:0] in_c_r, out_c_r;
    reg [19:0] w_base_r;
    reg [9:0]  b_base_r;

    localparam S_IDLE = 2'd0, S_RUN = 2'd1, S_DRAIN = 2'd2, S_DONE = 2'd3;
    localparam DRAIN_CYCLES = 8; // >= pipeline depth (2 mem + operand reg + product reg), with margin
    reg [1:0]  state;
    reg [11:0] n_idx, c_idx;
    reg [3:0]  drain_cnt;

    wire accept_start = (state == S_IDLE || state == S_DONE) && start;
    wire mac_active   = (state == S_RUN);

    assign w_rd_addr = w_base_r + (n_idx * in_c_r) + c_idx;
    assign b_rd_addr = b_base_r + n_idx[9:0];

    wire        tag0_is_first = (c_idx == 12'd0);
    wire        tag0_is_last  = (c_idx == in_c_r - 12'd1);
    wire [7:0]  gap_sel       = gap_in_flat[c_idx * 8 +: 8];

    // ------------------------------------------------------------------
    // FSM + counters (c innermost, then n)
    // ------------------------------------------------------------------
    always @(posedge clk) begin
        if (rst) begin
            state <= S_IDLE; done <= 1'b0;
            n_idx <= 12'd0; c_idx <= 12'd0; drain_cnt <= 4'd0;
        end else if (accept_start) begin
            in_c_r   <= layer_word[`LT_IN_C_MSB   : `LT_IN_C_LSB];
            out_c_r  <= layer_word[`LT_OUT_C_MSB  : `LT_OUT_C_LSB];
            w_base_r <= layer_word[`LT_W_BASE_MSB : `LT_W_BASE_LSB];
            b_base_r <= layer_word[`LT_B_BASE_MSB : `LT_B_BASE_LSB];
            n_idx <= 12'd0; c_idx <= 12'd0; drain_cnt <= 4'd0;
            done  <= 1'b0;
            state <= S_RUN;
        end else begin
            case (state)
                S_IDLE: ;
                S_RUN: begin
                    if (c_idx == in_c_r - 12'd1) begin
                        c_idx <= 12'd0;
                        if (n_idx == out_c_r - 12'd1) begin
                            drain_cnt <= 4'd0;
                            state     <= S_DRAIN;
                        end else begin
                            n_idx <= n_idx + 12'd1;
                        end
                    end else begin
                        c_idx <= c_idx + 12'd1;
                    end
                end
                S_DRAIN: begin
                    if (drain_cnt == DRAIN_CYCLES - 1) state <= S_DONE;
                    else drain_cnt <= drain_cnt + 4'd1;
                end
                S_DONE: done <= 1'b1;
            endcase
        end
    end

    // ------------------------------------------------------------------
    // Tag pipeline, 4 deep: 2 cycles of ROM latency, then the operand
    // register, then the product register -- identical staging to
    // conv_engine.v so the accumulate stage knows which neuron each
    // product belongs to and whether to start from bias.
    // ------------------------------------------------------------------
    reg        tag_valid   [1:4];
    reg        tag_is_first[1:4];
    reg        tag_is_last [1:4];
    reg [11:0] tag_n       [1:4];
    integer    k;

    // gap comes from a register bus (0-cycle), the weight from ROM (2-cycle):
    // delay gap by 2 so both operands reach the operand mux on the same cycle.
    reg [7:0] gap_d1, gap_d2;

    always @(posedge clk) begin
        if (rst) begin
            for (k = 1; k <= 4; k = k + 1) tag_valid[k] <= 1'b0;
        end else begin
            gap_d1 <= gap_sel;
            gap_d2 <= gap_d1;

            tag_valid[1]    <= mac_active;
            tag_is_first[1] <= tag0_is_first;
            tag_is_last[1]  <= tag0_is_last;
            tag_n[1]        <= n_idx;

            tag_valid[2]    <= tag_valid[1];
            tag_is_first[2] <= tag_is_first[1];
            tag_is_last[2]  <= tag_is_last[1];
            tag_n[2]        <= tag_n[1];

            tag_valid[3]    <= tag_valid[2];
            tag_is_first[3] <= tag_is_first[2];
            tag_is_last[3]  <= tag_is_last[2];
            tag_n[3]        <= tag_n[2];

            tag_valid[4]    <= tag_valid[3];
            tag_is_first[4] <= tag_is_first[3];
            tag_is_last[4]  <= tag_is_last[3];
            tag_n[4]        <= tag_n[3];
        end
    end

    // ------------------------------------------------------------------
    // operand mux -> REG -> multiply -> REG -> accumulate
    // ------------------------------------------------------------------
    reg signed [7:0] w_operand_reg;
    reg signed [8:0] act_operand_reg;
    always @(posedge clk) begin
        w_operand_reg   <= w_rd_data;        // register between operand mux and multiplier
        act_operand_reg <= {1'b0, gap_d2};   // uint8 zero-extended to 9-bit signed
    end

    wire signed [16:0] product_mux = w_operand_reg * act_operand_reg;
    reg  signed [16:0] product_reg;
    always @(posedge clk) begin
        product_reg <= product_mux;          // register between multiplier and accumulator
    end

    // bias mirrors the operand-reg/product-reg delay so it lands on the
    // accumulate stage with its neuron's first product (same trick as
    // conv_engine.v -- bias bypasses the multiplier).
    reg signed [31:0] bias_stage1, bias_stage2;
    always @(posedge clk) begin
        bias_stage1 <= b_rd_data;
        bias_stage2 <= bias_stage1;
    end

    reg  signed [31:0] acc_reg;
    wire signed [31:0] product_sext = {{15{product_reg[16]}}, product_reg};
    wire signed [31:0] acc_add_base = tag_is_first[4] ? bias_stage2 : acc_reg;
    wire signed [31:0] acc_comb     = acc_add_base + product_sext;

    always @(posedge clk) begin
        if (rst) begin
            logit0 <= 32'sd0;
            logit1 <= 32'sd0;
        end else begin
            if (tag_valid[4]) begin
                acc_reg <= acc_comb;
                if (tag_is_last[4]) begin
                    if (tag_n[4] == 12'd0) logit0 <= acc_comb;
                    else                   logit1 <= acc_comb;
                end
            end
        end
    end

endmodule
