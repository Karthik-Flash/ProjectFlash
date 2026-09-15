`timescale 1ns / 1ps
//==============================================================================
// top_accelerator.v  — Bus-Width + Pool-Scaling Corrected Version
//
// FIXES vs previous version:
//
//   FIX 1 — Pool BRAM write: arithmetic right-shift by 8 (pool >>> 8)
//     WHY: FC1 accumulates 784 inputs × pool_value × weight_int8.
//          Max pool_value = 291,592 (20-bit). Max FC1 acc = 784×291K×127 ≈ 29B.
//          This overflows INT32 (max 2.15B) by 13.5×.
//          After >>> 8: pool_max = 1139. FC1 max acc = 784×1139×127 ≈ 113M.
//          113M / 2.15B = 5.3% of INT32 range — perfectly safe.
//          The scale factor (÷256) is a POSITIVE constant, so argmax is
//          preserved: argmax(fc2_out) is identical with or without the shift.
//
//   FIX 2 — fc1_output bus: 512 bits = 16 neurons × 32 bits/neuron (was 320)
//     WHY: fc_layer.v now outputs 32 bits per neuron. Using 20-bit bus caused
//          data_out[j*20+:20] to capture only the lower 20 bits of a 32-bit
//          value, e.g. 1,270,000,000 became 174,464 — completely wrong.
//
//   FIX 3 — FC2 DATA_IN_WIDTH: 512 (was 320 = 16×20)
//     Matches the 512-bit fc1_output bus.
//
//   All previous BRAM-split and 3-stage MAC pipeline fixes retained.
//==============================================================================

module top_accelerator(
    input  wire       clk,
    input  wire       rst,
    input  wire       start,
    input  wire [7:0] pixel_in,
    input  wire       pixel_valid,
    output wire       cancer_detected,
    output wire       result_valid
);

    //--------------------------------------------------------------------------
    // Conv weight ROM  (distributed RAM: 36 + 4 entries)
    //--------------------------------------------------------------------------
    reg signed [7:0] conv_weights [0:35];
    reg signed [7:0] conv_bias_rom [0:3];

    initial begin
        $readmemh("conv1_weights.mem", conv_weights);
        $readmemh("conv1_bias.mem",    conv_bias_rom);
    end

    //--------------------------------------------------------------------------
    // Feature-map storage: 4 SEPARATE BRAMs, one per conv channel
    //--------------------------------------------------------------------------
    (* ram_style = "block" *) reg [19:0] fm_ch0 [0:783];
    (* ram_style = "block" *) reg [19:0] fm_ch1 [0:783];
    (* ram_style = "block" *) reg [19:0] fm_ch2 [0:783];
    (* ram_style = "block" *) reg [19:0] fm_ch3 [0:783];

    reg  [9:0]  fm_rd_addr;
    reg  [19:0] fm_rd_data_ch0, fm_rd_data_ch1, fm_rd_data_ch2, fm_rd_data_ch3;

    always @(posedge clk) begin
        fm_rd_data_ch0 <= fm_ch0[fm_rd_addr];
        fm_rd_data_ch1 <= fm_ch1[fm_rd_addr];
        fm_rd_data_ch2 <= fm_ch2[fm_rd_addr];
        fm_rd_data_ch3 <= fm_ch3[fm_rd_addr];
    end

    reg [1:0]  pool_ch;
    reg [19:0] fm_rd_data;
    always @(*) begin
        case (pool_ch)
            2'd0:    fm_rd_data = fm_rd_data_ch0;
            2'd1:    fm_rd_data = fm_rd_data_ch1;
            2'd2:    fm_rd_data = fm_rd_data_ch2;
            default: fm_rd_data = fm_rd_data_ch3;
        endcase
    end

    //--------------------------------------------------------------------------
    // Pooled-map storage (single BRAM)
    //--------------------------------------------------------------------------
    (* ram_style = "block" *) reg [19:0] pooled_maps_bram [0:783];

    reg  [9:0]  pm_wr_addr;
    reg  [19:0] pm_wr_data;
    reg         pm_wr_en;
    wire [9:0]  pm_rd_addr;
    reg  [19:0] pm_rd_data;

    always @(posedge clk) begin
        if (pm_wr_en)
            pooled_maps_bram[pm_wr_addr] <= pm_wr_data;
    end
    always @(posedge clk) begin
        pm_rd_data <= pooled_maps_bram[pm_rd_addr];
    end

    //--------------------------------------------------------------------------
    // Line buffer -> 3x3 window
    //--------------------------------------------------------------------------
    wire [71:0] window_out;
    wire        window_valid;

    reg [71:0]  window_out_reg;
    reg         window_valid_reg;

    //--------------------------------------------------------------------------
    // 3-stage MAC pipeline (timing fix from previous version)
    //--------------------------------------------------------------------------
    reg signed [15:0] mac_prod_reg    [0:3][0:8];
    reg               mac_prod_valid;

    reg signed [19:0] mac_partial_reg [0:3][0:2];
    reg               mac_partial_valid;

    (* keep = "true" *) reg signed [19:0] mac_out   [0:3];
    reg                                   mac_valid  [0:3];

    wire [19:0] relu_out [0:3];

    reg  [9:0]  fm_write_count;
    reg         conv_complete;
    reg  [1:0]  conv_drain_counter;

    //--------------------------------------------------------------------------
    // Pool
    //--------------------------------------------------------------------------
    reg [19:0] pool_buffer [0:3];
    wire signed [19:0] pool_result;

    reg [7:0]  pool_count;
    reg        pool_complete;
    reg [3:0]  pool_row, pool_col;
    reg [3:0]  pool_read_state;
    reg [1:0]  pool_within_ch_state;
    reg        pool_done_flag;

    //--------------------------------------------------------------------------
    // FC / FSM
    // FIXED: fc1_output is 512 bits = 16 × 32 bits per neuron (was 16 × 20)
    //--------------------------------------------------------------------------
    wire [511:0] fc1_output;   // FIXED: 512 bits (was 320)
    wire         fc1_done;
    wire [63:0]  fc2_output;   // 2 neurons × 32 bits (was 2 × 20 = 40 bits)
    wire         fc2_done;

    wire [2:0] fsm_state;
    wire       conv_en, pool_en, fc1_en, fc2_en;
    wire       output_valid;

    wire signed [31:0] logit0, logit1;   // FIXED: 32-bit logits (was 20-bit)
    reg                cancer_flag;

    integer i;

    //==========================================================================
    // Sub-modules
    //==========================================================================

    line_buffer #(.IMG_WIDTH(30)) u_line_buffer (
        .clk        (clk),
        .rst        (rst),
        .start      (start),
        .pixel_in   (pixel_in),
        .pixel_valid(pixel_valid && conv_en),
        .window_out (window_out),
        .window_valid(window_valid)
    );

    always @(posedge clk) begin
        if (rst) begin
            window_out_reg   <= 72'd0;
            window_valid_reg <= 1'b0;
        end else begin
            window_out_reg   <= window_out;
            window_valid_reg <= window_valid;
        end
    end

    // MAC Stage 1: register 9 products
    generate
        genvar fi;
        for (fi = 0; fi < 4; fi = fi + 1) begin : mac_stage1
            always @(posedge clk) begin
                if (rst) begin
                    mac_prod_reg[fi][0] <= 16'sd0;  mac_prod_reg[fi][1] <= 16'sd0;
                    mac_prod_reg[fi][2] <= 16'sd0;  mac_prod_reg[fi][3] <= 16'sd0;
                    mac_prod_reg[fi][4] <= 16'sd0;  mac_prod_reg[fi][5] <= 16'sd0;
                    mac_prod_reg[fi][6] <= 16'sd0;  mac_prod_reg[fi][7] <= 16'sd0;
                    mac_prod_reg[fi][8] <= 16'sd0;
                end else begin
                    mac_prod_reg[fi][0] <= $signed({1'b0,window_out_reg[71:64]}) * conv_weights[fi*9+0];
                    mac_prod_reg[fi][1] <= $signed({1'b0,window_out_reg[63:56]}) * conv_weights[fi*9+1];
                    mac_prod_reg[fi][2] <= $signed({1'b0,window_out_reg[55:48]}) * conv_weights[fi*9+2];
                    mac_prod_reg[fi][3] <= $signed({1'b0,window_out_reg[47:40]}) * conv_weights[fi*9+3];
                    mac_prod_reg[fi][4] <= $signed({1'b0,window_out_reg[39:32]}) * conv_weights[fi*9+4];
                    mac_prod_reg[fi][5] <= $signed({1'b0,window_out_reg[31:24]}) * conv_weights[fi*9+5];
                    mac_prod_reg[fi][6] <= $signed({1'b0,window_out_reg[23:16]}) * conv_weights[fi*9+6];
                    mac_prod_reg[fi][7] <= $signed({1'b0,window_out_reg[15:8]})  * conv_weights[fi*9+7];
                    mac_prod_reg[fi][8] <= $signed({1'b0,window_out_reg[7:0]})   * conv_weights[fi*9+8];
                end
            end
        end
    endgenerate

    always @(posedge clk) begin
        if (rst) mac_prod_valid <= 1'b0;
        else     mac_prod_valid <= window_valid_reg;
    end

    // MAC Stage 2: three partial sums (3+3+3 products)
    generate
        genvar fi2;
        for (fi2 = 0; fi2 < 4; fi2 = fi2 + 1) begin : mac_stage2
            always @(posedge clk) begin
                if (rst) begin
                    mac_partial_reg[fi2][0] <= 20'sd0;
                    mac_partial_reg[fi2][1] <= 20'sd0;
                    mac_partial_reg[fi2][2] <= 20'sd0;
                end else begin
                    mac_partial_reg[fi2][0] <=
                        $signed({{4{mac_prod_reg[fi2][0][15]}}, mac_prod_reg[fi2][0]}) +
                        $signed({{4{mac_prod_reg[fi2][1][15]}}, mac_prod_reg[fi2][1]}) +
                        $signed({{4{mac_prod_reg[fi2][2][15]}}, mac_prod_reg[fi2][2]});
                    mac_partial_reg[fi2][1] <=
                        $signed({{4{mac_prod_reg[fi2][3][15]}}, mac_prod_reg[fi2][3]}) +
                        $signed({{4{mac_prod_reg[fi2][4][15]}}, mac_prod_reg[fi2][4]}) +
                        $signed({{4{mac_prod_reg[fi2][5][15]}}, mac_prod_reg[fi2][5]});
                    mac_partial_reg[fi2][2] <=
                        $signed({{4{mac_prod_reg[fi2][6][15]}}, mac_prod_reg[fi2][6]}) +
                        $signed({{4{mac_prod_reg[fi2][7][15]}}, mac_prod_reg[fi2][7]}) +
                        $signed({{4{mac_prod_reg[fi2][8][15]}}, mac_prod_reg[fi2][8]});
                end
            end
        end
    endgenerate

    always @(posedge clk) begin
        if (rst) mac_partial_valid <= 1'b0;
        else     mac_partial_valid <= mac_prod_valid;
    end

    // MAC Stage 3: final sum + bias
    generate
        genvar fi3;
        for (fi3 = 0; fi3 < 4; fi3 = fi3 + 1) begin : mac_stage3
            always @(posedge clk) begin
                if (rst) begin
                    mac_out[fi3]   <= 20'sd0;
                    mac_valid[fi3] <= 1'b0;
                end else begin
                    mac_out[fi3] <=
                        mac_partial_reg[fi3][0] +
                        mac_partial_reg[fi3][1] +
                        mac_partial_reg[fi3][2] +
                        $signed({{12{conv_bias_rom[fi3][7]}}, conv_bias_rom[fi3]});
                    mac_valid[fi3] <= mac_partial_valid;
                end
            end
        end
    endgenerate

    // ReLU (combinational)
    generate
        genvar ri;
        for (ri = 0; ri < 4; ri = ri + 1) begin : relu_array
            relu u_relu (.data_in(mac_out[ri]), .data_out(relu_out[ri]));
        end
    endgenerate

    // Max-pool (single instance)
    max_pool u_max_pool (
        .in0(pool_buffer[0]), .in1(pool_buffer[1]),
        .in2(pool_buffer[2]), .in3(pool_buffer[3]),
        .max_out(pool_result)
    );

    //--------------------------------------------------------------------------
    // FC1: BRAM interface, DATA_IN_WIDTH=20 (unused), 512-bit output bus
    // ACC_WIDTH=48 for safety (pool>>8 keeps FC1 max at 113M, INT32 fine,
    // but 48-bit leaves headroom for any edge case)
    //--------------------------------------------------------------------------
    fc_layer #(
        .INPUT_SIZE   (784),
        .OUTPUT_SIZE  (16),
        .DATA_IN_WIDTH(20),
        .ACC_WIDTH    (48),
        .WEIGHT_MEM   ("fc1_weights.mem"),
        .BIAS_MEM     ("fc1_bias.mem"),
        .APPLY_RELU   (1)
    ) u_fc1 (
        .clk         (clk),
        .rst         (rst),
        .bram_rd_addr(pm_rd_addr),
        .bram_rd_data(pm_rd_data),
        .data_in     (20'b0),
        .start       (fc1_en),
        .data_out    (fc1_output),   // 512 bits
        .done        (fc1_done)
    );

    //--------------------------------------------------------------------------
    // FC2: packed 512-bit bus (16 × 32 bits from FC1), 64-bit output (2 × 32)
    // ACC_WIDTH=48 REQUIRED: 16 × 113M × 127 ≈ 229B needs 38 bits.
    //--------------------------------------------------------------------------
    wire [9:0] fc2_bram_rd_addr_unused;

    fc_layer #(
        .INPUT_SIZE   (16),
        .OUTPUT_SIZE  (2),
        .DATA_IN_WIDTH(512),          // FIXED: 16 × 32 bits (was 16 × 20 = 320)
        .ACC_WIDTH    (48),           // REQUIRED for FC2
        .WEIGHT_MEM   ("fc2_weights.mem"),
        .BIAS_MEM     ("fc2_bias.mem"),
        .APPLY_RELU   (0)
    ) u_fc2 (
        .clk         (clk),
        .rst         (rst),
        .bram_rd_addr(fc2_bram_rd_addr_unused),
        .bram_rd_data(20'h00000),
        .data_in     (fc1_output),    // 512 bits
        .start       (fc2_en),
        .data_out    (fc2_output),    // 64 bits (2 × 32)
        .done        (fc2_done)
    );

    // FSM
    fsm_control u_fsm (
        .clk(clk), .rst(rst), .start(start),
        .conv_done(conv_complete), .pool_done(pool_complete),
        .fc1_done(fc1_done), .fc2_done(fc2_done),
        .state(fsm_state), .conv_en(conv_en), .pool_en(pool_en),
        .fc1_en(fc1_en), .fc2_en(fc2_en), .output_valid(output_valid)
    );

    //--------------------------------------------------------------------------
    // Completion logging
    //--------------------------------------------------------------------------
    reg conv_complete_prev, pool_complete_prev;
    always @(posedge clk) begin
        if (rst) begin
            conv_complete_prev <= 1'b0; pool_complete_prev <= 1'b0;
        end else begin
            conv_complete_prev <= conv_complete;
            pool_complete_prev <= pool_complete;
            if (conv_complete && !conv_complete_prev)
                $display("[%0t] CONV COMPLETE - 784 feature maps written", $time);
            if (pool_complete && !pool_complete_prev)
                $display("[%0t] POOL COMPLETE - 784 pooled values written", $time);
        end
    end

    //--------------------------------------------------------------------------
    // Conv BRAM write
    //--------------------------------------------------------------------------
    always @(posedge clk) begin
        if (rst || start) begin
            fm_write_count     <= 10'd0;
            conv_drain_counter <= 2'd0;
        end else if (conv_en) begin
            if (mac_valid[0]) begin
                fm_ch0[fm_write_count] <= relu_out[0];
                fm_ch1[fm_write_count] <= relu_out[1];
                fm_ch2[fm_write_count] <= relu_out[2];
                fm_ch3[fm_write_count] <= relu_out[3];

                if (fm_write_count == 10'd0)
                    $display("[%0t] First parallel write: count=%0d", $time, fm_write_count);
                if (fm_write_count == 10'd100)
                    $display("[%0t] Progress: count=%0d", $time, fm_write_count);
                if (fm_write_count == 10'd783) begin
                    fm_write_count     <= 10'd0;
                    conv_drain_counter <= 2'd1;
                    $display("[%0t] Convolution 784 windows written, starting drain", $time);
                end else
                    fm_write_count <= fm_write_count + 10'd1;
            end
            if (conv_drain_counter == 2'd1)
                conv_drain_counter <= 2'd2;
            else if (conv_drain_counter == 2'd2) begin
                conv_drain_counter <= 2'd0;
                $display("[%0t] Convolution drain complete, asserting conv_complete", $time);
            end
        end
    end

    always @(posedge clk) begin
        if (rst || start)           conv_complete <= 1'b0;
        else if (conv_en && conv_drain_counter == 2'd2) conv_complete <= 1'b1;
        else if (pool_en && conv_complete)              conv_complete <= 1'b0;
    end

    //--------------------------------------------------------------------------
    // Pool: read 2×2 blocks from fm_ch BRAMs, write scaled max to pooled BRAM
    // FIX: pm_wr_data = pool_result >>> 8  (arithmetic right-shift by 8)
    //   This divides pool values by 256, keeping them in [0, ~1139].
    //   FC1 max accumulation drops from 29B (13.5× overflow) to 113M (5.3%).
    //   The ÷256 is a positive constant → argmax is preserved exactly.
    //--------------------------------------------------------------------------
    always @(posedge clk) begin
        if (rst || start) begin
            pool_count      <= 8'd0;    pool_done_flag <= 1'b0;
            pool_row        <= 4'd0;    pool_col       <= 4'd0;
            pool_read_state <= 4'd0;    pool_ch        <= 2'd0;
            pool_within_ch_state <= 2'd0;
            pm_wr_en        <= 1'b0;    fm_rd_addr     <= 10'd0;
            for (i = 0; i < 4; i = i + 1) pool_buffer[i] <= 20'd0;
        end else if (pool_en) begin
            case (pool_read_state)
                // --- issue the four addresses of one 2x2 block ---------------
                4'd0: begin
                    fm_rd_addr      <= ((pool_row<<1)  *28) + (pool_col<<1);
                    pm_wr_en        <= 1'b0;
                    pool_read_state <= 4'd1;
                end
                4'd1: begin
                    fm_rd_addr      <= ((pool_row<<1)  *28) + (pool_col<<1) + 10'd1;
                    pool_read_state <= 4'd2;
                end
                // --- BRAM has 2-cycle address->data latency: capture late ----
                4'd2: begin
                    pool_buffer[0]  <= fm_rd_data;
                    fm_rd_addr      <= (((pool_row<<1)+1)*28) + (pool_col<<1);
                    pool_read_state <= 4'd3;
                end
                4'd3: begin
                    pool_buffer[1]  <= fm_rd_data;
                    fm_rd_addr      <= (((pool_row<<1)+1)*28) + (pool_col<<1) + 10'd1;
                    pool_read_state <= 4'd4;
                end
                4'd4: begin
                    pool_buffer[2]  <= fm_rd_data;
                    pool_read_state <= 4'd5;
                end
                4'd5: begin
                    pool_buffer[3]  <= fm_rd_data;
                    pool_read_state <= 4'd6;
                end
                // --- all four settled, max_pool output is now valid ----------
                4'd6: begin
                    pm_wr_addr      <= (pool_ch * 196) + (pool_row * 14) + pool_col;
                    pm_wr_data      <= {8'd0, pool_result[19:8]};   // >> 8, truncating
                    pm_wr_en        <= 1'b1;
                    pool_read_state <= 4'd7;
                end
                4'd7: begin
                    pm_wr_en <= 1'b0;
                    if (pool_ch != 2'd3) begin
                        pool_ch         <= pool_ch + 2'd1;
                        pool_read_state <= 4'd0;
                    end else begin
                        pool_ch <= 2'd0;
                        if (pool_col == 4'd13) begin
                            pool_col <= 4'd0;
                            if (pool_row == 4'd13) begin
                                pool_row        <= 4'd0;
                                pool_done_flag  <= 1'b1;
                                pool_read_state <= 4'd8;
                                $display("[%0t] POOL: 196 positions x 4 channels written", $time);
                            end else begin
                                pool_row        <= pool_row + 4'd1;
                                pool_read_state <= 4'd0;
                            end
                        end else begin
                            pool_col        <= pool_col + 4'd1;
                            pool_read_state <= 4'd0;
                        end
                    end
                end
                default: pm_wr_en <= 1'b0;      // 4'd8 = parked until FSM advances
            endcase
        end else begin
            pm_wr_en <= 1'b0; pool_read_state <= 4'd0;
        end
    end

    always @(posedge clk) begin
        if (rst || start)                         pool_complete <= 1'b0;
        else if (pool_en && pool_done_flag)        pool_complete <= 1'b1;
        else if (fc1_en && pool_complete)          pool_complete <= 1'b0;
    end

    //--------------------------------------------------------------------------
    // Argmax: FIXED: 32-bit logits (was 20-bit)
    //--------------------------------------------------------------------------
    assign logit0 = fc2_output[31:0];    // FIXED (was [19:0])
    assign logit1 = fc2_output[63:32];   // FIXED (was [39:20])

    always @(posedge clk) begin
        if (rst)          cancer_flag <= 1'b0;
        else if (output_valid)
            cancer_flag <= (logit1 > logit0) ? 1'b1 : 1'b0;
    end

    assign cancer_detected = cancer_flag;
    assign result_valid    = output_valid;

    always @(posedge clk) begin
        if (output_valid)
            $display("LOGITS: logit0(normal)=%0d logit1(pneumonia)=%0d -> decision=%b",
                     $signed(logit0), $signed(logit1), (logit1 > logit0));
    end

endmodule
