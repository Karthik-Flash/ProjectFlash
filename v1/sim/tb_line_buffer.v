// tb_line_buffer.v -- Project FLASH V1, line_buffer_v1.v testbench (iverilog-only).
//
// Drives line_buffer_v1 with the real conv1 layer word (28x28, 1 channel) and
// the real img_0.mem pixels, and checks all 196 emitted 3x3 windows against a
// reference computed directly in this testbench (not from a trace file -- the
// input is already fully known, per the task brief).
`include "layer_table.vh"

module tb_line_buffer;

    reg clk, rst, start;
    reg [`LT_WORD_W-1:0] layer_word;
    wire [17:0] fm_rd_addr;
    reg  [7:0]  fm_rd_data;
    wire [71:0] win_flat;
    wire [11:0] win_y, win_x, win_c;
    wire        win_valid, done;

    line_buffer_v1 dut (
        .clk(clk), .rst(rst), .start(start), .layer_word(layer_word),
        .fm_rd_addr(fm_rd_addr), .fm_rd_data(fm_rd_data),
        .win_flat(win_flat), .win_y(win_y), .win_x(win_x), .win_c(win_c),
        .win_valid(win_valid), .done(done)
    );

    initial clk = 1'b0;
    always #5 clk = ~clk;

    reg [7:0]            input_ram      [0:783];
    reg [`LT_WORD_W-1:0] layer_table_rom[0:6];

    // 2-cycle latency BRAM stub, same convention as conv_engine's testbench.
    reg [17:0] addr_q1;
    reg [7:0]  data_q2;
    always @(posedge clk) begin
        addr_q1 <= fm_rd_addr;
        data_q2 <= input_ram[addr_q1];
    end
    always @(*) fm_rd_data = data_q2;

    // ---- reference model, computed directly from input_ram: 28x28, one
    // pixel zero pad, stride 2 -> 14x14 = 196 output windows ----
    function [7:0] ref_pixel;
        input integer iy, ix;
        begin
            if (iy < 0 || iy >= 28 || ix < 0 || ix >= 28)
                ref_pixel = 8'd0;
            else
                ref_pixel = input_ram[iy * 28 + ix];
        end
    endfunction

    // TOOLCHAIN NOTE: this iverilog only supports 1D memory arrays, so both
    // reference and captured windows are flattened: index = win_idx*9 + tap.
    reg [7:0] exp_win [0:1763]; // 196 windows * 9 taps
    integer   gy, gx, gi, gj, gidx;

    // ---- capture of every emitted window, indexed by (y*14+x) ----
    reg [7:0] cap_win     [0:1763];
    integer   cap_written [0:195];

    wire [11:0] cap_idx = win_y * 12'd14 + win_x;
    always @(posedge clk) begin
        if (win_valid) begin
            cap_win[cap_idx * 9 + 0] <= win_flat[71:64];
            cap_win[cap_idx * 9 + 1] <= win_flat[63:56];
            cap_win[cap_idx * 9 + 2] <= win_flat[55:48];
            cap_win[cap_idx * 9 + 3] <= win_flat[47:40];
            cap_win[cap_idx * 9 + 4] <= win_flat[39:32];
            cap_win[cap_idx * 9 + 5] <= win_flat[31:24];
            cap_win[cap_idx * 9 + 6] <= win_flat[23:16];
            cap_win[cap_idx * 9 + 7] <= win_flat[15:8];
            cap_win[cap_idx * 9 + 8] <= win_flat[7:0];
            cap_written[cap_idx] <= 1;
        end
    end

    integer m, k, n_ok, n_mismatch, printed;
    reg any_mismatch_this_window;
    initial begin
        rst = 1'b1; start = 1'b0; layer_word = {`LT_WORD_W{1'b0}};
        for (m = 0; m < 196; m = m + 1) cap_written[m] = 0;

        $readmemh("../mem/v1_1/flash_v1_1/vectors/img_0.mem", input_ram);
        $readmemh("../mem/v1_1/flash_v1_1/layer_table.mem", layer_table_rom);

        for (gy = 0; gy < 14; gy = gy + 1) begin
            for (gx = 0; gx < 14; gx = gx + 1) begin
                gidx = gy * 14 + gx;
                for (gi = 0; gi < 3; gi = gi + 1) begin
                    for (gj = 0; gj < 3; gj = gj + 1) begin
                        exp_win[gidx * 9 + gi * 3 + gj] = ref_pixel(2 * gy - 1 + gi, 2 * gx - 1 + gj);
                    end
                end
            end
        end

        repeat (4) @(posedge clk);
        rst = 1'b0;
        @(posedge clk);

        layer_word = layer_table_rom[0]; // conv1: in_c=1, in_h=in_w=28, out_h=out_w=14
        start = 1'b1;
        @(posedge clk);
        start = 1'b0;

        wait (done);
        @(posedge clk);

        n_ok = 0; n_mismatch = 0; printed = 0;
        for (m = 0; m < 196; m = m + 1) begin
            any_mismatch_this_window = 1'b0;
            if (!cap_written[m]) begin
                any_mismatch_this_window = 1'b1;
            end else begin
                for (k = 0; k < 9; k = k + 1)
                    if (cap_win[m * 9 + k] !== exp_win[m * 9 + k]) any_mismatch_this_window = 1'b1;
            end
            if (any_mismatch_this_window) begin
                n_mismatch = n_mismatch + 1;
                if (printed < 5) begin
                    $display("WINDOW MISMATCH (y=%0d x=%0d)%s", m / 14, m % 14,
                              cap_written[m] ? "" : "  (never emitted!)");
                    for (k = 0; k < 9; k = k + 1)
                        $display("   tap %0d: got=%0d expected=%0d", k, cap_win[m * 9 + k], exp_win[m * 9 + k]);
                    printed = printed + 1;
                end
            end else begin
                n_ok = n_ok + 1;
            end
        end

        $display("LINE_BUFFER conv1: %0d / 196 windows exact  ( %0d mismatches )", n_ok, n_mismatch);
        if (n_mismatch == 0) $display("RESULT: PASS");
        else                 $display("RESULT: FAIL");
        $finish;
    end

    initial begin
        #2000000;
        $display("RESULT: FAIL  (timeout -- line_buffer_v1 never asserted done)");
        $finish;
    end

endmodule
