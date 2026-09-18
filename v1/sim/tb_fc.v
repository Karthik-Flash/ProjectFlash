// tb_fc.v -- Project FLASH V1, fc_unit.v testbench (iverilog-only).
//
// Builds the GAP vector for image 0 from the golden model's img0_conv5.mem
// trace (V1.1's final map is 1x1 and s_gap=0, so gap[c] == conv5[c]), drives
// fc_unit with the real fc layer word (layer_table[6]) against the real
// weight/bias ROMs, and checks both logits against the exported
// exp_logit0.mem[0] / exp_logit1.mem[0].
`include "layer_table.vh"

module tb_fc;

    reg clk, rst, start;
    reg [`LT_WORD_W-1:0] layer_word;
    reg [511:0] gap_in_flat;
    wire [19:0] w_rd_addr;
    reg  signed [7:0]  w_rd_data;
    wire [9:0]  b_rd_addr;
    reg  signed [31:0] b_rd_data;
    wire signed [31:0] logit0, logit1;
    wire done;

    fc_unit dut (
        .clk(clk), .rst(rst), .start(start), .layer_word(layer_word),
        .gap_in_flat(gap_in_flat),
        .w_rd_addr(w_rd_addr), .w_rd_data(w_rd_data),
        .b_rd_addr(b_rd_addr), .b_rd_data(b_rd_data),
        .logit0(logit0), .logit1(logit1), .done(done)
    );

    initial clk = 1'b0;
    always #5 clk = ~clk;

    reg [7:0]  weight_rom [0:47431];
    reg [31:0] bias_rom   [0:169];
    reg [`LT_WORD_W-1:0] layer_table_rom [0:6];
    reg [7:0]  conv5_data [0:63];
    reg [31:0] exp_l0 [0:243];
    reg [31:0] exp_l1 [0:243];

    // 2-cycle latency ROM stubs (address reg + output reg), matching the
    // LATENCY comments on fc_unit's ROM ports.
    reg [19:0] w_addr_q1;
    reg signed [7:0] w_data_q2;
    reg [9:0]  b_addr_q1;
    reg signed [31:0] b_data_q2;
    always @(posedge clk) begin
        w_addr_q1 <= w_rd_addr;
        w_data_q2 <= weight_rom[w_addr_q1];
        b_addr_q1 <= b_rd_addr;
        b_data_q2 <= bias_rom[b_addr_q1];
    end
    always @(*) begin
        w_rd_data = w_data_q2;
        b_rd_data = b_data_q2;
    end

    integer ch;
    reg signed [31:0] e0, e1;
    initial begin
        rst = 1'b1; start = 1'b0;
        layer_word = {`LT_WORD_W{1'b0}};
        gap_in_flat = {512{1'b0}};

        $readmemh("../mem/v1_1/flash_v1_1/weights.mem", weight_rom);
        $readmemh("../mem/v1_1/flash_v1_1/bias.mem", bias_rom);
        $readmemh("../mem/v1_1/flash_v1_1/layer_table.mem", layer_table_rom);
        $readmemh("../mem/v1_1/flash_v1_1/vectors/trace/img0_conv5.mem", conv5_data);
        $readmemh("../mem/v1_1/flash_v1_1/vectors/exp_logit0.mem", exp_l0);
        $readmemh("../mem/v1_1/flash_v1_1/vectors/exp_logit1.mem", exp_l1);

        // GAP for V1.1 = conv5 value >> s_gap(=0), i.e. the conv5 value itself.
        for (ch = 0; ch < 64; ch = ch + 1) begin
            gap_in_flat[ch * 8 +: 8] = conv5_data[ch];
        end

        repeat (4) @(posedge clk);
        rst = 1'b0;
        @(posedge clk);

        layer_word = layer_table_rom[6]; // fc entry
        start = 1'b1;
        @(posedge clk);
        start = 1'b0;

        wait (done);
        @(posedge clk);

        e0 = $signed(exp_l0[0]);
        e1 = $signed(exp_l1[0]);
        $display("FC img_0: got (l0=%0d, l1=%0d) expected (l0=%0d, l1=%0d)", logit0, logit1, e0, e1);
        if ((logit0 === e0) && (logit1 === e1)) $display("RESULT: PASS");
        else                                    $display("RESULT: FAIL");
        $finish;
    end

    initial begin
        #2000000;
        $display("RESULT: FAIL  (timeout -- fc_unit never asserted done)");
        $finish;
    end

endmodule
