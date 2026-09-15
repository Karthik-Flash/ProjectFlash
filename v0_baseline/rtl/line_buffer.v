`timescale 1ns / 1ps
//==============================================================================
// line_buffer.v  -- V5 (ProjectFlash) : correctly aligned 3x3 window generator
//
// WHAT WAS WRONG IN V3
// --------------------
//  (1) The window's bottom-right tap read row2[col_wr+1], a location that had
//      NOT yet been written for the current row. It still held the pixel from
//      the PREVIOUS row, so every single 3x3 window had one corrupt tap.
//  (2) The window was emitted centred on (row_wr-1, col_wr). Over 784 input
//      pixels that produces centres for image rows -1..26. Image row 27 was
//      never convolved at all, and an all-padding row was written into feature
//      map row 0. The whole feature map was shifted up by one row.
//
// HOW THIS VERSION WORKS
// ----------------------
//  Padding is no longer synthesised with comparators. The caller streams a
//  PRE-PADDED (IMG_WIDTH x IMG_WIDTH) frame -- for a 28x28 image that is a
//  30x30 frame with a zero border. This module is then a pure "valid window"
//  generator with no border special-cases, which is exactly what makes it
//  bit-identical to torch.nn.Conv2d(padding=1).
//
//  Two line stores (lb1 = row r-1, lb2 = row r-2) feed three 3-deep tap
//  registers. After pixel (r,c) is clocked in, the taps hold columns
//  c, c-1, c-2 of rows r, r-1, r-2, i.e. a window centred on (r-1, c-1).
//  That window is real data whenever r >= 2 and c >= 2, which yields exactly
//  (IMG_WIDTH-2)^2 = 784 windows for a 30x30 padded frame.
//
//  Window bit order (MSB first) matches conv_weights[0..8]:
//      top-left top-centre top-right  mid-left mid-centre mid-right
//      bot-left bot-centre bot-right
//==============================================================================

module line_buffer #(
    parameter IMG_WIDTH = 30          // PADDED frame width (28 + 2)
)(
    input  wire       clk,
    input  wire       rst,
    input  wire       start,
    input  wire [7:0] pixel_in,
    input  wire       pixel_valid,
    output reg [71:0] window_out,
    output reg        window_valid
);

    // Line stores. lb1 returns the pixel one row back, lb2 two rows back.
    (* ram_style = "distributed" *) reg [7:0] lb1 [0:IMG_WIDTH-1];
    (* ram_style = "distributed" *) reg [7:0] lb2 [0:IMG_WIDTH-1];

    // Column taps. *_0 is the newest column, *_1 one back, *_2 two back.
    reg [7:0] t0_0, t0_1;             // current row   (r)
    reg [7:0] t1_0, t1_1;             // one row back  (r-1)
    reg [7:0] t2_0, t2_1;             // two rows back (r-2)

    reg [5:0] col, row;

    // Old contents at this column, read before they are overwritten below.
    wire [7:0] d1 = lb1[col];         // row r-1, column c
    wire [7:0] d2 = lb2[col];         // row r-2, column c

    integer m;

    always @(posedge clk) begin
        if (rst || start) begin
            col          <= 6'd0;
            row          <= 6'd0;
            window_out   <= 72'd0;
            window_valid <= 1'b0;
            t0_0 <= 8'd0; t0_1 <= 8'd0;
            t1_0 <= 8'd0; t1_1 <= 8'd0;
            t2_0 <= 8'd0; t2_1 <= 8'd0;
            for (m = 0; m < IMG_WIDTH; m = m + 1) begin
                lb1[m] <= 8'd0;
                lb2[m] <= 8'd0;
            end

        end else if (!pixel_valid) begin
            window_valid <= 1'b0;

        end else begin
            // Push the column down one row in each store.
            lb2[col] <= d1;
            lb1[col] <= pixel_in;

            // Shift the column taps.
            t0_1 <= t0_0;  t0_0 <= pixel_in;
            t1_1 <= t1_0;  t1_0 <= d1;
            t2_1 <= t2_0;  t2_0 <= d2;

            // Assemble the window from the values the taps are ABOUT to hold.
            window_out <= { t2_1, t2_0, d2,          // row r-2 : c-2 c-1 c
                            t1_1, t1_0, d1,          // row r-1
                            t0_1, t0_0, pixel_in };  // row r

            // Centre (r-1, c-1) is inside the padded frame once r>=2 and c>=2.
            window_valid <= (row >= 6'd2) && (col >= 6'd2);

            if (col == IMG_WIDTH-1) begin
                col <= 6'd0;
                row <= row + 6'd1;
            end else begin
                col <= col + 6'd1;
            end
        end
    end

endmodule
