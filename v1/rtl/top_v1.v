// top_v1.v -- Project FLASH V1, top level.
//
// layer_seq + conv_engine + 2x fmap_ram (A/B ping-pong) + gap_unit + fc_unit
// + decision, plus the on-chip weight and bias ROMs.
//
// Usage: stream the input image in on pixel_in/pixel_valid (one uint8 per
// cycle, row-major, in_c-major -- 784 bytes for V1.1), optionally write the
// decision threshold via threshold_wr/threshold_wr_en, then pulse `start`.
// result_valid rises when the last layer has retired, with logit0/logit1/
// margin/positive valid alongside it.
//
// LATENCY MATCHING (the thing most likely to break if this is ever
// re-plumbed): conv_engine.v and fc_unit.v were both written against a
// 2-cycle read latency at every memory port (address reg + BRAM output
// reg), but fmap_ram.v is a 1-cycle synchronous read. top_v1 therefore
// inserts ONE extra register stage on the feature-map read data before it
// reaches conv_engine, making that path 2 cycles end to end. The weight and
// bias ROMs below are built with two register stages for the same reason.
// gap_unit, by contrast, consumes the 1-cycle fmap_ram data directly, so
// layer_seq's stream valid/channel tag are delayed by exactly one cycle to
// meet it. Get any of these wrong and the arithmetic silently reads the
// neighbouring pixel -- the v0 lesson, restated.
//
// NOTE ON line_buffer_v1.v: it is NOT instantiated here. conv_engine.v is
// frozen for this session and does its own per-tap addressing against a
// plain byte-addressable feature map, so it has no port that can consume
// line_buffer_v1's 9-tap parallel window bus. Wiring the two together would
// require changing conv_engine's interface, which this session's brief
// explicitly forbids. line_buffer_v1 is built and independently verified
// (see tb_line_buffer.v) and is ready for a future conv_engine revision
// that takes a windowed input.
`include "layer_table.vh"

module top_v1 #(
    parameter WEIGHTS_FILE     = "../mem/v1_1/flash_v1_1/weights.mem",
    parameter BIAS_FILE        = "../mem/v1_1/flash_v1_1/bias.mem",
    parameter LAYER_TABLE_FILE = "../mem/v1_1/flash_v1_1/layer_table.mem"
) (
    input  wire               clk,
    input  wire               rst,
    input  wire               start,

    input  wire [7:0]         pixel_in,
    input  wire               pixel_valid,

    input  wire signed [31:0] threshold_wr,
    input  wire               threshold_wr_en,

    output wire signed [31:0] logit0,
    output wire signed [31:0] logit1,
    output wire signed [31:0] margin,
    output wire               positive,
    output wire               result_valid
);

    // ------------------------------------------------------------------
    // Threshold register
    // ------------------------------------------------------------------
    reg signed [31:0] threshold_reg;
    always @(posedge clk) begin
        if (rst)                  threshold_reg <= 32'sd0;
        else if (threshold_wr_en) threshold_reg <= threshold_wr;
    end

    // ------------------------------------------------------------------
    // Input image loader: writes pixel_in sequentially into buffer A, which
    // is what layer 0 (conv1) reads. The counter resets on `start` so the
    // next image can be streamed in for the next run.
    // ------------------------------------------------------------------
    reg [17:0] pixel_addr;
    always @(posedge clk) begin
        if (rst)            pixel_addr <= 18'd0;
        else if (start)     pixel_addr <= 18'd0;
        else if (pixel_valid) pixel_addr <= pixel_addr + 18'd1;
    end

    // ------------------------------------------------------------------
    // Sequencer
    // ------------------------------------------------------------------
    wire [`LT_WORD_W-1:0] layer_word;
    wire [2:0]  layer_idx;
    wire        buf_sel;
    wire        conv_start, gap_start, fc_start;
    wire        conv_done,  gap_done,  fc_done;
    wire [17:0] gap_stream_addr;
    wire        gap_stream_valid;
    wire [11:0] gap_stream_c;
    wire        seq_done;

    layer_seq #(.LAYER_TABLE_FILE(LAYER_TABLE_FILE)) u_seq (
        .clk(clk), .rst(rst), .start(start),
        .layer_word(layer_word), .layer_idx(layer_idx), .buf_sel(buf_sel),
        .conv_start(conv_start), .gap_start(gap_start), .fc_start(fc_start),
        .conv_done(conv_done),   .gap_done(gap_done),   .fc_done(fc_done),
        .gap_stream_addr(gap_stream_addr), .gap_stream_valid(gap_stream_valid),
        .gap_stream_c(gap_stream_c),
        .done(seq_done)
    );

    wire [3:0] cur_op = layer_word[`LT_OP_MSB : `LT_OP_LSB];
    wire       op_is_gap = (cur_op == `LT_OP_GAP);

    // ------------------------------------------------------------------
    // Weight / bias ROMs -- two register stages each, so address -> data is
    // 2 cycles exactly as conv_engine.v and fc_unit.v document.
    // ------------------------------------------------------------------
    reg [7:0]  weight_rom [0:47431];
    reg [31:0] bias_rom   [0:169];
    initial begin
        $readmemh(WEIGHTS_FILE, weight_rom);
        $readmemh(BIAS_FILE, bias_rom);
    end

    wire [19:0] conv_w_addr, fc_w_addr;
    wire [9:0]  conv_b_addr, fc_b_addr;
    wire        fc_active = (cur_op == `LT_OP_FC);

    wire [19:0] w_addr_mux = fc_active ? fc_w_addr : conv_w_addr;
    wire [9:0]  b_addr_mux = fc_active ? fc_b_addr : conv_b_addr;

    reg [19:0] w_addr_q1;
    reg [7:0]  w_data_q2;
    reg [9:0]  b_addr_q1;
    reg [31:0] b_data_q2;
    always @(posedge clk) begin
        w_addr_q1 <= w_addr_mux;               // LATENCY: w addr -> data is 2 cycles
        w_data_q2 <= weight_rom[w_addr_q1];
        b_addr_q1 <= b_addr_mux;               // LATENCY: b addr -> data is 2 cycles
        b_data_q2 <= bias_rom[b_addr_q1];
    end
    wire signed [7:0]  w_rd_data = w_data_q2;
    wire signed [31:0] b_rd_data = b_data_q2;

    // ------------------------------------------------------------------
    // Feature-map ping-pong
    // ------------------------------------------------------------------
    wire [17:0] conv_fm_rd_addr, conv_fm_wr_addr;
    wire [7:0]  conv_fm_wr_data;
    wire        conv_fm_wr_en;

    // read address: conv_engine owns it except during the GAP layer
    wire [17:0] rd_addr_mux = op_is_gap ? gap_stream_addr : conv_fm_rd_addr;

    wire [7:0] ram_a_rd_data, ram_b_rd_data;

    // buf_sel = 0 -> read A, write B ; buf_sel = 1 -> read B, write A
    wire        wr_to_a = buf_sel;
    wire        a_we    = pixel_valid | (wr_to_a & conv_fm_wr_en);
    wire [17:0] a_wr_addr = pixel_valid ? pixel_addr : conv_fm_wr_addr;
    wire [7:0]  a_wr_data = pixel_valid ? pixel_in   : conv_fm_wr_data;
    wire        b_we      = (~wr_to_a) & conv_fm_wr_en;

    fmap_ram u_ram_a (
        .clk(clk), .we(a_we), .wr_addr(a_wr_addr), .wr_data(a_wr_data),
        .rd_addr(rd_addr_mux), .rd_data(ram_a_rd_data)
    );
    fmap_ram u_ram_b (
        .clk(clk), .we(b_we), .wr_addr(conv_fm_wr_addr), .wr_data(conv_fm_wr_data),
        .rd_addr(rd_addr_mux), .rd_data(ram_b_rd_data)
    );

    // fmap_ram is 1-cycle; select the live buffer, then add ONE more
    // register so conv_engine sees the 2-cycle latency it was built for.
    wire [7:0] fm_rd_data_1cyc = buf_sel ? ram_b_rd_data : ram_a_rd_data;
    reg  [7:0] fm_rd_data_2cyc;
    always @(posedge clk) fm_rd_data_2cyc <= fm_rd_data_1cyc;

    // ------------------------------------------------------------------
    // Conv engine
    // ------------------------------------------------------------------
    wire        dbg_acc_valid;
    wire signed [21:0] dbg_acc_value;
    wire [17:0] dbg_acc_idx;

    conv_engine u_conv (
        .clk(clk), .rst(rst), .start(conv_start), .layer_word(layer_word),
        .done(conv_done),
        .w_rd_addr(conv_w_addr), .w_rd_data(w_rd_data),
        .b_rd_addr(conv_b_addr), .b_rd_data(b_rd_data),
        .fm_rd_addr(conv_fm_rd_addr), .fm_rd_data(fm_rd_data_2cyc),
        .fm_wr_addr(conv_fm_wr_addr), .fm_wr_data(conv_fm_wr_data), .fm_wr_en(conv_fm_wr_en),
        .dbg_acc_valid(dbg_acc_valid), .dbg_acc_value(dbg_acc_value), .dbg_acc_idx(dbg_acc_idx)
    );

    // ------------------------------------------------------------------
    // GAP: layer_seq issues the address; fmap_ram answers one cycle later,
    // so the valid/channel tag are delayed by one cycle to match the data.
    // ------------------------------------------------------------------
    reg        gap_in_valid_d1;
    reg [11:0] gap_in_c_d1;
    always @(posedge clk) begin
        gap_in_valid_d1 <= gap_stream_valid;
        gap_in_c_d1     <= gap_stream_c;
    end

    wire [895:0] gap_out_flat;

    gap_unit u_gap (
        .clk(clk), .rst(rst), .start(gap_start), .layer_word(layer_word),
        .in_data(fm_rd_data_1cyc), .in_valid(gap_in_valid_d1), .in_c(gap_in_c_d1),
        .gap_out_flat(gap_out_flat), .done(gap_done)
    );

    // ------------------------------------------------------------------
    // FC: gap_unit gives 14 bits per channel, fc_unit wants 8. The GAP
    // result is mathematically bounded to 0..255 (see gap_unit.v), so the
    // low byte of each channel is the whole value.
    // ------------------------------------------------------------------
    wire [511:0] gap_in_flat;
    genvar gi;
    generate
        for (gi = 0; gi < 64; gi = gi + 1) begin : g_narrow
            assign gap_in_flat[gi * 8 +: 8] = gap_out_flat[gi * 14 +: 8];
        end
    endgenerate

    fc_unit u_fc (
        .clk(clk), .rst(rst), .start(fc_start), .layer_word(layer_word),
        .gap_in_flat(gap_in_flat),
        .w_rd_addr(fc_w_addr), .w_rd_data(w_rd_data),
        .b_rd_addr(fc_b_addr), .b_rd_data(b_rd_data),
        .logit0(logit0), .logit1(logit1), .done(fc_done)
    );

    // ------------------------------------------------------------------
    // Decision
    // ------------------------------------------------------------------
    decision u_dec (
        .logit0(logit0), .logit1(logit1), .threshold(threshold_reg),
        .margin(margin), .positive(positive)
    );

    assign result_valid = seq_done;

endmodule
