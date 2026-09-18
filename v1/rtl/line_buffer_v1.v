// line_buffer_v1.v -- Project FLASH V1, streaming 3x3/stride-2 windower.
//
// Streams one input feature map channel at a time out of an external BRAM and
// emits, one per cycle, the 3x3 zero-padded window centred on every stride-2
// output position (out_y, out_x) for every input channel (in_c). Out-of-bounds
// taps (row or column) are gated to 0, exactly like the golden model's padded
// array and exactly like conv_engine.v's own padding handling.
//
// TOOLCHAIN NOTE: the installed iverilog (0.9.7) does not parse unpacked-array
// module ports in ANY form (`output ... win [0:8]` is a syntax error regardless
// of ANSI/non-ANSI style or generation flag -- confirmed empirically before
// writing this file). Every array-shaped port in this session's modules is
// therefore a flattened packed bus instead, documented at each port.
//
// win_flat packing: 9 taps of 8 bits each = 72 bits, row-major (i outer, j
// inner, tap_idx = i*3+j, i/j in 0..2), tap_idx 0 = (row-1,col-1) at the
// bus's MSB end:
//   win_flat[71:64] = tap(i=0,j=0)   win_flat[63:56] = tap(0,1)   win_flat[55:48] = tap(0,2)
//   win_flat[47:40] = tap(1,0)       win_flat[39:32] = tap(1,1)   win_flat[31:24] = tap(1,2)
//   win_flat[23:16] = tap(2,0)       win_flat[15:8]  = tap(2,1)   win_flat[7:0]   = tap(2,2)
// Each 8-bit slice holds a raw uint8 activation value (0..255); the "signed"
// wording in the original port sketch only matters if a consumer chooses to
// read it that way -- these are never negative, so it is bit-identical to
// treat each slice as unsigned uint8, which is what the testbench does.
//
// Implementation note: rather than the "2 row buffers that rotate" hinted in
// the brief, this version keeps 3 full row buffers and re-fetches all 3 for
// every output row (in_h/in_w are tiny for every V1 stage: 28 max for V1.1,
// 224 max for V1.2 -- the extra reads are free in simulation time and this
// removes an entire class of rotation-indexing bugs for a module this
// session's job is to get bit-exact, not area-optimal).
`include "layer_table.vh"

module line_buffer_v1 (
    input  wire                  clk,
    input  wire                  rst,
    input  wire                  start,
    input  wire [`LT_WORD_W-1:0] layer_word,

    // input feature map (external BRAM, uint8, channel-major: idx = c*in_h*in_w + y*in_w + x)
    // LATENCY: fm_rd_addr -> fm_rd_data is 2 cycles (address reg + BRAM output reg)
    output wire [17:0]           fm_rd_addr,
    input  wire [7:0]            fm_rd_data,

    output reg  [71:0]           win_flat,   // 9 taps, packed -- see header comment for layout
    output reg  [11:0]           win_y,
    output reg  [11:0]           win_x,
    output reg  [11:0]           win_c,
    output reg                   win_valid,  // pulses 1 cycle per emitted window
    output reg                   done
);

    // ------------------------------------------------------------------
    // Layer parameters (CONV3X3 only: stride=2, kernel=3, pad=1 hardcoded,
    // matching what this module is documented to handle).
    // ------------------------------------------------------------------
    localparam STRIDE = 2, PAD = 1;
    reg [11:0] in_c_r, in_h_r, in_w_r, out_h_r, out_w_r;

    // ------------------------------------------------------------------
    // FSM: for each channel c, fetch 3 rows (row_slot 0,1,2 = i = 0,1,2
    // relative to the current output row), then emit out_w_r windows.
    // ------------------------------------------------------------------
    localparam S_IDLE       = 3'd0,
               S_FETCH_ROW  = 3'd1,
               S_FETCH_DRAIN= 3'd2,
               S_EMIT       = 3'd3,
               S_DRAIN      = 3'd4,
               S_DONE       = 3'd5;
    reg [2:0] state;

    reg [11:0] c_cnt, y_out, x_out, col;
    reg [1:0]  row_slot;
    reg [2:0]  fetch_drain_cnt;
    reg [2:0]  final_drain_cnt;

    // Per-row-slot bookkeeping, latched once when that row's fetch begins.
    reg        row_in_bounds;
    reg signed [19:0] iy_i;

    // 3 row buffers, sized generously for any V1 stage (max in_w = 224).
    // TOOLCHAIN NOTE: this iverilog also rejects 2D memory arrays ("only 1
    // dimensional arrays are currently supported"), so row_slot 0/1/2 are
    // three separate 1D arrays instead of rowbuf[0:2][0:223].
    reg [7:0] rowbuf0 [0:223];
    reg [7:0] rowbuf1 [0:223];
    reg [7:0] rowbuf2 [0:223];

    wire accept_start = (state == S_IDLE || state == S_DONE) && start;

    // ------------------------------------------------------------------
    // Row-fetch read pipeline: address issued from `col` each cycle while
    // fetching; matches the 2-cycle external-memory latency at fm_rd_addr.
    // ------------------------------------------------------------------
    // NOTE: a Verilog part-select of a signed reg (e.g. iy_i[19:0]) is always
    // unsigned, so the in-bounds test below deliberately uses `row_in_bounds`
    // (computed with a proper signed comparison further down) rather than
    // re-deriving it inline here. When the row is out of bounds the address
    // is clamped to 0 -- harmless, since fetch_rowok_d2 forces the captured
    // byte to 0 regardless of what garbage that address happens to read.
    assign fm_rd_addr = c_cnt * in_h_r * in_w_r
                       + (row_in_bounds ? iy_i[17:0] : 18'd0) * in_w_r
                       + col;

    reg        fetch_valid_d1, fetch_valid_d2;
    reg [11:0] fetch_col_d1, fetch_col_d2;
    reg        fetch_rowok_d1, fetch_rowok_d2;
    always @(posedge clk) begin
        fetch_valid_d1  <= (state == S_FETCH_ROW);
        fetch_col_d1    <= col;
        fetch_rowok_d1  <= row_in_bounds;
        fetch_valid_d2  <= fetch_valid_d1;
        fetch_col_d2    <= fetch_col_d1;
        fetch_rowok_d2  <= fetch_rowok_d1;
    end
    wire [7:0] fetch_byte = fetch_rowok_d2 ? fm_rd_data : 8'd0;
    always @(posedge clk) begin
        if (fetch_valid_d2) begin
            case (row_slot)
                2'd0: rowbuf0[fetch_col_d2] <= fetch_byte;
                2'd1: rowbuf1[fetch_col_d2] <= fetch_byte;
                default: rowbuf2[fetch_col_d2] <= fetch_byte;
            endcase
        end
    end

    // ------------------------------------------------------------------
    // Main FSM
    // ------------------------------------------------------------------
    always @(posedge clk) begin
        if (rst) begin
            state <= S_IDLE;
            done  <= 1'b0;
            win_valid <= 1'b0;
            c_cnt <= 12'd0; y_out <= 12'd0; x_out <= 12'd0; col <= 12'd0;
            row_slot <= 2'd0; fetch_drain_cnt <= 3'd0; final_drain_cnt <= 3'd0;
        end else if (accept_start) begin
            in_c_r  <= layer_word[`LT_IN_C_MSB : `LT_IN_C_LSB];
            in_h_r  <= layer_word[`LT_IN_H_MSB : `LT_IN_H_LSB];
            in_w_r  <= layer_word[`LT_IN_W_MSB : `LT_IN_W_LSB];
            out_h_r <= layer_word[`LT_OUT_H_MSB: `LT_OUT_H_LSB];
            out_w_r <= layer_word[`LT_OUT_W_MSB: `LT_OUT_W_LSB];
            c_cnt <= 12'd0; y_out <= 12'd0; x_out <= 12'd0; col <= 12'd0;
            row_slot <= 2'd0; fetch_drain_cnt <= 3'd0;
            done <= 1'b0; win_valid <= 1'b0;
            state <= S_FETCH_ROW;
        end else begin
            win_valid <= 1'b0; // default; set below on an actual emit cycle
            case (state)
                S_IDLE: ;
                S_FETCH_ROW: begin
                    if (col == in_w_r - 12'd1) begin
                        col <= 12'd0;
                        fetch_drain_cnt <= 3'd0;
                        state <= S_FETCH_DRAIN;
                    end else begin
                        col <= col + 12'd1;
                    end
                end
                S_FETCH_DRAIN: begin
                    // 2 cycles for the last column's data to land, +1 margin.
                    if (fetch_drain_cnt == 3'd2) begin
                        if (row_slot == 2'd2) begin
                            row_slot <= 2'd0;
                            x_out    <= 12'd0;
                            state    <= S_EMIT;
                        end else begin
                            row_slot <= row_slot + 2'd1;
                            state    <= S_FETCH_ROW;
                        end
                    end else begin
                        fetch_drain_cnt <= fetch_drain_cnt + 3'd1;
                    end
                end
                S_EMIT: begin
                    // win_flat captures the SAME (pre-increment) x_out/y_out
                    // this cycle as win_x/win_y below -- it must not be a bare
                    // combinational function of the live x_out/y_out counters,
                    // or it would show next cycle's window on this cycle's
                    // coordinates once x_out/y_out advance below.
                    win_flat <= win_flat_comb;
                    win_valid <= 1'b1;
                    win_y     <= y_out;
                    win_x     <= x_out;
                    win_c     <= c_cnt;
                    if (x_out == out_w_r - 12'd1) begin
                        if (y_out == out_h_r - 12'd1) begin
                            y_out <= 12'd0;
                            if (c_cnt == in_c_r - 12'd1) begin
                                final_drain_cnt <= 3'd0;
                                state <= S_DRAIN;
                            end else begin
                                c_cnt <= c_cnt + 12'd1;
                                row_slot <= 2'd0;
                                state <= S_FETCH_ROW;
                            end
                        end else begin
                            y_out <= y_out + 12'd1;
                            row_slot <= 2'd0;
                            state <= S_FETCH_ROW;
                        end
                        x_out <= 12'd0;
                    end else begin
                        x_out <= x_out + 12'd1;
                    end
                end
                S_DRAIN: begin
                    if (final_drain_cnt == 3'd3) state <= S_DONE;
                    else final_drain_cnt <= final_drain_cnt + 3'd1;
                end
                S_DONE: begin
                    done <= 1'b1;
                end
            endcase
        end
    end

    // ------------------------------------------------------------------
    // Row-in-bounds latch + iy for the row currently being fetched
    // (row_slot acts as `i`; iy = stride*y_out - pad + row_slot).
    // ------------------------------------------------------------------
    always @(*) begin
        iy_i = (STRIDE * y_out) + row_slot - PAD;
    end
    always @(*) begin
        row_in_bounds = (iy_i >= 0) && (iy_i < $signed({8'd0, in_h_r}));
    end

    // ------------------------------------------------------------------
    // Window assembly (combinational, from the fully-populated row
    // buffers). Column padding is applied here; row padding was already
    // baked into rowbuf during fetch.
    // ------------------------------------------------------------------
    wire signed [13:0] ix0 = (STRIDE * x_out) + 12'd0 - PAD; // j=0
    wire signed [13:0] ix1 = (STRIDE * x_out) + 12'd1 - PAD; // j=1
    wire signed [13:0] ix2 = (STRIDE * x_out) + 12'd2 - PAD; // j=2
    wire signed [13:0] in_w_s = $signed({2'd0, in_w_r});

    wire ix0_ok = (ix0 >= 0) && (ix0 < in_w_s);
    wire ix1_ok = (ix1 >= 0) && (ix1 < in_w_s);
    wire ix2_ok = (ix2 >= 0) && (ix2 < in_w_s);

    wire [7:0] t00 = ix0_ok ? rowbuf0[ix0[7:0]] : 8'd0;
    wire [7:0] t01 = ix1_ok ? rowbuf0[ix1[7:0]] : 8'd0;
    wire [7:0] t02 = ix2_ok ? rowbuf0[ix2[7:0]] : 8'd0;
    wire [7:0] t10 = ix0_ok ? rowbuf1[ix0[7:0]] : 8'd0;
    wire [7:0] t11 = ix1_ok ? rowbuf1[ix1[7:0]] : 8'd0;
    wire [7:0] t12 = ix2_ok ? rowbuf1[ix2[7:0]] : 8'd0;
    wire [7:0] t20 = ix0_ok ? rowbuf2[ix0[7:0]] : 8'd0;
    wire [7:0] t21 = ix1_ok ? rowbuf2[ix1[7:0]] : 8'd0;
    wire [7:0] t22 = ix2_ok ? rowbuf2[ix2[7:0]] : 8'd0;

    wire [71:0] win_flat_comb = {t00, t01, t02, t10, t11, t12, t20, t21, t22};

endmodule
