// tb_v1.v -- Project FLASH V1, top-level bit-exactness sweep (iverilog-only).
//
// Runs top_v1 over the first 16 exported verification images and checks the
// logits, margin and decision against the golden model's exported vectors.
// For images 0 and 1 it additionally taps every intermediate layer out of
// the feature-map ping-pong (and the GAP register bus) and compares it to
// the golden model's per-layer trace files.
`include "layer_table.vh"

module tb_v1;

    localparam N_IMAGES = 16;
    localparam DEFAULT_THRESHOLD = -32'sd8050; // sim_config.vh, V1.1

    reg clk, rst, start;
    reg [7:0] pixel_in;
    reg pixel_valid;
    reg signed [31:0] threshold_wr;
    reg threshold_wr_en;
    wire signed [31:0] logit0, logit1, margin;
    wire positive, result_valid;

    top_v1 dut (
        .clk(clk), .rst(rst), .start(start),
        .pixel_in(pixel_in), .pixel_valid(pixel_valid),
        .threshold_wr(threshold_wr), .threshold_wr_en(threshold_wr_en),
        .logit0(logit0), .logit1(logit1), .margin(margin),
        .positive(positive), .result_valid(result_valid)
    );

    initial clk = 1'b0;
    always #5 clk = ~clk;

    // ---- expected vectors ----
    reg [7:0]  img        [0:783];
    reg [31:0] exp_l0     [0:243];
    reg [31:0] exp_l1     [0:243];
    reg [31:0] exp_margin [0:243];
    reg [7:0]  exp_dec    [0:243];

    reg [7:0] exp_conv1 [0:1567];
    reg [7:0] exp_conv2 [0:783];
    reg [7:0] exp_conv3 [0:511];
    reg [7:0] exp_conv4 [0:191];
    reg [7:0] exp_conv5 [0:63];
    reg [7:0] exp_gap   [0:63];

    reg [7:0] cap_conv1 [0:1567];
    reg [7:0] cap_conv2 [0:783];
    reg [7:0] cap_conv3 [0:511];
    reg [7:0] cap_conv4 [0:191];
    reg [7:0] cap_conv5 [0:63];
    reg [7:0] cap_gap   [0:63];

    // ---- scoreboard ----
    integer ok_l0, ok_l1, ok_margin, ok_dec, ok_trace;
    integer fail_img, fail_layer;
    reg     have_failure;

    integer i, k, n_bad, printed;

    // ------------------------------------------------------------------
    // Per-layer capture: when layer_seq reaches S_NEXT_LAYER (3'd4) the
    // layer just finished, buf_sel still names its write buffer (it flips
    // in that same state), so the output is readable right here.
    // ------------------------------------------------------------------
    reg capture_en;
    integer c_i;
    always @(posedge clk) begin
        if (capture_en && dut.u_seq.state == 3'd4) begin
            case (dut.u_seq.layer_idx)
                3'd0: for (c_i = 0; c_i < 1568; c_i = c_i + 1)
                          cap_conv1[c_i] = dut.buf_sel ? dut.u_ram_a.mem[c_i] : dut.u_ram_b.mem[c_i];
                3'd1: for (c_i = 0; c_i < 784; c_i = c_i + 1)
                          cap_conv2[c_i] = dut.buf_sel ? dut.u_ram_a.mem[c_i] : dut.u_ram_b.mem[c_i];
                3'd2: for (c_i = 0; c_i < 512; c_i = c_i + 1)
                          cap_conv3[c_i] = dut.buf_sel ? dut.u_ram_a.mem[c_i] : dut.u_ram_b.mem[c_i];
                3'd3: for (c_i = 0; c_i < 192; c_i = c_i + 1)
                          cap_conv4[c_i] = dut.buf_sel ? dut.u_ram_a.mem[c_i] : dut.u_ram_b.mem[c_i];
                3'd4: for (c_i = 0; c_i < 64; c_i = c_i + 1)
                          cap_conv5[c_i] = dut.buf_sel ? dut.u_ram_a.mem[c_i] : dut.u_ram_b.mem[c_i];
                3'd5: for (c_i = 0; c_i < 64; c_i = c_i + 1)
                          cap_gap[c_i] = dut.gap_out_flat[c_i * 14 +: 8];
                default: ;
            endcase
        end
    end

    // ------------------------------------------------------------------
    // Trace comparison for one layer. Reports the first 5 (o,y,x)
    // mismatches, mapped back through the layer's own out_w/out_h.
    // ------------------------------------------------------------------
    task check_layer;
        input integer img_idx;
        input integer layer_no;     // 1..5 = conv, 6 = gap
        input integer n_vals;
        input integer out_h;
        input integer out_w;
        integer j, bad, o_i, y_i, x_i, rem, got, exp;
        begin
            bad = 0; printed = 0;
            for (j = 0; j < n_vals; j = j + 1) begin
                case (layer_no)
                    1: begin got = cap_conv1[j]; exp = exp_conv1[j]; end
                    2: begin got = cap_conv2[j]; exp = exp_conv2[j]; end
                    3: begin got = cap_conv3[j]; exp = exp_conv3[j]; end
                    4: begin got = cap_conv4[j]; exp = exp_conv4[j]; end
                    5: begin got = cap_conv5[j]; exp = exp_conv5[j]; end
                    default: begin got = cap_gap[j]; exp = exp_gap[j]; end
                endcase
                if (got !== exp) begin
                    bad = bad + 1;
                    if (printed < 5) begin
                        o_i = j / (out_h * out_w);
                        rem = j % (out_h * out_w);
                        y_i = rem / out_w;
                        x_i = rem % out_w;
                        $display("    (o=%0d y=%0d x=%0d)   got=%0d   expected=%0d", o_i, y_i, x_i, got, exp);
                        printed = printed + 1;
                    end
                end
            end
            if (bad == 0) begin
                ok_trace = ok_trace + 1;
            end else if (!have_failure) begin
                have_failure = 1'b1;
                fail_img   = img_idx;
                fail_layer = layer_no;
                $display("  FIRST FAILURE: image %0d, layer %0d (%0d mismatches)", img_idx, layer_no, bad);
            end
        end
    endtask

    // ------------------------------------------------------------------
    // Run one image end to end
    // ------------------------------------------------------------------
    task run_image;
        input integer img_idx;
        integer p;
        begin
            // stream the 784 input pixels in
            @(posedge clk);
            for (p = 0; p < 784; p = p + 1) begin
                @(posedge clk);
                pixel_valid <= 1'b1;
                pixel_in    <= img[p];
            end
            @(posedge clk);
            pixel_valid <= 1'b0;

            @(posedge clk);
            start <= 1'b1;
            @(posedge clk);
            start <= 1'b0;

            // result_valid is still high from the PREVIOUS image at this
            // point, so wait for it to drop before waiting for this run's
            // rise -- otherwise the very next line would sample the last
            // image's logits and call them this image's.
            wait (!result_valid);
            wait (result_valid);
            @(posedge clk);
        end
    endtask

    reg signed [31:0] e_l0, e_l1, e_mg;
    reg e_dec;

    initial begin
        rst = 1'b1; start = 1'b0; pixel_valid = 1'b0; pixel_in = 8'd0;
        threshold_wr = 32'sd0; threshold_wr_en = 1'b0;
        capture_en = 1'b0; have_failure = 1'b0;
        ok_l0 = 0; ok_l1 = 0; ok_margin = 0; ok_dec = 0; ok_trace = 0;
        fail_img = -1; fail_layer = -1;

        $readmemh("../mem/v1_1/flash_v1_1/vectors/exp_logit0.mem", exp_l0);
        $readmemh("../mem/v1_1/flash_v1_1/vectors/exp_logit1.mem", exp_l1);
        $readmemh("../mem/v1_1/flash_v1_1/vectors/exp_margin.mem", exp_margin);
        $readmemh("../mem/v1_1/flash_v1_1/vectors/exp_decision.mem", exp_dec);

        repeat (5) @(posedge clk);
        rst = 1'b0;
        @(posedge clk);
        threshold_wr    <= DEFAULT_THRESHOLD;
        threshold_wr_en <= 1'b1;
        @(posedge clk);
        threshold_wr_en <= 1'b0;

        for (k = 0; k < N_IMAGES; k = k + 1) begin
            case (k)
                0:  $readmemh("../mem/v1_1/flash_v1_1/vectors/img_0.mem",  img);
                1:  $readmemh("../mem/v1_1/flash_v1_1/vectors/img_1.mem",  img);
                2:  $readmemh("../mem/v1_1/flash_v1_1/vectors/img_2.mem",  img);
                3:  $readmemh("../mem/v1_1/flash_v1_1/vectors/img_3.mem",  img);
                4:  $readmemh("../mem/v1_1/flash_v1_1/vectors/img_4.mem",  img);
                5:  $readmemh("../mem/v1_1/flash_v1_1/vectors/img_5.mem",  img);
                6:  $readmemh("../mem/v1_1/flash_v1_1/vectors/img_6.mem",  img);
                7:  $readmemh("../mem/v1_1/flash_v1_1/vectors/img_7.mem",  img);
                8:  $readmemh("../mem/v1_1/flash_v1_1/vectors/img_8.mem",  img);
                9:  $readmemh("../mem/v1_1/flash_v1_1/vectors/img_9.mem",  img);
                10: $readmemh("../mem/v1_1/flash_v1_1/vectors/img_10.mem", img);
                11: $readmemh("../mem/v1_1/flash_v1_1/vectors/img_11.mem", img);
                12: $readmemh("../mem/v1_1/flash_v1_1/vectors/img_12.mem", img);
                13: $readmemh("../mem/v1_1/flash_v1_1/vectors/img_13.mem", img);
                14: $readmemh("../mem/v1_1/flash_v1_1/vectors/img_14.mem", img);
                default: $readmemh("../mem/v1_1/flash_v1_1/vectors/img_15.mem", img);
            endcase

            if (k == 0) begin
                $readmemh("../mem/v1_1/flash_v1_1/vectors/trace/img0_conv1.mem", exp_conv1);
                $readmemh("../mem/v1_1/flash_v1_1/vectors/trace/img0_conv2.mem", exp_conv2);
                $readmemh("../mem/v1_1/flash_v1_1/vectors/trace/img0_conv3.mem", exp_conv3);
                $readmemh("../mem/v1_1/flash_v1_1/vectors/trace/img0_conv4.mem", exp_conv4);
                $readmemh("../mem/v1_1/flash_v1_1/vectors/trace/img0_conv5.mem", exp_conv5);
                $readmemh("../mem/v1_1/flash_v1_1/vectors/trace/img0_gap.mem",   exp_gap);
            end else if (k == 1) begin
                $readmemh("../mem/v1_1/flash_v1_1/vectors/trace/img1_conv1.mem", exp_conv1);
                $readmemh("../mem/v1_1/flash_v1_1/vectors/trace/img1_conv2.mem", exp_conv2);
                $readmemh("../mem/v1_1/flash_v1_1/vectors/trace/img1_conv3.mem", exp_conv3);
                $readmemh("../mem/v1_1/flash_v1_1/vectors/trace/img1_conv4.mem", exp_conv4);
                $readmemh("../mem/v1_1/flash_v1_1/vectors/trace/img1_conv5.mem", exp_conv5);
                $readmemh("../mem/v1_1/flash_v1_1/vectors/trace/img1_gap.mem",   exp_gap);
            end

            capture_en = (k < 2);
            run_image(k);

            e_l0 = $signed(exp_l0[k]);
            e_l1 = $signed(exp_l1[k]);
            e_mg = $signed(exp_margin[k]);
            e_dec = exp_dec[k][0];

            if (logit0 === e_l0) ok_l0 = ok_l0 + 1;
            else if (!have_failure) begin
                have_failure = 1'b1; fail_img = k;
                $display("  FIRST FAILURE: image %0d logit0 got=%0d expected=%0d", k, logit0, e_l0);
            end
            if (logit1 === e_l1) ok_l1 = ok_l1 + 1;
            if (margin === e_mg) ok_margin = ok_margin + 1;
            if (positive === e_dec) ok_dec = ok_dec + 1;

            if (k < 2) begin
                check_layer(k, 1, 1568, 14, 14);
                check_layer(k, 2, 784,   7,  7);
                check_layer(k, 3, 512,   4,  4);
                check_layer(k, 4, 192,   2,  2);
                check_layer(k, 5, 64,    1,  1);
                check_layer(k, 6, 64,    1,  1);
            end
        end

        $display("V1 SMOKE SWEEP (%0d images):", N_IMAGES);
        $display("  logit0:    %0d / %0d exact", ok_l0, N_IMAGES);
        $display("  logit1:    %0d / %0d exact", ok_l1, N_IMAGES);
        $display("  margin:    %0d / %0d exact", ok_margin, N_IMAGES);
        $display("  decision:  %0d / %0d exact", ok_dec, N_IMAGES);
        $display("  trace:     %0d / 12 files exact  (conv1..5, gap; images 0 and 1)", ok_trace);
        if (ok_l0 == N_IMAGES && ok_l1 == N_IMAGES && ok_margin == N_IMAGES &&
            ok_dec == N_IMAGES && ok_trace == 12)
            $display("RESULT: PASS");
        else
            $display("RESULT: FAIL");
        $finish;
    end

    initial begin
        #200000000;
        $display("RESULT: FAIL  (timeout)");
        $finish;
    end

endmodule
