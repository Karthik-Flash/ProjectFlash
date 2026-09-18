// tb_gap.v -- Project FLASH V1, gap_unit.v testbench (iverilog-only).
//
// Streams the real conv5 output for image 0 (64 channels, 1x1 each -- V1.1's
// final map is already 1x1) into gap_unit and checks its output against the
// golden model's own img0_gap.mem trace, bit-exact.
//
// Driven with layer_table[5] (the "gap" table entry) rather than conv5's own
// entry (index 4): the gap entry's in_c/in_h/in_w/shift fields are exactly
// what describes gap_unit's job (64 channels of 1x1 input, shift 0 for
// V1.1) -- conv5's own entry carries its own (irrelevant here) conv shift.
`include "layer_table.vh"

module tb_gap;

    reg clk, rst, start;
    reg [`LT_WORD_W-1:0] layer_word;
    reg [7:0]  in_data;
    reg        in_valid;
    reg [11:0] in_c;
    wire [895:0] gap_out_flat;
    wire done;

    gap_unit dut (
        .clk(clk), .rst(rst), .start(start), .layer_word(layer_word),
        .in_data(in_data), .in_valid(in_valid), .in_c(in_c),
        .gap_out_flat(gap_out_flat), .done(done)
    );

    initial clk = 1'b0;
    always #5 clk = ~clk;

    reg [`LT_WORD_W-1:0] layer_table_rom [0:6];
    reg [7:0] conv5_data   [0:63];
    reg [7:0] expected_gap [0:63];

    integer ch, n_ok, n_mismatch;
    reg [13:0] got_val;
    initial begin
        rst = 1'b1; start = 1'b0; layer_word = {`LT_WORD_W{1'b0}};
        in_data = 8'd0; in_valid = 1'b0; in_c = 12'd0;

        $readmemh("../mem/v1_1/flash_v1_1/layer_table.mem", layer_table_rom);
        $readmemh("../mem/v1_1/flash_v1_1/vectors/trace/img0_conv5.mem", conv5_data);
        $readmemh("../mem/v1_1/flash_v1_1/vectors/trace/img0_gap.mem", expected_gap);

        repeat (4) @(posedge clk);
        rst = 1'b0;
        @(posedge clk);

        layer_word = layer_table_rom[5]; // "gap" entry
        start = 1'b1;
        @(posedge clk);
        start = 1'b0;

        // Stimulus driven with NON-BLOCKING assignments. Blocking assignments
        // here would execute in the same timestep as the posedge and race the
        // DUT's own clocked block, which can hand it a mix of the old and new
        // in_c/in_data (verified: that race silently mis-binds samples to the
        // wrong channel). Non-blocking schedules them in the NBA region, so
        // the DUT sees one settled, consistent sample per cycle.
        for (ch = 0; ch < 64; ch = ch + 1) begin
            @(posedge clk);
            in_valid <= 1'b1;
            in_c     <= ch[11:0];
            in_data  <= conv5_data[ch];
        end
        @(posedge clk);
        in_valid <= 1'b0;

        wait (done);
        @(posedge clk);

        n_ok = 0; n_mismatch = 0;
        for (ch = 0; ch < 64; ch = ch + 1) begin
            got_val = gap_out_flat[ch * 14 +: 14];
            if (got_val === {6'd0, expected_gap[ch]}) begin
                n_ok = n_ok + 1;
            end else begin
                n_mismatch = n_mismatch + 1;
                if (n_mismatch <= 5)
                    $display("GAP MISMATCH ch=%0d   got=%0d   expected=%0d", ch, got_val, expected_gap[ch]);
            end
        end

        $display("GAP: %0d / 64 exact  ( %0d mismatches )", n_ok, n_mismatch);
        if (n_mismatch == 0) $display("RESULT: PASS");
        else                 $display("RESULT: FAIL");
        $finish;
    end

    initial begin
        #2000000;
        $display("RESULT: FAIL  (timeout -- gap_unit never asserted done)");
        $finish;
    end

endmodule
