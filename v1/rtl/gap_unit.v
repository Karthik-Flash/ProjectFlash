// gap_unit.v -- Project FLASH V1, global average pooling.
//
// 64 running sums over the final feature map, one uint8 sample per cycle
// (tagged with which channel it belongs to via `in_c`), then per channel:
// `gap = sum >> s_gap`. No explicit clamp is applied beyond what the shift
// itself guarantees -- s_gap is chosen at export time as
// ceil(log2(in_h*in_w)) specifically so that sum>>s_gap can never exceed 255
// for any non-negative uint8 inputs (see docs/V1_audit_v1_1.md section 8);
// the golden model applies no clamp here either (unlike the conv layers),
// so matching it bit-exactly means NOT clamping. For V1.1, in_h=in_w=1 (the
// final conv5 map is already 1x1) and s_gap=0, so this degenerates to sum
// -> passthrough per channel, exactly as the brief describes; the exact
// same RTL handles V1.2's 7x7/s_gap=6 case with no changes, parameterised
// entirely from layer_word.
//
// TOOLCHAIN NOTE (same as line_buffer_v1.v/conv_engine.v): the installed
// iverilog does not parse unpacked-array ports, so `gap_out[0:63]` is
// flattened to a packed bus, gap_out_flat: channel k occupies bits
// [14*k+13 : 14*k] (channel 0 at the LSB end, ascending -- no MSB-first
// convention was specified for this port, unlike line_buffer_v1's win[]).
// 14 bits/channel comfortably covers the running sum for any V1 stage
// (worst case in this project: V1.2's 49-pixel map, sum <= 49*255 = 12,495,
// needs 14 bits) as well as the final 0..255 result.
`include "layer_table.vh"

module gap_unit (
    input  wire                  clk,
    input  wire                  rst,
    input  wire                  start,
    input  wire [`LT_WORD_W-1:0] layer_word,
    input  wire [7:0]            in_data,
    input  wire                  in_valid,
    input  wire [11:0]           in_c,
    output reg  [895:0]          gap_out_flat, // 64 channels x 14 bits, packed -- see header
    output reg                   done
);

    reg [11:0] in_c_cnt_r, in_h_r, in_w_r;
    reg [5:0]  shift_r;

    reg [17:0] sum [0:63];
    reg [17:0] count_received;
    wire [17:0] total_expected = in_c_cnt_r * in_h_r * in_w_r;

    localparam S_IDLE = 2'd0, S_RUN = 2'd1, S_FINALIZE = 2'd2, S_DONE = 2'd3;
    reg [1:0] state;
    integer   kk, ch;

    function [13:0] shift_clamp;
        input [17:0] s;
        input [5:0]  sh;
        reg   [17:0] shifted;
        begin
            shifted     = s >> sh; // sum is always non-negative (uint8 accumulation)
            shift_clamp = (shifted > 18'd255) ? 14'd255 : shifted[13:0];
        end
    endfunction

    wire accept_start = (state == S_IDLE || state == S_DONE) && start;

    always @(posedge clk) begin
        if (rst) begin
            state <= S_IDLE;
            done  <= 1'b0;
            count_received <= 18'd0;
            for (kk = 0; kk < 64; kk = kk + 1) sum[kk] <= 18'd0;
        end else if (accept_start) begin
            in_c_cnt_r <= layer_word[`LT_IN_C_MSB : `LT_IN_C_LSB];
            in_h_r     <= layer_word[`LT_IN_H_MSB : `LT_IN_H_LSB];
            in_w_r     <= layer_word[`LT_IN_W_MSB : `LT_IN_W_LSB];
            shift_r    <= layer_word[`LT_SHIFT_MSB: `LT_SHIFT_LSB];
            count_received <= 18'd0;
            done  <= 1'b0;
            state <= S_RUN;
            for (kk = 0; kk < 64; kk = kk + 1) sum[kk] <= 18'd0;
        end else begin
            case (state)
                S_IDLE: ;
                S_RUN: begin
                    if (in_valid) begin
                        sum[in_c]      <= sum[in_c] + {10'd0, in_data};
                        count_received <= count_received + 18'd1;
                        if (count_received + 18'd1 == total_expected) begin
                            state <= S_FINALIZE;
                        end
                    end
                end
                S_FINALIZE: begin
                    // one cycle after S_RUN's last write, so every sum[] entry
                    // (including the final sample just accumulated) is settled.
                    for (ch = 0; ch < 64; ch = ch + 1) begin
                        gap_out_flat[ch * 14 +: 14] <= shift_clamp(sum[ch], shift_r);
                    end
                    state <= S_DONE;
                end
                S_DONE: begin
                    done <= 1'b1;
                end
            endcase
        end
    end

endmodule
