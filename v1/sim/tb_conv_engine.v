// tb_conv_engine.v -- Project FLASH V1, conv_engine.v testbench (iverilog-only).
//
// Drives conv_engine with the REAL conv1 layer word decoded straight from
// v1/mem/v1_1/flash_v1_1/layer_table.mem, the real trained weights/bias, and
// the real image 0 test vector, then checks every one of the 1568 conv1
// outputs -- both the raw 22-bit accumulator and the shifted/clamped uint8 --
// bit-exact against the golden model's own trace files. Nothing here is
// synthesizable; it exists purely to pin down conv_engine's correctness.
`include "layer_table.vh"

module tb_conv_engine;

    reg clk, rst, start;
    reg [`LT_WORD_W-1:0] layer_word;
    wire done;

    wire [19:0]        w_rd_addr;
    reg  signed [7:0]  w_rd_data;
    wire [9:0]         b_rd_addr;
    reg  signed [31:0] b_rd_data;
    wire [17:0]        fm_rd_addr;
    reg  [7:0]         fm_rd_data;
    wire [17:0]        fm_wr_addr;
    wire [7:0]         fm_wr_data;
    wire               fm_wr_en;
    wire               dbg_acc_valid;
    wire signed [21:0] dbg_acc_value;
    wire [17:0]        dbg_acc_idx;

    conv_engine dut (
        .clk(clk), .rst(rst), .start(start), .layer_word(layer_word), .done(done),
        .w_rd_addr(w_rd_addr), .w_rd_data(w_rd_data),
        .b_rd_addr(b_rd_addr), .b_rd_data(b_rd_data),
        .fm_rd_addr(fm_rd_addr), .fm_rd_data(fm_rd_data),
        .fm_wr_addr(fm_wr_addr), .fm_wr_data(fm_wr_data), .fm_wr_en(fm_wr_en),
        .dbg_acc_valid(dbg_acc_valid), .dbg_acc_value(dbg_acc_value), .dbg_acc_idx(dbg_acc_idx)
    );

    initial clk = 1'b0;
    always #5 clk = ~clk;

    // ------------------------------------------------------------------
    // Backing memories, loaded verbatim from the audited V1.1 export.
    // ------------------------------------------------------------------
    reg [7:0]   weight_rom      [0:47431];
    reg [31:0]  bias_rom        [0:169];
    reg [`LT_WORD_W-1:0] layer_table_rom [0:6];
    reg [7:0]   input_ram       [0:783];   // img_0.mem, 28*28 uint8

    reg [31:0]  expected_acc    [0:1567];  // img0_conv1_acc.mem, int32
    reg [7:0]   expected_out    [0:1567];  // img0_conv1.mem, uint8

    // ------------------------------------------------------------------
    // BRAM stubs. LATENCY: addr -> data is 2 cycles at every one of these
    // (address reg + BRAM output reg), matching what conv_engine.v expects
    // at w_rd_addr/b_rd_addr/fm_rd_addr.
    // ------------------------------------------------------------------
    reg [19:0]        w_addr_q1;
    reg signed [7:0]  w_data_q2;
    reg [9:0]         b_addr_q1;
    reg signed [31:0] b_data_q2;
    reg [17:0]        fm_addr_q1;
    reg [7:0]         fm_data_q2;

    always @(posedge clk) begin
        w_addr_q1  <= w_rd_addr;
        w_data_q2  <= weight_rom[w_addr_q1];
        b_addr_q1  <= b_rd_addr;
        b_data_q2  <= bias_rom[b_addr_q1];
        fm_addr_q1 <= fm_rd_addr;
        fm_data_q2 <= input_ram[fm_addr_q1];
    end
    always @(*) begin
        w_rd_data  = w_data_q2;
        b_rd_data  = b_data_q2;
        fm_rd_data = fm_data_q2;
    end

    // ------------------------------------------------------------------
    // Capture every value conv_engine writes, indexed by its own out_idx
    // (= o*out_h*out_w + y*out_w + x), which is the same channel-major
    // flat ordering the golden model uses for its trace dumps.
    // ------------------------------------------------------------------
    reg [7:0]          captured_out [0:1567];
    reg signed [31:0]  captured_acc [0:1567];
    integer             out_written [0:1567];
    integer             acc_written [0:1567];

    integer init_i;
    initial begin
        for (init_i = 0; init_i < 1568; init_i = init_i + 1) begin
            out_written[init_i] = 0;
            acc_written[init_i] = 0;
        end
    end

    always @(posedge clk) begin
        if (fm_wr_en) begin
            captured_out[fm_wr_addr] <= fm_wr_data;
            out_written[fm_wr_addr]  <= 1;
        end
        if (dbg_acc_valid) begin
            captured_acc[dbg_acc_idx] <= dbg_acc_value; // signed 22 -> signed 32, auto sign-extended
            acc_written[dbg_acc_idx]  <= 1;
        end
    end

    // ------------------------------------------------------------------
    // Stimulus: reset, load memories, run conv1 on image 0 once, check.
    // ------------------------------------------------------------------
    task report_results;
        integer m, n_acc_ok, n_out_ok, n_acc_mismatch, n_out_mismatch, printed_acc, printed_out;
        integer o_i, y_i, x_i, rem;
        reg signed [31:0] exp32, got32;
        begin
            n_acc_ok = 0; n_out_ok = 0; n_acc_mismatch = 0; n_out_mismatch = 0;
            printed_acc = 0; printed_out = 0;

            for (m = 0; m < 1568; m = m + 1) begin
                exp32 = $signed(expected_acc[m]);
                got32 = captured_acc[m];
                if (acc_written[m] && (got32 == exp32)) begin
                    n_acc_ok = n_acc_ok + 1;
                end else begin
                    n_acc_mismatch = n_acc_mismatch + 1;
                    if (printed_acc < 5) begin
                        o_i = m / (14*14); rem = m % (14*14); y_i = rem / 14; x_i = rem % 14;
                        $display("ACC (o=%0d y=%0d x=%0d)   got=%0d   expected=%0d%s",
                                 o_i, y_i, x_i, got32, exp32,
                                 acc_written[m] ? "" : "   (index never written by conv_engine!)");
                        printed_acc = printed_acc + 1;
                    end
                end

                if (out_written[m] && (captured_out[m] == expected_out[m])) begin
                    n_out_ok = n_out_ok + 1;
                end else begin
                    n_out_mismatch = n_out_mismatch + 1;
                    if (printed_out < 5) begin
                        o_i = m / (14*14); rem = m % (14*14); y_i = rem / 14; x_i = rem % 14;
                        $display("OUT (o=%0d y=%0d x=%0d)   got=%0d   expected=%0d%s",
                                 o_i, y_i, x_i, captured_out[m], expected_out[m],
                                 out_written[m] ? "" : "   (index never written by conv_engine!)");
                        printed_out = printed_out + 1;
                    end
                end
            end

            $display("CONV1 ACC:  %0d / 1568 exact  ( %0d mismatches )", n_acc_ok, n_acc_mismatch);
            $display("CONV1 OUT:  %0d / 1568 exact  ( %0d mismatches )", n_out_ok, n_out_mismatch);
            if ((n_acc_mismatch == 0) && (n_out_mismatch == 0))
                $display("RESULT: PASS");
            else
                $display("RESULT: FAIL");
        end
    endtask

    initial begin
        rst = 1'b1; start = 1'b0; layer_word = {`LT_WORD_W{1'b0}};

        $readmemh("../mem/v1_1/flash_v1_1/weights.mem", weight_rom);
        $readmemh("../mem/v1_1/flash_v1_1/bias.mem", bias_rom);
        $readmemh("../mem/v1_1/flash_v1_1/layer_table.mem", layer_table_rom);
        $readmemh("../mem/v1_1/flash_v1_1/vectors/img_0.mem", input_ram);
        $readmemh("../mem/v1_1/flash_v1_1/vectors/trace/img0_conv1_acc.mem", expected_acc);
        $readmemh("../mem/v1_1/flash_v1_1/vectors/trace/img0_conv1.mem", expected_out);

        repeat (4) @(posedge clk);
        rst = 1'b0;
        @(posedge clk);

        layer_word = layer_table_rom[0]; // record 0 = conv1
        start = 1'b1;
        @(posedge clk);
        start = 1'b0;

        wait (done);
        @(posedge clk);

        report_results;
        $finish;
    end

    // Safety net: fail loudly instead of hanging forever if `done` never comes.
    initial begin
        #2000000;
        $display("RESULT: FAIL  (timeout -- conv_engine never asserted done)");
        $finish;
    end

endmodule
